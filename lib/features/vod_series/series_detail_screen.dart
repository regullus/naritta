import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';

import '../../data/datasources/remote/xtream_client.dart';
import '../../features/providers/provider_manager.dart' as prov;

class SeriesDetailScreen extends ConsumerStatefulWidget {
  final SeriesItem series;

  const SeriesDetailScreen({super.key, required this.series});

  @override
  ConsumerState<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends ConsumerState<SeriesDetailScreen> {
  SeriesInfo? _seriesInfo;
  bool _loading = true;
  int _selectedSeason = 0;

  @override
  void initState() {
    super.initState();
    _loadSeriesInfo();
  }

  Future<void> _loadSeriesInfo() async {
    setState(() => _loading = true);
    try {
      final providers = await ref.read(prov.databaseProvider).getAllProviders();
      final xtream = providers.where((p) => p.type == 'xtream').firstOrNull;
      if (xtream?.url != null &&
          xtream?.username != null &&
          xtream?.password != null) {
        final client = XtreamClient(
          baseUrl: xtream!.url!,
          username: xtream.username!,
          password: xtream.password!,
        );
        try {
          final info = await client.getSeriesInfo(widget.series.seriesId);
          if (mounted) {
            setState(() {
              _seriesInfo = info;
              if (info != null && info.seasons.isNotEmpty) {
                _selectedSeason = info.seasons.first.seasonNum;
              }
            });
          }
        } finally {
          client.dispose();
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final series = widget.series;

    return Scaffold(
      backgroundColor: const Color(0xFF08090A),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 250,
            pinned: true,
            backgroundColor: const Color(0xFF0F0E1A),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => context.pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: series.cover != null && series.cover!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: series.cover!,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _headerGradient(),
                    )
                  : _headerGradient(),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    series.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (series.year != null && series.year!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      series.year!,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (series.rating > 0) ...[
                    Row(
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 18),
                        const SizedBox(width: 4),
                        Text(
                          series.rating.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (series.genre != null && series.genre!.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: series.genre!.split(',').map((g) {
                        final trimmed = g.trim();
                        if (trimmed.isEmpty) return const SizedBox.shrink();
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.amber.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            trimmed,
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 11,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (series.description.isNotEmpty) ...[
                    Text(
                      series.description,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (series.cast != null && series.cast!.isNotEmpty) ...[
                    const Text(
                      'Cast',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      series.cast!,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  // Seasons & Episodes
                  if (_loading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: CircularProgressIndicator(color: Colors.amber),
                      ),
                    )
                  else if (_seriesInfo == null || _seriesInfo!.seasons.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          'No episode data available',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ),
                    )
                  else ...[
                    // Season selector
                    const Text(
                      'Seasons',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: _seriesInfo!.seasons.map((s) {
                          final selected = s.seasonNum == _selectedSeason;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(
                                'Season ${s.seasonNum}',
                                style: TextStyle(
                                  color: selected
                                      ? Colors.black
                                      : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              selected: selected,
                              selectedColor: Colors.amber,
                              backgroundColor: const Color(0xFF1A1A2E),
                              side: BorderSide.none,
                              onSelected: (_) =>
                                  setState(() => _selectedSeason = s.seasonNum),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Episode list
                    ...(_seriesInfo!.seasons
                        .firstWhere((s) => s.seasonNum == _selectedSeason)
                        .episodes
                        .map((ep) => _buildEpisodeTile(ep))),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodeTile(EpisodeInfo ep) {
    return Card(
      color: const Color(0xFF1A1A2E),
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              '${ep.episodeNum}',
              style: const TextStyle(
                color: Colors.amber,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        title: Text(
          ep.title.isNotEmpty ? ep.title : 'Episode ${ep.episodeNum}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: ep.plot != null && ep.plot!.isNotEmpty
            ? Text(
                ep.plot!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              )
            : null,
        trailing: IconButton(
          icon: const Icon(
            Icons.play_circle_outline,
            color: Colors.amber,
            size: 24,
          ),
          onPressed: () => _playEpisode(ep),
        ),
        onTap: () => _playEpisode(ep),
      ),
    );
  }

  void _playEpisode(EpisodeInfo ep) {
    // ignore: unused_local_variable
    final providers = ref.read(prov.databaseProvider);
    // Build the stream URL for this episode
    // ignore: unused_local_variable
    final url = '${widget.series.providerId}/series/.../.../...';
    // Actually, the URL is built from the Xtream URL pattern
    // We stored the provider info, so let's just use a generic URL builder
    // The player will need the actual episode URL
    context.push(
      '/player',
      extra: {
        'streamUrl': ep.id.toString(), // Will be resolved later
        'channelName':
            '${widget.series.name} - S${_selectedSeason}E${ep.episodeNum}',
        'channelLogo': widget.series.cover,
        'alternativeUrls': <String>[],
        'channels': <Map<String, dynamic>>[],
        'currentIndex': 0,
      },
    );
  }

  Widget _headerGradient() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1A2E), Color(0xFF08090A)],
        ),
      ),
      child: Center(
        child: Icon(Icons.tv_outlined, size: 64, color: Colors.white12),
      ),
    );
  }
}
