import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';

import '../../data/datasources/remote/xtream_client.dart';
import 'vod_series_service.dart';

class SeriesScreen extends ConsumerStatefulWidget {
  const SeriesScreen({super.key});

  @override
  ConsumerState<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends ConsumerState<SeriesScreen> {
  String _selectedCategory = '';
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(seriesNotifierProvider.notifier).loadIfNeeded();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch the stream — rebuild when data arrives
    final seriesAsync = ref.watch(seriesNotifierProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF08090A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0E1A),
        title: const Text(
          'Series',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.pop(),
        ),
      ),
      body: seriesAsync.when(
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF6C5CE7)),
              SizedBox(height: 12),
              Text(
                'Loading series...',
                style: TextStyle(color: Colors.white38),
              ),
            ],
          ),
        ),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text('Error: $e', style: const TextStyle(color: Colors.white54)),
            ],
          ),
        ),
        data: (seriesItems) => _buildContent(seriesItems),
      ),
    );
  }

  Widget _buildContent(List<SeriesItem> items) {
    // Build category map from current items
    final byCategory = <String, List<SeriesItem>>{};
    for (final item in items) {
      final cat = item.categoryName ?? 'Uncategorized';
      byCategory.putIfAbsent(cat, () => []).add(item);
    }
    final categories = byCategory.keys.toList()..sort();

    // Apply category filter
    List<SeriesItem> displayItems;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      displayItems = items
          .where(
            (s) =>
                s.name.toLowerCase().contains(q) ||
                (s.genre?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    } else if (_selectedCategory.isEmpty) {
      displayItems = items;
    } else {
      displayItems = byCategory[_selectedCategory] ?? [];
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search series...',
              hintStyle: const TextStyle(color: Colors.white24),
              prefixIcon: const Icon(
                Icons.search,
                color: Colors.white38,
                size: 20,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.clear,
                        color: Colors.white38,
                        size: 18,
                      ),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFF1A1A2E),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _buildCategoryChip('All', _selectedCategory.isEmpty),
              ...categories.map(
                (cat) => _buildCategoryChip(cat, _selectedCategory == cat),
              ),
            ],
          ),
        ),
        Expanded(
          child: displayItems.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tv_outlined, size: 64, color: Colors.white24),
                      const SizedBox(height: 12),
                      Text(
                        _searchQuery.isNotEmpty
                            ? 'No series found for "$_searchQuery"'
                            : items.isEmpty
                            ? 'No series loaded.\nAdd an Xtream provider first.'
                            : 'Select a category',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.67,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: displayItems.length,
                  itemBuilder: (ctx, i) => _buildSeriesCard(displayItems[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildCategoryChip(String label, bool selected) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontSize: 12,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        selected: selected,
        selectedColor: Colors.amber,
        backgroundColor: const Color(0xFF1A1A2E),
        side: BorderSide.none,
        onSelected: (v) {
          setState(() => _selectedCategory = selected ? '' : label);
        },
      ),
    );
  }

  Widget _buildSeriesCard(SeriesItem series) {
    return GestureDetector(
      onTap: () => _openSeries(series),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (series.cover != null && series.cover!.isNotEmpty)
              CachedNetworkImage(
                imageUrl: series.cover!,
                fit: BoxFit.cover,
                placeholder: (_, __) => _seriesPlaceholder(),
                errorWidget: (_, __, ___) => _seriesPlaceholder(),
              )
            else
              _seriesPlaceholder(),
            if (series.rating > 0)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, size: 10, color: Colors.amber),
                      const SizedBox(width: 2),
                      Text(
                        series.rating.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Text(
                  series.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _seriesPlaceholder() {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Center(
        child: Icon(Icons.tv_outlined, size: 32, color: Colors.white12),
      ),
    );
  }

  void _openSeries(SeriesItem series) {
    context.push('/series-detail', extra: series);
  }
}
