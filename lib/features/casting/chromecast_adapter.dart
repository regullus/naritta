import 'dart:async';
import 'dart:io';

import 'package:flutter_chrome_cast/cast_context.dart';
import 'package:flutter_chrome_cast/discovery.dart';
import 'package:flutter_chrome_cast/session.dart';
import 'package:flutter_chrome_cast/media.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_chrome_cast/enums.dart';
import 'package:logger/logger.dart';

import '../player/stream_proxy.dart';

final _log = Logger(printer: SimplePrinter());

/// Wraps the flutter_chrome_cast (Google Cast) API into a simpler interface
/// that integrates with the existing CastService architecture.
class ChromecastAdapter {
  bool _initialized = false;
  bool _discovering = false;
  StreamSubscription<GoogleCastSession?>? _sessionSub;
  final StreamProxy _proxy = StreamProxy();

  /// Stream of discovered Chromecast devices.
  final _devicesStreamController =
      StreamController<List<GoogleCastDevice>>.broadcast();
  Stream<List<GoogleCastDevice>> get devicesStream =>
      _devicesStreamController.stream;

  /// The currently active session.
  GoogleCastSession? _currentSession;

  /// Whether we are connected to a Chromecast device.
  bool get isConnected =>
      GoogleCastSessionManager.instance.connectionState ==
      GoogleCastConnectState.connected;

  /// The current session if connected.
  GoogleCastSession? get currentSession => _currentSession;

