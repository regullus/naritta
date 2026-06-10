import 'dart:async';

import 'package:flutter_chrome_cast/cast_context.dart';
import 'package:flutter_chrome_cast/discovery.dart';
import 'package:flutter_chrome_cast/session.dart';
import 'package:flutter_chrome_cast/media.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_chrome_cast/enums.dart';
import 'package:logger/logger.dart';

final _log = Logger(printer: SimplePrinter());

/// Wraps the flutter_chrome_cast (Google Cast) API into a simpler interface
/// that integrates with the existing CastService architecture.
class ChromecastAdapter {
  bool _initialized = false;
  bool _discovering = false;
  StreamSubscription<GoogleCastSession?>? _sessionSub;

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
        _log.i('Chromecast session: ${session?.device?.friendlyName ?? "none"}');
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
    _discoverySub =
        GoogleCastDiscoveryManager.instance.devicesStream.listen((devices) {
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
      if (isConnected &&
          _currentSession?.device?.deviceID == device.deviceID) {
        _log.i('Already connected to ${device.friendlyName}');
        return true;
      }

      // Disconnect any existing session first
      if (isConnected) {
        await disconnect();
      }

      // Wait for the session to become connected
      final sessionReady = GoogleCastSessionManager.instance
          .currentSessionStream
          .firstWhere(
        (session) =>
            session != null &&
            session.device?.deviceID == device.deviceID &&
            session.connectionState == GoogleCastConnectState.connected,
      );

      await GoogleCastSessionManager.instance
          .startSessionWithDevice(device);

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
  }

  /// Cast an HLS stream URL to the connected Chromecast device.
  Future<bool> castStream(String url, {String title = ''}) async {
    try {
      final mediaInfo = GoogleCastMediaInformation(
        contentId: url,
        streamType: CastMediaStreamType.live,
        contentUrl: Uri.parse(url),
        contentType: 'application/x-mpegURL',
        metadata: GoogleCastMovieMediaMetadata(
          title: title.isNotEmpty ? title : 'IPTV Stream',
          images: [],
        ),
      );

      await GoogleCastRemoteMediaClient.instance.loadMedia(mediaInfo);
      _log.i('Casting stream: $url');
      return true;
    } catch (e) {
      _log.e('Failed to cast stream: $e');
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
      GoogleCastSessionManager.instance
          .setDeviceVolume(volume.clamp(0.0, 1.0));
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
    _devicesStreamController.close();
  }
}
