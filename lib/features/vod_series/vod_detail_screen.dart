import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';

import '../../data/datasources/remote/xtream_client.dart';

class VodDetailScreen extends ConsumerWidget {
  final VodItem movie;

  const VodDetailScreen({super.key, required this.movie});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090A),
      body: CustomScrollView(
        slivers: [
          // App bar with backdrop
          SliverAppBar(
            expandedHeight: 250,
            pinned: true,
            backgroundColor: const Color(0xFF0F0E1A),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => context.pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: movie.backdropPath != null && movie.backdropPath!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: movie.backdropPath![0].toString(),
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _buildHeaderGradient(movie),
                    )
                  : _buildHeaderGradient(movie),
            ),
          ),

          // Content
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title + year
                  Text(
                    movie.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (movie.year != null && movie.year!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      movie.year!,
                      style: const TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // Info row
                  Row(
                    children: [
                      if (movie.rating > 0) ...[
                        const Icon(Icons.star, color: Colors.amber, size: 18),
                        const SizedBox(width: 4),
                        Text(
                          movie.rating.toStringAsFixed(1),
                          style: const TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 16),
                      ],
                      if (movie.duration.isNotEmpty) ...[
                        const Icon(Icons.access_time, color: Colors.white54, size: 16),
                        const SizedBox(width: 4),
                        Text(
                          movie.duration,
                          style: const TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      ],
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Genre chips
                  if (movie.genre != null && movie.genre!.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: movie.genre!.split(',').map((g) {
                        final trimmed = g.trim();
                        if (trimmed.isEmpty) return const SizedBox.shrink();
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            trimmed,
                            style: const TextStyle(color: Colors.amber, fontSize: 11),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Description
                  if (movie.description.isNotEmpty) ...[
                    Text(
                      movie.description,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Cast
                  if (movie.cast != null && movie.cast!.isNotEmpty) ...[
                    const Text(
                      'Cast',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      movie.cast!,
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Director
                  if (movie.director != null && movie.director!.isNotEmpty) ...[
                    const Text(
                      'Director',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      movie.director!,
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Play button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: () => _playMovie(context),
                      icon: const Icon(Icons.play_arrow, size: 24),
                      label: const Text('Watch Now', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderGradient(VodItem movie) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1A2E), Color(0xFF08090A)],
        ),
      ),
      child: Center(
        child: Icon(Icons.movie_outlined, size: 64, color: Colors.white12),
      ),
    );
  }

  void _playMovie(BuildContext context) {
    context.push('/player', extra: {
      'streamUrl': movie.streamUrl,
      'channelName': movie.name,
      'channelLogo': movie.cover,
      'alternativeUrls': <String>[],
      'channels': <Map<String, dynamic>>[],
      'currentIndex': 0,
    });
  }
}
