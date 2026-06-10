import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Proxies an MPEG-TS stream through system ffmpeg to fix codec detection.
///
/// media_kit's bundled FFmpeg cannot detect EAC-3 audio with non-standard
/// MPEG-TS codec tag 0x0087. System ffmpeg (7.x) handles this correctly.
/// This proxy pipes the stream through system ffmpeg with `-c copy` (no
/// transcoding) and serves it on a local HTTP port for mpv to play.
class StreamProxy {
  static const int _maxBufferChunks = 64;
  HttpServer? _server;
  Process? _ffmpeg;
  String? _activeUrl;
  int? _port;
  String? _hlsTempDir;
  final List<HttpResponse> _clients = [];

  /// Whether the proxy is currently running.
  bool get isRunning => _server != null;

  /// The local URL to play from, or null if not running.
  String? get localUrl => _port != null ? 'http://127.0.0.1:$_port/' : null;

  /// Start proxying a remote stream URL.
  /// Returns the local URL that the player should use.
  Future<String?> start(String remoteUrl) async {
    // Stop any existing proxy
    await stop();

    // Check if ffmpeg is available
    final ffmpegPath = await _findFfmpeg();

    try {
      // Start local HTTP server on a random port
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      _activeUrl = remoteUrl;

      if (ffmpegPath != null) {
        await _startFfmpegProxy(ffmpegPath, remoteUrl);
      } else {
        _startDirectProxy(remoteUrl);
      }

      // Wait briefly for proxy to start producing data
      await Future<void>.delayed(const Duration(seconds: 1));

      debugPrint('[StreamProxy] Started on port $_port for $remoteUrl');
      return localUrl;
    } catch (e) {
      debugPrint('[StreamProxy] Failed to start: $e');
      await stop();
      return null;
    }
  }

  Future<void> _startFfmpegProxy(String ffmpegPath, String remoteUrl) async {
    // Start ffmpeg: read remote stream, copy codecs, output mpegts to stdout
    _ffmpeg = await Process.start(ffmpegPath, [
      '-hide_banner',
      '-loglevel',
      'warning',
      '-reconnect',
      '1',
      '-reconnect_streamed',
      '1',
      '-reconnect_delay_max',
      '5',
      '-i',
      remoteUrl,
      '-c',
      'copy',
      '-f',
      'mpegts',
      'pipe:1',
    ]);

    // Log ffmpeg stderr for debugging
    _ffmpeg!.stderr.transform(const SystemEncoding().decoder).listen((line) {
      if (line.trim().isNotEmpty) {
        debugPrint('[StreamProxy] ffmpeg: ${line.trim()}');
      }
    });

    // Handle ffmpeg exit
    _ffmpeg!.exitCode.then((code) {
      if (code != 0 && _activeUrl != null) {
        debugPrint('[StreamProxy] ffmpeg exited with code $code');
      }
    });

    _serveFromStream(_ffmpeg!.stdout.asBroadcastStream());
  }

  void _startDirectProxy(String remoteUrl) {
    // No ffmpeg — fetch the remote stream and serve it directly
    // We use a single HttpClient connection that stays open
    _serveFromStream(null, remoteUrl: remoteUrl);
  }

  void _serveFromStream(Stream<List<int>>? broadcast, {String? remoteUrl}) {
    // Buffer data so late-connecting clients get stream headers
    final dataBuffer = <List<int>>[];

    if (broadcast != null) {
      // ffmpeg mode — use the broadcast stream
      broadcast.listen((data) {
        dataBuffer.add(data);
        if (dataBuffer.length > _maxBufferChunks) {
          dataBuffer.removeAt(0);
        }
      });
      _serveHttp(dataBuffer, broadcast);
    } else if (remoteUrl != null) {
      // Direct proxy mode — fetch the remote URL and pipe it
      _startDirectFetch(remoteUrl, dataBuffer);
    }
  }

