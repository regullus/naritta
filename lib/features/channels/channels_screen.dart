import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileMode, Platform;

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/countdown_snackbar.dart';



import '../../core/weather_clock_widget.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/remote/tmdb_client.dart';
import '../../data/services/app_update_service.dart';
import '../../data/services/epg_refresh_service.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../player/player_service.dart';
import '../player/stream_info_badges.dart';
import '../providers/provider_manager.dart';
import '../shows/shows_providers.dart';
import 'channel_debug_dialog.dart';

class ChannelsScreen extends ConsumerStatefulWidget {
  const ChannelsScreen({super.key});

  @override
  ConsumerState<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends ConsumerState<ChannelsScreen> {
  static bool _updateCheckDone = false;
  bool _initialLoadDone = false;
  String _loadStatus = '';
  bool _epgLoading = false;
  List<db.Channel> _allChannels = [];
  List<db.Channel> _filteredChannels = [];
  List<String> _groups = [];
  String _selectedGroup = 'All';
  String _searchQuery = '';
  // _showSearch removed — search bar is always visible in the top navbar
  int _selectedIndex = -1;
  db.Channel? _previewChannel;
  List<db.EpgProgramme> _nowPlaying = [];

  /// Maps channel ID → mapped EPG channel ID (from epg_mappings table)
  Map<String, String> _epgMappings = {};
  /// Maps channel ID → user-set vanity name (original name preserved in DB)
  Map<String, String> _vanityNames = {};
  Set<String> _validEpgChannelIds = {};
  Map<String, String> _rawToPrefixedEpg = {}; // XMLTV channelId → prefixed id
  Map<String, String> _epgNameToId = {}; // normalized EPG displayName → prefixed id
  Map<String, String> _epgCallSignToId = {}; // call sign (e.g. WABC) → prefixed id
  final bool _showGuideView = true;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  List<String> _searchHistory = [];
  static const _kSearchHistory = 'search_history';
  static const _kMaxSearchHistory = 20;
  final _channelListController = ScrollController();
  late final ScrollController _guideScrollController;
  Timer? _guideIdleTimer;
  DateTime? _guideDayStart; // stored for snap-back calculation
  Timer? _searchDebounce;

  // Overlay state
  bool _showOverlay = false;
  // _showDebugOverlay removed — debug info is now a dialog
  Timer? _overlayTimer;
  Timer? _nowPlayingTimer;
  final _focusNode = FocusNode();

  // Volume state
  double _volume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeOverlayTimer;

  // Last channel for back/forth toggle (not a full history stack)
  int _previousIndex = -1;

  // Sidebar state
  bool _sidebarExpanded = true;
  final Set<String> _expandedSections = {'favorites'};
  final _sidebarSearchController = TextEditingController();
  final _sidebarFocusNode = FocusScopeNode(debugLabel: 'sidebar');
  final _sidebarAllItemFocusNode = FocusNode(debugLabel: 'sidebar-all');
  final _firstChannelFocusNode = FocusNode(debugLabel: 'channel-first');
  String _sidebarSearchQuery = '';

  // Top bar auto-hide
  double _topBarOpacity = 1.0;
  Timer? _topBarTimer;
  bool _mouseInTopBar = false;

  // Failover suggestion
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<List<db.Provider>>? _providersSub;
  StreamSubscription<List<db.Channel>>? _channelsSub;
  Timer? _failoverTimer;
  db.Channel? _failoverSuggestion;
  bool _showFailoverBanner = false;
  static const _kFailoverEnabled = 'failover_enabled';
  bool _failoverEnabled = true;

  // Provider list for sidebar
  List<db.Provider> _providers = [];
  // Pre-computed: provider ID → sorted group names
  Map<String, List<String>> _providerGroups = {};
  // Track which providers' channels have been loaded into _allChannels
  final Set<String> _loadedProviders = {};
  // True while background is still loading all channels
  bool _backgroundLoading = false;
  // Favorite lists state
  List<db.FavoriteList> _favoriteLists = [];
  Set<String> _favoritedChannelIds = {};

  // Multi-select mode for failover group creation
  bool _multiSelectMode = false;
  Set<String> _multiSelectedChannelIds = {};
  // Long-press timer for TV remote multi-select (CENTER held >600ms)
  Timer? _longPressTimer;
  String? _longPressChannelId;

  // Failover groups state
  List<db.FailoverGroup> _failoverGroups = [];
  /// groupId → ordered list of channel IDs
  Map<int, List<String>> _failoverGroupMembers = {};
  /// channelId → list of group memberships (for fast player lookup)
  Map<String, List<db.FailoverGroupMembership>> _failoverGroupIndex = {};
  final Set<int> _expandedFailoverGroups = {};
  final bool _lastClickShift = false;

  // Time format
  bool _use24HourTime = false;
  static const _kUse24HourTime = 'use_24_hour_time';

  // Per-channel EPG timeshift in hours
  final Map<String, int> _epgTimeshifts = {};
  static const _kEpgTimeshifts = 'epg_timeshifts';

  // IMDB ID cache: show title → IMDB ID (null = lookup in progress/failed)
  final Map<String, String?> _imdbIdCache = {};

  // Persistence keys
  static const _kLastChannelId = 'last_channel_id';
  static const _kLastGroup = 'last_group';

  @override
  void initState() {
    super.initState();
    _guideScrollController = ScrollController();
    _loadChannels();
    _ensureEpgSources();
    _startTopBarFade();
    _initFailoverListener();
    _loadSearchHistory();
    // Resolve missing logos on startup (in background)
    ref.read(providerManagerProvider).resolveAllMissingLogos().catchError((_) {});
    // Auto-failover toast
    final ps = ref.read(playerServiceProvider);
    ps.onFailover = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            width: 250,
          ),
        );
        // Update channel list selection to reflect the failover target
        final newId = ps.lastFailoverChannelId;
        if (newId != null) {
          final idx = _filteredChannels.indexWhere((c) => c.id == newId);
          if (idx >= 0 && idx != _selectedIndex) {
            setState(() {
              _previousIndex = _selectedIndex;
              _selectedIndex = idx;
              _previewChannel = _filteredChannels[idx];
            });
            if (_channelListController.hasClients) {
              _scrollToIndex(idx);
            }
          }
        }
      }
    };
    // Watch providers table — reload when providers or channels change
    final database = ref.read(databaseProvider);
    Timer? debounce;
    void debouncedReload() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 500), () {
        if (mounted) _loadChannels();
      });
    }
    _providersSub = database.select(database.providers).watch().listen((_) => debouncedReload());
    _channelsSub = database.select(database.channels).watch().listen((_) => debouncedReload());
    // Refresh now-playing every 60 seconds so the info panel stays current
    _nowPlayingTimer = Timer.periodic(const Duration(seconds: 60), (_) => _refreshNowPlaying());
    // Check for app updates after a short delay so the UI loads first
    // Disabled during development
    // Future.delayed(const Duration(seconds: 3), _checkForUpdateOnStartup);
  }

  Future<void> _checkForUpdateOnStartup() async {
    if (_updateCheckDone || !mounted) return;
    _updateCheckDone = true;
    final release = await AppUpdateService.checkForUpdate();
    if (!mounted || release == null || !release.isNewer) return;

    // Show a non-intrusive banner at the bottom
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        backgroundColor: const Color(0xFF1A1A2E),
        content: Text(
          'Update available: v${release.version}',
          style: const TextStyle(color: Colors.white),
        ),
        leading: const Icon(Icons.system_update, color: Color(0xFF6C5CE7)),
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
            },
            child: const Text('LATER'),
          ),
          if (release.apkDownloadUrl != null)
            TextButton(
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                _showDownloadDialog(release.apkDownloadUrl!);
              },
              child: const Text('UPDATE'),
            ),
        ],
      ),
    );
  }

  Future<void> _showDownloadDialog(String apkUrl) async {
    double progress = 0;
    late StateSetter dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          dialogSetState = setState;
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            title: const Text('Downloading Update…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 12),
                Text('${(progress * 100).toStringAsFixed(0)}%'),
              ],
            ),
          );
        },
      ),
    );

    await AppUpdateService.downloadAndInstall(
      apkUrl,
      onProgress: (p) {
        try { dialogSetState(() => progress = p); } catch (_) {}
      },
      onError: (error) {
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.red),
          );
        }
      },
    );
    // Dismiss dialog after install intent launches
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _refreshNowPlaying() async {
    if (!mounted) return;
    final database = ref.read(databaseProvider);
    // Collect EPG channel IDs for all favorited channels + their failover alts
    final epgChannelIds = <String>{};
    final favChannels = _allChannels.where((c) => _favoritedChannelIds.contains(c.id));
    for (final c in favChannels) {
      final epgId = _getEpgId(c);
      if (epgId != null) epgChannelIds.add(epgId);
    }
    // Also include any currently filtered channels (e.g. failover alts in view)
    for (final c in _filteredChannels) {
      final epgId = _getEpgId(c);
      if (epgId != null) epgChannelIds.add(epgId);
    }
    if (epgChannelIds.isEmpty) return;
    final maxShift = _epgTimeshifts.values.fold<int>(0, (m, v) => v.abs() > m ? v.abs() : m);
    final now = DateTime.now();
    final nowPlaying = maxShift > 0
        ? await database.getNowPlayingWindow(
            epgChannelIds.toList(),
            now.subtract(Duration(hours: maxShift + 1)),
            now.add(Duration(hours: maxShift + 1)))
        : await database.getNowPlaying(epgChannelIds.toList());
    if (!mounted) return;
    setState(() {
      _nowPlaying = nowPlaying;
    });
  }

  void _initFailoverListener() async {
    final prefs = await SharedPreferences.getInstance();
    _failoverEnabled = prefs.getBool(_kFailoverEnabled) ?? true;
    final playerService = ref.read(playerServiceProvider);
    _bufferingSub = playerService.bufferingStream.listen((buffering) {
      if (!_failoverEnabled) return;
      if (buffering) {
        // Start a 5-second timer — if still buffering, suggest alternative
        _failoverTimer?.cancel();
        _failoverTimer = Timer(const Duration(seconds: 5), () {
          if (!mounted) return;
          _suggestAlternative();
        });
      } else {
        _failoverTimer?.cancel();
        if (_showFailoverBanner) {
          setState(() => _showFailoverBanner = false);
        }
      }
    });
  }

  void _suggestAlternative() {
    if (_selectedIndex < 0 || _selectedIndex >= _filteredChannels.length) return;
    final current = _filteredChannels[_selectedIndex];
    final currentName = current.name.toLowerCase()
        .replaceAll(RegExp(r'\b(hd|fhd|shd|sd|4k|uhd)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'(us-?[a-z]*\|?|uk-?[a-z]*\|?|ca-?[a-z]*\|?|mx-?[a-z]*\|?)'), '')
        .replaceAll(RegExp(r'[\s|()[\]]+'), ' ')
        .trim();

    // 1. Best: exact same normalized name on a different provider
    final sameNameDiffProvider = _allChannels.where((c) =>
        c.id != current.id &&
        c.providerId != current.providerId &&
        _normalizeName(c.name) == currentName).toList();

    // 2. Good: exact same normalized name on the same provider (different stream)
    final sameNameSameProvider = _allChannels.where((c) =>
        c.id != current.id &&
        c.providerId == current.providerId &&
        _normalizeName(c.name) == currentName).toList();

    // 3. Fallback: channels containing key words of the current name
    final words = currentName.split(RegExp(r'\s+'))
        .where((w) => w.length > 2).toList();
    final fuzzyMatches = words.isEmpty ? <db.Channel>[] : _allChannels
        .where((c) => c.id != current.id &&
            words.every((w) => c.name.toLowerCase().contains(w)))
        .toList();

    final candidates = [
      ...sameNameDiffProvider,
      ...sameNameSameProvider,
      ...fuzzyMatches,
    ];
    if (candidates.isEmpty) return;

    setState(() {
      _failoverSuggestion = candidates.first;
      _showFailoverBanner = true;
    });
  }

  String _normalizeName(String name) {
    return name.toLowerCase()
        .replaceAll(RegExp(r'\b(hd|fhd|shd|sd|4k|uhd)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'(us-?[a-z]*\|?|uk-?[a-z]*\|?|ca-?[a-z]*\|?|mx-?[a-z]*\|?)'), '')
        .replaceAll(RegExp(r'[\s|()[\]]+'), ' ')
        .trim();
  }

  /// Extract a broadcast call-sign sort key from a channel name.
  /// Channels with call signs (W/K + 2-3 letters) sort first (uppercase),
  /// others sort by cleaned name (lowercase) so they come after.
  static String _callSignSortKey(String name) {
    // Strip provider prefixes like "US-P|", "US: ", "UK- ", "CA-", "MX-"
    var s = name.replaceAll(RegExp(r'^[A-Z]{2}[\s:-]*[A-Z]*\|'), '');
    s = s.replaceAll(RegExp(r'^(US|UK|CA|MX)[\s:-]+', caseSensitive: false), '');
    // Strip bracketed tags [US], [SP], [H]
    s = s.replaceAll(RegExp(r'\[.*?\]'), '');
    // Strip quality tags
    s = s.replaceAll(RegExp(r'\b(HD|FHD|SHD|SD|4K|UHD)\b', caseSensitive: false), '');
    // Strip common location names
    s = s.replaceAll(RegExp(r'\b(New York|Los Angeles|Chicago|Houston|Phoenix|Philadelphia|San Antonio|San Diego|Dallas|San Jose|Austin|Jacksonville|Fort Worth|Columbus|Charlotte|Indianapolis|San Francisco|Seattle|Denver|Washington|Nashville|Oklahoma City|El Paso|Boston|Portland|Las Vegas|Memphis|Louisville|Baltimore|Milwaukee|Albuquerque|Tucson|Fresno|Mesa|Sacramento|Atlanta|Kansas City|Colorado Springs|Omaha|Raleigh|Long Beach|Virginia Beach|Miami|Oakland|Minneapolis|Tampa|Tulsa|Arlington|New Orleans|Cleveland|Orlando|Cincinnati|Pittsburgh|Detroit|St\.? Louis)\b', caseSensitive: false), '');
    s = s.trim();
    // Try to find a broadcast call sign: W or K followed by 2-3 letters
    final csMatch = RegExp(r'\b([WK][A-Z]{2,3})\b', caseSensitive: false).firstMatch(s);
    if (csMatch != null) {
      final cs = csMatch.group(1)!.toUpperCase();
      // Validate it looks like a real call sign (not a common word)
      if (cs.length >= 3 && cs.length <= 4) return cs;
    }
    // No call sign found — return cleaned name lowercase (sorts after uppercase)
    return s.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ').trim().toLowerCase();
  }

  /// Normalize a channel/EPG display name for fuzzy EPG matching.
  /// Strips country tags, quality tags, provider prefixes, call signs in parens.
  static String _normalizeForEpgMatch(String name) {
    return name.toLowerCase()
        .replaceAll(RegExp(r'\[.*?\]'), '')           // [US], [SP], [H]
        .replaceAll(RegExp(r'\(.*?\)'), '')            // (WABC), (S)
        .replaceAll(RegExp(r'\b(hd|fhd|shd|sd|4k|uhd|us|uk|ca|mx)\b'), '')
        .replaceAll(RegExp(r'us-?[a-z]*\|'), '')      // US-P| prefix
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')        // non-alphanum → space
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Extract a broadcast call sign (3-4 uppercase letters starting with W or K)
  /// from a channel name. Checks parenthesized call signs like (WABC) first,
  /// then tvgId patterns, then words in the name.
  static final _callSignInParens = RegExp(r'\(([WK][A-Z]{2,3})\)');
  static final _callSignInTvgId = RegExp(r'[.\-_]([wk][a-z]{2,3})(?:[.\-_]|$)', caseSensitive: false);
  static final _callSignWord = RegExp(r'\b([WK][A-Z]{2,3})\b');

  static String? _extractCallSign(String name, String? tvgId) {
    // 1. Check parenthesized call sign: (WABC)
    final parenMatch = _callSignInParens.firstMatch(name);
    if (parenMatch != null) return parenMatch.group(1)!.toUpperCase();
    // 2. Check tvgId for embedded call sign: abcwabc.us, ABC.(WABC).New.York
    if (tvgId != null && tvgId.isNotEmpty) {
      final tvgMatch = _callSignInTvgId.firstMatch(tvgId);
      if (tvgMatch != null) return tvgMatch.group(1)!.toUpperCase();
      // Also try last segment before .us: e.g. "cbs2wcbs.us" → extract WCBS
      final dotParts = tvgId.replaceAll(RegExp(r'\.us$', caseSensitive: false), '').split('.');
      for (final part in dotParts) {
        final m = RegExp(r'([wk][a-z]{2,3})$', caseSensitive: false).firstMatch(part);
        if (m != null) return m.group(1)!.toUpperCase();
      }
    }
    // 3. Check name for standalone call sign word
    final wordMatch = _callSignWord.firstMatch(name.replaceAll(RegExp(r'\(.*?\)'), ''));
    if (wordMatch != null) return wordMatch.group(1)!.toUpperCase();
    return null;
  }

  /// Clear the search bar and re-apply filters.
  void _clearSearch() {
    if (_searchQuery.isEmpty) return;
    // Save non-empty query to history before clearing
    _addSearchHistory(_searchQuery);
    _searchQuery = '';
    _searchController.clear();
    _applyFilters();
  }

  /// Add a query to search history (persisted via SharedPreferences).
  void _addSearchHistory(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _searchHistory.remove(trimmed);
    _searchHistory.insert(0, trimmed);
    if (_searchHistory.length > _kMaxSearchHistory) {
      _searchHistory = _searchHistory.sublist(0, _kMaxSearchHistory);
    }
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList(_kSearchHistory, _searchHistory);
    });
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory = prefs.getStringList(_kSearchHistory) ?? [];
  }

  void _acceptFailover() {
    if (_failoverSuggestion == null) return;
    final idx = _filteredChannels.indexWhere((c) => c.id == _failoverSuggestion!.id);
    if (idx >= 0) {
      _selectChannel(idx);
    } else {
      // Channel not in current filter — play directly
      final playerService = ref.read(playerServiceProvider);
      playerService.play(_failoverSuggestion!.streamUrl,
        channelId: _failoverSuggestion!.id,
        epgChannelId: _getEpgId(_failoverSuggestion!),
        tvgId: _failoverSuggestion!.tvgId,
        channelName: _failoverSuggestion!.name,
        vanityName: _vanityNames[_failoverSuggestion!.id],
        originalName: _failoverSuggestion!.tvgName,
      );
      setState(() {
        _previewChannel = _failoverSuggestion;
      });
    }
    setState(() {
      _showFailoverBanner = false;
      _failoverSuggestion = null;
    });
  }

  void _startTopBarFade() {
    _topBarTimer?.cancel();
    if (_mouseInTopBar || Platform.isAndroid) return;
    _topBarTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_mouseInTopBar) setState(() => _topBarOpacity = 0.0);
    });
  }

  void _showTopBar() {
    setState(() => _topBarOpacity = 1.0);
    _startTopBarFade();
  }

  /// Add default EPG sources on first run and kick off a background refresh.
  Future<void> _ensureEpgSources() async {
    final epgService = ref.read(epgRefreshServiceProvider);
    await epgService.addDefaultSources();
    // Refresh in background — don't block the UI
    epgService.refreshAllSources().then((_) {
      debugPrint('[EPG] Background refresh complete');
    }).catchError((e) {
      debugPrint('[EPG] Background refresh failed: $e');
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _sidebarSearchController.dispose();
    _sidebarFocusNode.dispose();
    _sidebarAllItemFocusNode.dispose();
    _firstChannelFocusNode.dispose();
    _channelListController.dispose();
    _guideScrollController.dispose();
    _guideIdleTimer?.cancel();
    _searchDebounce?.cancel();
    _overlayTimer?.cancel();
    _nowPlayingTimer?.cancel();
    _volumeOverlayTimer?.cancel();
    _topBarTimer?.cancel();
    _failoverTimer?.cancel();
    _bufferingSub?.cancel();
    _providersSub?.cancel();
    _channelsSub?.cancel();
    _longPressTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadChannels() async {
    final database = ref.read(databaseProvider);
    final isFirstLoad = _allChannels.isEmpty;

    // ── Micro-phase 1: providers + favIds (tiny queries) ──
    if (mounted) setState(() => _loadStatus = 'Loading providers…');
    final results = await Future.wait([
      database.getAllProviders(),
      database.getAllFavoriteLists(),
      database.getAllFavoritedChannelIds(),
      SharedPreferences.getInstance(),
    ]);
    final providers = results[0] as List<db.Provider>;
    final favLists = results[1] as List<db.FavoriteList>;
    final favChannelIds = results[2] as Set<String>;
    final prefs = results[3] as SharedPreferences;

    // Vanity names (sync parse from already-loaded prefs)
    final vanityJson = prefs.getString('channel_vanity_names');
    if (vanityJson != null) {
      try {
        final decoded = jsonDecode(vanityJson) as Map<String, dynamic>;
        _vanityNames = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {}
    }

    // ── Micro-phase 2: favorite channels (direct ID query, ~18 rows) ──
    if (mounted) setState(() => _loadStatus = 'Loading ${favChannelIds.length} favorites…');
    List<db.Channel> favChannels = [];
    if (favChannelIds.isNotEmpty) {
      favChannels = await database.getChannelsByIds(favChannelIds);
    }

    if (!mounted) return;
    if (mounted) setState(() => _loadStatus = 'Found ${providers.length} providers, ${favChannels.length} favorites');
    // FIRST RENDER — user sees Favorites immediately
    setState(() {
      _initialLoadDone = true;
      _allChannels = favChannels;
      _providers = providers;
      _favoriteLists = favLists;
      _favoritedChannelIds = favChannelIds;
      _selectedGroup = 'Favorites';
      _applyFilters();
    });
    if (isFirstLoad) _restoreSession();

    // ── Background: sidebar groups + failover groups (non-blocking) ──
    if (mounted) setState(() => _loadStatus = 'Loading Smart Channel groups…');
    final bgResults = await Future.wait([
      database.getProviderGroups(),
      database.getAllFailoverGroups(),
    ]);
    final pGroups = bgResults[0] as Map<String, List<String>>;
    final foGroups = bgResults[1] as List<db.FailoverGroup>;
    final allGroupNames = <String>{};
    for (final gl in pGroups.values) {
      allGroupNames.addAll(gl);
    }

    final foGroupMembers = <int, List<String>>{};
    for (final g in foGroups) {
      final members = await database.getFailoverGroupMembers(g.id);
      foGroupMembers[g.id] = members.map((m) => m.channelId).toList();
    }
    final foGroupIndex = await database.getFailoverGroupIndex();

    if (!mounted) return;
    setState(() {
      _providerGroups = pGroups;
      _groups = allGroupNames.toList()..sort();
      _failoverGroups = foGroups;
      _failoverGroupMembers = foGroupMembers;
      _failoverGroupIndex = foGroupIndex;
      _applyFilters(); // Re-filter to hide grouped channels
    });

    // ── Background: EPG for favorites ──
    setState(() => _epgLoading = true);
    await _loadEpgData(database, favChannels, favChannelIds);
    if (mounted) setState(() => _epgLoading = false);

    // ── Background: load all provider channels incrementally ──
    _backgroundLoading = true;
    for (final provider in providers) {
      if (!mounted) return;
      final channels = await database.getChannelsForProvider(provider.id);
      if (!mounted) return;
      final existingIds = _allChannels.map((c) => c.id).toSet();
      final newChannels = channels.where((c) => !existingIds.contains(c.id)).toList();
      _loadedProviders.add(provider.id);
      setState(() {
        _allChannels = [..._allChannels, ...newChannels];
        if (_selectedGroup == 'All' || _selectedGroup == 'provider:${provider.id}' ||
            _selectedGroup.startsWith('provgroup:${provider.id}:')) {
          _applyFilters();
        }
      });
    }
    _backgroundLoading = false;

    // Re-index EPG with full channel set
    if (mounted) _loadEpgData(database, _allChannels, favChannelIds);
  }

  /// On-demand: load a single provider's channels into _allChannels.
  Future<void> _loadProviderChannels(String providerId) async {
    if (_loadedProviders.contains(providerId)) return;
    final database = ref.read(databaseProvider);
    final channels = await database.getChannelsForProvider(providerId);
    if (!mounted) return;
    _loadedProviders.add(providerId);
    final existingIds = _allChannels.map((c) => c.id).toSet();
    final newChannels = channels.where((c) => !existingIds.contains(c.id)).toList();
    setState(() {
      _allChannels = [..._allChannels, ...newChannels];
      _applyFilters();
    });
  }

  /// Loads EPG sources, mappings, and now-playing data in the background.
  /// Updates state incrementally so the UI is never blocked.
  Future<void> _loadEpgData(
    db.AppDatabase database,
    List<db.Channel> allChannels,
    Set<String> favChannelIds,
  ) async {
    final epgSources = await database.getAllEpgSources();
    final currentSourceIds = epgSources.map((s) => s.id).toSet();
    final validIds = <String>{};
    final rawToPrefixed = <String, String>{};
    final epgNameToId = <String, String>{};
    final epgCallSignToId = <String, String>{}; // WABC → prefixed id
    for (final src in epgSources) {
      final chs = await database.getEpgChannelsForSource(src.id);
      for (final ch in chs) {
        validIds.add(ch.id);
        rawToPrefixed[ch.channelId.toLowerCase()] = ch.id;
        final normName = _normalizeForEpgMatch(ch.displayName);
        if (normName.isNotEmpty) epgNameToId[normName] = ch.id;
        // Index by call sign extracted from channelId (e.g. WABC.us → WABC)
        final rawUpper = ch.channelId.toUpperCase();
        final csMatch = RegExp(r'^([WK][A-Z]{2,3})\.').firstMatch(rawUpper);
        if (csMatch != null) {
          epgCallSignToId.putIfAbsent(csMatch.group(1)!, () => ch.id);
        }
        // Also index from local station IDs like abc.ny.newyork.wabc
        final dotParts = ch.channelId.split('.');
        if (dotParts.length >= 4) {
          final lastPart = dotParts.last.toUpperCase();
          if (RegExp(r'^[WK][A-Z]{2,3}$').hasMatch(lastPart)) {
            epgCallSignToId.putIfAbsent(lastPart, () => ch.id);
          }
        }
      }
    }

    final mappings = await database.getAllMappings();
    final epgMap = <String, String>{};
    for (final m in mappings) {
      final directKey = '${m.epgSourceId}_${m.epgChannelId}';
      if (currentSourceIds.contains(m.epgSourceId)) {
        epgMap[m.channelId] = directKey;
      } else {
        for (final srcId in currentSourceIds) {
          final candidate = '${srcId}_${m.epgChannelId}';
          if (validIds.contains(candidate)) {
            epgMap[m.channelId] = candidate;
            break;
          }
        }
      }
    }

    // Build failover name index + EPG scope
    final normNameIndex = <String, List<String>>{};
    for (final c in allChannels) {
      final norm = _normalizeName(c.name);
      (normNameIndex[norm] ??= []).add(c.id);
    }
    final epgScopeIds = <String>{...favChannelIds};
    final favChannels = allChannels.where((c) => favChannelIds.contains(c.id));
    for (final fav in favChannels) {
      final normName = _normalizeName(fav.name);
      final alts = normNameIndex[normName];
      if (alts != null) epgScopeIds.addAll(alts);
    }

    // Collect EPG channel IDs for now-playing lookup
    final epgChannelIds = <String>{};
    for (final c in allChannels) {
      if (!epgScopeIds.contains(c.id)) continue;
      final mapped = epgMap[c.id];
      if (mapped != null && mapped.isNotEmpty) {
        epgChannelIds.add(mapped);
        continue;
      }
      if (c.tvgId != null && c.tvgId!.isNotEmpty) {
        final prefixed = rawToPrefixed[c.tvgId!.toLowerCase()];
        if (prefixed != null) { epgChannelIds.add(prefixed); continue; }
      }
      // Fallback: match by normalized channel name
      final normName = _normalizeForEpgMatch(c.name);
      if (normName.isNotEmpty) {
        final byName = epgNameToId[normName];
        if (byName != null) { epgChannelIds.add(byName); continue; }
      }
      // Fallback: match by call sign (WABC, WCBS, WNYW)
      final callSign = _extractCallSign(c.name, c.tvgId);
      if (callSign != null) {
        final byCs = epgCallSignToId[callSign];
        if (byCs != null) epgChannelIds.add(byCs);
      }
    }
    List<db.EpgProgramme> nowPlaying = [];
    if (epgChannelIds.isNotEmpty) {
      nowPlaying = await database.getNowPlaying(epgChannelIds.toList());
    }

    if (!mounted) return;
    setState(() {
      _nowPlaying = nowPlaying;
      _epgMappings = epgMap;
      _validEpgChannelIds = validIds;
      _rawToPrefixedEpg = rawToPrefixed;
      _epgNameToId = epgNameToId;
      _epgCallSignToId = epgCallSignToId;
    });
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _use24HourTime = prefs.getBool(_kUse24HourTime) ?? false;

    // Restore EPG timeshifts
    final tsJson = prefs.getString(_kEpgTimeshifts);
    if (tsJson != null) {
      try {
        final decoded = jsonDecode(tsJson) as Map<String, dynamic>;
        _epgTimeshifts.clear();
        decoded.forEach((k, v) => _epgTimeshifts[k] = v as int);
      } catch (_) {}
    }
    final lastGroup = prefs.getString(_kLastGroup);
    final lastChannelId = prefs.getString(_kLastChannelId);

    if (lastGroup != null && lastGroup != _selectedGroup) {
      setState(() {
        _selectedGroup = lastGroup;
        _applyFilters();
      });
    }

    if (lastChannelId != null && _filteredChannels.isNotEmpty) {
      final idx = _filteredChannels.indexWhere((c) => c.id == lastChannelId);
      if (idx >= 0) {
        _selectChannel(idx);
      }
    }

    // Refresh EPG now-playing after restoring timeshifts and group
    _refreshNowPlaying();
  }

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastGroup, _selectedGroup);
    if (_selectedIndex >= 0 && _selectedIndex < _filteredChannels.length) {
      await prefs.setString(_kLastChannelId, _filteredChannels[_selectedIndex].id);
    }
  }

  void _applyFilters() {
    var channels = _allChannels;

    // When sidebar search is active, search ALL channels regardless of group
    if (_sidebarSearchQuery.isNotEmpty) {
      final terms = _sidebarSearchQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      channels = channels
          .where((c) {
            final nowPlaying = _getChannelNowPlaying(c) ?? '';
            final haystack = '${c.name} ${c.groupTitle ?? ''} $nowPlaying'.toLowerCase();
            return terms.every((t) => haystack.contains(t));
          })
          .toList();
    } else {
      // Group filters only apply when not searching
      if (_selectedGroup == 'Favorites') {
        channels =
            channels.where((c) => _favoritedChannelIds.contains(c.id)).toList()
              ..sort((a, b) => _callSignSortKey(_channelDisplayName(a)).compareTo(_callSignSortKey(_channelDisplayName(b))));
      } else if (_selectedGroup.startsWith('fav:')) {
        final listId = _selectedGroup.substring(4);
        _applyFavoriteListFilter(listId);
        return;
      } else if (_selectedGroup.startsWith('provider:')) {
        final providerId = _selectedGroup.substring(9);
        if (!_loadedProviders.contains(providerId)) {
          _loadProviderChannels(providerId);
          _filteredChannels = [];
          return;
        }
        channels =
            channels.where((c) => c.providerId == providerId).toList();
      } else if (_selectedGroup.startsWith('provgroup:')) {
        // Format: provgroup:{providerId}:{groupTitle}
        final parts = _selectedGroup.substring(10);
        final sepIdx = parts.indexOf(':');
        if (sepIdx > 0) {
          final providerId = parts.substring(0, sepIdx);
          final groupTitle = parts.substring(sepIdx + 1);
          if (!_loadedProviders.contains(providerId)) {
            _loadProviderChannels(providerId);
            _filteredChannels = [];
            return;
          }
          channels = channels
              .where((c) => c.providerId == providerId && c.groupTitle == groupTitle)
              .toList();
        }
      } else if (_selectedGroup != 'All') {
        channels =
            channels.where((c) => c.groupTitle == _selectedGroup).toList();
      }
    }

    // Top-bar search: when active, search ALL channels across ALL providers
    // regardless of group selection. Single-pass haystack for speed.
    if (_searchQuery.isNotEmpty) {
      final tokens = _searchQuery.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      if (tokens.isNotEmpty) {
        channels = _allChannels.where((c) {
          final haystack = '${c.name}\x00${_vanityNames[c.id] ?? ''}\x00${c.groupTitle ?? ''}\x00${c.tvgId ?? ''}'
              .toLowerCase();
          return tokens.every((t) => haystack.contains(t));
        }).toList();
      }
    }

    // Hide channels that belong to a failover group — group rows replace them
    if (_failoverGroupMembers.isNotEmpty) {
      final grouped = <String>{};
      for (final ids in _failoverGroupMembers.values) {
        grouped.addAll(ids);
      }
      channels = channels.where((c) => !grouped.contains(c.id)).toList();
    }

    _filteredChannels = channels;
    if (_selectedIndex >= _filteredChannels.length) {
      _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
    }
  }

  Future<void> _applyFavoriteListFilter(String listId) async {
    final database = ref.read(databaseProvider);
    var channels = await database.getChannelsInList(listId);
    if (_searchQuery.isNotEmpty) {
      final tokens = _searchQuery.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      if (tokens.isNotEmpty) {
        // Search ALL channels, not just favorites
        channels = _allChannels.where((c) {
          final haystack = '${c.name}\x00${_vanityNames[c.id] ?? ''}\x00${c.groupTitle ?? ''}\x00${c.tvgId ?? ''}'
              .toLowerCase();
          return tokens.every((t) => haystack.contains(t));
        }).toList();
      }
    }
    if (_sidebarSearchQuery.isNotEmpty) {
      channels = channels
          .where((c) {
            final q = _sidebarSearchQuery;
            return c.name.toLowerCase().contains(q) ||
                (_vanityNames[c.id]?.toLowerCase().contains(q) ?? false);
          })
          .toList();
    }
    channels.sort((a, b) => _callSignSortKey(_channelDisplayName(a)).compareTo(_callSignSortKey(_channelDisplayName(b))));
    if (!mounted) return;
    setState(() {
      _filteredChannels = channels;
      if (_selectedIndex >= _filteredChannels.length) {
        _selectedIndex = _filteredChannels.isEmpty ? -1 : 0;
      }
    });
    // Ensure EPG data is loaded for the favorite list channels
    _refreshNowPlaying();
  }

  void _selectChannel(int index) {
    if (index < 0 || index >= _filteredChannels.length) return;
    // Skip if already selected — don't reload the stream
    if (index == _selectedIndex) return;
    // Remember current as previous (for back/forth toggle)
    if (_selectedIndex >= 0 && _selectedIndex != index) {
      _previousIndex = _selectedIndex;
    }
    final channel = _filteredChannels[index];
    final playerService = ref.read(playerServiceProvider);

    // Check if channel belongs to a failover group → pass group URLs
    final groupMemberships = _failoverGroupIndex[channel.id];
    List<String>? failoverUrls;
    if (groupMemberships != null && groupMemberships.isNotEmpty) {
      final groupId = groupMemberships.first.group.id;
      final memberIds = _failoverGroupMembers[groupId] ?? [];
      final channelById = <String, db.Channel>{};
      for (final c in _allChannels) {
        channelById[c.id] = c;
      }
      failoverUrls = memberIds
          .map((id) => channelById[id]?.streamUrl)
          .whereType<String>()
          .where((url) => url != channel.streamUrl)
          .toList();
    }

    playerService.play(channel.streamUrl,
      channelId: channel.id,
      epgChannelId: _getEpgId(channel),
      tvgId: channel.tvgId,
      channelName: channel.name,
      vanityName: _vanityNames[channel.id],
      originalName: channel.tvgName,
      failoverGroupUrls: failoverUrls,
    );
    setState(() {
      _selectedIndex = index;
      _previewChannel = channel;
    });
    _showInfoOverlay(channel, index);
    _saveSession();
  }

  /// Toggle between current channel and the last channel.
  void _goBackChannel() {
    if (_previousIndex < 0 || _previousIndex >= _filteredChannels.length) return;
    final swapTo = _previousIndex;
    _previousIndex = _selectedIndex;
    final channel = _filteredChannels[swapTo];
    final playerService = ref.read(playerServiceProvider);
    playerService.play(channel.streamUrl,
      channelId: channel.id,
      epgChannelId: _getEpgId(channel),
      tvgId: channel.tvgId,
      channelName: channel.name,
      vanityName: _vanityNames[channel.id],
      originalName: channel.tvgName,
    );
    setState(() {
      _selectedIndex = swapTo;
      _previewChannel = channel;
    });
    _showInfoOverlay(channel, swapTo);
  }

  void _showInfoOverlay(db.Channel channel, int index) {
    setState(() => _showOverlay = true);

    // Reset auto-hide timer
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showOverlay = false);
    });
  }

  Future<void> _goFullscreen(db.Channel channel) async {
    final channelMaps = _filteredChannels
        .map((c) => <String, dynamic>{
              'id': c.id,
              'providerId': c.providerId,
              'name': _channelDisplayName(c),
              'originalName': c.name,
              'streamUrl': c.streamUrl,
              'tvgLogo': c.tvgLogo,
              'tvgId': c.tvgId,
              'tvgName': c.tvgName,
              'groupTitle': c.groupTitle,
              'streamType': c.streamType,
              'epgId': _getEpgId(c),
              'epgChannelId': _getEpgId(c),
              'vanityName': _vanityNames[c.id],
              'alternativeUrls': <String>[],
            })
        .toList();
    await context.push('/player', extra: {
      'streamUrl': channel.streamUrl,
      'channelName': _channelDisplayName(channel),
      'channelLogo': channel.tvgLogo,
      'alternativeUrls': <String>[],
      'channels': channelMaps,
      'currentIndex': _selectedIndex >= 0 ? _selectedIndex : 0,
    });
    if (mounted) _showTopBar();
  }

  // ---------------------------------------------------------------------------
  // EPG helpers
  // ---------------------------------------------------------------------------

  /// Get the effective EPG channel ID: mapped ID takes priority, then tvgId, then name match.
  String? _getEpgId(db.Channel channel) {
    final mapped = _epgMappings[channel.id];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    if (channel.tvgId != null && channel.tvgId!.isNotEmpty) {
      final prefixed = _rawToPrefixedEpg[channel.tvgId!.toLowerCase()];
      if (prefixed != null) return prefixed;
    }
    // Fallback: match by normalized channel name against EPG display names
    final normName = _normalizeForEpgMatch(channel.name);
    if (normName.isNotEmpty) {
      final byName = _epgNameToId[normName];
      if (byName != null) return byName;
    }
    // Fallback: match by broadcast call sign (WABC, WCBS, etc.)
    final callSign = _extractCallSign(channel.name, channel.tvgId);
    if (callSign != null) {
      final byCs = _epgCallSignToId[callSign];
      if (byCs != null) return byCs;
    }
    return null;
  }

  String _getProviderName(String providerId) {
    for (final p in _providers) {
      if (p.id == providerId) return p.name;
    }
    return '';
  }

  String? _getChannelNowPlaying(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final match =
        _nowPlaying.where((p) => p.epgChannelId == epgId).toList();
    return match.isNotEmpty ? match.first.title : null;
  }

  /// Display name for a channel — vanity name if set, otherwise original name.
  String _channelDisplayName(db.Channel channel) =>
      _vanityNames[channel.id] ?? channel.name;

  /// Get failover alternative details for a channel (for debug dialog).
  List<AlternativeDetail> _getFailoverAlts(db.Channel channel) {
    try {
      return ref.read(streamAlternativesProvider).getAlternativeDetails(
        channelId: channel.id,
        epgChannelId: _getEpgId(channel),
        tvgId: channel.tvgId,
        channelName: channel.name,
        vanityName: _vanityNames[channel.id],
        originalName: channel.tvgName,
        excludeUrl: channel.streamUrl,
      );
    } catch (_) {
      return [];
    }
  }

  /// All current/upcoming programme titles for a channel (for search).
  List<String> _getChannelProgrammeTitles(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return const [];
    return _nowPlaying
        .where((p) => p.epgChannelId == epgId)
        .map((p) => p.title)
        .toList();
  }

  db.EpgProgramme? _getEpgProgramme(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final shift = _epgTimeshifts[channel.id] ?? 0;
    final adjusted = DateTime.now().subtract(Duration(hours: shift));
    final matches = _nowPlaying.where((p) =>
        p.epgChannelId == epgId &&
        !p.start.isAfter(adjusted) &&
        p.stop.isAfter(adjusted)).toList();
    return matches.isNotEmpty ? matches.first : null;
  }

  db.EpgProgramme? _getNextProgramme(db.Channel channel) {
    final epgId = _getEpgId(channel);
    if (epgId == null) return null;
    final current = _getEpgProgramme(channel);
    if (current == null) return null;
    final matches = _nowPlaying.where((p) =>
        p.epgChannelId == epgId &&
        !p.start.isBefore(current.stop)).toList();
    matches.sort((a, b) => a.start.compareTo(b.start));
    return matches.isNotEmpty ? matches.first : null;
  }

  String _formatTime(DateTime dt) {
    if (_use24HourTime) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  String? _programmeTimeRange(db.EpgProgramme? p, {int timeshiftHours = 0}) {
    if (p == null) return null;
    final shift = Duration(hours: timeshiftHours);
    return '${_formatTime(p.start.add(shift))} - ${_formatTime(p.stop.add(shift))}';
  }

  /// Parse XMLTV episode-num into readable label (e.g. "S2 E5").
  String? _parseEpisodeLabel(String? episodeNum) {
    if (episodeNum == null || episodeNum.isEmpty) return null;
    final se = _parseSeasonEpisode(episodeNum);
    if (se != null) return 'S${se.$1} E${se.$2}';
    return episodeNum;
  }

  /// Parse episode string into (season, episode) integers.
  (int, int)? _parseSeasonEpisode(String? episodeNum) {
    if (episodeNum == null || episodeNum.isEmpty) return null;
    final seFmt = RegExp(r'S(\d+)\s*E(\d+)', caseSensitive: false);
    final seMatch = seFmt.firstMatch(episodeNum);
    if (seMatch != null) {
      return (int.parse(seMatch.group(1)!), int.parse(seMatch.group(2)!));
    }
    final nsFmt = RegExp(r'^(\d+)\.(\d+)');
    final nsMatch = nsFmt.firstMatch(episodeNum);
    if (nsMatch != null) {
      return (int.parse(nsMatch.group(1)!) + 1, int.parse(nsMatch.group(2)!) + 1);
    }
    return null;
  }

  /// Build IMDB URL — exact if IMDB ID cached, otherwise search fallback.
  String _imdbUrl(String title, String? episodeNum) {
    final imdbId = _imdbIdCache[title.toLowerCase()];
    if (imdbId != null) {
      final se = _parseSeasonEpisode(episodeNum);
      if (se != null) {
        return 'https://www.imdb.com/title/$imdbId/episodes/?season=${se.$1}';
      }
      return 'https://www.imdb.com/title/$imdbId/';
    }
    return 'https://www.imdb.com/find/?q=${Uri.encodeComponent(title)}&s=tt&ttype=tv';
  }

  /// Resolve IMDB ID for a show via TMDB (cached, background).
  Future<void> _resolveImdbId(String title) async {
    final key = title.toLowerCase();
    if (_imdbIdCache.containsKey(key)) return;
    _imdbIdCache[key] = null; // mark in-progress
    try {
      final keys = ref.read(showsApiKeysProvider);
      if (!keys.hasTmdbKey) return;
      final tmdb = TmdbClient(apiKey: keys.tmdbApiKey);
      final results = await tmdb.searchTv(title);
      if (results.isEmpty) return;
      final detail = await tmdb.getTvShow(results.first.id);
      if (detail.imdbId != null && detail.imdbId!.isNotEmpty) {
        _imdbIdCache[key] = detail.imdbId;
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  void _resetGuideIdleTimer(DateTime dayStart) {
    _guideIdleTimer?.cancel();
    _guideIdleTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || !_guideScrollController.hasClients) return;
      final now = DateTime.now();
      // Scroll to 30 minutes before now
      final targetMin = now.difference(dayStart).inMinutes - 30;
      final target = (targetMin * _pixelsPerMinute)
          .clamp(0.0, _guideScrollController.position.maxScrollExtent);
      _guideScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Keyboard navigation
  // ---------------------------------------------------------------------------

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    // On Android/TV, arrow keys are used for D-pad focus navigation.
    // Channel switching uses dedicated channelUp/channelDown keys.
    final isAndroid = Platform.isAndroid;

    // Open debug info dialog with 'D' key
    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.keyD) {
      if (_previewChannel != null) {
        final ps = ref.read(playerServiceProvider);
        final alts = _getFailoverAlts(_previewChannel!);
        ChannelDebugDialog.show(context, _previewChannel!, ps,
            mappedEpgId: _getEpgId(_previewChannel!),
            originalName: _previewChannel!.tvgName ?? _previewChannel!.name,
            currentProviderName: ref.read(streamAlternativesProvider).providerName(_previewChannel!.providerId),
            alternatives: alts);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.channelUp ||
        (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowUp)) {
      final newIndex = (_selectedIndex - 1).clamp(0, _filteredChannels.length - 1);
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.channelDown ||
        (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowDown)) {
      final newIndex = (_selectedIndex + 1).clamp(0, _filteredChannels.length - 1);
      if (newIndex != _selectedIndex) {
        _selectChannel(newIndex);
        _scrollToIndex(newIndex);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.select) {
      if (_previewChannel != null) {
        _goFullscreen(_previewChannel!);
      }
      return KeyEventResult.handled;
    }

    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }

    if (!isAndroid && event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    }

    // Backspace → go back in channel history
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _goBackChannel();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _scrollToIndex(int index) {
    // Approximate item height of ~52px
    final offset = (index * 52.0).clamp(
      0.0,
      _channelListController.position.maxScrollExtent,
    );
    _channelListController.animateTo(
      offset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _adjustVolume(double delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0.0, 100.0);
      _showVolumeOverlay = true;
    });
    ref.read(playerServiceProvider).setVolume(_volume);
    _volumeOverlayTimer?.cancel();
    _volumeOverlayTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolumeOverlay = false);
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_initialLoadDone) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A1A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/icon/naritta-icon.png', width: 80, height: 80,
                errorBuilder: (_, _, _) => const Icon(Icons.tv, size: 64, color: Color(0xFF6C5CE7))),
              const SizedBox(height: 12),
              const Text('Naritta', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              const SizedBox(
                width: 32, height: 32,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6C5CE7)),
              ),
              const SizedBox(height: 16),
              Text(_loadStatus,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ),
      );
    }
    if (_allChannels.isEmpty && _providers.isEmpty) {
      return _buildEmptyState(context);
    }

    return PopScope(
      canPop: false,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Focus(
          focusNode: _focusNode,
          autofocus: !Platform.isAndroid,
          skipTraversal: Platform.isAndroid,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (_searchFocusNode.hasFocus) return KeyEventResult.ignored;
            // Don't swallow keys when a dialog/overlay is open
            if (ModalRoute.of(context)?.isCurrent != true) return KeyEventResult.ignored;
            final key = event.logicalKey;
            // Let Flutter's spatial focus system handle D-pad arrows
            if (key == LogicalKeyboardKey.arrowUp ||
                key == LogicalKeyboardKey.arrowDown ||
                key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.arrowRight) {
              return KeyEventResult.ignored;
            }
            return _handleKeyEvent(event);
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF1A1A2E),
            body: SafeArea(
              child: Column(
                children: [
                  if (!Platform.isAndroid)
                  MouseRegion(
                    onEnter: (_) {
                      _mouseInTopBar = true;
                      _topBarTimer?.cancel();
                      setState(() => _topBarOpacity = 1.0);
                    },
                    onExit: (_) {
                      _mouseInTopBar = false;
                      _startTopBarFade();
                    },
                    child: AnimatedOpacity(
                      opacity: _topBarOpacity,
                      duration: const Duration(milliseconds: 600),
                      child: _buildTopBar(context),
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        // Main content area (full width, sidebar overlays on top)
                        Positioned.fill(
                          child: Column(
                            children: [
                              _buildPreviewRow(),
                              if (_showFailoverBanner && _failoverSuggestion != null)
                                _buildFailoverBanner(),
                              Expanded(
                                child: Stack(
                                  children: [
                                    _showGuideView ? _buildGuideView() : _buildChannelList(),
                                    if (_multiSelectMode)
                                      Positioned(
                                        left: 8, right: 8, bottom: 8,
                                        child: _buildMultiSelectBar(),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Collapsible sidebar tree — overlays content on the left
                        Positioned(
                          left: 0, top: 0, bottom: 0,
                          child: _buildSidebar(),
                        ),
                        // Hamburger button to reopen sidebar (always visible)
                        if (!_sidebarExpanded)
                          Positioned(
                            left: 4, top: 4,
                            child: Material(
                              color: const Color(0xFF111127).withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(8),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => setState(() => _sidebarExpanded = true),
                                child: const Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(Icons.menu_rounded, color: Colors.white70, size: 22),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (!Platform.isAndroid) _buildTopBar(context),
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.live_tv_rounded,
                        size: 64, color: Colors.white24),
                    SizedBox(height: 16),
                    Text(
                      'No channels yet',
                      style:
                          TextStyle(fontSize: 20, color: Colors.white54),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Add an IPTV provider to get started',
                      style:
                          TextStyle(fontSize: 14, color: Colors.white38),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              autofocus: true,
              onPressed: () => context.push('/providers'),
              icon: const Icon(Icons.add),
              label: const Text('Add Provider'),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final isMoviesRoute = GoRouterState.of(context).uri.toString() == '/movies';
    final isSeriesRoute = GoRouterState.of(context).uri.toString() == '/series';
    final isLiveRoute = GoRouterState.of(context).uri.toString() == '/';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Menu toggle (hamburger)
          IconButton(
            icon: Icon(
              _sidebarExpanded ? Icons.menu_open_rounded : Icons.menu_rounded,
              color: Colors.white70,
              size: 20,
            ),
            onPressed: () => setState(() => _sidebarExpanded = !_sidebarExpanded),
            tooltip: 'Toggle sidebar',
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
          const SizedBox(width: 8),
          // Navigation tabs
          _navTab(Icons.live_tv, 'TV', () => context.go('/'), isLiveRoute),
          const SizedBox(width: 4),
          _navTab(Icons.movie_outlined, 'Movies', () => context.go('/movies'), isMoviesRoute),
          const SizedBox(width: 4),
          _navTab(Icons.tv_outlined, 'Series', () => context.go('/series'), isSeriesRoute),
          const SizedBox(width: 16),
          Expanded(
            child: SizedBox(
              height: 36,
              child: RawAutocomplete<String>(
                textEditingController: _searchController,
                focusNode: _searchFocusNode,
                optionsBuilder: (textEditingValue) {
                  if (textEditingValue.text.isEmpty && _searchHistory.isNotEmpty) {
                    return _searchHistory;
                  }
                  if (_searchHistory.isEmpty) return const Iterable<String>.empty();
                  final q = textEditingValue.text.toLowerCase();
                  return _searchHistory.where((h) => h.toLowerCase().contains(q));
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search channels...',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white12,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18, color: Colors.white38),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close,
                                  size: 18, color: Colors.white54),
                              onPressed: () {
                                setState(() {
                                  _clearSearch();
                                });
                                _focusNode.requestFocus();
                              },
                            )
                          : null,
                    ),
                    onChanged: (value) {
                      _searchDebounce?.cancel();
                      _searchQuery = value;
                      _searchDebounce = Timer(const Duration(seconds: 2), () {
                        if (mounted) setState(() => _applyFilters());
                      });
                    },
                    onSubmitted: (value) {
                      if (value.trim().isNotEmpty) _addSearchHistory(value.trim());
                      _focusNode.requestFocus();
                    },
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 8,
                      color: const Color(0xFF1A1A2E),
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240, maxWidth: 400),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final option = options.elementAt(index);
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.history, size: 16, color: Colors.white38),
                              title: Text(option, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 14, color: Colors.white24),
                                onPressed: () {
                                  setState(() {
                                    _searchHistory.remove(option);
                                    SharedPreferences.getInstance().then((prefs) {
                                      prefs.setStringList(_kSearchHistory, _searchHistory);
                                    });
                                  });
                                },
                              ),
                              onTap: () => onSelected(option),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
                onSelected: (selection) {
                  _searchController.text = selection;
                  setState(() {
                    _searchQuery = selection;
                    _applyFilters();
                  });
                  _focusNode.requestFocus();
                },
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
          // Previous channel toggle button
          if (_previousIndex >= 0)
            IconButton(
              icon: const Icon(Icons.swap_horiz_rounded, color: Colors.white70),
              tooltip: 'Previous channel (Backspace)',
              onPressed: _goBackChannel,
            ),
          IconButton(
            icon: const Icon(Icons.settings_rounded, color: Colors.white70),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
          // Cast icon removed — available in fullscreen player
                ],
              ),
            ),
          ),
          const Spacer(),
          const WeatherClockWidget(),
        ],
      ),
    );
  }

  Widget _navTab(IconData icon, String label, VoidCallback onTap, bool isActive) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? Colors.amber : Colors.white12,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isActive ? Colors.black : Colors.white70),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.black : Colors.white70,
                fontSize: 13,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Top section: video preview on left, programme + status info on right.
  Widget _buildPreviewRow() {
    final playerService = ref.watch(playerServiceProvider);
    final programme = _previewChannel != null ? _getEpgProgramme(_previewChannel!) : null;
    final nextProg = _previewChannel != null ? _getNextProgramme(_previewChannel!) : null;

    return SizedBox(
      height: 200,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Video preview (left, ~40% of available width, max 400px)
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: _previewChannel == null
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.tv_rounded, size: 48, color: Colors.white24),
                            SizedBox(height: 8),
                            Text('Select a channel', style: TextStyle(color: Colors.white38, fontSize: 13)),
                          ],
                        ),
                      )
                    : GestureDetector(
                        onTap: () => _goFullscreen(_previewChannel!),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Video(
                              controller: playerService.videoController,
                              controls: NoVideoControls,
                            ),
                            // Channel info overlay removed — info shown in panel to the right
                            if (_showVolumeOverlay)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _volume == 0 ? Icons.volume_off : _volume < 50 ? Icons.volume_down : Icons.volume_up,
                                        color: Colors.white, size: 16,
                                      ),
                                      const SizedBox(width: 4),
                                      Text('${_volume.round()}%', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            // Programme info + controls (right side)
            Expanded(
              child: _previewChannel == null
                  ? const SizedBox.shrink()
                  : Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16213E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top row: name+group left, badges+provider+time right
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _channelDisplayName(_previewChannel!),
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (_previewChannel!.groupTitle != null && _previewChannel!.groupTitle!.isNotEmpty)
                                      Text(
                                        _previewChannel!.groupTitle!,
                                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              // Stream info badges + provider + time
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _StreamInfoBadges(playerService: playerService),
                                      if (_getProviderName(_previewChannel!.providerId).isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF6C5CE7).withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            _getProviderName(_previewChannel!.providerId),
                                            style: const TextStyle(fontSize: 10, color: Color(0xFF6C5CE7), fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatTime(DateTime.now()),
                                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          // Now playing
                          if (programme != null) ...[
                            Row(
                              children: [
                                const Icon(Icons.play_circle_outline, size: 14, color: Colors.cyanAccent),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    programme.title,
                                    style: const TextStyle(color: Colors.white, fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              _programmeTimeRange(programme, timeshiftHours: _epgTimeshifts[_previewChannel!.id] ?? 0) ?? '',
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                          ],
                          if (programme != null && programme.description != null && programme.description!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                programme.description!,
                                style: const TextStyle(color: Colors.white54, fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          // Episode info + IMDB link
                          if (programme != null && programme.episodeNum != null && programme.episodeNum!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Builder(builder: (_) {
                                _resolveImdbId(programme.title);
                                final hasExact = _imdbIdCache[programme.title.toLowerCase()] != null;
                                return GestureDetector(
                                  onTap: () => launchUrl(Uri.parse(_imdbUrl(programme.title, programme.episodeNum))),
                                  child: Row(
                                    children: [
                                      Text(
                                        _parseEpisodeLabel(programme.episodeNum) ?? programme.episodeNum!,
                                        style: const TextStyle(color: Colors.white60, fontSize: 11),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        hasExact ? 'IMDb ↗' : 'IMDb 🔍',
                                        style: const TextStyle(color: Colors.amber, fontSize: 11, decoration: TextDecoration.underline),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ),
                          // Next up
                          if (nextProg != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                children: [
                                  const Text('Next: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                                  Expanded(
                                    child: Text(
                                      '${nextProg.title}  ${_programmeTimeRange(nextProg, timeshiftHours: _epgTimeshifts[_previewChannel!.id] ?? 0) ?? ''}',
                                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          // Bottom row: status + controls
                          Row(
                            children: [
                              // Buffering status
                              StreamBuilder<bool>(
                                stream: playerService.bufferingStream,
                                builder: (context, snapshot) {
                                  final buffering = snapshot.data ?? false;
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (buffering)
                                        const SizedBox(
                                          width: 12, height: 12,
                                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.orangeAccent),
                                        )
                                      else
                                        const Icon(Icons.signal_cellular_alt, size: 14, color: Colors.green),
                                      const SizedBox(width: 4),
                                      Text(
                                        buffering ? 'Buffering' : 'OK',
                                        style: TextStyle(color: buffering ? Colors.orangeAccent : Colors.green, fontSize: 11),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(width: 4),
                              // Audio indicator
                              StreamBuilder<bool>(
                                stream: playerService.hasAudioStream,
                                builder: (context, snapshot) {
                                  final hasAudio = snapshot.data ?? true;
                                  if (hasAudio) return const SizedBox.shrink();
                                  return const Tooltip(
                                    message: 'No audio track detected',
                                    child: Icon(Icons.volume_off_rounded, size: 14, color: Colors.redAccent),
                                  );
                                },
                              ),
                              const Spacer(),
                              // Debug info
                              SizedBox(
                                height: 28, width: 28,
                                child: ExcludeFocus(
                                  excluding: Platform.isAndroid,
                                  child: IconButton(
                                    onPressed: () {
                                      if (_previewChannel == null) return;
                                      final ps = ref.read(playerServiceProvider);
                                      ChannelDebugDialog.show(context, _previewChannel!, ps,
                                          mappedEpgId: _getEpgId(_previewChannel!),
                                          originalName: _previewChannel!.tvgName ?? _previewChannel!.name,
                                          currentProviderName: ref.read(streamAlternativesProvider).providerName(_previewChannel!.providerId),
                                          alternatives: _getFailoverAlts(_previewChannel!));
                                    },
                                    icon: const Icon(Icons.info_outline, size: 16),
                                    padding: EdgeInsets.zero,
                                    color: Colors.white70,
                                    tooltip: 'Channel debug info',
                                  ),
                                ),
                              ),
                              // Fullscreen
                              SizedBox(
                                height: 28, width: 28,
                                child: ExcludeFocus(
                                  excluding: Platform.isAndroid,
                                  child: IconButton(
                                    onPressed: () => _goFullscreen(_previewChannel!),
                                    icon: const Icon(Icons.fullscreen_rounded, size: 16),
                                    padding: EdgeInsets.zero,
                                    color: Colors.white70,
                                    tooltip: 'Fullscreen',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Extract quality tag (UHD/4K/FHD/HD/SD) from channel name and return a badge widget.
  Widget? _qualityBadge(String name) {
    final upper = name.toUpperCase();
    String? label;
    Color? color;
    if (upper.contains('4K') || upper.contains('UHD')) {
      label = 'UHD';
      color = const Color(0xFF9B59B6);
    } else if (upper.contains('FHD') || upper.contains('FULLHD') || upper.contains('FULL HD')) {
      label = 'FHD';
      color = const Color(0xFF2ECC71);
    } else if (RegExp(r'\bHD\b').hasMatch(upper)) {
      label = 'HD';
      color = const Color(0xFF3498DB);
    } else if (RegExp(r'\bSD\b').hasMatch(upper)) {
      label = 'SD';
      color = const Color(0xFF95A5A6);
    }
    if (label == null) return null;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color!.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _buildSidebar() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: _sidebarExpanded ? 220.0 : 0.0,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(color: Color(0xFF111127)),
      child: FocusScope(
        node: _sidebarFocusNode,
        child: Column(
          children: [
          // Toggle button
          InkWell(
            onTap: () => setState(() => _sidebarExpanded = !_sidebarExpanded),
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerRight,
              child: Icon(
                Icons.chevron_left_rounded,
                color: Colors.white38,
                size: 20,
              ),
            ),
          ),
          if (_sidebarExpanded) ...[
            // Search field — only on iOS (Android TV uses D-pad nav, desktop uses top bar)
            if (Platform.isIOS) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: SizedBox(
                  height: 30,
                  child: TextFormField(
                    controller: _sidebarSearchController,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'Search channels…',
                      hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                      prefixIcon: const Icon(Icons.search_rounded, size: 14, color: Colors.white24),
                      prefixIconConstraints: const BoxConstraints(minWidth: 30),
                      suffixIcon: _sidebarSearchQuery.isNotEmpty
                          ? GestureDetector(
                              onTap: () {
                                _sidebarSearchController.clear();
                                setState(() => _sidebarSearchQuery = '');
                              },
                              child: const Icon(Icons.close_rounded, size: 14, color: Colors.white24),
                            )
                          : null,
                      suffixIconConstraints: const BoxConstraints(minWidth: 30),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.06),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (v) {
                      setState(() {
                        _sidebarSearchQuery = v.toLowerCase();
                        _applyFilters();
                      });
                    },
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white10),
            ],
          ],
          // Tree content
          Expanded(
            child: _sidebarExpanded ? _buildSidebarTree() : const SizedBox.shrink(),
          ),
          // Settings — anchored at bottom of sidebar
          const Divider(height: 1, color: Colors.white10),
          if (_sidebarExpanded) ...[
            _buildSidebarNavItem(Icons.settings_rounded, 'Settings', () {
              context.push('/settings');
            }),
          ] else ...[
            _sidebarIcon(Icons.settings_rounded, 'Settings', false, () {
              context.push('/settings');
            }),
          ],
          // Version watermark
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Text(
              _sidebarExpanded ? 'Naritta v${AppUpdateService.currentVersion}' : 'v${AppUpdateService.currentVersion}',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white24,
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildCollapsedSidebar() {
    // Icons-only when collapsed
    final isAll = _selectedGroup == 'All';
    final isFav = _selectedGroup == 'Favorites' || _selectedGroup.startsWith('fav:');
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _sidebarIcon(Icons.grid_view_rounded, 'All', isAll, () {
          setState(() { _clearSearch(); _selectedGroup = 'All'; _applyFilters(); _saveSession(); });
        }),
        _sidebarIcon(Icons.star_rounded, 'Favorites', isFav, () {
          setState(() { _clearSearch(); _selectedGroup = 'Favorites'; _applyFilters(); _saveSession(); });
        }),
        const Divider(height: 1, color: Colors.white10),
        _sidebarIcon(Icons.folder_rounded, 'Groups', !isAll && !isFav, () {
          setState(() => _sidebarExpanded = true);
        }),
        const Divider(height: 1, color: Colors.white10),
        _sidebarIcon(Icons.movie_outlined, 'Movies', false, () {
          _handleQuickAction('movies');
        }),
        _sidebarIcon(Icons.live_tv_rounded, 'Series', false, () {
          _handleQuickAction('series');
        }),
      ],
    );
  }

  Widget _sidebarIcon(IconData icon, String tooltip, bool active, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _firstChannelFocusNode.requestFocus();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            return InkWell(
              onTap: onTap,
              child: Container(
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? Colors.white.withValues(alpha: 0.08) : Colors.transparent,
                  border: hasFocus ? Border.all(color: Colors.purpleAccent, width: 1.5) : null,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(icon, size: 18, color: active ? Colors.white : Colors.white38),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSidebarNavItem(IconData icon, String label, VoidCallback onTap) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _firstChannelFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return InkWell(
            onTap: onTap,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: hasFocus ? Border.all(color: Colors.purpleAccent, width: 1.5) : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: Colors.white54),
                  const SizedBox(width: 8),
                  Text(label, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSidebarTree() {
    final q = _sidebarSearchQuery;
    final filteredGroups = q.isEmpty
        ? _groups
        : _groups.where((g) => g.toLowerCase().contains(q)).toList();
    final filteredFavs = q.isEmpty
        ? _favoriteLists
        : _favoriteLists.where((l) => l.name.toLowerCase().contains(q)).toList();
    final filteredProviders = q.isEmpty
        ? _providers
        : _providers.where((p) => p.name.toLowerCase().contains(q)).toList();
    final showAll = q.isEmpty || 'all'.contains(q);
    final showFavSection = q.isEmpty || filteredFavs.isNotEmpty || 'favorites'.contains(q);
    final showProvSection = q.isEmpty || filteredProviders.isNotEmpty || 'providers'.contains(q);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        if (showAll)
          _buildTreeItem('All (${_allChannels.length})', 'All', Icons.grid_view_rounded, indent: 0, focusNode: _sidebarAllItemFocusNode),
        if (showFavSection)
          _buildTreeSection(
            'favorites',
            Icons.star_rounded,
            'Favorites',
            [
              if (q.isEmpty || 'favorites'.contains(q))
                _buildTreeItem('All Favorites', 'Favorites', Icons.star_rounded, indent: 1),
              for (final list in filteredFavs)
                _buildTreeItem(list.name, 'fav:${list.id}', Icons.star_outline_rounded, indent: 1,
                    onSecondaryTap: () => _renameFavoriteList(list)),
              if (q.isEmpty)
                _buildTreeAction('New List…', Icons.add_rounded, () => _showManageFavoritesDialog(), indent: 1),
            ],
          ),
        if (showFavSection || showProvSection)
          const Divider(height: 1, color: Colors.white10),
        if (showProvSection)
          ..._buildProviderTrees(filteredProviders, q),
        if (showProvSection || filteredGroups.isNotEmpty)
          const Divider(height: 1, color: Colors.white10),
        if (filteredGroups.isNotEmpty)
          _buildTreeSection(
            'groups',
            Icons.folder_rounded,
            'Groups (${filteredGroups.length})',
            [
              for (final group in filteredGroups)
                _buildTreeItem(group, group, null, indent: 1),
            ],
          ),
        // Shows, Movies & Series
        const Divider(height: 1, color: Colors.white10),
        _buildTreeItem('Shows (Trakt)', 'action:shows', Icons.tv_rounded, indent: 0),
        _buildTreeItem('Movies', 'action:movies', Icons.movie_outlined, indent: 0),
        _buildTreeItem('Series', 'action:series', Icons.live_tv_rounded, indent: 0),
        // Quick actions
        const Divider(height: 1, color: Colors.white10),
        _buildTreeItem('Recordings', 'action:recordings', Icons.videocam_rounded, indent: 0),
        _buildTreeItem('Play File', 'action:play_file', Icons.play_circle_outline_rounded, indent: 0),
        _buildTreeItem('Play URL', 'action:play_url', Icons.link_rounded, indent: 0),
      ],
    );
  }

  /// Build provider tree nodes: each provider is a collapsible section
  /// containing its category groups as sub-items.
  List<Widget> _buildProviderTrees(List<db.Provider> providers, String query) {
    final widgets = <Widget>[];
    for (final prov in providers) {
      final sortedGroups = _providerGroups[prov.id] ?? [];
      final filteredGroups = query.isEmpty
          ? sortedGroups
          : sortedGroups.where((g) => g.toLowerCase().contains(query)).toList();

      // No subcategories — show as a flat link
      if (filteredGroups.isEmpty) {
        widgets.add(
          _buildTreeItem(
            prov.name,
            'provider:${prov.id}',
            prov.type == 'xtream' ? Icons.bolt_rounded : Icons.playlist_play_rounded,
            indent: 0,
          ),
        );
      } else {
        // Has subcategories — show as expandable tree
        widgets.add(
          _buildTreeSection(
            'prov_${prov.id}',
            prov.type == 'xtream' ? Icons.bolt_rounded : Icons.playlist_play_rounded,
            prov.name,
            [
              for (final group in filteredGroups)
                _buildTreeItem(
                  group,
                  'provgroup:${prov.id}:$group',
                  Icons.folder_open_rounded,
                  indent: 1,
                ),
            ],
            filterKey: 'provider:${prov.id}',
          ),
        );
      }
    }
    return widgets;
  }

  Widget _buildTreeSection(String sectionKey, IconData icon, String label, List<Widget> children, {String? filterKey}) {
    final expanded = _expandedSections.contains(sectionKey);
    final isSelected = filterKey != null && _selectedGroup == filterKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _firstChannelFocusNode.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter) {
              setState(() {
                _clearSearch();
                // Only change channel list if provider has no subcategories
                if (filterKey != null && children.isEmpty) {
                  _selectedGroup = filterKey;
                  _applyFilters();
                  _saveSession();
                }
                if (expanded) {
                  _expandedSections.remove(sectionKey);
                } else {
                  _expandedSections.add(sectionKey);
                }
              });
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (context) {
              final hasFocus = Focus.of(context).hasFocus;
              return InkWell(
                onTap: () {
                  setState(() {
                    _clearSearch();
                    // Only change channel list if provider has no subcategories
                    if (filterKey != null && children.isEmpty) {
                      _selectedGroup = filterKey;
                      _applyFilters();
                      _saveSession();
                    }
                    if (expanded) {
                      _expandedSections.remove(sectionKey);
                    } else {
                      _expandedSections.add(sectionKey);
                    }
                  });
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: hasFocus ? Border.all(color: Colors.purpleAccent, width: 1.5) : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                        size: 16,
                        color: Colors.white38,







































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































                    
