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

  /// Cast a stream URL to the connected Chromecast device.
  ///
  /// Chromecast only supports: HLS (.m3u8), DASH (.mpd), MP4, WebM
  /// For .ts streams, we need to transcode to HLS via ffmpeg proxy.
  Future<bool> castStream(String url, {String title = ''}) async {
    try {
      String castUrl = url;
      String contentType;
      final isHls = url.endsWith('.m3u8');
      final isMp4 = url.endsWith('.mp4');
      final isDash = url.endsWith('.mpd');
      final isTs = url.endsWith('.ts') || url.contains('type=.ts');

      _log.i('Cast request: url=$url, isHls=$isHls, isTs=$isTs');

      // For HLS streams, use directly
      if (isHls) {
        contentType = 'application/vnd.apple.mpegurl';
        _log.i('Using HLS stream directly');
      }
      // For MP4 streams, use directly
      else if (isMp4) {
        contentType = 'video/mp4';
        _log.i('Using MP4 stream directly');
      }
      // For DASH streams, use directly
      else if (isDash) {
        contentType = 'application/dash+xml';
        _log.i('Using DASH stream directly');
      }
      // For .ts streams, transcode to HLS via proxy
      else if (isTs) {
        _log.i('Detected .ts stream, transcoding to HLS for Chromecast...');

        final proxyUrl = await _proxy.startHlsTranscode(url);
        if (proxyUrl != null) {
          String? lanIp = await _getLanIp();

          if (lanIp != null) {
            castUrl = proxyUrl.replaceFirst('127.0.0.1', lanIp);
            contentType = 'application/vnd.apple.mpegurl';
            _log.i('Using HLS transcode proxy: $castUrl (LAN IP: $lanIp)');
          } else {
            _log.e('No LAN IP found — cannot proxy .ts stream to Chromecast');
            return false;
          }
        } else {
          _log.e(
            'StreamProxy HLS transcode failed — Chromecast cannot play .ts directly',
          );
          return false;
        }
      }
      // Unknown format - try as HLS
      else {
        _log.w('Unknown stream format, attempting as HLS: $url');
        contentType = 'application/vnd.apple.mpegurl';
      }

      _log.i('Casting to Chromecast: url=$castUrl, type=$contentType');

      final mediaInfo = GoogleCastMediaInformation(
        contentId: castUrl,
        streamType: isTs || isHls
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
      _log.e('Failed to cast stream: $e\n$stackTrace');
      return false;
    }
  }

  /// Get the device's LAN IP address
  Future<String?> _getLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(includeLinkLocal: false);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              !addr.isMulticast) {
            if (!addr.address.startsWith('169.254.')) {
              _log.i('Found LAN IP: ${addr.address}');
              return addr.address;
            }
          }
        }
      }
      _log.w('No suitable LAN IP found');
      return null;
    } catch (e) {
      _log.e('Error getting LAN IP: $e');
      return null;
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
