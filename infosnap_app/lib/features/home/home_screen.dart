import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/widgets/hexagon_background.dart';
import '../../core/providers/notes_provider.dart';
import '../../core/services/api_service.dart';
import '../../core/services/app_cache_warmer.dart';
import '../../core/services/auth_service.dart';
import '../../core/utils/responsive.dart';
import '../recap/home_recap_provider.dart';
import '../recap/recap_api.dart';
import '../recap/recap_models.dart';
import '../recap/recap_stories_screen.dart';
import '../notes/widgets/snap_preview_surface.dart';

enum _CollectionFilterMode { tags, type }

class _CollectionVisual {
  final IconData icon;
  final List<Color> gradient;
  const _CollectionVisual(this.icon, this.gradient);
}

/// Home Screen - Redesigned with Header, Center SnapBot, and Bottom Navigation
/// Colors from welcome-email-2.html branding

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // Brand colors from email template
  static const Color _headerBg = Color(0xFF18181b);
  static const Color _greenPrimary = Color(0xFF22c55e);
  static const Color _greenDark = Color(0xFF15803d);
  static const Color _greenLight = Color(0xFF86efac);
  static const Color _amber = Color(0xFFF59E0B);
  static const Color _mutedGray = Color(0xFF71717a);

  final TextEditingController _searchController = TextEditingController();
  int _currentNavIndex = 0; // legacy, used by dead bottom nav code
  _CollectionFilterMode _collectionFilterMode = _CollectionFilterMode.tags;

  // Tag filter state
  final Set<String> _selectedTags = {};
  List<String> _availableTags = [];
  bool _tagsLoading = false;
  String? _lastAuthUserId;
  bool _authReadyTagReloadDone = false;
  int _groupUnreadCount = 0;
  late final VoidCallback _tagCacheListener;

  // Server-aggregated collections (counts + cover thumb) — full DB scope.
  List<CollectionSummary> _tagCollections = const [];
  List<CollectionSummary> _typeCollections = const [];

  // Recap on Home is cached in a Riverpod StateNotifier
  // (`homeRecapProvider`) so bottom-nav tab switches don't refetch. See
  // features/recap/home_recap_provider.dart. Pull-to-refresh explicitly
  // calls `refresh()` to force a new fetch.

  // Theme-aware color getters
  Color _bg(BuildContext context) => Theme.of(context).scaffoldBackgroundColor;
  Color _surface(BuildContext context) => Theme.of(context).colorScheme.surface;
  Color _border(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF374151)
          : const Color(0xFFE2E8F0);
  Color _greenAccent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? _greenPrimary.withOpacity(0.15)
          : const Color(0xFFDCFCE7);
  Color _textPrimary(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.white
          : Colors.black;
  Color _textMuted(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF9CA3AF)
          : const Color(0xFF374151);

  @override
  void initState() {
    super.initState();
    _tagCacheListener = () {
      if (!mounted) return;
      _loadTags(forceRefresh: true);
    };
    ApiService().tagsCacheVersion.addListener(_tagCacheListener);
    final cachedTags = ApiService().cachedTags;
    final cachedGroups = ApiService().cachedGroups;
    if (cachedTags.isNotEmpty || cachedGroups.isNotEmpty) {
      _availableTags = cachedTags;
      _groupUnreadCount = cachedGroups.fold<int>(
        0,
        (sum, group) =>
            sum + group.unreadCount + (group.status == 'pending' ? 1 : 0),
      );
      _tagsLoading = false;
    }
    _loadPersistedHomeCache();
    _loadHomeBootstrap();
  }

  Future<void> _loadPersistedHomeCache() async {
    final api = ApiService();
    final results = await Future.wait([
      api.loadPersistedTags(),
      api.loadPersistedGroups(),
    ]);
    if (!mounted) return;
    final tags = results[0] as List<String>;
    final groups = results[1] as List<GroupSummary>;
    if (tags.isEmpty && groups.isEmpty) return;
    setState(() {
      if (tags.isNotEmpty) {
        _availableTags = tags;
        _tagsLoading = false;
      }
      if (groups.isNotEmpty) {
        _groupUnreadCount = groups.fold<int>(
          0,
          (sum, group) =>
              sum + group.unreadCount + (group.status == 'pending' ? 1 : 0),
        );
      }
    });
  }

  Future<void> _loadHomeBootstrap() async {
    final bootstrap = await ApiService().fetchAppBootstrap(notesLimit: 20);
    if (!mounted) return;

    if (bootstrap != null) {
      setState(() {
        _groupUnreadCount = bootstrap.notificationCounts.totalGroupBadgeCount;
        if (bootstrap.tags.isNotEmpty) _availableTags = bootstrap.tags;
        _tagCollections = bootstrap.tagCollections;
        _typeCollections = bootstrap.typeCollections;
      });
      // Restore the persistent custom avatar from user_profiles. Google
      // sign-in re-overwrites auth user_metadata.avatar_url with the Google
      // picture on every login, so after a reinstall we'd otherwise lose the
      // user's uploaded profile image.
      final avatar = bootstrap.profile?.avatarUrl;
      if (avatar != null && avatar.isNotEmpty) {
        ref.read(authUserProvider.notifier).setPhotoUrl(avatar);
      }
      ref.read(notesProvider.notifier).seedFromBootstrap(
            bootstrap.recentNotes,
            hasMore: bootstrap.recentNotesHasMore,
          );
      unawaited(AppCacheWarmer.warmRecentThumbnails());
    } else {
      await _loadGroupUnreadCount();
      if (!mounted) return;
      await ref.read(notesProvider.notifier).loadNotes();
    }

    if (!mounted) return;
    // Cached-first recap load — no-op if `homeRecapProvider` already holds a
    // payload from an earlier tab visit. Pull-to-refresh calls `refresh()`.
    unawaited(ref.read(homeRecapProvider.notifier).loadIfNeeded());
  }

  Future<void> _loadGroupUnreadCount() async {
    final groups = await ApiService().fetchGroups();
    if (!mounted) return;
    setState(() {
      _groupUnreadCount = groups.fold<int>(
        0,
        (sum, group) =>
            sum + group.unreadCount + (group.status == 'pending' ? 1 : 0),
      );
    });
  }

  Future<void> _loadTags({
    bool forceRefresh = false,
    bool showLoader = true,
  }) async {
    if (showLoader && _availableTags.isEmpty) {
      setState(() => _tagsLoading = true);
    }
    try {
      final tags = await ApiService().fetchTags(forceRefresh: forceRefresh);
      if (mounted) {
        setState(() {
          _availableTags = tags;
          _tagsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _tagsLoading = false);
      }
    }
  }

  @override
  void dispose() {
    ApiService().tagsCacheVersion.removeListener(_tagCacheListener);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authUser = ref.watch(authUserProvider);

    if (authUser?.id != _lastAuthUserId) {
      _lastAuthUserId = authUser?.id;
      _authReadyTagReloadDone = false;
    }

    if (authUser != null && !_authReadyTagReloadDone && !_tagsLoading) {
      _authReadyTagReloadDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_availableTags.isEmpty) _loadTags();
      });
    }

    // Reload tags whenever notes count changes (e.g., after deletion on Notes screen)
    ref.listen<NotesState>(notesProvider, (previous, next) {
      if (previous != null && previous.notes.length != next.notes.length) {
        _loadTags(forceRefresh: true);
      }
    });

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: _bg(context),
      body: Stack(
        children: [
          const Positioned.fill(
            child: SoftGridBackground(),
          ),
          // Main content
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: _buildCenterContent(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Contact banner at top
  Widget _buildContactBanner() {
    return GestureDetector(
      onTap: () async {
        // Open email client
        final Uri emailUri = Uri(scheme: 'mailto', path: 'contact@infoSnap.ai');
        // ignore: deprecated_member_use
        // ignore: avoid_print
        print('Open email: $emailUri');
      },
      child: Container(
        padding: EdgeInsets.symmetric(
            vertical: Responsive.pp(8), horizontal: Responsive.pp(16)),
        color: const Color(0xFF4f46e5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '📬 Get in Touch: ',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(12),
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
            Text(
              'contact@infoSnap.ai',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(12),
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Dark header with infoSnap.ai branding (email template style)
  Widget _buildHeader() {
    final user = ref.watch(authUserProvider);
    final userInitial =
        user?.email.isNotEmpty == true ? user!.email[0].toUpperCase() : 'U';

    return Container(
      decoration: BoxDecoration(
        color: _headerBg,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: Responsive.wp(8),
            offset: Offset(0, Responsive.wp(2)),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRect(
                child: Align(
                  alignment: Alignment.topRight,
                  child: HexagonBackground(
                    color: _amber,
                    opacity: 0.22,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(Responsive.pp(20), Responsive.pp(16),
                Responsive.pp(20), Responsive.pp(16)),
            child: Row(
              children: [
                // Two overlapping green boxes logo (from email template)
                SizedBox(
                  width: Responsive.wp(40),
                  height: Responsive.wp(40),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        child: Container(
                          width: Responsive.wp(26),
                          height: Responsive.wp(26),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [_greenPrimary, _greenDark],
                            ),
                            borderRadius:
                                BorderRadius.circular(Responsive.wp(6)),
                          ),
                        ),
                      ),
                      Positioned(
                        top: Responsive.wp(8),
                        left: Responsive.wp(8),
                        child: Container(
                          width: Responsive.wp(26),
                          height: Responsive.wp(26),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                _greenPrimary.withOpacity(0.6),
                                _greenDark.withOpacity(0.8),
                              ],
                            ),
                            borderRadius:
                                BorderRadius.circular(Responsive.wp(6)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: Responsive.wp(12)),
                // Brand name: info (white) Snap (green light) .ai (muted)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'info',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: Responsive.sp(24),
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    Text(
                      'Snap',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: Responsive.sp(24),
                        fontWeight: FontWeight.w700,
                        color: _greenLight,
                        letterSpacing: -0.5,
                      ),
                    ),
                    Text(
                      '.ai',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: Responsive.sp(24),
                        fontWeight: FontWeight.w300,
                        color: _mutedGray,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
                Spacer(),
                // User avatar
                GestureDetector(
                  onTap: () => context.push('/settings'),
                  child: Container(
                    width: Responsive.wp(46),
                    height: Responsive.wp(46),
                    decoration: BoxDecoration(
                      color: _greenPrimary.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(Responsive.wp(12)),
                      border: Border.all(color: _greenPrimary.withOpacity(0.3)),
                      image:
                          (user?.photoUrl != null && user!.photoUrl!.isNotEmpty)
                              ? DecorationImage(
                                  image: NetworkImage(user.photoUrl!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                    ),
                    child:
                        (user?.photoUrl != null && user!.photoUrl!.isNotEmpty)
                            ? null
                            : Center(
                                child: Text(
                                  userInitial,
                                  style: GoogleFonts.inter(
                                    fontSize: Responsive.sp(18),
                                    fontWeight: FontWeight.w600,
                                    color: _greenLight,
                                  ),
                                ),
                              ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  /// Center content - Clean search interface with centered SnapBot search box
  Widget _buildCenterContent() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final user = ref.watch(authUserProvider);
    final notesState = ref.watch(notesProvider);
    final availableNotes =
        notesState.notes.where((note) => !note.isProcessing).toList();
    final serverCollections = _collectionFilterMode == _CollectionFilterMode.tags
        ? _tagCollections
        : _typeCollections;

    // Get user's first name for greeting
    final displayName = user?.displayName ?? '';
    final firstName = displayName.split(' ').first;

    return RefreshIndicator(
      onRefresh: () async {
        // Pull-to-refresh on Home should rebuild every section of the
        // screen, not just the tag list. Bust the relevant caches first so
        // the bootstrap RPC and the recap endpoint actually re-query
        // Supabase instead of returning whatever we last cached.
        final api = ApiService();
        api.invalidateTagsCache();
        api.invalidateGroupsCache();
        api.invalidateBillingCache();
        api.invalidateRecentNotesCache();
        api.invalidateCollectionsCache();
        // Bootstrap re-populates tags, groups, collections (full-DB
        // tag/type aggregates with cover thumbs) and seeds Recent Snaps.
        // _loadTags is called as a safety net in case the bootstrap RPC
        // is not available and we fall back to the legacy fan-out path.
        final reloads = <Future<void>>[
          _loadHomeBootstrap(),
          _loadTags(forceRefresh: true, showLoader: false),
        ];
        // Recap is cached in `homeRecapProvider`. Force a re-fetch so the
        // strip rebuilds with the latest stories.
        if (mounted) {
          unawaited(ref.read(homeRecapProvider.notifier).refresh());
        }
        await Future.wait(reloads);
      },
      color: _greenPrimary,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Builder(builder: (context) {
              final hp = Responsive.pp(Responsive.isNarrow ? 16 : 24);
              Widget hpad(Widget child) =>
                  Padding(padding: EdgeInsets.symmetric(horizontal: hp), child: child);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: Responsive.wp(12)),
                  hpad(Text(
                    firstName.isNotEmpty
                        ? 'Hey $firstName, what\'s on your mind today?'
                        : 'Hey, what\'s on your mind today?',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: Responsive.sp(20),
                      fontWeight: FontWeight.w700,
                      color: _textPrimary(context),
                      height: 1.2,
                    ),
                  ).animate().fadeIn(duration: 360.ms)),
                  SizedBox(height: Responsive.wp(14)),
                  hpad(Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Responsive.pp(16),
                        vertical: Responsive.pp(10)),
                    decoration: BoxDecoration(
                      color: _surface(context),
                      borderRadius: BorderRadius.circular(Responsive.wp(16)),
                      border: Border.all(color: _border(context)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(isDark ? 0.2 : 0.06),
                          blurRadius: Responsive.wp(12),
                          offset: Offset(0, Responsive.wp(4)),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _searchController,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(15),
                        color: _textPrimary(context),
                      ),
                      decoration: InputDecoration(
                        hintText: 'Ask Snapbot to find your saved content...',
                        hintStyle: GoogleFonts.inter(
                          fontSize:
                              Responsive.sp(Responsive.isNarrow ? 11 : 13),
                          color: _textMuted(context),
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        hintMaxLines: 2,
                        contentPadding: EdgeInsets.symmetric(
                          vertical: Responsive.pp(10),
                          horizontal: Responsive.pp(2),
                        ),
                        suffixIcon: IconButton(
                          icon: Icon(Icons.send_rounded,
                              color: _greenPrimary, size: Responsive.sp(22)),
                          onPressed: () {
                            final q = _searchController.text.trim();
                            if (q.isNotEmpty) {
                              HapticFeedback.lightImpact();
                              String url = '/chat?q=${Uri.encodeComponent(q)}';
                              if (_selectedTags.isNotEmpty) {
                                url +=
                                    '&tags=${Uri.encodeComponent(_selectedTags.join(','))}';
                              }
                              context.push(url);
                              _searchController.clear();
                            }
                          },
                        ),
                        suffixIconConstraints: BoxConstraints(
                          minWidth: Responsive.pp(34),
                          minHeight: Responsive.pp(34),
                        ),
                      ),
                      onSubmitted: (value) {
                        final q = value.trim();
                        if (q.isNotEmpty) {
                          String url = '/chat?q=${Uri.encodeComponent(q)}';
                          if (_selectedTags.isNotEmpty) {
                            url +=
                                '&tags=${Uri.encodeComponent(_selectedTags.join(','))}';
                          }
                          context.push(url);
                          _searchController.clear();
                        }
                      },
                    ),
                  )
                      .animate()
                      .fadeIn(duration: 400.ms, delay: 200.ms)
                      .slideY(begin: 0.1, end: 0, curve: Curves.easeOut)),
                  SizedBox(height: Responsive.wp(18)),
                  _buildTagChips(hp: hp),
                  SizedBox(height: Responsive.wp(4)),
                  _buildCollectionsSection(
                    availableNotes,
                    serverCollections,
                    notesState.isLoading,
                    hp: hp,
                  ),
                  SizedBox(height: Responsive.wp(20)),
                  _buildRecapStrip(hp: hp),
                  SizedBox(height: Responsive.wp(28)),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestionsSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: Responsive.pp(4)),
          child: Container(
            height: Responsive.wp(14),
            width: Responsive.wp(80),
            decoration: BoxDecoration(
              color: _border(context),
              borderRadius: BorderRadius.circular(Responsive.wp(4)),
            ),
          ),
        ),
        SizedBox(height: Responsive.wp(12)),
        Wrap(
          spacing: Responsive.wp(8),
          runSpacing: Responsive.wp(8),
          children: List.generate(
              3,
              (i) => Container(
                    height: Responsive.wp(36),
                    width: Responsive.wp(120 + (i * 20)),
                    decoration: BoxDecoration(
                      color: _border(context),
                      borderRadius: BorderRadius.circular(Responsive.wp(20)),
                    ),
                  )).animate(onPlay: (c) => c.repeat()).shimmer(
              duration: 1500.ms, color: _greenAccent(context).withOpacity(0.5)),
        ),
      ],
    );
  }

  Widget _buildDefaultSuggestions() {
    final suggestions = [
      'Show my recent saves',
      'Find documents from last week',
      'What articles did I save?',
    ];
    return _buildSuggestionsWidget(suggestions);
  }

  Widget _buildDynamicSuggestions(List<Note> notes) {
    if (notes.isEmpty) {
      return _buildEmptyStateSuggestions();
    }

    // Generate relevant suggestions based on actual saved content
    final suggestions = <String>[];

    // Group notes by topic/title keywords
    final keywordCounts = <String, int>{};
    final domains = <String>{};
    final contentTypes = <String, int>{};
    final recentTitles = <String>[];

    for (int i = 0; i < notes.length && i < 20; i++) {
      final note = notes[i];

      // Extract meaningful keywords from titles
      final titleWords = note.title
          .toLowerCase()
          .replaceAll(RegExp(r'[^\w\s]'), ' ')
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 4 && !_isCommonWord(w))
          .toList();

      for (final word in titleWords) {
        keywordCounts[word] = (keywordCounts[word] ?? 0) + 1;
      }

      if (note.sourceDomain != null && note.sourceDomain!.isNotEmpty) {
        domains.add(note.sourceDomain!);
      }

      if (note.contentType != null) {
        contentTypes[note.contentType!] =
            (contentTypes[note.contentType!] ?? 0) + 1;
      }

      if (i < 5) recentTitles.add(note.title);
    }

    // Sort keywords by frequency
    final topKeywords = keywordCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 1. Question about most frequent topic
    if (topKeywords.isNotEmpty && topKeywords.first.value >= 2) {
      final topic = topKeywords.first.key;
      suggestions.add('What do I have about $topic?');
    }

    // 2. Summarize most recent note
    if (recentTitles.isNotEmpty) {
      final title = _truncate(recentTitles.first, 25);
      suggestions.add('Summarize "$title"');
    }

    // 3. Ask about second topic
    if (topKeywords.length > 1 && topKeywords[1].value >= 2) {
      final topic = topKeywords[1].key;
      suggestions.add('Find notes about $topic');
    }

    // 4. Content type specific
    if (contentTypes.containsKey('pdf') && (contentTypes['pdf'] ?? 0) >= 2) {
      suggestions.add('List all my PDFs');
    } else if (contentTypes.containsKey('youtube') &&
        (contentTypes['youtube'] ?? 0) >= 2) {
      suggestions.add('Show my YouTube videos');
    } else if (contentTypes.containsKey('article') &&
        (contentTypes['article'] ?? 0) >= 1) {
      suggestions.add('Summarize my saved articles');
    }

    // 5. Domain specific
    if (domains.isNotEmpty && suggestions.length < 4) {
      suggestions.add('Notes from ${domains.first}');
    }

    // Fallback: use recent title directly
    if (suggestions.length < 3 && recentTitles.length > 1) {
      final title = _truncate(recentTitles[1], 25);
      suggestions.add('What is "$title" about?');
    }

    // Stats question if still need more
    if (suggestions.length < 4) {
      suggestions.add('What did I save this week?');
    }

    return _buildSuggestionsWidget(suggestions.take(4).toList());
  }

  bool _isCommonWord(String word) {
    const commonWords = {
      'the',
      'and',
      'for',
      'that',
      'this',
      'with',
      'from',
      'have',
      'are',
      'was',
      'were',
      'been',
      'being',
      'has',
      'had',
      'does',
      'did',
      'will',
      'would',
      'could',
      'should',
      'about',
      'what',
      'how',
      'when',
      'where',
      'which',
      'their',
      'there',
      'these',
      'those',
      'some',
      'more',
      'than',
      'into',
      'your',
      'just',
      'like',
      'make',
      'know',
      'time',
      'very',
      'after',
      'most',
      'also',
      'made',
      'over',
      'such',
      'only',
      'other',
      'before',
      'http',
      'https',
      'www',
      'html',
      'page',
      'file',
      'document',
      'untitled',
    };
    return commonWords.contains(word);
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }

  Widget _buildEmptyStateSuggestions() {
    return Container(
      padding: EdgeInsets.all(Responsive.pp(20)),
      decoration: BoxDecoration(
        color: _surface(context),
        borderRadius: BorderRadius.circular(Responsive.wp(16)),
        border: Border.all(color: _border(context)),
      ),
      child: Column(
        children: [
          Icon(Icons.bookmark_add_outlined,
              color: _greenPrimary, size: Responsive.sp(40)),
          SizedBox(height: Responsive.wp(12)),
          Text(
            'No snaps yet',
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(16),
              fontWeight: FontWeight.w600,
              color: _textPrimary(context),
            ),
          ),
          SizedBox(height: Responsive.wp(4)),
          Text(
            'Save web pages, PDFs, and screenshots to search them with AI',
            style: GoogleFonts.inter(
                fontSize: Responsive.sp(13), color: _textMuted(context)),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: Responsive.wp(16)),
          GestureDetector(
            onTap: () => context.push('/upload'),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(20), vertical: Responsive.pp(12)),
              decoration: BoxDecoration(
                gradient:
                    const LinearGradient(colors: [_greenPrimary, _greenDark]),
                borderRadius: BorderRadius.circular(Responsive.wp(10)),
              ),
              child: Text(
                'Add your first snap',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(14),
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 250.ms);
  }

  Widget _buildSuggestionsWidget(List<String> suggestions) {
    final tips = [
      {
        'emoji': '🔍',
        'title': 'Search',
        'desc': 'Ask natural questions like "Show me my github invoice"'
      },
      {
        'emoji': '🏷️',
        'title': 'Filter by tag',
        'desc': 'Use tag filters to narrow results to a specific category'
      },
      {
        'emoji': '📄',
        'title': 'Upload',
        'desc': 'Save PDFs, screenshots, web pages, or quick notes'
      },
      {
        'emoji': '🔎',
        'title': 'Search Deeper',
        'desc': 'Click "Search Deeper" below results to find more'
      },
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: Responsive.pp(4)),
          child: Row(
            children: [
              Icon(Icons.lightbulb_outline,
                  color: _amber, size: Responsive.sp(16)),
              SizedBox(width: Responsive.wp(6)),
              Text(
                'Tips',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(13),
                  fontWeight: FontWeight.w600,
                  color: _textMuted(context),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: Responsive.wp(10)),
        ...tips.asMap().entries.map((entry) {
          final i = entry.key;
          final tip = entry.value;
          return Padding(
            padding: EdgeInsets.only(
                bottom: i < tips.length - 1 ? Responsive.wp(6) : 0),
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(12), vertical: Responsive.pp(10)),
              decoration: BoxDecoration(
                color: _surface(context),
                borderRadius: BorderRadius.circular(Responsive.wp(8)),
                border: Border.all(color: _border(context)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tip['emoji']!,
                      style: TextStyle(fontSize: Responsive.sp(16))),
                  SizedBox(width: Responsive.wp(10)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tip['title']!,
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(12),
                            fontWeight: FontWeight.w600,
                            color: _textPrimary(context),
                          ),
                        ),
                        SizedBox(height: Responsive.wp(2)),
                        Text(
                          tip['desc']!,
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(11),
                            color: _textMuted(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(
                  duration: 300.ms,
                  delay: Duration(milliseconds: 250 + i * 50),
                ),
          );
        }),
      ],
    ).animate().fadeIn(duration: 400.ms, delay: 250.ms);
  }

  /// Tag filter chips widget
  Widget _buildTagChips({double hp = 0}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_tagsLoading) {
      return Padding(
        padding: EdgeInsets.only(left: hp, right: hp, bottom: Responsive.pp(16)),
        child: Row(
          children: [
            SizedBox(
              width: Responsive.wp(14),
              height: Responsive.wp(14),
              child: CircularProgressIndicator(
                strokeWidth: Responsive.wp(2),
                color: _textMuted(context),
              ),
            ),
            SizedBox(width: Responsive.wp(8)),
            Text(
              'Loading tags...',
              style: TextStyle(
                color: _textMuted(context),
                fontSize: Responsive.sp(11),
              ),
            ),
          ],
        ),
      );
    }

    if (_availableTags.isEmpty) {
      return const SizedBox.shrink();
    }

    // Sort tags: selected first, then alphabetically
    final sortedTags = [..._availableTags]..sort((a, b) {
        final aSelected = _selectedTags.contains(a);
        final bSelected = _selectedTags.contains(b);
        if (aSelected && !bSelected) return -1;
        if (!aSelected && bSelected) return 1;
        return a.compareTo(b);
      });

    const maxVisibleTags = 12;
    final visibleTags = sortedTags.take(maxVisibleTags).toList();
    final overflowTags = sortedTags.skip(maxVisibleTags).toList();
    final hasOverflow = overflowTags.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.pp(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(left: hp, right: hp),
            child: Row(
              children: [
                Icon(Icons.filter_list_rounded,
                    color: _textMuted(context), size: Responsive.sp(14)),
                SizedBox(width: Responsive.wp(6)),
                Text(
                  'Filter by Tag:',
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(12),
                    fontWeight: FontWeight.w500,
                    color: _textMuted(context),
                  ),
                ),
                if (_selectedTags.isNotEmpty) ...[
                  SizedBox(width: Responsive.wp(8)),
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Responsive.pp(6), vertical: Responsive.pp(2)),
                    decoration: BoxDecoration(
                      color: _greenPrimary.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(Responsive.wp(8)),
                    ),
                    child: Text(
                      '${_selectedTags.length} selected',
                      style: TextStyle(
                        color: _greenPrimary,
                        fontSize: Responsive.sp(10),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: Responsive.wp(8)),
          SizedBox(
            height: Responsive.wp(34),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsetsDirectional.only(start: hp, end: 0),
              itemCount: visibleTags.length + 1 + (hasOverflow ? 1 : 0),
              separatorBuilder: (_, __) => SizedBox(width: Responsive.wp(6)),
              itemBuilder: (context, i) {
                if (i == 0) return _buildTagChip(null, 'All', isDark, theme);
                if (i <= visibleTags.length) {
                  final tag = visibleTags[i - 1];
                  return _buildTagChip(tag, tag, isDark, theme);
                }
                return _buildOverflowButton(overflowTags, isDark, theme);
              },
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 200.ms);
  }

  Widget _buildCollectionsSection(
    List<Note> notes,
    List<CollectionSummary> serverCollections,
    bool isLoading, {
    double hp = 0,
  }) {
    // Prefer server-aggregated collections (full DB scope, with counts and
    // cover thumbs). Fall back to deriving from currently-loaded notes when
    // the server payload is empty (legacy worker, fan-out fallback, etc.).
    final hasServer = serverCollections.isNotEmpty;
    final localOptions = hasServer ? const <String>[] : _collectionOptions(notes);
    final itemCount = hasServer ? serverCollections.length : localOptions.length;
    final isEmpty = itemCount == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: hp, right: hp),
          child: Text(
            'Collections',
            style: GoogleFonts.spaceGrotesk(
              fontSize: Responsive.sp(17),
              fontWeight: FontWeight.w800,
              color: _textPrimary(context),
            ),
          ),
        ),
        SizedBox(height: Responsive.wp(8)),
        Padding(
          padding: EdgeInsets.only(left: hp, right: hp),
          child: Row(
            children: [
              _buildCollectionModeChip(_CollectionFilterMode.tags, 'Tags'),
              SizedBox(width: Responsive.wp(6)),
              _buildCollectionModeChip(_CollectionFilterMode.type, 'Type'),
            ],
          ),
        ),
        SizedBox(height: Responsive.wp(14)),
        if (isLoading && isEmpty)
          SizedBox(
            height: Responsive.wp(150),
            child: Center(
              child: SizedBox(
                width: Responsive.wp(22),
                height: Responsive.wp(22),
                child: CircularProgressIndicator(
                  strokeWidth: Responsive.wp(2),
                  color: _greenPrimary,
                ),
              ),
            ),
          )
        else if (isEmpty)
          Padding(
            padding: EdgeInsets.only(left: hp, right: hp),
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.all(Responsive.pp(18)),
              decoration: BoxDecoration(
                color: _surface(context),
                borderRadius: BorderRadius.circular(Responsive.wp(20)),
                border: Border.all(color: _border(context)),
              ),
              child: Text(
                'No collections yet — start saving snaps to see them here.',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(12),
                  color: _textMuted(context),
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: Responsive.wp(150),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsetsDirectional.only(start: hp, end: 0),
              itemCount: itemCount,
              separatorBuilder: (_, __) => SizedBox(width: Responsive.wp(10)),
              itemBuilder: (context, index) {
                if (hasServer) {
                  final entry = serverCollections[index];
                  return SizedBox(
                    width: Responsive.wp(120),
                    child: _buildCollectionOptionCard(
                      entry.value,
                      entry.count,
                      coverImageUrl: entry.coverThumbnailUrl,
                    ),
                  );
                }
                final value = localOptions[index];
                final filtered = _filterCollectionNotes(notes, value);
                final cover = _pickRepresentativeNote(filtered);
                return SizedBox(
                  width: Responsive.wp(120),
                  child: _buildCollectionOptionCard(
                    value,
                    filtered.length,
                    coverNote: cover,
                  ),
                );
              },
            ),
          ),
      ],
    ).animate().fadeIn(duration: 420.ms, delay: 160.ms);
  }

  Note? _pickRepresentativeNote(List<Note> notes) {
    for (final n in notes) {
      final t = n.thumbnailUrl;
      if (t != null && t.isNotEmpty) return n;
    }
    for (final n in notes) {
      final b = n.blobUrl;
      if (b != null && b.isNotEmpty) return n;
    }
    return notes.isEmpty ? null : notes.first;
  }

  String? _formatRecapRange(RecapPayload? payload) {
    if (payload == null) return null;
    final start = DateTime.tryParse(payload.periodStart);
    final end = DateTime.tryParse(payload.periodEnd);
    if (start == null || end == null) return null;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String fmt(DateTime d) => '${months[d.month - 1]} ${d.day}';
    if (start.year == end.year && start.month == end.month) {
      return '${months[start.month - 1]} ${start.day}–${end.day}';
    }
    return '${fmt(start)} – ${fmt(end)}';
  }

  Widget _buildRecapStrip({double hp = 0}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: hp, right: hp),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'Recap',
              style: GoogleFonts.spaceGrotesk(
                fontSize: Responsive.sp(17),
                fontWeight: FontWeight.w800,
                color: _textPrimary(context),
              ),
            ),
            SizedBox(width: Responsive.wp(8)),
            Padding(
              padding: EdgeInsets.only(bottom: Responsive.wp(2)),
              child: Consumer(
                builder: (context, ref, _) {
                  final recap = ref.watch(homeRecapProvider);
                  final range = _formatRecapRange(recap.payload);
                  final text = range != null
                      ? 'This week · $range · AI generated'
                      : 'This week · AI generated';
                  return Text(
                    text,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(10.5),
                      fontStyle: FontStyle.italic,
                      color: _textMuted(context),
                    ),
                  );
                },
              ),
            ),
          ],
          ),
        ),
        SizedBox(height: Responsive.wp(12)),
        Consumer(
          builder: (context, ref, _) {
            final recap = ref.watch(homeRecapProvider);
            // Only show the spinner on the very first load. Once we've got
            // a cached payload, subsequent background refreshes should not
            // wipe the strip.
            if (recap.payload == null && recap.isLoading) {
              return SizedBox(
                height: Responsive.wp(150),
                child: const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final cats =
                recap.payload?.categories ?? const <RecapCategory>[];
            if (cats.isEmpty) {
              return Padding(
                padding: EdgeInsets.only(left: hp, right: hp),
                child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(Responsive.pp(18)),
                  decoration: BoxDecoration(
                    color: _surface(context),
                    borderRadius: BorderRadius.circular(Responsive.wp(20)),
                    border: Border.all(color: _border(context)),
                  ),
                  child: Text(
                    'No recap for this week yet.',
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(12),
                      color: _textMuted(context),
                    ),
                  ),
                ),
              );
            }
            return SizedBox(
              height: Responsive.wp(150),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsetsDirectional.only(start: hp, end: 0),
                itemCount: cats.length,
                separatorBuilder: (_, __) => SizedBox(width: Responsive.wp(10)),
                itemBuilder: (context, i) {
                  final cat = cats[i];
                  return SizedBox(
                    width: Responsive.wp(120),
                    child: _RecapStripTile(
                      category: cat,
                      onTap: () {
                        // Open the slideshow for the tapped recap tile via
                        // an in-shell route so the bottom footer is preserved.
                        context.push('/recap/stories', extra: cat);
                      },
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    ).animate().fadeIn(duration: 420.ms, delay: 220.ms);
  }

  Widget _buildCollectionModeChip(_CollectionFilterMode mode, String label) {
    final selected = _collectionFilterMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() {
          _collectionFilterMode = mode;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(10),
          vertical: Responsive.pp(6),
        ),
        decoration: BoxDecoration(
          color: selected ? _greenPrimary : _surface(context),
          borderRadius: BorderRadius.circular(Responsive.wp(14)),
          border:
              Border.all(color: selected ? _greenPrimary : _border(context)),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(10.8),
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : _textPrimary(context),
          ),
        ),
      ),
    );
  }

  Widget _buildCollectionOptionCard(
    String value,
    int count, {
    Note? coverNote,
    String? coverImageUrl,
  }) {
    final visuals = _collectionOptionVisuals(value);
    final tint = visuals.gradient.last;
    final coverUrl = (coverImageUrl != null && coverImageUrl.isNotEmpty)
        ? coverImageUrl
        : (coverNote?.thumbnailUrl?.isNotEmpty == true
            ? coverNote!.thumbnailUrl
            : (coverNote?.blobUrl?.isNotEmpty == true
                ? coverNote!.blobUrl
                : null));
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        // Always open My Snaps filtered by the chosen collection value.
        final encoded = Uri.encodeQueryComponent(value);
        if (_collectionFilterMode == _CollectionFilterMode.tags) {
          context.push('/notes?tag=$encoded');
        } else {
          context.push('/notes?type=$encoded');
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: _surface(context),
          borderRadius: BorderRadius.circular(Responsive.wp(18)),
          border: Border.all(color: tint.withOpacity(0.22), width: 1),
          boxShadow: [
            BoxShadow(
              color: tint.withOpacity(0.18),
              blurRadius: Responsive.wp(16),
              spreadRadius: -2,
              offset: Offset(0, Responsive.wp(6)),
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: Responsive.wp(8),
              offset: Offset(0, Responsive.wp(3)),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Backdrop: real cover image when available, else a soft tinted gradient.
            if (coverUrl != null)
              CachedNetworkImage(
                imageUrl: coverUrl,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 220),
                placeholder: (_, __) => _collectionGradientBackdrop(visuals),
                errorWidget: (_, __, ___) =>
                    _collectionGradientBackdrop(visuals),
              )
            else
              _collectionGradientBackdrop(visuals),

            // Soft tint wash on top so each tile has a subtle brand glow.
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      tint.withOpacity(0.18),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Bottom dark gradient → keeps the label readable on any image.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: Responsive.wp(90),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00000000),
                      Color(0x80000000),
                      Color(0xE6000000),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),

            // Count chip — top-right
            Positioned(
              top: Responsive.wp(8),
              right: Responsive.wp(8),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(8),
                  vertical: Responsive.pp(4),
                ),
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(Responsive.wp(20)),
                  border: Border.all(
                      color: Colors.white.withOpacity(0.9), width: 1.2),
                ),
                child: Text(
                  '$count',
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: Responsive.sp(10.5),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),

            // Label — bottom-left
            Positioned(
              left: Responsive.wp(10),
              right: Responsive.wp(10),
              bottom: Responsive.wp(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: Responsive.sp(13.5),
                      fontWeight: FontWeight.w800,
                      height: 1.18,
                      shadows: const [
                        Shadow(
                            color: Color(0xCC000000),
                            blurRadius: 6,
                            offset: Offset(0, 1)),
                      ],
                    ),
                  ),
                  SizedBox(height: Responsive.wp(2)),
                  Text(
                    count == 1 ? '1 snap' : '$count snaps',
                    style: GoogleFonts.inter(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: Responsive.sp(10),
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(color: Color(0xAA000000), blurRadius: 4),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _collectionGradientBackdrop(_CollectionVisual visuals) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: visuals.gradient,
        ),
      ),
      alignment: Alignment.center,
      child: Container(
        width: Responsive.wp(64),
        height: Responsive.wp(64),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.18),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.45), width: 1.5),
        ),
        alignment: Alignment.center,
        child: Icon(
          visuals.icon,
          size: Responsive.sp(34),
          color: Colors.white,
        ),
      ),
    );
  }

  int _countNotesForOption(List<Note> notes, String value) {
    return _filterCollectionNotes(notes, value).length;
  }

  _CollectionVisual _collectionOptionVisuals(String value) {
    final lower = value.toLowerCase();
    // Brand-style mapping for Type mode.
    if (lower == 'instagram') {
      return const _CollectionVisual(Icons.camera_alt_rounded,
          [Color(0xFFFDE68A), Color(0xFFEC4899), Color(0xFF8B5CF6)]);
    }
    if (lower == 'youtube') {
      return const _CollectionVisual(Icons.play_circle_fill_rounded,
          [Color(0xFFFCA5A5), Color(0xFFEF4444), Color(0xFF991B1B)]);
    }
    if (lower == 'twitter' || lower == 'x') {
      return const _CollectionVisual(Icons.alternate_email_rounded,
          [Color(0xFF60A5FA), Color(0xFF2563EB), Color(0xFF1E40AF)]);
    }
    if (lower == 'reddit') {
      return const _CollectionVisual(Icons.forum_rounded,
          [Color(0xFFFDBA74), Color(0xFFF97316), Color(0xFFC2410C)]);
    }
    if (lower == 'linkedin') {
      return const _CollectionVisual(Icons.business_center_rounded,
          [Color(0xFF93C5FD), Color(0xFF2563EB), Color(0xFF1E3A8A)]);
    }
    if (lower == 'facebook') {
      return const _CollectionVisual(Icons.facebook_rounded,
          [Color(0xFF93C5FD), Color(0xFF3B82F6), Color(0xFF1D4ED8)]);
    }
    if (lower == 'webpage' || lower == 'article') {
      return const _CollectionVisual(Icons.public_rounded,
          [Color(0xFF6EE7B7), Color(0xFF10B981), Color(0xFF047857)]);
    }
    if (lower == 'image' || lower == 'screenshot') {
      return const _CollectionVisual(Icons.image_rounded,
          [Color(0xFFA7F3D0), Color(0xFF34D399), Color(0xFF059669)]);
    }
    if (lower == 'file' || lower == 'pdf' || lower == 'document') {
      return const _CollectionVisual(Icons.description_rounded,
          [Color(0xFFFCA5A5), Color(0xFFF87171), Color(0xFFB91C1C)]);
    }
    if (lower == 'note' || lower == 'quick_note') {
      return const _CollectionVisual(Icons.sticky_note_2_rounded,
          [Color(0xFFFDE68A), Color(0xFFFACC15), Color(0xFFCA8A04)]);
    }

    // Categories (AI generated).
    if (lower == 'food') {
      return const _CollectionVisual(Icons.restaurant_rounded,
          [Color(0xFFFCA5A5), Color(0xFFF97316), Color(0xFFC2410C)]);
    }
    if (lower == 'work') {
      return const _CollectionVisual(Icons.work_rounded,
          [Color(0xFF93C5FD), Color(0xFF3B82F6), Color(0xFF1E3A8A)]);
    }
    if (lower == 'entertainment') {
      return const _CollectionVisual(Icons.movie_rounded,
          [Color(0xFFC4B5FD), Color(0xFF8B5CF6), Color(0xFF5B21B6)]);
    }
    if (lower == 'learning') {
      return const _CollectionVisual(Icons.school_rounded,
          [Color(0xFF6EE7B7), Color(0xFF10B981), Color(0xFF065F46)]);
    }
    if (lower == 'travel') {
      return const _CollectionVisual(Icons.flight_takeoff_rounded,
          [Color(0xFF7DD3FC), Color(0xFF0EA5E9), Color(0xFF075985)]);
    }
    if (lower == 'personal') {
      return const _CollectionVisual(Icons.favorite_rounded,
          [Color(0xFFFBCFE8), Color(0xFFEC4899), Color(0xFF9D174D)]);
    }

    // Tag-style heuristics.
    if (lower.contains('home') || lower.contains('decor')) {
      return const _CollectionVisual(Icons.chair_rounded,
          [Color(0xFFFED7AA), Color(0xFFFB923C), Color(0xFFB45309)]);
    }
    if (lower.contains('expense') ||
        lower.contains('money') ||
        lower.contains('budget')) {
      return const _CollectionVisual(Icons.account_balance_wallet_rounded,
          [Color(0xFFA7F3D0), Color(0xFF10B981), Color(0xFF047857)]);
    }
    if (lower.contains('movie') || lower.contains('film')) {
      return const _CollectionVisual(Icons.local_movies_rounded,
          [Color(0xFFC4B5FD), Color(0xFF7C3AED), Color(0xFF4C1D95)]);
    }
    if (lower.contains('food') || lower.contains('recipe')) {
      return const _CollectionVisual(Icons.restaurant_menu_rounded,
          [Color(0xFFFCA5A5), Color(0xFFF87171), Color(0xFFB91C1C)]);
    }
    if (lower.contains('travel') || lower.contains('trip')) {
      return const _CollectionVisual(Icons.flight_rounded,
          [Color(0xFF7DD3FC), Color(0xFF0EA5E9), Color(0xFF0C4A6E)]);
    }
    if (lower.contains('book') || lower.contains('read')) {
      return const _CollectionVisual(Icons.menu_book_rounded,
          [Color(0xFFFEF3C7), Color(0xFFFACC15), Color(0xFFA16207)]);
    }
    if (lower.contains('fitness') ||
        lower.contains('gym') ||
        lower.contains('health')) {
      return const _CollectionVisual(Icons.fitness_center_rounded,
          [Color(0xFFA7F3D0), Color(0xFF22C55E), Color(0xFF14532D)]);
    }
    if (lower.contains('general')) {
      return const _CollectionVisual(Icons.bookmark_rounded,
          [Color(0xFFE0E7FF), Color(0xFF818CF8), Color(0xFF4338CA)]);
    }

    // Deterministic colorful default by hashing the label.
    const palettes = <List<Color>>[
      [Color(0xFF6EE7B7), Color(0xFF10B981), Color(0xFF065F46)],
      [Color(0xFFFCA5A5), Color(0xFFF97316), Color(0xFFC2410C)],
      [Color(0xFF93C5FD), Color(0xFF3B82F6), Color(0xFF1E3A8A)],
      [Color(0xFFC4B5FD), Color(0xFF8B5CF6), Color(0xFF5B21B6)],
      [Color(0xFFFBCFE8), Color(0xFFEC4899), Color(0xFF9D174D)],
      [Color(0xFFFDE68A), Color(0xFFFACC15), Color(0xFFB45309)],
      [Color(0xFF7DD3FC), Color(0xFF0EA5E9), Color(0xFF075985)],
    ];
    final palette = palettes[lower.hashCode.abs() % palettes.length];
    return _CollectionVisual(Icons.label_rounded, palette);
  }

  List<String> _collectionOptions(List<Note> notes) {
    final values = <String>{};
    for (final note in notes) {
      switch (_collectionFilterMode) {
        case _CollectionFilterMode.tags:
          values.addAll(note.tags.where((tag) => tag.trim().isNotEmpty));
          break;
        case _CollectionFilterMode.type:
          values.add(_collectionTypeLabel(note));
          break;
      }
    }
    final sorted = values.where((value) => value.trim().isNotEmpty).toList()
      ..sort();
    return sorted;
  }

  List<Note> _filterCollectionNotes(List<Note> notes, String? selectedValue) {
    if (selectedValue == null) return notes;
    return notes.where((note) {
      switch (_collectionFilterMode) {
        case _CollectionFilterMode.tags:
          return note.tags.contains(selectedValue);
        case _CollectionFilterMode.type:
          return _collectionTypeLabel(note) == selectedValue;
      }
    }).toList(growable: false);
  }

  String _collectionTypeLabel(Note note) {
    final social = (note.socialSource ?? '').trim();
    if (social.isNotEmpty) {
      return '${social[0].toUpperCase()}${social.substring(1)}';
    }

    switch ((note.contentType ?? '').toLowerCase()) {
      case 'quick_note':
        return 'Note';
      case 'webpage':
      case 'article':
        return 'Webpage';
      case 'image':
      case 'screenshot':
        return 'Image';
      case 'uploaded_file':
      case 'pdf':
        return 'File';
      default:
        final value = (note.contentType ?? 'Snap').trim();
        return value.isEmpty
            ? 'Snap'
            : '${value[0].toUpperCase()}${value.substring(1)}';
    }
  }

  String _collectionCategoryLabel(Note note) {
    final combined =
        '${note.displayTitle} ${note.description ?? ''} ${note.tags.join(' ')}'
            .toLowerCase();
    if (combined.contains('recipe') ||
        combined.contains('food') ||
        combined.contains('restaurant')) {
      return 'Food';
    }
    if (combined.contains('work') ||
        combined.contains('meeting') ||
        combined.contains('project')) {
      return 'Work';
    }
    if (combined.contains('movie') ||
        combined.contains('music') ||
        combined.contains('watch')) {
      return 'Entertainment';
    }
    if (combined.contains('learn') ||
        combined.contains('course') ||
        combined.contains('article')) {
      return 'Learning';
    }
    if (combined.contains('travel') ||
        combined.contains('trip') ||
        combined.contains('place')) {
      return 'Travel';
    }
    return 'Personal';
  }

  Widget _buildTagChip(
      String? tag, String label, bool isDark, ThemeData theme) {
    final isAll = tag == null;
    final isSelected =
        isAll ? _selectedTags.isEmpty : _selectedTags.contains(tag);

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() {
          if (isAll) {
            _selectedTags.clear();
          } else {
            if (_selectedTags.contains(tag)) {
              _selectedTags.remove(tag);
            } else {
              _selectedTags.add(tag);
            }
          }
        });
      },
      onDoubleTap: () {
        HapticFeedback.mediumImpact();
        setState(() => _selectedTags.clear());
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(10), vertical: Responsive.pp(6)),
        decoration: BoxDecoration(
          color: isSelected
              ? _greenPrimary
              : (isDark ? const Color(0xFF1F2937) : Colors.white),
          borderRadius: BorderRadius.circular(Responsive.wp(14)),
          border: Border.all(
            color: isSelected ? _greenPrimary : _border(context),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            color: isSelected
                ? Colors.white
                : _textPrimary(context).withOpacity(0.8),
            fontSize: Responsive.sp(12),
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildOverflowButton(
      List<String> overflowTags, bool isDark, ThemeData theme) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _showOverflowDialog(overflowTags, isDark, theme);
      },
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(10), vertical: Responsive.pp(6)),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1F2937) : Colors.white,
          borderRadius: BorderRadius.circular(Responsive.wp(14)),
          border: Border.all(
            color: _greenPrimary.withOpacity(0.5),
          ),
        ),
        child: Text(
          '+${overflowTags.length}',
          style: TextStyle(
            color: _greenPrimary,
            fontSize: Responsive.sp(12),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  void _showOverflowDialog(
      List<String> overflowTags, bool isDark, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Responsive.wp(16))),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: Padding(
            padding: EdgeInsets.all(Responsive.pp(16)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'More tags',
                      style: TextStyle(
                        fontSize: Responsive.sp(16),
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() => _selectedTags.clear());
                        setModalState(() {});
                      },
                      child: Text(
                        'Clear all',
                        style: TextStyle(
                          color: _greenPrimary,
                          fontSize: Responsive.sp(13),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Responsive.wp(12)),
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: Responsive.wp(8),
                      runSpacing: Responsive.wp(8),
                      children: overflowTags.map((tag) {
                        final isSelected = _selectedTags.contains(tag);
                        return GestureDetector(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            setState(() {
                              if (isSelected) {
                                _selectedTags.remove(tag);
                              } else {
                                _selectedTags.add(tag);
                              }
                            });
                            setModalState(() {});
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: EdgeInsets.symmetric(
                                horizontal: Responsive.pp(12),
                                vertical: Responsive.pp(6)),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? _greenPrimary
                                  : (isDark
                                      ? const Color(0xFF1F2937)
                                      : Colors.white),
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(14)),
                              border: Border.all(
                                color: isSelected
                                    ? _greenPrimary
                                    : _border(context),
                              ),
                            ),
                            child: Text(
                              tag,
                              style: GoogleFonts.inter(
                                color: isSelected
                                    ? Colors.white
                                    : theme.colorScheme.onSurface
                                        .withOpacity(0.8),
                                fontSize: Responsive.sp(12),
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                SizedBox(height: Responsive.wp(16)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Bottom navigation: Home | + | My Snaps
  Widget _buildBottomNav() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.pp(24), Responsive.pp(12),
          Responsive.pp(24), Responsive.pp(16)),
      decoration: BoxDecoration(
        color: _surface(context),
        border: Border(top: BorderSide(color: _border(context))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.15 : 0.05),
            blurRadius: Responsive.wp(10),
            offset: Offset(0, Responsive.wp(-2)),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            // Home button
            _buildNavItem(
              icon: Icons.home_rounded,
              label: 'Home',
              isSelected: _currentNavIndex == 0,
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() => _currentNavIndex = 0);
              },
            ),
            // Big + button (center)
            _buildAddButton(),
            // My Snaps button
            _buildNavItem(
              icon: Icons.folder_rounded,
              label: 'My Snaps',
              isSelected: _currentNavIndex == 2,
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() => _currentNavIndex = 2);
                context.push('/notes');
              },
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 300.ms, delay: 100.ms);
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: BoxConstraints(
          minWidth: Responsive.wp(76),
          maxWidth: Responsive.wp(96),
        ),
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(10), vertical: Responsive.pp(8)),
        decoration: BoxDecoration(
          color: isSelected ? _greenAccent(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? _greenPrimary : _textMuted(context),
              size: Responsive.sp(24),
            ),
            SizedBox(height: Responsive.wp(4)),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(10.5),
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? _greenPrimary : _textMuted(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddButton() {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        _showAddMenu(context);
      },
      child: Container(
        width: Responsive.wp(60),
        height: Responsive.wp(60),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_greenPrimary, _greenDark],
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: _greenPrimary.withOpacity(0.4),
              blurRadius: Responsive.wp(12),
              offset: Offset(0, Responsive.wp(4)),
            ),
          ],
        ),
        child: Icon(
          Icons.add_rounded,
          color: Colors.white,
          size: Responsive.sp(32),
        ),
      ),
    ).animate().scale(duration: 400.ms, delay: 150.ms, curve: Curves.easeOut);
  }

  void _showAddMenu(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: EdgeInsets.fromLTRB(
            Responsive.pp(24), 0, Responsive.pp(24), Responsive.pp(100)),
        padding: EdgeInsets.all(Responsive.pp(20)),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1F2937) : Colors.white,
          borderRadius: BorderRadius.circular(Responsive.wp(20)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: Responsive.wp(20),
              offset: Offset(0, Responsive.wp(-4)),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: Responsive.wp(40),
              height: Responsive.wp(4),
              margin: EdgeInsets.only(bottom: Responsive.pp(16)),
              decoration: BoxDecoration(
                color: isDark ? Colors.grey[600] : Colors.grey[300],
                borderRadius: BorderRadius.circular(Responsive.wp(2)),
              ),
            ),
            Text(
              'Add New Snap',
              style: GoogleFonts.spaceGrotesk(
                fontSize: Responsive.sp(18),
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
            SizedBox(height: Responsive.wp(20)),
            _buildAddOption(
              ctx,
              icon: Icons.link_rounded,
              title: 'Save URL',
              subtitle: 'Paste a link to save',
              color: Colors.blue,
              onTap: () {
                Navigator.pop(ctx);
                context.push('/upload');
              },
            ),
            SizedBox(height: Responsive.wp(12)),
            _buildAddOption(
              ctx,
              icon: Icons.edit_note_rounded,
              title: 'Quick Note',
              subtitle: 'Write a quick note',
              color: _greenPrimary,
              onTap: () {
                Navigator.pop(ctx);
                context.push('/upload');
              },
            ),
            SizedBox(height: Responsive.wp(12)),
            _buildAddOption(
              ctx,
              icon: Icons.upload_file_rounded,
              title: 'Upload File',
              subtitle: 'PDF, images, documents',
              color: _amber,
              onTap: () {
                Navigator.pop(ctx);
                context.push('/upload');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddOption(
    BuildContext ctx, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(Responsive.pp(14)),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF374151) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(Responsive.wp(14)),
          border: Border.all(
            color: isDark ? const Color(0xFF4B5563) : const Color(0xFFE2E8F0),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(Responsive.pp(10)),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(Responsive.wp(10)),
              ),
              child: Icon(icon, color: color, size: Responsive.sp(22)),
            ),
            SizedBox(width: Responsive.wp(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(15),
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(13),
                      color:
                          isDark ? Colors.grey[400] : const Color(0xFF374151),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: Responsive.sp(16),
              color: isDark ? Colors.grey[500] : const Color(0xFF374151),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact recap tile used by the home Recap strip. Mirrors the look of the
// recap mosaic's _CategoryTile (image backdrop + tinted glow + bottom gradient
// + frosted label) but in a fixed-size horizontal-strip layout.
// ─────────────────────────────────────────────────────────────────────────────
class _RecapStripTile extends StatelessWidget {
  final RecapCategory category;
  final VoidCallback onTap;
  const _RecapStripTile({required this.category, required this.onTap});

  Color get _tint {
    final hex = category.color.replaceAll('#', '');
    if (hex.length != 6) return const Color(0xFF3B82F6);
    return Color(int.parse('FF$hex', radix: 16));
  }

  String? get _thumb {
    final t = category.coverThumb;
    return (t == null || t.isEmpty) ? null : t;
  }

  RecapSlide? get _previewSlide {
    if (category.slides.isEmpty) return null;
    return category.slides.first;
  }

  String? _socialSourceFor(RecapSlide slide) {
    final type = slide.fileType.toLowerCase();
    if (type == 'instagram' ||
        type == 'facebook' ||
        type == 'linkedin' ||
        type == 'twitter' ||
        type == 'reddit') {
      return type;
    }
    final url = slide.sourceUrl.toLowerCase();
    if (url.contains('instagram.com')) return 'instagram';
    if (url.contains('facebook.com') || url.contains('fb.watch')) {
      return 'facebook';
    }
    if (url.contains('linkedin.com')) return 'linkedin';
    if (url.contains('twitter.com') || url.contains('x.com')) return 'twitter';
    if (url.contains('reddit.com') || url.contains('redd.it')) return 'reddit';
    return null;
  }

  Widget _visualBackdrop() {
    final thumb = _thumb;
    if (thumb != null) {
      return CachedNetworkImage(
        imageUrl: thumb,
        fit: BoxFit.cover,
        placeholder: (_, __) => _emojiBackdrop(),
        errorWidget: (_, __, ___) => _emojiBackdrop(),
      );
    }

    final slide = _previewSlide;
    final socialSource = slide == null ? null : _socialSourceFor(slide);
    if (slide != null && socialSource != null && slide.sourceUrl.isNotEmpty) {
      return SnapPreviewSurface(
        title: slide.fullTitle.isNotEmpty ? slide.fullTitle : slide.title,
        description: slide.description,
        originalFilename: slide.originalFilename,
        contentType: slide.fileType,
        imageUrl: null,
        socialSource: socialSource,
        sourceUrl: slide.sourceUrl,
        mode: SnapPreviewMode.grid,
        accentColor: _tint,
        imageFit: BoxFit.cover,
      );
    }

    return _emojiBackdrop();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Responsive.wp(18));
    return Material(
      color: Colors.white,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: _tint.withOpacity(0.25), width: 1),
            boxShadow: [
              BoxShadow(
                color: _tint.withOpacity(0.22),
                blurRadius: Responsive.wp(18),
                spreadRadius: -2,
                offset: Offset(0, Responsive.wp(8)),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _visualBackdrop(),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: Responsive.wp(60),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [_tint.withOpacity(0.4), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: Responsive.wp(95),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x00000000),
                          Color(0x80000000),
                          Color(0xE6000000),
                        ],
                        stops: [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: Responsive.wp(8),
                  right: Responsive.wp(8),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: Responsive.pp(8),
                      vertical: Responsive.pp(4),
                    ),
                    decoration: BoxDecoration(
                      color: _tint,
                      borderRadius: BorderRadius.circular(Responsive.wp(20)),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.9), width: 1.2),
                    ),
                    child: Text(
                      '${category.count}',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: Responsive.sp(10.5),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: Responsive.wp(10),
                  right: Responsive.wp(10),
                  bottom: Responsive.wp(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        category.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.spaceGrotesk(
                          color: Colors.white,
                          fontSize: Responsive.sp(13.5),
                          fontWeight: FontWeight.w800,
                          height: 1.18,
                          shadows: const [
                            Shadow(
                                color: Color(0xCC000000),
                                blurRadius: 6,
                                offset: Offset(0, 1)),
                          ],
                        ),
                      ),
                      SizedBox(height: Responsive.wp(2)),
                      Text(
                        category.count == 1
                            ? '1 snap'
                            : '${category.count} snaps',
                        style: GoogleFonts.inter(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: Responsive.sp(10),
                          fontWeight: FontWeight.w600,
                          shadows: const [
                            Shadow(color: Color(0xAA000000), blurRadius: 4),
                          ],
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
    );
  }

  Widget _emojiBackdrop() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(_tint, Colors.white, 0.2) ?? _tint,
            _tint,
            Color.lerp(_tint, Colors.black, 0.25) ?? _tint,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      alignment: Alignment.center,
      child: Opacity(
        opacity: 0.55,
        child: Text(
          category.name.characters.isEmpty
              ? '·'
              : category.name.characters.first,
          style: TextStyle(
            color: Colors.white,
            fontSize: Responsive.sp(72),
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}
