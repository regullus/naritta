import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../data/datasources/remote/xtream_client.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../features/providers/provider_manager.dart' as prov;

final _log = Logger(printer: SimplePrinter());

/// Manages VOD (movies) and Series data from Xtream providers.
class VodSeriesService {
  final db.AppDatabase _database;

  List<VodItem> _vodItems = [];
  List<SeriesItem> _seriesItems = [];
  bool _loaded = false;

  final _vodController = StreamController<List<VodItem>>.broadcast();
  final _seriesController = StreamController<List<SeriesItem>>.broadcast();

  VodSeriesService(this._database);

  Stream<List<VodItem>> get vodStream => _vodController.stream;
  Stream<List<SeriesItem>> get seriesStream => _seriesController.stream;

  List<VodItem> get vodItems => _vodItems;
  List<SeriesItem> get seriesItems => _seriesItems;
  bool get isLoaded => _loaded;

  /// Fetch VOD and Series from all Xtream providers.
  Future<void> loadAll() async {
    _loaded = false;
    _vodItems = [];
    _seriesItems = [];

    final providers = await _database.getAllProviders();
    final xtreamProviders = providers.where((p) => p.type == 'xtream');

    for (final provider in xtreamProviders) {
      if (provider.url == null || provider.username == null || provider.password == null) continue;

      final client = XtreamClient(
        baseUrl: provider.url!,
        username: provider.username!,
        password: provider.password!,
      );

      try {
        // Fetch VOD
        final vods = await client.getVodStreams(providerId: provider.id);
        _vodItems.addAll(vods);
        _log.i('Loaded ${vods.length} VOD items from ${provider.name}');

        // Fetch Series
        final series = await client.getSeriesStreams(providerId: provider.id);
        _seriesItems.addAll(series);
        _log.i('Loaded ${series.length} series from ${provider.name}');
      } catch (e) {
        _log.e('Failed to load VOD/Series from ${provider.name}: $e');
      } finally {
        client.dispose();
      }
    }

    _loaded = true;
    _vodController.add(_vodItems);
    _seriesController.add(_seriesItems);
  }

  /// Get VOD items grouped by category.
  Map<String, List<VodItem>> get vodByCategory {
    final map = <String, List<VodItem>>{};
    for (final item in _vodItems) {
      final cat = item.categoryName ?? 'Uncategorized';
      map.putIfAbsent(cat, () => []).add(item);
    }
    return map;
  }

  /// Get Series items grouped by category.
  Map<String, List<SeriesItem>> get seriesByCategory {
    final map = <String, List<SeriesItem>>{};
    for (final item in _seriesItems) {
      final cat = item.categoryName ?? 'Uncategorized';
      map.putIfAbsent(cat, () => []).add(item);
    }
    return map;
  }

  /// Search VOD by name.
  List<VodItem> searchVod(String query) {
    if (query.isEmpty) return _vodItems;
    final q = query.toLowerCase();
    return _vodItems.where((v) =>
      v.name.toLowerCase().contains(q) ||
      (v.genre?.toLowerCase().contains(q) ?? false)
    ).toList();
  }

  /// Search Series by name.
  List<SeriesItem> searchSeries(String query) {
    if (query.isEmpty) return _seriesItems;
    final q = query.toLowerCase();
    return _seriesItems.where((s) =>
      s.name.toLowerCase().contains(q) ||
      (s.genre?.toLowerCase().contains(q) ?? false)
    ).toList();
  }

  void dispose() {
    _vodController.close();
    _seriesController.close();
  }
}

/// Riverpod provider for VOD/Series service.
final vodSeriesServiceProvider = Provider<VodSeriesService>((ref) {
  final database = ref.read(prov.databaseProvider);
  return VodSeriesService(database);
});

/// Async provider that loads VOD/Series data.
final vodSeriesLoaderProvider = FutureProvider<void>((ref) async {
  final service = ref.read(vodSeriesServiceProvider);
  await service.loadAll();
});

/// Stream of VOD items.
final vodStreamProvider = StreamProvider<List<VodItem>>((ref) {
  return ref.watch(vodSeriesServiceProvider).vodStream;
});

/// Stream of Series items.
final seriesStreamProvider = StreamProvider<List<SeriesItem>>((ref) {
  return ref.watch(vodSeriesServiceProvider).seriesStream;
});

/// VOD items by category.
final vodByCategoryProvider = Provider<Map<String, List<VodItem>>>((ref) {
  return ref.watch(vodSeriesServiceProvider).vodByCategory;
});

/// Series items by category.
final seriesByCategoryProvider = Provider<Map<String, List<SeriesItem>>>((ref) {
  return ref.watch(vodSeriesServiceProvider).seriesByCategory;
});
