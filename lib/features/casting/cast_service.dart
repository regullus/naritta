import 'dart:async';

import 'package:flutter_chrome_cast/entities.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import 'chromecast_adapter.dart';
import 'lg_webos_client.dart';

final _log = Logger(printer: SimplePrinter());

/// Represents a discovered cast target on the local network.
class CastDevice {
  final String id;
  final String name;
  final String type; // 'dlna', 'webos', or 'chromecast'
  final DLNADevice? dlnaDevice;
  final LgWebOsClient? webosClient;
  final GoogleCastDevice? chromecastDevice;

  CastDevice({
    required this.id,
    required this.name,
    required this.type,
    this.dlnaDevice,
    this.webosClient,
    this.chromecastDevice,
  });

  @override
  String toString() => '$name ($type)';
}

/// Manages device discovery and casting of IPTV streams
/// via DLNA/UPnP, LG WebOS, and Google Cast (Chromecast).
class CastService {
  // --- DLNA ---
  DLNAManager? _dlnaManager;
  DeviceManager? _deviceManager;
  StreamSubscription? _dlnaSub;

  // --- Chromecast ---
  final ChromecastAdapter _chromecastAdapter = ChromecastAdapter();
  StreamSubscription? _chromecastSub;

  final _devicesController = StreamController<List<CastDevice>>.broadcast();
  final Map<String, CastDevice> _devices = {};

  CastDevice? _activeDevice;
  // ignore: unused_field
  String? _activeUrl;
  bool _isCasting = false;

  /// Stream of discovered cast devices.
  Stream<List<CastDevice>> get devicesStream => _devicesController.stream;

  /// Currently available devices.
  List<CastDevice> get devices => _devices.values.toList();

  /// Whether we are actively casting.
  bool get isCasting => _isCasting;

  /// The device we are casting to.
  CastDevice? get activeDevice => _activeDevice;

  /// Initialize Chromecast support (must be called once).
  Future<void> initChromecast() async {
    await _chromecastAdapter.initialize();
  }

  /// Start scanning for all cast devices (DLNA + Chromecast).
  Future<void> startDiscovery() async {
    await stopDiscovery();
    _devices.clear();

    // Ensure Chromecast adapter is initialized
    await _chromecastAdapter.initialize();

    // --- DLNA Discovery ---
    _dlnaManager = DLNAManager();
    try {
      _deviceManager = await _dlnaManager!.start(reusePort: false);
      _listenToDlnaDevices();
      _log.i('DLNA discovery started');
    } catch (e) {
      _log.e('DLNA discovery failed: $e');
      try {
        _deviceManager = await _dlnaManager!.start(reusePort: true);
        _listenToDlnaDevices();
        _log.i('DLNA discovery started (reusePort fallback)');
      } catch (e2) {
        _log.e('DLNA discovery failed on retry: $e2');
      }
    }

    // --- Chromecast Discovery ---
    _chromecastAdapter.startDiscovery();
    _listenToChromecastDevices();
    _log.i('Chromecast discovery started');
  }

  void _listenToDlnaDevices() {
    _dlnaSub = _deviceManager!.devices.stream.listen((deviceMap) {
      for (final entry in deviceMap.entries) {
        final dlna = entry.value;
        final name = dlna.info.friendlyName;
        _devices[entry.key] = CastDevice(
          id: entry.key,
          name: name.isNotEmpty ? name : 'Unknown Device',
          type: 'dlna',
          dlnaDevice: dlna,
        );
      }
      _devicesController.add(_devices.values.toList());
    });
  }

  void _listenToChromecastDevices() {
    _chromecastSub = _chromecastAdapter.devicesStream.listen((devices) {
      for (final device in devices) {
        final id = 'chromecast_${device.deviceID}';
        _devices[id] = CastDevice(
          id: id,
          name: device.friendlyName,
          type: 'chromecast',
          chromecastDevice: device,
        );
      }
      _devicesController.add(_devices.values.toList());
    });
  }

  /// Stop scanning.
  Future<void> stopDiscovery() async {
    // Stop DLNA
    _dlnaSub?.cancel();
    _dlnaSub = null;
    _dlnaManager?.stop();
    _dlnaManager = null;
    _deviceManager = null;

    // Stop Chromecast
    _chromecastAdapter.stopDiscovery();
    _chromecastSub?.cancel();
    _chromecastSub = null;
  }