  /// Initialize the Google Cast context.
  /// Must be called once before any other operations.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final options = GoogleCastOptions(
        appId: 'CC1AD845',
        stopCastingOnAppTerminated: false,
        disableDiscoveryAutostart: true,
      );
      await GoogleCastContext.instance.setSharedInstanceWithOptions(options);

      _sessionSub = GoogleCastSessionManager.instance.currentSessionStream
          .listen((session) {
            _currentSession = session;
            _log.i(
              'Chromecast session: ${session?.device?.friendlyName ?? "none"}',
            );
          });

      _initialized = true;
      _log.i('Chromecast adapter initialized');
    } catch (e) {
      _log.e('Failed to initialize Chromecast: $e');
    }
  }

  StreamSubscription<List<GoogleCastDevice>>? _discoverySub;

  /// Start discovering Chromecast devices on the network.
  void startDiscovery() {
    if (!_initialized) return;
    if (_discovering) return;
    _discovering = true;

    GoogleCastDiscoveryManager.instance.startDiscovery();

    // Listen for device changes and forward to our stream
    _discoverySub?.cancel();
    _discoverySub = GoogleCastDiscoveryManager.instance.devicesStream.listen((
      devices,
    ) {
      _devicesStreamController.add(devices);
    });
  }

  /// Stop discovering Chromecast devices.
  void stopDiscovery() {
    if (!_discovering) return;
    _discovering = false;
    try {
      GoogleCastDiscoveryManager.instance.stopDiscovery();
    } catch (e) {
      _log.e('Error stopping discovery: $e');
    }
  }

  /// Connect to a Chromecast device and wait for the session to establish.
  Future<bool> connectToDevice(GoogleCastDevice device) async {
    try {
      // If already connected and on same device, skip
      if (isConnected && _currentSession?.device?.deviceID == device.deviceID) {
        _log.i('Already connected to ${device.friendlyName}');
        return true;
      }

      // Disconnect any existing session first
      if (isConnected) {
        await disconnect();
      }

      // Wait for the session to become connected
      final sessionReady = GoogleCastSessionManager
          .instance
          .currentSessionStream
          .firstWhere(
            (session) =>
                session != null &&
                session.device?.deviceID == device.deviceID &&
                session.connectionState == GoogleCastConnectState.connected,
          );

      await GoogleCastSessionManager.instance.startSessionWithDevice(device);

      // Wait up to 15 seconds for the session to establish
      await sessionReady.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
          'Chromecast session did not connect within 15s',
        ),
      );

      _log.i('Connected to Chromecast: ${device.friendlyName}');
      return true;
    } catch (e) {
      _log.e('Failed to connect to Chromecast: $e');
      return false;
    }
  }

  /// Disconnect from the current Chromecast device.
  Future<void> disconnect() async {
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
      _log.i('Disconnected from Chromecast');
    } catch (e) {
      _log.e('Error disconnecting Chromecast: $e');
    }
    await _proxy.stop();
  }

  /// Try to convert a .ts URL to .m3u8 by changing the extension.
  /// Many Xtream providers serve the same content at both paths.
  String? _tryM3u8FromTs(String url) {
    if (url.endsWith('.ts')) {
      return '${url.substring(0, url.length - 3)}.m3u8';
    }
    // Also handle URLs with query params like streamId.ts?token=abc
    final tsQueryMatch = RegExp(r'^(.*\.ts)(\?.*)?$').firstMatch(url);
    if (tsQueryMatch != null) {
      final base = tsQueryMatch.group(1)!;
      final query = tsQueryMatch.group(2) ?? '';
      return '${base.substring(0, base.length - 3)}.m3u8$query';
    }
    return null;
  }

  /// Probe whether a URL returns valid content by making a HEAD request.
  /// Returns true if the server responds with a success status.
  Future<bool> _urlExists(String url) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.headUrl(Uri.parse(url));
      // Some IPTV servers don't support HEAD, try GET with early close
      request.followRedirects = true;
      final response = await request.close();
      final success = response.statusCode >= 200 && response.statusCode < 400;
      client.close(force: true);
      return success;
    } catch (e) {
      _log.w('URL probe failed for $url: $e');
      return false;
    }
  }

  /// Internal helper: cast a URL to the Chromecast with the given content type.
  Future<bool> _castDirect(
    String castUrl, {
    required String contentType,
    required String title,
    required bool isLive,
  }) async {
    try {
      _log.i('Casting URL: $castUrl');
      _log.i('Content type: $contentType');
      _log.i('Stream type: ${isLive ? "live" : "buffered"}');

      final mediaInfo = GoogleCastMediaInformation(
        contentId: castUrl,
        streamType: isLive
            ? CastMediaStreamType.live
            : CastMediaStreamType.buffered,
        contentUrl: Uri.parse(castUrl),
        contentType: contentType,
        metadata: GoogleCastMovieMediaMetadata(
          title: title.isNotEmpty ? title : 'IPTV Stream',
          images: [],
        ),
      );

      await GoogleCastRemoteMediaClient.instance.loadMedia(mediaInfo);
      _log.i('Successfully sent load command to Chromecast');
      return true;
    } catch (e, stackTrace) {
      _log.e('_castDirect failed: $e\n$stackTrace');
      return false;
    }
  }

  /// Cast a stream URL to the connected Chromecast device.
  ///
  /// Chromecast only supports: HLS (.m3u8), DASH (.mpd), MP4, WebM
  /// For .ts streams (common in Xtream Live TV), uses a multi-strategy approach:
  /// 1. Try converting .ts → .m3u8 (many Xtream providers serve both)
  /// 2. Fall back to proxying via local ffmpeg (remuxes .ts → HLS for Chromecast)
  /// 3. Last resort: send raw .ts with video/mp2t content type
  Future<bool> castStream(String url, {String title = ''}) async {
    try {
      // Detect stream type
      final isHls =
          url.endsWith('.m3u8') ||
          url.contains('.m3u8') ||
          url.contains('type=m3u8');
      final isMp4 = url.endsWith('.mp4') || url.endsWith('.mkv');
      final isDash = url.endsWith('.mpd');
      // Detect .ts streams more broadly: Xtream Live TV URLs end in .ts
      final isTs =
          url.endsWith('.ts') ||
          url.contains('type=.ts') ||
          url.contains('/live/') && url.contains('.ts');

      _log.i('Cast request: url=$url');
      _log.i(
        'Detected: isHls=$isHls, isMp4=$isMp4, isDash=$isDash, isTs=$isTs',
      );

      // HLS / MP4 / DASH: cast directly (native Chromecast support)
      if (isHls) {
        return _castDirect(
          url,
          contentType: 'application/vnd.apple.mpegurl',
          title: title,
          isLive: true,
        );
      }
      if (isMp4) {
        return _castDirect(
          url,
          contentType: 'video/mp4',
          title: title,
          isLive: false,
        );
      }
      if (isDash) {
        return _castDirect(
          url,
          contentType: 'application/dash+xml',
          title: title,
          isLive: true,
        );
      }

      // .ts streams (Live TV) — multi-strategy for Chromecast compatibility
      if (isTs) {
        // Strategy 1: Try converting .ts → .m3u8
        // Many Xtream providers serve the same stream at both extensions
        final m3u8Url = _tryM3u8FromTs(url);
        if (m3u8Url != null) {
          _log.i('Attempting .ts → .m3u8 conversion: $m3u8Url');
          final exists = await _urlExists(m3u8Url);
          if (exists) {
            _log.i('m3u8 variant exists, casting HLS directly');
            return _castDirect(
              m3u8Url,
              contentType: 'application/vnd.apple.mpegurl',
              title: title,
              isLive: true,
            );
          }
          _log.i('m3u8 variant not available, trying ffmpeg HLS transcode');
        }

        // Strategy 2: Use ffmpeg to transcode .ts → HLS
        // Chromecast Default Media Receiver has poor raw MPEG-TS support
        // but excellent HLS support. ffmpeg remuxes to HLS (H.264 + AAC).
        _log.i(
          'Attempting ffmpeg HLS transcode for Chromecast compatibility...',
        );
        final hlsUrl = await _proxy.startHlsTranscode(url);
        if (hlsUrl != null) {
          _log.i('HLS transcode started at $hlsUrl');
          return _castDirect(
            hlsUrl,
            contentType: 'application/vnd.apple.mpegurl',
            title: title,
            isLive: true,
          );
        }

        // Strategy 3 (last resort): Send raw .ts with video/mp2t
        _log.w('HLS transcode unavailable, sending raw .ts as video/mp2t');
        return _castDirect(
          url,
          contentType: 'video/mp2t',
          title: title,
          isLive: true,
        );
      }

      // Unknown format — try as HLS (most common for IPTV)
      _log.w('Unknown stream format, attempting as HLS: $url');
      return _castDirect(
        url,
        contentType: 'application/vnd.apple.mpegurl',
        title: title,
        isLive: true,
      );
    } catch (e, stackTrace) {
      _log.e('Failed to cast stream: $e\n$stackTrace');
      return false;
    }
  }

  /// Pause playback on the Chromecast device.
  Future<void> pause() async {
    try {
      await GoogleCastRemoteMediaClient.instance.pause();
    } catch (e) {
      _log.e('Chromecast pause error: $e');
    }
  }

  /// Resume playback on the Chromecast device.
  Future<void> resume() async {
    try {
      await GoogleCastRemoteMediaClient.instance.play();
    } catch (e) {
      _log.e('Chromecast resume error: $e');
    }
  }

  /// Stop playback on the Chromecast device.
  Future<void> stop() async {
    try {
      await GoogleCastRemoteMediaClient.instance.stop();
    } catch (e) {
      _log.e('Chromecast stop error: $e');
    }
  }

  /// Set volume (0.0 to 1.0) on the connected device.
  Future<void> setDeviceVolume(double volume) async {
    try {
      GoogleCastSessionManager.instance.setDeviceVolume(volume.clamp(0.0, 1.0));
    } catch (e) {
      _log.e('Chromecast volume error: $e');
    }
  }

  /// Get media playback status.
  GoggleCastMediaStatus? get mediaStatus =>
      GoogleCastRemoteMediaClient.instance.mediaStatus;

  /// Dispose resources.
  void dispose() {
    _sessionSub?.cancel();
    _discoverySub?.cancel();
    stopDiscovery();
    _proxy.stop();
    _devicesStreamController.close();
  }
}
