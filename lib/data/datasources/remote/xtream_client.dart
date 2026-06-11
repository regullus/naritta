import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../models/channel.dart';

/// Safely extract a String from a dynamic JSON value.
/// Some providers return nested objects instead of plain strings
/// (e.g. {"en": "Title"} instead of "Title").
String? _safeString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value.isEmpty ? null : value;
  if (value is Map) {
    // Try common nested key patterns: {"en": "..."}, {"default": "..."}
    for (final key in ['en', 'default', 'pt', 'title', 'name']) {
      final nested = value[key];
      if (nested is String && nested.isNotEmpty) return nested;
    }
    // Fallback: first string value in the map
    for (final v in value.values) {
      if (v is String && v.isNotEmpty) return v;
    }
  }
  return value.toString().isEmpty ? null : value.toString();
}

/// Xtream Codes API client.
///
/// Supports both Xtream Codes and XUI APIs which share the same player_api.php
/// endpoint structure. Handles authentication, category/stream listing,
/// EPG retrieval, and VOD/series catalogs.
class XtreamClient {
  final Dio _dio;
  final String baseUrl;
  final String username;
  final String password;

  XtreamClient({
    required this.baseUrl,
    required this.username,
    required this.password,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30);
  }

  String get _apiBase => '$baseUrl/player_api.php';

  Map<String, String> get _authParams => {
    'username': username,
    'password': password,
  };

