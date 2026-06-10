import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/remote/xtream_client.dart';
import '../../features/providers/provider_manager.dart' as prov;

/// Notifier that loads and caches VOD (movies) data from Xtream providers.
class VodNotifier extends AsyncNotifier<List<VodItem>> {
  bool _loaded = false;

  @override
  Future<List<VodItem>> build() async {
    // Build eagerly starts loading so the screen gets a proper loading state
    await _load();
    return state.valueOrNull ?? [];
  }

  Future<void> _load() async {
    if (_loaded) return;
    state = const AsyncLoading();

    final database = ref.read(prov.databaseProvider);
    final providers = await database.getAllProviders();
    debugPrint('[VOD] getAllProviders returned ${providers.length} providers');
    final xtreamProviders = providers.where((p) => p.type == 'xtream');
    debugPrint('[VOD] xtream providers: ${xtreamProviders.length}');

    final items = <VodItem>[];

    for (final provider in xtreamProviders) {
      if (provider.url == null ||
          provider.username == null ||
          provider.password == null) {
        debugPrint(
          '[VOD] Skipping provider ${provider.name}: missing credentials',
        );
        continue;
      }

      debugPrint('[VOD] Fetching from ${provider.name} (${provider.url})');
      final client = XtreamClient(
        baseUrl: provider.url!,
        username: provider.username!,
        password: provider.password!,
      );

      try {
        final vods = await client.getVodStreams(providerId: provider.id);
        items.addAll(vods);
        debugPrint(
          '[VOD] Loaded ${vods.length} VOD items from ${provider.name}',
        );
      } catch (e) {
        debugPrint('[VOD] Failed to load VOD from ${provider.name}: $e');
      } finally {
        client.dispose();
      }
    }

    debugPrint('[VOD] Load complete: ${items.length} movies');
    _loaded = true;
    state = AsyncData(items);
  }

  /// Called by screens to trigger eager load (already handled by build()).
  Future<void> loadIfNeeded() async {
    // no-op — build() already loads eagerly
  }

  /// Force reload.
  Future<void> reload() async {
    _loaded = false;
    await build();
  }

  /// Get VOD items grouped by category.
  Map<String, List<VodItem>> get vodByCategory {
    final items = state.valueOrNull ?? [];
    final map = <String, List<VodItem>>{};
    for (final item in items) {
      final cat = item.categoryName ?? 'Uncategorized';
      map.putIfAbsent(cat, () => []).add(item);
    }
    return map;
  }

  /// Search VOD by name.
  List<VodItem> searchVod(String query) {
    final items = state.valueOrNull ?? [];
    if (query.isEmpty) return items;
    final q = query.toLowerCase();
    return items
        .where(
          (v) =>
              v.name.toLowerCase().contains(q) ||
              (v.genre?.toLowerCase().contains(q) ?? false),
        )
        .toList();
  }
}

/// Notifier that loads and caches Series data from Xtream providers.
class SeriesNotifier extends AsyncNotifier<List<SeriesItem>> {
  bool _loaded = false;

  @override
  Future<List<SeriesItem>> build() async {
    // Build eagerly starts loading so the screen gets a proper loading state
    await _load();
    return state.valueOrNull ?? [];
  }

  Future<void> _load() async {
    if (_loaded) return;
    state = const AsyncLoading();

    final database = ref.read(prov.databaseProvider);
    final providers = await database.getAllProviders();
    debugPrint('[Series] getAllProviders returned ${providers.length} providers');
    final xtreamProviders = providers.where((p) => p.type == 'xtream');
    debugPrint('[Series] xtream providers: ${xtreamProviders.length}');

    final items = <SeriesItem>[];

    for (final provider in xtreamProviders) {
      if (provider.url == null ||
          provider.username == null ||
          provider.password == null) {
        debugPrint(
          '[Series] Skipping provider ${provider.name}: missing credentials',
        );
        continue;
      }

      debugPrint('[Series] Fetching from ${provider.name} (${provider.url})');
      final client = XtreamClient(
        baseUrl: provider.url!,
        username: provider.username!,
        password: provider.password!,
      );

      try {
        final series = await client.getSeriesStreams(providerId: provider.id);
        items.addAll(series);
        debugPrint(
          '[Series] Loaded ${series.length} series from ${provider.name}',
        );
      } catch (e) {
        debugPrint('[Series] Failed to load series from ${provider.name}: $e');
      } finally {
        client.dispose();
      }
    }

    debugPrint('[Series] Load complete: ${items.length} series');
    _loaded = true;
    state = AsyncData(items);
  }

  /// Called by screens to trigger eager load (already handled by build()).
  Future<void> loadIfNeeded() async {
    // no-op — build() already loads eagerly
  }

  /// Force reload.
  Future<void> reload() async {
    _loaded = false;
    await build();
  }

  /// Get Series items grouped by category.
  Map<String, List<SeriesItem>> get seriesByCategory {
    final items = state.valueOrNull ?? [];
    final map = <String, List<SeriesItem>>{};
    for (final item in items) {
      final cat = item.categoryName ?? 'Uncategorized';
      map.putIfAbsent(cat, () => []).add(item);
    }
    return map;
  }

  /// Search Series by name.
  List<SeriesItem> searchSeries(String query) {
    final items = state.valueOrNull ?? [];
    if (query.isEmpty) return items;
    final q = query.toLowerCase();
    return items
        .where(
          (s) =>
              s.name.toLowerCase().contains(q) ||
              (s.genre?.toLowerCase().contains(q) ?? false),
        )
        .toList();
  }
}

/// Providers
final vodNotifierProvider =
    AsyncNotifierProvider<VodNotifier, List<VodItem>>(() => VodNotifier());
final seriesNotifierProvider =
    AsyncNotifierProvider<SeriesNotifier, List<SeriesItem>>(() => SeriesNotifier());

/// Derived provider: VOD items grouped by category.
final vodByCategoryProvider = Provider<Map<String, List<VodItem>>>((ref) {
  return ref.watch(vodNotifierProvider).maybeWhen(
        data: (items) {
          final map = <String, List<VodItem>>{};
          for (final item in items) {
            final cat = item.categoryName ?? 'Uncategorized';
            map.putIfAbsent(cat, () => []).add(item);
          }
          return map;
        },
        orElse: () => {},
      );
});

/// Derived provider: Series items grouped by category.
final seriesByCategoryProvider = Provider<Map<String, List<SeriesItem>>>((ref) {
  return ref.watch(seriesNotifierProvider).maybeWhen(
        data: (items) {
          final map = <String, List<SeriesItem>>{};
          for (final item in items) {
            final cat = item.categoryName ?? 'Uncategorized';
            map.putIfAbsent(cat, () => []).add(item);
          }
          return map;
        },
        orElse: () => {},
      );
});