  /// Cast a stream URL to the given device.
  Future<bool> castTo(
    CastDevice device,
    String url, {
    String title = '',
  }) async {
    try {
      if (device.type == 'chromecast' && device.chromecastDevice != null) {
        // Connect first if needed
        if (!_chromecastAdapter.isConnected) {
          final connected = await _chromecastAdapter.connectToDevice(
            device.chromecastDevice!,
          );
          if (!connected) return false;
        }
        final success = await _chromecastAdapter.castStream(url, title: title);
        if (success) {
          _activeDevice = device;
          _activeUrl = url;
          _isCasting = true;
          _log.i('Casting to ${device.name} via Chromecast: $url');
          return true;
        }
        return false;
      } else if (device.type == 'webos' && device.webosClient != null) {
        await device.webosClient!.playMedia(url, title: title);
        _activeDevice = device;
        _activeUrl = url;
        _isCasting = true;
        _log.i('Casting to ${device.name} via WebOS: $url');
        return true;
      } else if (device.dlnaDevice != null) {
        await device.dlnaDevice!.setUrl(url, title: title);
        await device.dlnaDevice!.play();
        _activeDevice = device;
        _activeUrl = url;
        _isCasting = true;
        _log.i('Casting to ${device.name} via DLNA: $url');
        return true;
      }
      return false;
    } catch (e) {
      _log.e('Cast failed: $e');
      return false;
    }
  }

  /// Stop casting on the active device.
  Future<void> stopCasting() async {
    try {
      if (_activeDevice?.type == 'chromecast') {
        await _chromecastAdapter.disconnect();
      } else if (_activeDevice?.type == 'webos') {
        await _activeDevice?.webosClient?.stop();
      } else if (_activeDevice?.dlnaDevice != null) {
        await _activeDevice!.dlnaDevice!.stop();
      }
    } catch (e) {
      _log.e('Stop cast error: $e');
    }
    _activeDevice = null;
    _activeUrl = null;
    _isCasting = false;
  }

  /// Pause playback on the active device.
  Future<void> pause() async {
    try {
      if (_activeDevice?.type == 'chromecast') {
        await _chromecastAdapter.pause();
      } else if (_activeDevice?.type == 'webos') {
        await _activeDevice?.webosClient?.pause();
      } else {
        await _activeDevice?.dlnaDevice?.pause();
      }
    } catch (e) {
      _log.e('Cast pause error: $e');
    }
  }

  /// Resume playback on the active device.
  Future<void> resume() async {
    try {
      if (_activeDevice?.type == 'chromecast') {
        await _chromecastAdapter.resume();
      } else if (_activeDevice?.type == 'webos') {
        await _activeDevice?.webosClient?.play();
      } else {
        await _activeDevice?.dlnaDevice?.play();
      }
    } catch (e) {
      _log.e('Cast resume error: $e');
    }
  }

  /// Set volume (0-100) on the active device.
  Future<void> setVolume(int volume) async {
    try {
      if (_activeDevice?.type == 'chromecast') {
        await _chromecastAdapter.setDeviceVolume(volume / 100.0);
      } else if (_activeDevice?.type == 'webos') {
        await _activeDevice?.webosClient?.setVolume(volume.clamp(0, 100));
      } else {
        await _activeDevice?.dlnaDevice?.volume(volume.clamp(0, 100));
      }
    } catch (e) {
      _log.e('Cast volume error: $e');
    }
  }

  /// Switch channel: cast a new URL to the same device.
  Future<bool> switchChannel(String url, {String title = ''}) async {
    if (_activeDevice == null) return false;
    return castTo(_activeDevice!, url, title: title);
  }

  /// Add a device manually by IP address.
  /// Probes for LG WebOS (port 3000) first, then adds as generic DLNA.
  Future<CastDevice?> addManualDevice(String ip) async {
    // Try LG WebOS first
    final isWebOs = await LgWebOsClient.probe(ip);
    if (isWebOs) {
      final client = LgWebOsClient(host: ip);
      final connected = await client.connect();
      String name = 'LG TV ($ip)';
      if (connected) {
        try {
          final info = await client.getSystemInfo();
          final model = info['modelName'] as String? ?? '';
          if (model.isNotEmpty) name = 'LG $model';
        } catch (_) {}
      }
      final device = CastDevice(
        id: 'webos_$ip',
        name: name,
        type: 'webos',
        webosClient: client,
      );
      _devices[device.id] = device;
      _devicesController.add(_devices.values.toList());
      return device;
    }
    return null;
  }

  void dispose() {
    stopCasting();
    stopDiscovery();
    _chromecastAdapter.dispose();
    _devicesController.close();
  }
}

/// Riverpod provider for the cast service (singleton).
final castServiceProvider = Provider<CastService>((ref) {
  final service = CastService();
  ref.onDispose(() => service.dispose());
  return service;
});