  Future<void> _startDirectFetch(
    String remoteUrl,
    List<List<int>> dataBuffer,
  ) async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(remoteUrl));
      final response = await request.close();

      final broadcast = response.asBroadcastStream();
      broadcast.listen((data) {
        dataBuffer.add(data);
        if (dataBuffer.length > _maxBufferChunks) {
          dataBuffer.removeAt(0);
        }
      });

      _serveHttp(
        dataBuffer,
        broadcast,
        onDone: () => client.close(force: true),
      );
    } catch (e) {
      debugPrint('[StreamProxy] Direct fetch failed: $e');
    }
  }

  void _serveHttp(
    List<List<int>> dataBuffer,
    Stream<List<int>> broadcast, {
    VoidCallback? onDone,
  }) {
    _server!.listen((request) {
      request.response.headers.contentType = ContentType('video', 'mp2t');
      request.response.headers.set('Connection', 'close');
      request.response.bufferOutput = false;
      _clients.add(request.response);

      // Send buffered data first so client gets stream headers
      for (final chunk in dataBuffer) {
        try {
          request.response.add(chunk);
        } catch (_) {}
      }

      final sub = broadcast.listen(
        (data) {
          try {
            request.response.add(data);
          } catch (_) {}
        },
        onDone: () {
          try {
            request.response.close();
          } catch (_) {}
          _clients.remove(request.response);
          onDone?.call();
        },
        onError: (_) {
          try {
            request.response.close();
          } catch (_) {}
          _clients.remove(request.response);
        },
        cancelOnError: true,
      );

      request.response.done
          .then((_) {
            sub.cancel();
            _clients.remove(request.response);
          })
          .catchError((_) {
            sub.cancel();
            _clients.remove(request.response);
          });
    });
  }

  /// Start proxying a .ts stream as HLS for Chromecast compatibility.
  /// Chromecast only supports HLS, DASH, and MP4 — not raw MPEG-TS.
  /// This transcodes the stream to HLS format via ffmpeg.
  Future<String?> startHlsTranscode(String remoteUrl) async {
    // Stop any existing proxy
    await stop();

    // Check if ffmpeg is available
    final ffmpegPath = await _findFfmpeg();
    if (ffmpegPath == null) {
      debugPrint('[StreamProxy] ffmpeg not found — cannot transcode to HLS');
      return null;
    }

    try {
      // Create temp directory for HLS segments
      final tempDir = await Directory.systemTemp.createTemp('naritta_hls_');
      _hlsTempDir = tempDir.path;
      debugPrint('[StreamProxy] HLS temp dir: $_hlsTempDir');

      // Start local HTTP server on a random port
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      _activeUrl = remoteUrl;

      final playlistPath = '$_hlsTempDir/playlist.m3u8';
      final segmentPath = '$_hlsTempDir/segment_%03d.ts';

      // Start ffmpeg: read remote .ts stream, transcode to HLS
      _ffmpeg = await Process.start(ffmpegPath, [
        '-hide_banner',
        '-loglevel', 'warning',
        '-reconnect', '1',
        '-reconnect_streamed', '1',
        '-reconnect_delay_max', '5',
        '-i', remoteUrl,
        // Video: H.264 (Chromecast compatible)
        '-c:v', 'libx264',
        '-preset', 'ultrafast',
        '-crf', '23',
        // Audio: AAC (Chromecast compatible)
        '-c:a', 'aac',
        '-b:a', '128k',
        // HLS output settings
        '-f', 'hls',
        '-hls_time', '6',
        '-hls_list_size', '5',
        '-hls_flags', 'delete_segments',
        '-hls_segment_filename', segmentPath,
        playlistPath,
      ]);

      // Log ffmpeg stderr for debugging
      _ffmpeg!.stderr.transform(const SystemEncoding().decoder).listen((line) {
        if (line.trim().isNotEmpty) {
          debugPrint('[StreamProxy] ffmpeg HLS: ${line.trim()}');
        }
      });

      // Handle ffmpeg exit
      _ffmpeg!.exitCode.then((code) {
        if (code != 0 && _activeUrl != null) {
          debugPrint('[StreamProxy] ffmpeg HLS exited with code $code');
        }
      });

      // Serve the HLS playlist and segments via HTTP
      _serveHlsPlaylist();

      // Wait for HLS to initialize
      await Future<void>.delayed(const Duration(seconds: 4));

      debugPrint(
        '[StreamProxy] HLS transcode started on port $_port for $remoteUrl',
      );
      return localUrl;
    } catch (e) {
      debugPrint('[StreamProxy] HLS transcode failed: $e');
      await stop();
      return null;
    }
  }

  void _serveHlsPlaylist() {
    _server!.listen((request) {
      final uri = request.uri;
      final path = uri.path;

      // Serve the main playlist
      if (path == '/' || path == '/playlist.m3u8') {
        _serveHlsFile(
          request,
          '$_hlsTempDir/playlist.m3u8',
          'application/vnd.apple.mpegurl',
        );
      }
      // Serve HLS segments
      else if (path.startsWith('/segment_') && path.endsWith('.ts')) {
        final filename = path.substring(1); // Remove leading /
        _serveHlsFile(request, '$_hlsTempDir/$filename', 'video/MP2T');
      }
      // Default: serve playlist
      else {
        _serveHlsFile(
          request,
          '$_hlsTempDir/playlist.m3u8',
          'application/vnd.apple.mpegurl',
        );
      }
    });
  }

  Future<void> _serveHlsFile(
    HttpRequest request,
    String filepath,
    String mimeType,
  ) async {
    try {
      final file = File(filepath);
      if (await file.exists()) {
        request.response.headers.contentType = ContentType.parse(mimeType);
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.headers.set('Cache-Control', 'no-cache, no-store');
        await request.response.addStream(file.openRead());
        await request.response.close();
      } else {
        debugPrint('[StreamProxy] HLS file not found: $filepath');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e) {
      debugPrint('[StreamProxy] Error serving HLS file $filepath: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  /// Stop the proxy and clean up.
  Future<void> stop() async {
    _activeUrl = null;
    _port = null;

    // Close HTTP clients
    for (final client in _clients) {
      try {
        client.close();
      } catch (_) {}
    }
    _clients.clear();

    // Kill ffmpeg
    if (_ffmpeg != null) {
      try {
        _ffmpeg!.kill(ProcessSignal.sigterm);
      } catch (_) {}
      _ffmpeg = null;
    }

    // Close HTTP server
    if (_server != null) {
      try {
        await _server!.close(force: true);
      } catch (_) {}
      _server = null;
    }

    // Clean up HLS temp directory
    if (_hlsTempDir != null) {
      try {
        final dir = Directory(_hlsTempDir!);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          debugPrint('[StreamProxy] Cleaned up temp dir: $_hlsTempDir');
        }
      } catch (e) {
        debugPrint('[StreamProxy] Error cleaning temp dir: $e');
      }
      _hlsTempDir = null;
    }
  }

  /// Find ffmpeg binary on the system.
  static Future<String?> _findFfmpeg() async {
    // Check common locations
    const paths = [
      '/opt/homebrew/bin/ffmpeg', // macOS Apple Silicon
      '/usr/local/bin/ffmpeg', // macOS Intel / Linux
      '/usr/bin/ffmpeg', // Linux system
    ];

    for (final path in paths) {
      if (await File(path).exists()) return path;
    }

    // Try PATH lookup
    try {
      final result = await Process.run('which', ['ffmpeg']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
    } catch (_) {}

    return null;
  }
}
