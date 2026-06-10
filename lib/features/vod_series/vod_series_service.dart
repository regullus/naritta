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

        // Map category_name from the official category list if the item has
        // categoryId but a null/empty category_name.
        try {
          final officialCats = await client.getVodCategories();
          final catMap = <String, String>{};
          for (final cat in officialCats) {
            catMap[cat.id] = cat.name;
          }
          for (final v in vods) {
            if ((v.categoryName == null || v.categoryName!.isEmpty) &&
                v.categoryId != null) {
              v.categoryName = catMap[v.categoryId];
            }
          }
        } catch (_) {
          // Non-critical
        }

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

        // Map category_name from the official category list if the item has
        // categoryId but a null/empty category_name. Some providers return
        // category_id on each series but omit category_name from the listing.
        try {
          final officialCats = await client.getSeriesCategories();
          final catMap = <String, String>{};
          for (final cat in officialCats) {
            catMap[cat.id] = cat.name;
          }
          for (final s in series) {
            if ((s.categoryName == null || s.categoryName!.isEmpty) &&
                s.categoryId != null) {
              s.categoryName = catMap[s.categoryId];
            }
          }
        } catch (_) {
          // Non-critical: categories just fall back to what the API returns
        }

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

/// Series categories: brands first, in this exact order.
const _seriesPriorityCategories = [
  'Netflix',
  'Amazon Prime',
  'Apple TV+',
  'Paramount+',
  'Disney+',
  'HBO',
  'HBO Max',
  'Max',
  'Prime Video',
  'Star+',
  'Globoplay',
  'Telecine',
];

/// VOD/Movie categories: Filmes Lançamentos first, then brands, then alpha.
const _vodPriorityCategories = [
  'Filmes Lançamentos',
  'Netflix',
  'Amazon Prime',
  'Apple TV+',
  'Paramount+',
  'Disney+',
  'HBO',
  'HBO Max',
  'Max',
  'Prime Video',
  'Star+',
  'Globoplay',
  'Telecine',
];

/// Normalize a category name for matching: lowercase, remove pipes and extra spaces.
String _normalizeCat(String s) =>
    s.toLowerCase().replaceAll('|', '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Check if [cat] matches a priority entry [p] (case-insensitive, after normalization).
bool _matchesPriority(String cat, String p) {
  final c = _normalizeCat(cat);
  final normP = _normalizeCat(p);
  return c.contains(normP);
}

/// Sort categories: priority ones first (in the order above), then alphabetically.
List<String> _sortCategories(Iterable<String> cats, List<String> priorityList) {
  final unique = cats.toSet();
  final priority = <String>[];
  final rest = <String>[];
  for (final cat in unique) {
    final idx = priorityList.indexWhere(
      (p) => _matchesPriority(cat, p),
    );
    if (idx >= 0) {
      priority.add(cat);
    } else {
      rest.add(cat);
    }
  }
  // Sort priority group by their position in priorityList
  priority.sort(
    (a, b) {
      final ia = priorityList.indexWhere(
        (p) => _matchesPriority(a, p),
      );
      final ib = priorityList.indexWhere(
        (p) => _matchesPriority(b, p),
      );
      return ia.compareTo(ib);
    },
  );
  rest.sort();
  return [...priority, ...rest];
}

/// Sorted list of all unique categories across all providers.
final seriesCategoriesProvider = Provider<List<String>>((ref) {
  final items = ref.watch(seriesNotifierProvider).valueOrNull ?? [];
  final cats = <String>{};
  for (final item in items) {
    final cat = item.categoryName;
    if (cat != null && cat.isNotEmpty) cats.add(cat);
  }
  return _sortCategories(cats, _seriesPriorityCategories);
});

/// Derived provider: VOD categories (sorted unique).
final vodCategoriesProvider = Provider<List<String>>((ref) {
  final items = ref.watch(vodNotifierProvider).valueOrNull ?? [];
  final cats = <String>{};
  for (final item in items) {
    final cat = item.categoryName;
    if (cat != null && cat.isNotEmpty) cats.add(cat);
  }
  final result = _sortCategories(cats, _vodPriorityCategories);
  debugPrint('[VOD Categories] raw=${cats.toList()} sorted=$result');
  return result;
});
