import 'package:dio/dio.dart';
import '../../models/channel.dart';

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
    final response = await _dio.get(
      _apiBase,
      queryParameters: _authParams,
    );
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
    return (response.data as List).map((e) {
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
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return _seriesFromXtream(json, providerId);
    }).toList();
  }

  /// Get series info with seasons and episodes.
  Future<SeriesInfo?> getSeriesInfo(int seriesId) async {
    try {
      final response = await _dio.get(
        _apiBase,
        queryParameters: {
          ..._authParams,
          'action': 'get_series_info',
          'series_id': seriesId.toString(),
        },
      );
      final data = response.data as Map<String, dynamic>;
      if (data['info'] == null) return null;
      return SeriesInfo.fromJson(data);
    } catch (e) {
      return null;
    }
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
  String buildSeriesUrl(int seriesId, int episodeId) {
    return '$baseUrl/series/$username/$password/$episodeId.$seriesId';
  }

  Channel _channelFromXtream(Map<String, dynamic> json, String providerId) {
    final streamId = json['stream_id'];
    final num = json['num'] is int ? json['num'] as int : int.tryParse('${json['num']}');

    return Channel(
      id: '${providerId}_$streamId',
      providerId: providerId,
      name: json['name'] as String? ?? 'Unknown',
      tvgId: json['epg_channel_id'] as String?,
      tvgName: json['name'] as String?,
      tvgLogo: json['stream_icon'] as String?,
      groupTitle: json['category_name'] as String?,
      channelNumber: num,
      streamUrl: buildLiveUrl(streamId as int),
      streamType: StreamType.live,
    );
  }

  VodItem _vodFromXtream(Map<String, dynamic> json, String providerId) {
    final streamId = json['stream_id'];
    final ext = json['container_extension'] as String? ?? 'mp4';

    return VodItem(
      id: '${providerId}_vod_$streamId',
      providerId: providerId,
      name: json['name'] as String? ?? 'Unknown',
      cover: json['stream_icon'] as String?,
      categoryName: json['category_name'] as String?,
      streamUrl: buildVodUrl(streamId as int, extension: ext),
      streamId: streamId is int ? streamId : int.tryParse('$streamId') ?? 0,
      rating: _parseDouble(json['rating']),
      description: json['plot'] as String? ?? '',
      duration: _parseDuration(json['duration']),
      year: json['year'] as String?,
      genre: json['genre'] as String?,
      director: json['director'] as String?,
      cast: json['cast'] as String?,
      youtubeTrailer: json['youtube_trailer'] as String?,
      backdropPath: json['backdrop_path'] as List?,
    );
  }

  SeriesItem _seriesFromXtream(Map<String, dynamic> json, String providerId) {
    final seriesId = json['series_id'];

    return SeriesItem(
      id: '${providerId}_series_$seriesId',
      providerId: providerId,
      name: json['name'] as String? ?? 'Unknown',
      cover: json['cover'] as String?,
      categoryName: json['category_name'] as String?,
      seriesId: seriesId is int ? seriesId : int.tryParse('$seriesId') ?? 0,
      rating: _parseDouble(json['rating']),
      description: json['plot'] as String? ?? '',
      year: json['year'] as String?,
      genre: json['genre'] as String?,
      cast: json['cast'] as String?,
      backdropPath: json['backdrop_path'] as List?,
      lastModified: json['last_modified'] as String?,
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
      url: serverInfo['url'] as String?,
      port: serverInfo['port']?.toString(),
      httpsPort: serverInfo['https_port']?.toString(),
      serverProtocol: serverInfo['server_protocol'] as String?,
      status: userInfo['status'] as String?,
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

  const XtreamCategory({
    required this.id,
    required this.name,
    this.parentId,
  });

  factory XtreamCategory.fromJson(Map<String, dynamic> json) {
    return XtreamCategory(
      id: json['category_id']?.toString() ?? '',
      name: json['category_name'] as String? ?? '',
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
  final String? categoryName;
  final String streamUrl;
  final int streamId;
  final double rating;
  final String description;
  final String duration;
  final String? year;
  final String? genre;
  final String? director;
  final String? cast;
  final String? youtubeTrailer;
  final List? backdropPath;

  const VodItem({
    required this.id,
    required this.providerId,
    required this.name,
    this.cover,
    this.categoryName,
    required this.streamUrl,
    required this.streamId,
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
  final String? categoryName;
  final int seriesId;
  final double rating;
  final String description;
  final String? year;
  final String? genre;
  final String? cast;
  final List? backdropPath;
  final String? lastModified;

  const SeriesItem({
    required this.id,
    required this.providerId,
    required this.name,
    this.cover,
    this.categoryName,
    required this.seriesId,
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
    final episodesData = json['episodes'] as Map<String, dynamic>? ?? {};

    final seasons = <SeasonInfo>[];
    episodesData.forEach((seasonNum, episodesList) {
      final episodes = (episodesList as List)
          .map((e) => EpisodeInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      if (episodes.isNotEmpty) {
        seasons.add(SeasonInfo(
          seasonNum: int.tryParse(seasonNum) ?? 0,
          episodes: episodes,
        ));
      }
    });

    return SeriesInfo(
      name: info['name'] as String?,
      cover: info['cover'] as String?,
      plot: info['plot'] as String?,
      genre: info['genre'] as String?,
      rating: info['rating'] as String?,
      year: info['year'] as String?,
      seasons: seasons,
    );
  }
}

/// A season containing episodes.
class SeasonInfo {
  final int seasonNum;
  final List<EpisodeInfo> episodes;

  const SeasonInfo({
    required this.seasonNum,
    required this.episodes,
  });
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

  const EpisodeInfo({
    required this.id,
    required this.episodeNum,
    required this.title,
    this.plot,
    this.duration,
    this.releaseDate,
    this.info,
  });

  factory EpisodeInfo.fromJson(Map<String, dynamic> json) {
    return EpisodeInfo(
      id: int.tryParse('${json['id']}') ?? 0,
      episodeNum: int.tryParse('${json['episode_num']}') ?? 0,
      title: json['title'] as String? ?? '',
      plot: json['plot'] as String?,
      duration: json['duration'] as String?,
      releaseDate: json['release_date'] as String?,
      info: json['info'] as String?,
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
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      start: DateTime.tryParse(json['start'] as String? ?? ''),
      end: DateTime.tryParse(json['end'] as String? ?? ''),
    );
  }
}