  /// Authenticate and get server info + account status.
  Future<XtreamServerInfo> authenticate() async {
    final response = await _dio.get(_apiBase, queryParameters: _authParams);
    return XtreamServerInfo.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get live stream categories.
  Future<List<XtreamCategory>> getLiveCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_live_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get all live streams, optionally filtered by category.
  Future<List<Channel>> getLiveStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final params = {..._authParams, 'action': 'get_live_streams'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return _channelFromXtream(json, providerId);
    }).toList();
  }

  /// Get VOD categories.
  Future<List<XtreamCategory>> getVodCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_vod_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get VOD streams, optionally filtered by category.
  Future<List<VodItem>> getVodStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final params = {..._authParams, 'action': 'get_vod_streams'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    final raw = response.data;
    final list = raw is List
        ? raw
        : (raw is Map
              ? (raw['data'] as List? ?? raw['vod'] as List? ?? [])
              : []);
    return list.map((e) {
      final json = e as Map<String, dynamic>;
      return _vodFromXtream(json, providerId);
    }).toList();
  }

  /// Get series categories.
  Future<List<XtreamCategory>> getSeriesCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_series_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get series list.
  Future<List<SeriesItem>> getSeriesStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final params = {..._authParams, 'action': 'get_series'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    final raw = response.data;
    final list = raw is List
        ? raw
        : (raw is Map
              ? (raw['data'] as List? ?? raw['series'] as List? ?? [])
              : []);
    return list.map((e) {
      final json = e as Map<String, dynamic>;
      return _seriesFromXtream(json, providerId);
    }).toList();
  }

  /// Get series info with seasons and episodes.
  /// Handles multiple JSON formats from different Xtream providers:
  ///   - Standard Xtream: {info: {...}, episodes: {"1": [...], "2": [...]}}
  ///   - Flat episodes:   {info: {...}, episodes: [{season_number, id, ...}, ...]}
  ///   - TMDB-style:      {seasons: [{season_number, episode_count, ...}, ...]}
  Future<SeriesInfo?> getSeriesInfo(int seriesId) async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {
        ..._authParams,
        'action': 'get_series_info',
        'series_id': seriesId.toString(),
      },
    );
    final data = response.data;
    debugPrint(
      '[getSeriesInfo] series_id=$seriesId data type=${data.runtimeType}',
    );
    if (data is! Map) {
      debugPrint('[getSeriesInfo] data is not Map: ${data.runtimeType}');
      return null;
    }
    final map = data as Map<String, dynamic>;
    debugPrint('[getSeriesInfo] keys=${map.keys.toList()}');

    // Extract info block (may be nested or flat)
    final infoMap = (map['info'] is Map<String, dynamic>)
        ? map['info'] as Map<String, dynamic>
        : map;
    final name = _safeString(infoMap['name']) ?? _safeString(map['name']) ?? '';
    final cover = _safeString(infoMap['cover']) ?? _safeString(map['cover']);
    final plot = _safeString(infoMap['plot']) ?? _safeString(map['overview']);
    final genre = _safeString(infoMap['genre']) ?? _safeString(map['genre']);
    final rating =
        infoMap['rating']?.toString() ?? map['vote_average']?.toString();
    final year =
        _safeString(infoMap['year']) ??
        (map['first_air_date'] is String
            ? map['first_air_date']!.substring(0, 4)
            : null);

    // Try to parse episodes
    final episodesData = map['episodes'];
    final seasonsRaw = map['seasons'];

    List<SeasonInfo> seasons = [];

    // --- Format 1: Standard Xtream episodes Map {"1": [...], "2": [...]} ---
    if (episodesData is Map && episodesData.isNotEmpty) {
      debugPrint(
        '[getSeriesInfo] Format: episodes Map with ${episodesData.length} seasons',
      );
      final parsed = <SeasonInfo>[];
      episodesData.forEach((seasonKey, episodesList) {
        if (episodesList is! List) return;
        final episodes = <EpisodeInfo>[];
        for (final e in episodesList) {
          if (e is Map<String, dynamic>) {
            episodes.add(EpisodeInfo.fromJson(e));
          }
        }
        if (episodes.isNotEmpty) {
          parsed.add(
            SeasonInfo(
              seasonNum: int.tryParse('$seasonKey') ?? 0,
              episodes: episodes,
            ),
          );
        }
      });
      if (parsed.isNotEmpty) {
        seasons = parsed;
      }
    }
    // --- Format 2: Flat episodes List [{season_number, id, episode_num, ...}, ...] ---
    else if (episodesData is List && episodesData.isNotEmpty) {
      debugPrint(
        '[getSeriesInfo] Format: episodes List with ${episodesData.length} items',
      );
      final bySeason = <int, List<EpisodeInfo>>{};
      for (final e in episodesData) {
        if (e is! Map<String, dynamic>) continue;
        final ep = EpisodeInfo.fromJson(e);
        final sn = e['season_number'];
        final seasonNum = sn is int ? sn : int.tryParse('$sn') ?? 1;
        bySeason.putIfAbsent(seasonNum, () => []);
        bySeason[seasonNum]!.add(ep);
      }
      if (bySeason.isNotEmpty) {
        seasons = bySeason.entries.map((entry) {
          final eps = entry.value
            ..sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
          return SeasonInfo(seasonNum: entry.key, episodes: eps);
        }).toList()..sort((a, b) => a.seasonNum.compareTo(b.seasonNum));
      }
    }

    // --- Format 3: TMDB-style seasons [{season_number, episodes: [...], ...}] ---
    // Only use this if we haven't found episodes yet
    if (seasons.isEmpty && seasonsRaw is List && seasonsRaw.isNotEmpty) {
      debugPrint(
        '[getSeriesInfo] Format: TMDB-style seasons with ${seasonsRaw.length} seasons',
      );
      final parsed = <SeasonInfo>[];
      for (final s in seasonsRaw) {
        if (s is! Map<String, dynamic>) continue;
        final seasonNum = s['season_number'];
        final sn = seasonNum is int
            ? seasonNum
            : int.tryParse('$seasonNum') ?? 0;

        // Check if episodes are included inline
        final inlineEpisodes = s['episodes'];
        if (inlineEpisodes is List && inlineEpisodes.isNotEmpty) {
          final episodes = <EpisodeInfo>[];
          for (final e in inlineEpisodes) {
            if (e is Map<String, dynamic>) {
              episodes.add(EpisodeInfo.fromTmdbJson(e, seriesId, sn));
            }
          }
          if (episodes.isNotEmpty) {
            parsed.add(SeasonInfo(seasonNum: sn, episodes: episodes));
          }
        } else {
          // Only episode_count, no real episode data
          final episodeCount = s['episode_count'];
          final ec = episodeCount is int
              ? episodeCount
              : int.tryParse('$episodeCount') ?? 0;
          if (ec > 0) {
            debugPrint(
              '[getSeriesInfo] season $sn: episode_count=$ec (no real IDs)',
            );
            final episodes = <EpisodeInfo>[];
            for (var i = 1; i <= ec; i++) {
              episodes.add(
                EpisodeInfo(
                  id: 0,
                  episodeNum: i,
                  title: s['name'] != null
                      ? '${s['name']} - Ep. $i'
                      : 'Episode $i',
                  plot: null,
                ),
              );
            }
            parsed.add(SeasonInfo(seasonNum: sn, episodes: episodes));
          }
        }
      }
      if (parsed.isNotEmpty) {
        seasons = parsed;
      }
    }

    if (seasons.isEmpty) {
      debugPrint('[getSeriesInfo] no seasons found in any format');
      return null;
    }

    debugPrint('[getSeriesInfo] success: ${seasons.length} seasons');
    return SeriesInfo(
      name: name,
      cover: cover,
      plot: plot,
      genre: genre,
      rating: rating,
      year: year,
      seasons: seasons,
    );
  }

  /// Get short EPG for a specific stream (current + next few programs).
  Future<List<XtreamEpgEntry>> getShortEpg(String streamId) async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {
        ..._authParams,
        'action': 'get_short_epg',
        'stream_id': streamId,
      },
    );
    final data = response.data as Map<String, dynamic>;
    final listings = data['epg_listings'] as List? ?? [];
    return listings
        .map((e) => XtreamEpgEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Build a live stream URL.
  String buildLiveUrl(int streamId, {String extension = 'ts'}) {
    return '$baseUrl/live/$username/$password/$streamId.$extension';
  }

  /// Build a VOD stream URL.
  String buildVodUrl(int streamId, {String extension = 'mp4'}) {
    return '$baseUrl/movie/$username/$password/$streamId.$extension';
  }

  /// Build a series episode stream URL.
  /// Uses [extension] from episode metadata if provided, otherwise defaults to no extension.
  String buildSeriesUrl(int seriesId, int episodeId, {String? extension}) {
    if (extension != null && extension.isNotEmpty) {
      return '$baseUrl/series/$username/$password/$episodeId.$extension';
    }
    return '$baseUrl/series/$username/$password/$episodeId.$seriesId';
  }

  Channel _channelFromXtream(Map<String, dynamic> json, String providerId) {
    final streamId = json['stream_id'];
    final num = json['num'] is int
        ? json['num'] as int
        : int.tryParse('${json['num']}');

    return Channel(
      id: '${providerId}_$streamId',
      providerId: providerId,
      name: _safeString(json['name']) ?? 'Unknown',
      tvgId: _safeString(json['epg_channel_id']),
      tvgName: _safeString(json['name']),
      tvgLogo: _safeString(json['stream_icon']),
      groupTitle: _safeString(json['category_name']),
      channelNumber: num,
      streamUrl: buildLiveUrl(streamId as int),
      streamType: StreamType.live,
    );
  }

  VodItem _vodFromXtream(Map<String, dynamic> json, String providerId) {
    final streamId = json['stream_id'];
    final ext = _safeString(json['container_extension']) ?? 'mp4';

    return VodItem(
      id: '${providerId}_vod_$streamId',
      providerId: providerId,
      name: _safeString(json['name']) ?? 'Unknown',
      cover: _safeString(json['stream_icon']),
      categoryName: _safeString(json['category_name']),
      categoryId: json['category_id']?.toString(),
      streamUrl: buildVodUrl(streamId as int, extension: ext),
      streamId: streamId,
      rating: _parseDouble(json['rating']),
      description: _safeString(json['plot']) ?? '',
      duration: _parseDuration(json['duration']),
      year: _safeString(json['year']),
      genre: _safeString(json['genre']),
      director: _safeString(json['director']),
      cast: _safeString(json['cast']),
      youtubeTrailer: _safeString(json['youtube_trailer']),
      backdropPath: json['backdrop_path'] as List?,
    );
  }

  SeriesItem _seriesFromXtream(Map<String, dynamic> json, String providerId) {
    final seriesId = json['series_id'];

    return SeriesItem(
      id: '${providerId}_series_$seriesId',
      providerId: providerId,
      name: _safeString(json['name']) ?? 'Unknown',
      cover: _safeString(json['cover']),
      categoryName: _safeString(json['category_name']),
      categoryId: json['category_id']?.toString(),
      seriesId: seriesId is int ? seriesId : int.tryParse('$seriesId') ?? 0,
      rating: _parseDouble(json['rating']),
      description: _safeString(json['plot']) ?? '',
      year: _safeString(json['year']),
      genre: _safeString(json['genre']),
      cast: _safeString(json['cast']),
      backdropPath: json['backdrop_path'] as List?,
      lastModified: _safeString(json['last_modified']),
    );
  }

  double _parseDouble(dynamic value) {
    if (value == null || value == '' || value == 'null') return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  String _parseDuration(dynamic value) {
    if (value == null || value == '' || value == 'null') return '';
    return value.toString();
  }

  void dispose() {
    _dio.close();
  }
}

/// Server info returned by authentication.
class XtreamServerInfo {
  final String? url;
  final String? port;
  final String? httpsPort;
  final String? serverProtocol;
  final String? status;
  final DateTime? expDate;
  final int? maxConnections;
  final int? activeCons;
  final bool isTrial;

  const XtreamServerInfo({
    this.url,
    this.port,
    this.httpsPort,
    this.serverProtocol,
    this.status,
    this.expDate,
    this.maxConnections,
    this.activeCons,
    this.isTrial = false,
  });

  bool get isActive => status == 'Active';

  factory XtreamServerInfo.fromJson(Map<String, dynamic> json) {
    final userInfo = json['user_info'] as Map<String, dynamic>? ?? {};
    final serverInfo = json['server_info'] as Map<String, dynamic>? ?? {};

    DateTime? expDate;
    final exp = userInfo['exp_date'];
    if (exp != null && exp != '' && exp != 'null') {
      expDate = DateTime.fromMillisecondsSinceEpoch(
        int.parse(exp.toString()) * 1000,
      );
    }

    return XtreamServerInfo(
      url: _safeString(serverInfo['url']),
      port: serverInfo['port']?.toString(),
      httpsPort: serverInfo['https_port']?.toString(),
      serverProtocol: _safeString(serverInfo['server_protocol']),
      status: _safeString(userInfo['status']),
      expDate: expDate,
      maxConnections: int.tryParse('${userInfo['max_connections']}'),
      activeCons: int.tryParse('${userInfo['active_cons']}'),
      isTrial: userInfo['is_trial'] == '1',
    );
  }
}

/// Xtream category (live, VOD, or series).
class XtreamCategory {
  final String id;
  final String name;
  final int? parentId;

  const XtreamCategory({required this.id, required this.name, this.parentId});

  factory XtreamCategory.fromJson(Map<String, dynamic> json) {
    return XtreamCategory(
      id: json['category_id']?.toString() ?? '',
      name: _safeString(json['category_name']) ?? '',
      parentId: int.tryParse('${json['parent_id']}'),
    );
  }
}

/// A VOD (movie) item from Xtream.
class VodItem {
  final String id;
  final String providerId;
  final String name;
  final String? cover;
  String? categoryName;
  final String streamUrl;
  final int streamId;
  final String? categoryId;
  final double rating;
  final String description;
  final String duration;
  final String? year;
  final String? genre;
  final String? director;
  final String? cast;
  final String? youtubeTrailer;
  final List? backdropPath;

  VodItem({
    required this.id,
    required this.providerId,
    required this.name,
    this.cover,
    this.categoryName,
    required this.streamUrl,
    required this.streamId,
    this.categoryId,
    this.rating = 0.0,
    this.description = '',
    this.duration = '',
    this.year,
    this.genre,
    this.director,
    this.cast,
    this.youtubeTrailer,
    this.backdropPath,
  });
}

/// A series item from Xtream.
class SeriesItem {
  final String id;
  final String providerId;
  final String name;
  final String? cover;
  String? categoryName;
  final int seriesId;
  final String? categoryId;
  final double rating;
  final String description;
  final String? year;
  final String? genre;
  final String? cast;
  final List? backdropPath;
  final String? lastModified;

  SeriesItem({
    required this.id,
    required this.providerId,
    required this.name,
    this.cover,
    this.categoryName,
    required this.seriesId,
    this.categoryId,
    this.rating = 0.0,
    this.description = '',
    this.year,
    this.genre,
    this.cast,
    this.backdropPath,
    this.lastModified,
  });
}

/// Series info with seasons and episodes.
class SeriesInfo {
  final String? name;
  final String? cover;
  final String? plot;
  final String? genre;
  final String? rating;
  final String? year;
  final List<SeasonInfo> seasons;

  const SeriesInfo({
    this.name,
    this.cover,
    this.plot,
    this.genre,
    this.rating,
    this.year,
    this.seasons = const [],
  });

  factory SeriesInfo.fromJson(Map<String, dynamic> json) {
    final info = json['info'] as Map<String, dynamic>? ?? {};
    final episodesData = json['episodes'];

    final seasons = <SeasonInfo>[];

    // Format 1: episodes as Map {"1": [...], "2": [...]}
    if (episodesData is Map && episodesData.isNotEmpty) {
      episodesData.forEach((seasonKey, episodesList) {
        if (episodesList is! List) return;
        final episodes = episodesList
            .whereType<Map<String, dynamic>>()
            .map(EpisodeInfo.fromJson)
            .toList();
        if (episodes.isNotEmpty) {
          seasons.add(
            SeasonInfo(
              seasonNum: int.tryParse('$seasonKey') ?? 0,
              episodes: episodes,
            ),
          );
        }
      });
    }
    // Format 2: episodes as flat List [{season_number, id, ...}, ...]
    else if (episodesData is List && episodesData.isNotEmpty) {
      final bySeason = <int, List<EpisodeInfo>>{};
      for (final e in episodesData) {
        if (e is! Map<String, dynamic>) continue;
        final ep = EpisodeInfo.fromJson(e);
        final sn = e['season_number'];
        final seasonNum = sn is int ? sn : int.tryParse('$sn') ?? 1;
        bySeason.putIfAbsent(seasonNum, () => []);
        bySeason[seasonNum]!.add(ep);
      }
      for (final entry in bySeason.entries) {
        final eps = entry.value
          ..sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
        seasons.add(SeasonInfo(seasonNum: entry.key, episodes: eps));
      }
    }

    seasons.sort((a, b) => a.seasonNum.compareTo(b.seasonNum));

    return SeriesInfo(
      name: _safeString(info['name']),
      cover: _safeString(info['cover']),
      plot: _safeString(info['plot']),
      genre: _safeString(info['genre']),
      rating: _safeString(info['rating']),
      year: _safeString(info['year']),
      seasons: seasons,
    );
  }
}

/// A season containing episodes.
class SeasonInfo {
  final int seasonNum;
  final List<EpisodeInfo> episodes;

  const SeasonInfo({required this.seasonNum, required this.episodes});
}

/// A single episode.
class EpisodeInfo {
  final int id;
  final int episodeNum;
  final String title;
  final String? plot;
  final String? duration;
  final String? releaseDate;
  final String? info;

  /// Direct stream URL if provided by the provider (some providers return
  /// a full URL instead of requiring URL construction).
  final String? directSource;

  /// Container extension (mp4, mkv, ts, etc.) for URL construction.
  final String? containerExtension;

  const EpisodeInfo({
    required this.id,
    required this.episodeNum,
    required this.title,
    this.plot,
    this.duration,
    this.releaseDate,
    this.info,
    this.directSource,
    this.containerExtension,
  });

  factory EpisodeInfo.fromJson(Map<String, dynamic> json) {
    // Handle id that may come as int, double (e.g. 123.0), or string
    // Some providers use 'episode_id' instead of 'id'
    final rawId = json['id'] ?? json['episode_id'];
    final id = rawId is int
        ? rawId
        : rawId is double
        ? rawId.toInt()
        : int.tryParse('$rawId') ?? 0;

    // Handle episode_num similarly
    final rawEp = json['episode_num'];
    final episodeNum = rawEp is int
        ? rawEp
        : rawEp is double
        ? rawEp.toInt()
        : int.tryParse('$rawEp') ?? 0;

    // Some providers nest episode metadata inside 'movie_info'
    final movieInfo = json['movie_info'] as Map<String, dynamic>?;
    final directSource =
        _safeString(json['direct_source']) ??
        _safeString(movieInfo?['direct_source']);
    final containerExt =
        _safeString(json['container_extension']) ??
        _safeString(movieInfo?['container_extension']);

    // Log episode parsing for debugging
    debugPrint(
      '[EpisodeInfo] id=$id, epNum=$episodeNum, title=${json['title']}, directSource=$directSource, ext=$containerExt',
    );
    debugPrint('[EpisodeInfo] All keys: ${json.keys.toList()}');

    return EpisodeInfo(
      id: id,
      episodeNum: episodeNum,
      title: _safeString(json['title']) ?? '',
      plot: _safeString(json['plot']) ?? _safeString(movieInfo?['plot']),
      duration:
          _safeString(json['duration']) ?? _safeString(movieInfo?['duration']),
      releaseDate: _safeString(json['release_date']),
      info: _safeString(json['info']),
      directSource: directSource,
      containerExtension: containerExt,
    );
  }

  /// Parse episode from TMDB-style JSON (used inside seasons array).
  /// TMDB episodes don't have Xtream IDs, so we generate a synthetic ID
  /// based on seriesId + season + episode number for URL building.
  factory EpisodeInfo.fromTmdbJson(
    Map<String, dynamic> json,
    int seriesId,
    int seasonNum,
  ) {
    final rawEp = json['episode_number'];
    final episodeNum = rawEp is int ? rawEp : int.tryParse('$rawEp') ?? 0;

    // Generate a synthetic episode ID for URL building
    // Format: seriesId * 10000 + seasonNum * 100 + episodeNum
    final syntheticId = seriesId * 10000 + seasonNum * 100 + episodeNum;

    return EpisodeInfo(
      id: syntheticId,
      episodeNum: episodeNum,
      title:
          _safeString(json['name']) ??
          _safeString(json['title']) ??
          'Episode $episodeNum',
      plot: _safeString(json['overview']) ?? _safeString(json['plot']),
      duration: json['runtime'] != null ? '${json['runtime']} min' : null,
      releaseDate: _safeString(json['air_date']),
      directSource: _safeString(json['direct_source']),
      containerExtension: _safeString(json['container_extension']),
    );
  }
}

/// Single EPG entry from Xtream short EPG.
class XtreamEpgEntry {
  final String title;
  final String description;
  final DateTime? start;
  final DateTime? end;

  const XtreamEpgEntry({
    required this.title,
    this.description = '',
    this.start,
    this.end,
  });

  factory XtreamEpgEntry.fromJson(Map<String, dynamic> json) {
    return XtreamEpgEntry(
      title: _safeString(json['title']) ?? '',
      description: _safeString(json['description']) ?? '',
      start: DateTime.tryParse(_safeString(json['start']) ?? ''),
      end: DateTime.tryParse(_safeString(json['end']) ?? ''),
    );
  }
}
