import 'dart:async';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/providers/notes_provider.dart';
import '../../core/services/api_service.dart';
import '../../core/services/thumbnail_cache_manager.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';
import 'widgets/snap_preview_surface.dart';

/// Persistent view state for the My Snaps screen (survives bottom-nav tab
/// rebuilds). `NotesScreen` is behind a GoRouter `NoTransitionPage`, so every
/// tap on the My Snaps bottom-nav tab throws away `_NotesScreenState` and
/// re-runs `initState()`. Before this provider, `_viewMode`, `_filterTag`
/// and `_filterType` reset to their defaults on every return visit — so a
/// user who filtered by a tag, hopped over to SnapBot, and came back would
/// be dumped back into the default Date view. Persisting the trio here keeps
/// the last selected filter/view alive across tab switches.
///
/// Deep-linked entry (widget.initialTag / widget.initialType != null) still
/// overrides the cache — that's the intended behaviour when the user taps a
/// tag/type card from Home.
class NotesViewState {
  /// 'date' | 'tags' | 'type'
  final String viewMode;
  final String? filterTag;
  final String? filterType;

  const NotesViewState({
    this.viewMode = 'date',
    this.filterTag,
    this.filterType,
  });

  NotesViewState copyWith({
    String? viewMode,
    String? filterTag,
    String? filterType,
    bool clearFilterTag = false,
    bool clearFilterType = false,
  }) {
    return NotesViewState(
      viewMode: viewMode ?? this.viewMode,
      filterTag: clearFilterTag ? null : (filterTag ?? this.filterTag),
      filterType: clearFilterType ? null : (filterType ?? this.filterType),
    );
  }
}

final notesViewStateProvider =
    StateProvider<NotesViewState>((ref) => const NotesViewState());

class NotesScreen extends ConsumerStatefulWidget {
  final String? shareToGroupId;
  final String? shareToGroupName;
  final String? initialTag;
  final String? initialType;

  const NotesScreen({
    super.key,
    this.shareToGroupId,
    this.shareToGroupName,
    this.initialTag,
    this.initialType,
  });

  bool get isShareToGroupMode =>
      shareToGroupId != null && shareToGroupId!.trim().isNotEmpty;

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen>
    with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();
  final Set<String> _collapsedSections = {};

  /// Screen-local view mode: 'date', 'tags', or 'type'. Mirrors the
  /// notesProvider viewMode for date/tags, and adds 'type' as a third
  /// grouping that the provider doesn't know about (treated as date for
  /// fetching).
  String _viewMode = 'date';

  /// Active collection filter applied via the home screen or chip bar.
  String? _filterTag;
  String? _filterType;

  /// Screen-local notes loaded with a server-side filter (currently used
  /// when arriving here from a Collections card with a tag). Bypasses the
  /// global notes provider so we don't pollute home's Recent Snaps.
  List<Note>? _filteredNotes;
  bool _isLoadingFiltered = false;
  String? _filteredError;

  /// Polls the notes list every few seconds while at least one card is still
  /// marked `status != 'active'`, so the spinner badge clears as soon as the
  /// background pipeline finishes indexing. Hard-capped to avoid runaway
  /// polling when a note is permanently stuck in a non-active state.
  Timer? _processingPollTimer;
  int _processingPollTicks = 0;

  /// Stop after ~80s (20 ticks * 4s). User can pull-to-refresh after that.
  static const int _processingPollMaxTicks = 20;

  /// True once we've hit the cap for the current set of processing notes;
  /// reset whenever the processing-set shrinks (so a new note re-enables it).
  bool _processingPollExhausted = false;
  int _lastProcessingCount = 0;

  /// Full-DB tag/type universe for the chip strip. Populated from the
  /// ApiService bootstrap caches and refreshed via fetchAppBootstrap so the
  /// chip row reflects EVERY value the user owns, not just the page of notes
  /// currently rendered in the grid.
  List<String> _allTagValues = const <String>[];
  List<String> _allTypeValues = const <String>[];
  VoidCallback? _tagsCacheVersionListener;

  static const Color _greenPrimary = Color(0xFF22c55e);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Deep-linked entry (Home → tag/type card) overrides the persisted
    // view state and rewrites the cache so a subsequent tab-switch return
    // lands back on the same filter.
    final incomingTag = widget.initialTag?.trim().isNotEmpty == true
        ? widget.initialTag!.trim()
        : null;
    final incomingType = widget.initialType?.trim().isNotEmpty == true
        ? widget.initialType!.trim()
        : null;

    if (incomingTag != null || incomingType != null) {
      _filterTag = incomingTag;
      _filterType = incomingType;
      _viewMode = incomingTag != null ? 'tags' : 'type';
      // Persist the deep-linked filter so returning from another tab keeps
      // the user on this view (write after first frame — reads during
      // initState aren't allowed on StateProvider setters).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(notesViewStateProvider.notifier).state = NotesViewState(
          viewMode: _viewMode,
          filterTag: _filterTag,
          filterType: _filterType,
        );
      });
    } else {
      // Restore prior selection (from a previous My Snaps visit in the
      // same session). Falls back to the defaults when nothing is cached.
      final cached = ref.read(notesViewStateProvider);
      _viewMode = cached.viewMode;
      _filterTag = cached.filterTag;
      _filterType = cached.filterType;
    }
    // Schedule load after first frame to show loading spinner.
    //
    // Behaviour change (2026-08): don't unconditionally refetch on every
    // tab switch. Bottom-nav routes rebuild NotesScreen on each tap, so a
    // blind loadNotes() was making the list flash "loading…" and re-fetch
    // from the network every time the user hit "My Snaps". The Home
    // screen's bootstrap already seeds the first page of notes into
    // notesProvider at app startup (see _loadHomeBootstrap →
    // NotesNotifier.seedFromBootstrap). We only fetch here when the
    // provider is genuinely empty (deep-linked entry, cold-open that
    // skipped Home, or a filtered view that needs different data).
    // Pull-to-refresh and the app-lifecycle resume path still call
    // refresh() / refreshSilent() explicitly.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_filterTag != null) {
        // Filtered views build their own list — always fetch.
        _loadFilteredNotes();
        return;
      }
      final notesState = ref.read(notesProvider);
      final alreadyPopulated =
          notesState.notes.isNotEmpty || notesState.error != null;
      if (alreadyPopulated) return;
      ref.read(notesProvider.notifier).loadNotes();
    });

    // Prime the full-DB tag/type universe used by the chip strip so the
    // user sees every value they own — even ones whose snaps haven't been
    // paged in yet.
    _hydrateChipUniverseFromCache();
    _tagsCacheVersionListener = () {
      if (!mounted) return;
      _hydrateChipUniverseFromCache();
    };
    ApiService().tagsCacheVersion.addListener(_tagsCacheVersionListener!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureChipUniverseLoaded();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _processingPollTimer?.cancel();
    _scrollController.dispose();
    if (_tagsCacheVersionListener != null) {
      ApiService()
          .tagsCacheVersion
          .removeListener(_tagsCacheVersionListener!);
    }
    super.dispose();
  }

  /// Push the current `_viewMode` / `_filterTag` / `_filterType` into
  /// `notesViewStateProvider` so a bottom-nav tab switch and return lands
  /// back on the same view. Called from every mutation site.
  void _persistViewState() {
    ref.read(notesViewStateProvider.notifier).state = NotesViewState(
      viewMode: _viewMode,
      filterTag: _filterTag,
      filterType: _filterType,
    );
  }

  /// Read the cached full-DB tag / type collections (populated by the home
  /// bootstrap call) into the chip-strip universe. Safe to call repeatedly.
  void _hydrateChipUniverseFromCache() {
    final api = ApiService();
    final tags = <String>{
      ...api.cachedTags.where((t) => t.trim().isNotEmpty),
      ...api.cachedTagCollections
          .map((c) => c.value)
          .where((v) => v.trim().isNotEmpty),
    };
    final types = <String>{
      ...api.cachedTypeCollections
          .map((c) => c.value)
          .where((v) => v.trim().isNotEmpty),
    };
    if (tags.isEmpty && types.isEmpty) return;
    if (!mounted) {
      _allTagValues = tags.toList(growable: false);
      _allTypeValues = types.toList(growable: false);
      return;
    }
    setState(() {
      _allTagValues = tags.toList(growable: false);
      _allTypeValues = types.toList(growable: false);
    });
  }

  /// Trigger a server bootstrap fetch if the chip universe is empty or the
  /// cached collections have aged out. Bootstrap is single-flighted in
  /// ApiService, so this is safe to call alongside the home screen.
  Future<void> _ensureChipUniverseLoaded({bool forceRefresh = false}) async {
    final api = ApiService();
    final cacheFresh = api.hasFreshCollections;
    final needsBootstrap = forceRefresh ||
        !cacheFresh ||
        (api.cachedTagCollections.isEmpty &&
            api.cachedTypeCollections.isEmpty);
    final needsTags = forceRefresh || api.cachedTags.isEmpty;
    if (needsBootstrap) {
      // notesLimit: 0 → don't disturb the notes list, just refresh the
      // bootstrap collections/tag aggregates.
      await api.fetchAppBootstrap(notesLimit: 0);
    }
    if (needsTags) {
      await api.fetchTags(forceRefresh: forceRefresh);
    }
    if (!mounted) return;
    _hydrateChipUniverseFromCache();
  }

  /// Fetch a server-side filtered slice of notes for the active tag filter.
  /// Bypasses the global notes provider so home's Recent Snaps remain intact.
  Future<void> _loadFilteredNotes() async {
    final tag = _filterTag;
    if (tag == null) return;
    setState(() {
      _isLoadingFiltered = true;
      _filteredError = null;
    });
    try {
      final notes = await ApiService().fetchNotesPaginated(
        limit: 200,
        offset: 0,
        tag: tag,
      );
      if (!mounted) return;
      setState(() {
        _filteredNotes = notes;
        _isLoadingFiltered = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _filteredError = e.toString();
        _isLoadingFiltered = false;
      });
    }
  }

  Future<void> _shareNoteToRequestedGroup(Note note) async {
    final groupId = widget.shareToGroupId;
    if (groupId == null || groupId.trim().isEmpty) return;

    if (note.isProcessing || note.id.startsWith('optimistic-upload-')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'This snap is still processing. Try sharing it in a moment.',
            style: GoogleFonts.inter(fontSize: Responsive.sp(12)),
          ),
        ),
      );
      return;
    }

    final groupName = widget.shareToGroupName?.trim().isNotEmpty == true
        ? widget.shareToGroupName!.trim()
        : 'group';
    showRootSnackBar('Sharing to $groupName...');
    final ok = await ApiService().shareSnapToGroup(groupId, note.id);
    showRootSnackBar(ok ? 'Shared to $groupName' : 'Could not share snap');
    if (!mounted) return;
    if (ok && context.canPop()) {
      context.pop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // Pause polling while backgrounded — battery friendly. User must
      // pull-to-refresh or reopen the app to see updates.
      _processingPollTimer?.cancel();
      _processingPollTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      // One forced refresh on resume so user sees current state without
      // having to pull. Polling restarts on next build() if needed.
      if (mounted) {
        ref.read(notesProvider.notifier).refreshSilent();
      }
    }
  }

  /// Start/stop the processing-status poll based on whether any visible note
  /// is still indexing. Called from build() each time notes state changes.
  void _syncProcessingPoll(List<Note> notes) {
    final processingCount = notes.where((n) => n.isProcessing).length;
    // If the processing set shrank (a note finished), allow polling again.
    if (processingCount < _lastProcessingCount) {
      _processingPollExhausted = false;
      _processingPollTicks = 0;
    }
    _lastProcessingCount = processingCount;

    final anyProcessing = processingCount > 0;
    if (anyProcessing &&
        _processingPollTimer == null &&
        !_processingPollExhausted) {
      _processingPollTicks = 0;
      _processingPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted) return;
        _processingPollTicks++;
        if (_processingPollTicks > _processingPollMaxTicks) {
          _processingPollTimer?.cancel();
          _processingPollTimer = null;
          _processingPollExhausted = true;
          return;
        }
        ref.read(notesProvider.notifier).refreshSilent();
      });
    } else if (!anyProcessing && _processingPollTimer != null) {
      _processingPollTimer?.cancel();
      _processingPollTimer = null;
      _processingPollTicks = 0;
      _processingPollExhausted = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final notesState = ref.watch(notesProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    _syncProcessingPoll(notesState.notes);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          const Positioned.fill(child: SoftGridBackground()),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header - matching dashboard.html view-header
                _buildHeader(theme, isDark),
                // Toolbar - Date|Tags|Type toggle
                _buildToolbar(theme, isDark),
                // Tag/Type chip strip (only in tags or type mode).
                _buildFilterChipsBar(theme, isDark, notesState.notes),
                if (_filterTag != null || _filterType != null)
                  _buildActiveFilterChip(theme, isDark),
                // Notes list
                Expanded(
                  child: _buildNotesContent(notesState),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build notes content based on state - wrapped with RefreshIndicator for pull-to-refresh
  Widget _buildNotesContent(NotesState state) {
    return RefreshIndicator(
      onRefresh: () async {
        if (_filterTag != null) {
          await _loadFilteredNotes();
        } else {
          await ref.read(notesProvider.notifier).refresh();
        }
      },
      color: AppColors.primary,
      child: _buildNotesContentInner(state),
    );
  }

  /// Inner content without RefreshIndicator
  Widget _buildNotesContentInner(NotesState state) {
    // Server-side filtered mode (currently used for tag collections).
    if (_filterTag != null) {
      if (_isLoadingFiltered && (_filteredNotes == null)) {
        return LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: constraints.maxHeight,
              child: _buildLoadingState(),
            ),
          ),
        );
      }
      if (_filteredError != null && (_filteredNotes?.isEmpty ?? true)) {
        return LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: constraints.maxHeight,
              child: _buildErrorState(_filteredError!),
            ),
          ),
        );
      }
      final filtered = _filteredNotes ?? const <Note>[];
      if (filtered.isEmpty) {
        return LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: constraints.maxHeight,
              child: _buildEmptyState(),
            ),
          ),
        );
      }
      return _buildNotesList(filtered, false, false);
    }
    return _buildNotesContentInnerDefault(state);
  }

  /// Default (un-filtered) content path.
  Widget _buildNotesContentInnerDefault(NotesState state) {
    if (state.isLoading) {
      // Wrap loading state in scrollable for RefreshIndicator to work
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: _buildLoadingState(),
          ),
        ),
      );
    }
    if (state.error != null && state.notes.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: _buildErrorState(state.error!),
          ),
        ),
      );
    }
    final filtered = _filterNotes(state.notes);
    if (filtered.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: _buildEmptyState(),
          ),
        ),
      );
    }
    return _buildNotesList(filtered, state.hasMore, state.isLoadingMore);
  }

  /// Header: "My Snaps" + subtitle + refresh button (or Selection Mode header)
  Widget _buildHeader(ThemeData theme, bool isDark) {
    final notesState = ref.watch(notesProvider);
    final isShareMode = widget.isShareToGroupMode;
    final groupName = widget.shareToGroupName?.trim().isNotEmpty == true
        ? widget.shareToGroupName!.trim()
        : 'group';

    // Selection mode header
    if (notesState.isSelectionMode && !isShareMode) {
      return _buildSelectionHeader(theme, isDark, notesState);
    }

    // Normal header — light gradient pill matching the Groups page style.
    final title = isShareMode ? 'Choose a snap' : 'My Snaps';
    final subtitle = isShareMode
        ? 'Tap a snap to share it with $groupName'
        : 'All your saved content in one place';
    return Container(
      margin: EdgeInsets.fromLTRB(
        Responsive.pp(12),
        Responsive.pp(8),
        Responsive.pp(12),
        Responsive.pp(8),
      ),
      padding: EdgeInsets.fromLTRB(
        Responsive.pp(14),
        Responsive.pp(14),
        Responsive.pp(10),
        Responsive.pp(14),
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFD1FAE5),
            Color(0xFFE0F2FE),
            Color(0xFFFEF3C7),
          ],
        ),
        borderRadius: BorderRadius.circular(Responsive.wp(22)),
        border: Border.all(color: Colors.white.withOpacity(0.6)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF22C55E).withOpacity(0.14),
            blurRadius: Responsive.wp(20),
            offset: Offset(0, Responsive.wp(8)),
          ),
        ],
      ),
      child: Row(
        children: [
          if (isShareMode) ...[
            IconButton(
              icon: const Icon(
                Icons.arrow_back_rounded,
                color: Color(0xFF0F172A),
              ),
              onPressed: () => context.pop(),
              tooltip: 'Cancel',
              visualDensity: VisualDensity.compact,
            ),
            SizedBox(width: Responsive.wp(2)),
          ] else ...[
            Container(
              width: Responsive.wp(40),
              height: Responsive.wp(40),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.7),
                borderRadius: BorderRadius.circular(Responsive.wp(12)),
                border: Border.all(color: Colors.white.withOpacity(0.9)),
              ),
              child: Icon(
                // Match the bottom-nav My Snaps icon for consistency.
                Icons.photo_library_rounded,
                size: Responsive.sp(20),
                color: const Color(0xFF059669),
              ),
            ),
            SizedBox(width: Responsive.wp(12)),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: Responsive.sp(22),
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F172A),
                    height: 1.1,
                  ),
                ),
                SizedBox(height: Responsive.wp(2)),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(12),
                    color: const Color(0xFF475569),
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (!isShareMode)
            IconButton(
              icon: const Icon(Icons.refresh_rounded,
                  color: Color(0xFF0F172A)),
              onPressed: () => ref.read(notesProvider.notifier).refresh(),
              tooltip: 'Refresh',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  /// Selection mode header with count, cancel, select all, and delete buttons
  Widget _buildSelectionHeader(
      ThemeData theme, bool isDark, NotesState notesState) {
    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.pp(12), Responsive.pp(12),
          Responsive.pp(12), Responsive.pp(8)),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E24) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF2D2D35) : const Color(0xFFE2E8F0),
          ),
        ),
      ),
      child: Row(
        children: [
          // Cancel button
          IconButton(
            icon: Icon(Icons.close, color: theme.colorScheme.onSurface),
            onPressed: () =>
                ref.read(notesProvider.notifier).exitSelectionMode(),
            tooltip: 'Cancel',
          ),
          SizedBox(width: Responsive.wp(8)),
          // Selected count
          Expanded(
            child: Text(
              '${notesState.selectedCount} selected',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(16),
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          // Select All button
          TextButton(
            onPressed: () => ref.read(notesProvider.notifier).selectAll(),
            child: Text(
              'Select All',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(13),
                fontWeight: FontWeight.w500,
                color: _greenPrimary,
              ),
            ),
          ),
          SizedBox(width: Responsive.wp(4)),
          // Delete button
          ElevatedButton.icon(
            onPressed: notesState.selectedCount > 0 && !notesState.isDeleting
                ? () => _confirmBulkDelete(notesState.selectedCount)
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade500,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(12), vertical: Responsive.pp(8)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Responsive.wp(8))),
            ),
            icon: notesState.isDeleting
                ? SizedBox(
                    width: Responsive.wp(16),
                    height: Responsive.wp(16),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Icon(Icons.delete_outline, size: Responsive.sp(18)),
            label: Text(
              notesState.isDeleting ? 'Deleting...' : 'Delete',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.w500, fontSize: Responsive.sp(13)),
            ),
          ),
        ],
      ),
    );
  }

  /// Show confirmation dialog for bulk delete
  void _confirmBulkDelete(int count) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E24) : Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(12))),
        title: Row(
          children: [
            Icon(Icons.delete_outline,
                color: Colors.red.shade400, size: Responsive.sp(22)),
            SizedBox(width: Responsive.wp(8)),
            Text(
              'Delete $count Snaps',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w600,
                fontSize: Responsive.sp(16),
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to delete $count selected snaps? This action cannot be undone.',
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(13),
            color: theme.colorScheme.onSurface.withOpacity(0.7),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _performBulkDelete();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade500,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(16), vertical: Responsive.pp(8)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Responsive.wp(6))),
            ),
            child: Text(
              'Delete All',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.w500, fontSize: Responsive.sp(13)),
            ),
          ),
        ],
      ),
    );
  }

  /// Perform the bulk delete operation
  Future<void> _performBulkDelete() async {
    final count = ref.read(notesProvider).selectedCount;

    final success =
        await ref.read(notesProvider.notifier).deleteSelectedNotes();

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle,
                    color: Colors.white, size: Responsive.sp(18)),
                SizedBox(width: Responsive.wp(10)),
                Text('$count snaps deleted',
                    style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
              ],
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.green.shade600,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.error_outline,
                    color: Colors.white, size: Responsive.sp(18)),
                SizedBox(width: Responsive.wp(10)),
                Text('Failed to delete some snaps',
                    style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
              ],
            ),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }
  }

  /// Pill banner shown beneath the toolbar when the user navigated here from
  /// a Collections card on the home screen. Lets them clear the filter.
  Widget _buildActiveFilterChip(ThemeData theme, bool isDark) {
    final isTag = _filterTag != null;
    final value = _filterTag ?? _filterType ?? '';
    final label = isTag ? 'Tag: $value' : 'Type: $value';
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Responsive.pp(20), 0, Responsive.pp(20), Responsive.pp(8)),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: _greenPrimary.withOpacity(0.12),
          borderRadius: BorderRadius.circular(Responsive.wp(20)),
          child: InkWell(
            borderRadius: BorderRadius.circular(Responsive.wp(20)),
            onTap: () {
              setState(() {
                _filterTag = null;
                _filterType = null;
                _filteredNotes = null;
                _filteredError = null;
              });
              _persistViewState();
              // Now that we're back to the default (unfiltered) view, make
              // sure the global notes provider has data to render.
              ref.read(notesProvider.notifier).loadNotes();
            },
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: Responsive.pp(12),
                vertical: Responsive.pp(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.filter_alt_rounded,
                      size: Responsive.sp(14), color: _greenPrimary),
                  SizedBox(width: Responsive.wp(6)),
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(11.5),
                      fontWeight: FontWeight.w700,
                      color: _greenPrimary,
                    ),
                  ),
                  SizedBox(width: Responsive.wp(6)),
                  Icon(Icons.close_rounded,
                      size: Responsive.sp(14), color: _greenPrimary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Toolbar: Date | Tags | Type toggle (search box removed; tag/type chips
  /// render in their own scrollable strip below).
  Widget _buildToolbar(ThemeData theme, bool isDark) {
    final borderColor =
        isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
    final surfaceColor = theme.colorScheme.surface;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          Responsive.pp(20), 4, Responsive.pp(20), Responsive.pp(12)),
      child: Container(
        height: Responsive.wp(38),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(Responsive.wp(10)),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            Expanded(child: _buildToggleBtn('📅 Date', 'date', isDark)),
            Container(
                width: Responsive.wp(1),
                height: Responsive.wp(20),
                color: borderColor),
            Expanded(child: _buildToggleBtn('🏷️ Tags', 'tags', isDark)),
            Container(
                width: Responsive.wp(1),
                height: Responsive.wp(20),
                color: borderColor),
            Expanded(child: _buildToggleBtn('📦 Type', 'type', isDark)),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 300.ms, delay: 100.ms);
  }

  Widget _buildToggleBtn(String label, String mode, bool isDark) {
    final isActive = _viewMode == mode;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_viewMode == mode) return;
        HapticFeedback.lightImpact();
        setState(() {
          _viewMode = mode;
          // Switching modes resets the active chip filter so the user sees
          // the full grouped view first.
          if (mode != 'tags') _filterTag = null;
          if (mode != 'type') _filterType = null;
          _filteredNotes = null;
          _filteredError = null;
        });
        _persistViewState();
        // Sync provider sort: 'date' for both date+type modes, 'tags' for tags.
        final providerMode = mode == 'tags' ? 'tags' : 'date';
        ref.read(notesProvider.notifier).setViewMode(providerMode);
        // Switching into Tags/Type? Make sure the chip-strip universe is
        // fresh so the user sees every value, not just whatever the cache
        // happened to hold.
        if (mode == 'tags' || mode == 'type') {
          unawaited(_ensureChipUniverseLoaded());
        }
      },
      child: Container(
        margin: EdgeInsets.symmetric(
            horizontal: Responsive.pp(4), vertical: Responsive.pp(4)),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive
              ? (isDark
                  ? _greenPrimary.withOpacity(0.15)
                  : const Color(0xFFDCFCE7))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(Responsive.wp(8)),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(11),
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
            color: isActive
                ? _greenPrimary
                : (isDark ? const Color(0xFF9CA3AF) : const Color(0xFF374151)),
          ),
        ),
      ),
    );
  }

  /// Horizontal chip strip rendered when the user is in Tags or Type mode.
  /// Mirrors Snapbot's tag-filter chip row.
  Widget _buildFilterChipsBar(
      ThemeData theme, bool isDark, List<Note> notes) {
    if (_viewMode != 'tags' && _viewMode != 'type') {
      return const SizedBox.shrink();
    }
    final isTagMode = _viewMode == 'tags';
    // Union of full-DB values (from the bootstrap collections cache) with
    // anything present in the currently loaded notes. This guarantees the
    // chip strip lists every tag/type the user owns — not just the ones in
    // the first page of paginated snaps — while still surfacing any brand
    // new value that hasn't propagated to the cache yet.
    final values = <String>{};
    if (isTagMode) {
      values.addAll(_allTagValues.where((v) => v.trim().isNotEmpty));
      for (final n in notes) {
        for (final t in n.tags) {
          final v = t.trim();
          if (v.isNotEmpty) values.add(v);
        }
      }
    } else {
      values.addAll(_allTypeValues.where((v) => v.trim().isNotEmpty));
      for (final n in notes) {
        values.add(_typeLabelFor(n));
      }
    }
    if (values.isEmpty) return const SizedBox.shrink();

    final selected = isTagMode ? _filterTag : _filterType;
    final sorted = values.toList()
      ..sort((a, b) {
        if (a == selected && b != selected) return -1;
        if (b == selected && a != selected) return 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    return Container(
      padding: EdgeInsets.fromLTRB(
          Responsive.pp(20), 0, Responsive.pp(20), Responsive.pp(8)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            isTagMode ? 'Tag:' : 'Type:',
            style: GoogleFonts.inter(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              fontSize: Responsive.sp(11),
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(width: Responsive.wp(8)),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _buildFilterChip(null, 'All', isDark, theme, isTagMode),
                  SizedBox(width: Responsive.wp(6)),
                  for (int i = 0; i < sorted.length; i++) ...[
                    _buildFilterChip(
                        sorted[i], sorted[i], isDark, theme, isTagMode),
                    if (i != sorted.length - 1)
                      SizedBox(width: Responsive.wp(6)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String? value, String label, bool isDark,
      ThemeData theme, bool isTagMode) {
    final selected = isTagMode ? _filterTag : _filterType;
    final isActive = value == selected;
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() {
          if (isTagMode) {
            _filterTag = value;
            _filterType = null;
            if (value == null) {
              _filteredNotes = null;
              _filteredError = null;
            }
          } else {
            _filterType = value;
            _filterTag = null;
            _filteredNotes = null;
            _filteredError = null;
          }
        });
        _persistViewState();
        if (isTagMode && value != null) {
          _loadFilteredNotes();
        } else if (isTagMode && value == null) {
          ref.read(notesProvider.notifier).loadNotes();
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(10), vertical: Responsive.pp(4)),
        decoration: BoxDecoration(
          color: isActive
              ? _greenPrimary.withOpacity(isDark ? 0.22 : 0.15)
              : (isDark ? const Color(0xFF1F2937) : Colors.white),
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          border: Border.all(
            color: isActive
                ? _greenPrimary
                : (isDark
                    ? const Color(0xFF374151)
                    : const Color(0xFFE2E8F0)),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(11),
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
            color: isActive
                ? _greenPrimary
                : (isDark ? const Color(0xFFD1D5DB) : const Color(0xFF374151)),
          ),
        ),
      ),
    );
  }

  /// Filter notes by search query
  List<Note> _filterNotes(List<Note> notes) {
    var filtered = notes;

    // Filter by collection tag passed from the home screen or tag chip.
    if (_filterTag != null) {
      final t = _filterTag!;
      filtered = filtered.where((n) => n.tags.contains(t)).toList();
    }

    // Filter by type chip / collection-card type.
    if (_filterType != null) {
      final t = _filterType!;
      filtered = filtered.where((n) => _typeLabelFor(n) == t).toList();
    }

    return filtered;
  }

  /// Mirrors home_screen's _collectionTypeLabel so the type filter from
  /// Collections matches the same buckets shown there.
  String _typeLabelFor(Note note) {
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

  Widget _buildLoadingState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: Responsive.wp(48),
            height: Responsive.wp(48),
            child: CircularProgressIndicator(
              color: AppColors.primary,
              strokeWidth: 4,
            ),
          ),
          SizedBox(height: Responsive.wp(20)),
          Text(
            'Loading your snaps...',
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(16),
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(String error) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Responsive.pp(20)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline,
                size: Responsive.sp(48), color: Colors.red.shade400),
            SizedBox(height: Responsive.wp(16)),
            Text(
              'Failed to load notes',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(16),
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: Responsive.wp(8)),
            Text(
              error,
              style: GoogleFonts.inter(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                  fontSize: Responsive.sp(13)),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: Responsive.wp(16)),
            ElevatedButton.icon(
              onPressed: () => ref.read(notesProvider.notifier).refresh(),
              icon: Icon(Icons.refresh),
              label: Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(Responsive.pp(20)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.note_add_outlined,
                      size: Responsive.sp(64),
                      color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  SizedBox(height: Responsive.wp(16)),
                  Text(
                    'No snaps yet',
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(22),
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: Responsive.wp(8)),
                  Text(
                    'Upload your first snap(screnshot,image,document,quicknote, webpage) using the chrome extension\nor tap the + button.',
                    style: GoogleFonts.inter(
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                        fontSize: Responsive.sp(14)),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNotesList(List<Note> notes, bool hasMore, bool isLoadingMore) {
    // Group notes by date, tag, or type based on the screen-local view mode.
    // When a chip filter is active we always fall back to date sections so
    // the filtered subset stays compact.
    List<_NoteSection> grouped;
    if (_filterTag != null || _filterType != null) {
      grouped = _groupNotesByDate(notes);
    } else if (_viewMode == 'tags') {
      grouped = _groupNotesByTag(notes);
    } else if (_viewMode == 'type') {
      grouped = _groupNotesByType(notes);
    } else {
      grouped = _groupNotesByDate(notes);
    }

    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(), // Enable pull-to-refresh
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(16), vertical: Responsive.pp(12)),
      itemCount: grouped.length + (hasMore || isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        // Load More button at the end
        if (index == grouped.length) {
          return _buildLoadMoreButton(isLoadingMore);
        }

        final section = grouped[index];
        final isCollapsed = _collapsedSections.contains(section.title);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (index > 0) SizedBox(height: Responsive.wp(16)),
            _buildSectionTitle(
                section.title, section.notes.length, isCollapsed),
            if (!isCollapsed) ...[
              SizedBox(height: Responsive.wp(8)),
              // Responsive Bento Mosaic — variable-height cards.
              // Column count adapts to screen width: Responsive.wp(2) on small phones,
              // 3 on large phones / small tablets, 4 on tablets+.
              LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  // Target ~165 logical px per card; clamp 2-4 columns.
                  final crossAxisCount =
                      (w / Responsive.wp(165)).floor().clamp(2, 4);
                  final spacing = Responsive.wp(14);
                  return StaggeredGrid.count(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    children: [
                      for (final note in section.notes)
                        StaggeredGridTile.fit(
                          crossAxisCellCount:
                              note.isLinkedIn && crossAxisCount > 1 ? 2 : 1,
                          child: _buildNoteCard(note),
                        ),
                    ],
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  /// Build the Load More button
  Widget _buildLoadMoreButton(bool isLoading) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: Responsive.pp(24)),
      child: Center(
        child: isLoading
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: Responsive.wp(16),
                    height: Responsive.wp(16),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
                  SizedBox(width: Responsive.wp(8)),
                  Text(
                    'Loading more...',
                    style: GoogleFonts.inter(
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                      fontSize: Responsive.sp(13),
                    ),
                  ),
                ],
              )
            : TextButton(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  ref.read(notesProvider.notifier).loadMore();
                },
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                      horizontal: Responsive.pp(24),
                      vertical: Responsive.pp(12)),
                  backgroundColor: isDark
                      ? AppColors.primary.withOpacity(0.15)
                      : const Color(0xFFDCFCE7),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Responsive.wp(10)),
                  ),
                ),
                child: Text(
                  'Load More',
                  style: GoogleFonts.inter(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: Responsive.sp(14),
                  ),
                ),
              ),
      ),
    );
  }

  List<_NoteSection> _groupNotesByDate(List<Note> notes) {
    // Condensed with monthly rollup: Today, Yesterday, This Week, Last Week, Earlier This Month, then monthly
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    // Calculate start of this week (Monday)
    final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));
    // Start of last week
    final lastWeekStart = thisWeekStart.subtract(const Duration(days: 7));
    // Start of current month
    final thisMonthStart = DateTime(now.year, now.month, 1);

    final todayNotes = <Note>[];
    final yesterdayNotes = <Note>[];
    final thisWeekNotes = <Note>[];
    final lastWeekNotes = <Note>[];
    final earlierThisMonthNotes = <Note>[];
    // Group older notes by month: "March 2026" -> notes
    final monthlyNotes = <String, List<Note>>{};
    final monthKeys = <String>[]; // preserve order

    for (final note in notes) {
      final noteDate = DateTime(
        note.createdAt.year,
        note.createdAt.month,
        note.createdAt.day,
      );

      if (noteDate.isAtSameMomentAs(today) || noteDate.isAfter(today)) {
        todayNotes.add(note);
      } else if (noteDate.isAtSameMomentAs(yesterday) ||
          (noteDate.isAfter(yesterday) && noteDate.isBefore(today))) {
        yesterdayNotes.add(note);
      } else if (noteDate.isAtSameMomentAs(thisWeekStart) ||
          (noteDate.isAfter(thisWeekStart) && noteDate.isBefore(yesterday))) {
        thisWeekNotes.add(note);
      } else if (noteDate.isAtSameMomentAs(lastWeekStart) ||
          (noteDate.isAfter(lastWeekStart) &&
              noteDate.isBefore(thisWeekStart))) {
        lastWeekNotes.add(note);
      } else if (noteDate.isAtSameMomentAs(thisMonthStart) ||
          noteDate.isAfter(thisMonthStart)) {
        earlierThisMonthNotes.add(note);
      } else {
        // Group by month
        final monthNames = [
          'January',
          'February',
          'March',
          'April',
          'May',
          'June',
          'July',
          'August',
          'September',
          'October',
          'November',
          'December'
        ];
        final key =
            '${monthNames[note.createdAt.month - 1]} ${note.createdAt.year}';
        if (!monthlyNotes.containsKey(key)) {
          monthlyNotes[key] = [];
          monthKeys.add(key);
        }
        monthlyNotes[key]!.add(note);
      }
    }

    final sections = <_NoteSection>[];
    if (todayNotes.isNotEmpty) sections.add(_NoteSection('Today', todayNotes));
    if (yesterdayNotes.isNotEmpty)
      sections.add(_NoteSection('Yesterday', yesterdayNotes));
    if (thisWeekNotes.isNotEmpty)
      sections.add(_NoteSection('This Week', thisWeekNotes));
    if (lastWeekNotes.isNotEmpty)
      sections.add(_NoteSection('Last Week', lastWeekNotes));
    if (earlierThisMonthNotes.isNotEmpty)
      sections.add(_NoteSection('Earlier This Month', earlierThisMonthNotes));
    // Add monthly sections in chronological order (most recent first)
    for (final key in monthKeys) {
      sections.add(_NoteSection(key, monthlyNotes[key]!));
    }

    return sections;
  }

  List<_NoteSection> _groupNotesByTag(List<Note> notes) {
    final tagMap = <String, List<Note>>{};

    for (final note in notes) {
      if (note.tags.isEmpty) {
        tagMap.putIfAbsent('Untagged', () => []).add(note);
      } else {
        for (final tag in note.tags) {
          final displayTag = tag.isNotEmpty
              ? '${tag[0].toUpperCase()}${tag.substring(1)}'
              : tag;
          tagMap.putIfAbsent(displayTag, () => []).add(note);
        }
      }
    }

    return tagMap.entries.map((e) => _NoteSection(e.key, e.value)).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  /// Group notes into sections keyed by their type label (matches the
  /// labels emitted by `_typeLabelFor`).
  List<_NoteSection> _groupNotesByType(List<Note> notes) {
    final typeMap = <String, List<Note>>{};
    for (final note in notes) {
      final label = _typeLabelFor(note);
      typeMap.putIfAbsent(label, () => []).add(note);
    }
    return typeMap.entries.map((e) => _NoteSection(e.key, e.value)).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  Widget _buildSectionTitle(String title, int count, bool isCollapsed) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() {
          if (isCollapsed) {
            _collapsedSections.remove(title);
          } else {
            _collapsedSections.add(title);
          }
        });
      },
      child: Row(
        children: [
          Container(
            width: Responsive.wp(8),
            height: Responsive.wp(8),
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: Responsive.wp(10)),
          Flexible(
            child: Text(
              title,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(13),
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: Responsive.wp(8)),
          Text(
            '($count)',
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(11),
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
          ),
          SizedBox(width: Responsive.wp(12)),
          Expanded(
            child: Container(
              height: 1,
              color: isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0),
            ),
          ),
          SizedBox(width: Responsive.wp(8)),
          AnimatedRotation(
            turns: isCollapsed ? -0.25 : 0,
            duration: const Duration(milliseconds: 200),
            child: Icon(
              Icons.expand_more_rounded,
              size: Responsive.sp(20),
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteCard(Note note) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final notesState = ref.watch(notesProvider);
    final isSelectionMode = notesState.isSelectionMode;
    final isShareMode = widget.isShareToGroupMode;
    final isSelected = notesState.isSelected(note.id);
    final isOptimisticUpload = note.id.startsWith('optimistic-upload-');
    final contentTypeLower = (note.contentType ?? '').toLowerCase();
    final uploadType = contentTypeLower;
    final isQuickNote = uploadType == 'quick_note';
    final previewText = note.description ?? '';
    final previewLimit = 360;
    final preview = previewText.length > previewLimit
        ? '${previewText.substring(0, previewLimit)}...'.trim()
        : previewText.trim();
    final previewDisplay = preview.isEmpty ? '' : preview;
    final tagLabel =
        (note.tags.isNotEmpty ? note.tags.first : (note.contentType ?? 'snap'))
            .toUpperCase();
    final quickNoteHeroText =
        note.title.trim().isNotEmpty ? note.title.trim() : 'Quick Note';

    final primaryImageUrl =
        (note.thumbnailUrl != null && note.thumbnailUrl!.trim().isNotEmpty)
            ? note.thumbnailUrl!.trim()
            : null;
    final fallbackImageUrl =
        (note.blobUrl != null && note.blobUrl!.trim().isNotEmpty)
            ? note.blobUrl!.trim()
            : null;
    // Only use blob_url as a visual preview for image-like uploads.
    final useBlobAsPreview =
        uploadType == 'image' || uploadType == 'screenshot';
    final previewImageUrl =
        primaryImageUrl ?? (useBlobAsPreview ? fallbackImageUrl : null);
    final isInstagramNote = note.isInstagram;
    final isFacebookNote = note.isFacebook;
    final isLinkedInNote = note.isLinkedIn;
    // YouTube layout flags. YT thumbnails are always landscape 16:9 even for
    // Shorts (the portrait content sits centered inside the landscape frame).
    // For Shorts we want BoxFit.cover so the portrait subject fills the card
    // image area; for regular videos BoxFit.contain avoids cropping the
    // landscape frame.
    final isYouTubeNote = (note.socialSource ?? '').toLowerCase() == 'youtube';
    final isYouTubeShort =
        isYouTubeNote && (note.socialPostType ?? '').toLowerCase() == 'short';
    final isInstagramReel =
        isInstagramNote && (note.socialPostType ?? '').toLowerCase() == 'reel';
    final isTwitterNote = note.isTwitter;
    final isRedditNote = note.isReddit;
    final isImageCard = previewImageUrl != null ||
        isInstagramNote ||
        isFacebookNote ||
        isLinkedInNote ||
        isTwitterNote ||
        isRedditNote;
    final isSocialNote = isYouTubeNote ||
        isInstagramNote ||
        isFacebookNote ||
        isLinkedInNote ||
        isTwitterNote ||
        isRedditNote;
    final redditPostType = (note.socialPostType ?? '').toLowerCase();
    final isRedditImagePost = isRedditNote && redditPostType == 'image';
    final isRedditVideoPost = isRedditNote && redditPostType == 'video';
    // YouTube official thumbnails are usually 16:9. Shorts often place the
    // vertical video inside that frame, so cover makes the subject readable.
    final imageFit = isYouTubeNote
        ? BoxFit.cover
        : isSocialNote
            ? BoxFit.contain
            : BoxFit.cover;

    // Bento Mosaic — thumbnail aspect ratio varies by content type so each
    // snap occupies its natural shape (Reels tall, YouTube wide, docs square).
    // The card height is then thumbnail height + intrinsic footer height,
    // which is what makes the masonry grid look "bento".
    double thumbAspect;
    if (isInstagramReel) {
      thumbAspect =
          2 / 3; // official embed, a little taller while staying two-up
    } else if (isYouTubeShort) {
      thumbAspect = 9 / 16; // tall portrait video
    } else if (isYouTubeNote) {
      thumbAspect = 16 / 9; // wide landscape video
    } else if (isInstagramNote) {
      thumbAspect = 4 / 5; // IG post (slightly tall)
    } else if (isFacebookNote) {
      thumbAspect = 2 / 3; // Facebook official embed needs vertical room
    } else if (isLinkedInNote) {
      thumbAspect = 16 / 9; // full-row LinkedIn embed, controlled height
    } else if (isTwitterNote) {
      thumbAspect = 2 / 3; // taller two-up embed so tweet text is not clipped
    } else if (isRedditImagePost || isRedditVideoPost) {
      thumbAspect = 3 / 4; // reddit media posts are often portrait previews
    } else if (isRedditNote) {
      thumbAspect = 2 / 3; // taller two-up embed so reddit snippet can render
    } else if (uploadType == 'image' || uploadType == 'screenshot') {
      thumbAspect = 1 / 1; // square photo
    } else if (uploadType == 'quick_note') {
      thumbAspect =
          5 / 4; // slightly taller-than-wide for handwritten note feel
    } else if (uploadType == 'webpage') {
      thumbAspect = 4 / 5; // article hero / OG image — needs vertical room
    } else {
      thumbAspect = 4 / 5; // docs, pdfs, unknowns — match webpage card height
    }

    Gradient contentGradient;
    switch (uploadType) {
      case 'uploaded_file':
        contentGradient = const LinearGradient(
          begin: Alignment(-0.35, -1.0),
          end: Alignment(0.35, 1.0),
          colors: [Color(0xFFF8D7DF), Color(0xFFF3E4CB)],
        );
        break;
      case 'webpage':
      case 'article':
        contentGradient = const LinearGradient(
          begin: Alignment(-1.0, 0.0),
          end: Alignment(1.0, 0.0),
          colors: [Color(0xFFDDEAF6), Color(0xFFE9F5E8)],
        );
        break;
      case 'pdf':
        contentGradient = const LinearGradient(
          begin: Alignment(-0.6, -1.0),
          end: Alignment(0.9, 1.0),
          colors: [Color(0xFFE3EFFE), Color(0xFFF9EFFC)],
        );
        break;
      case 'quick_note':
        contentGradient = const RadialGradient(
          center: Alignment(0.10, 0.03),
          radius: 1.05,
          colors: [
            Color(0xFFE1F5FE),
            Color(0xFFF5F7FF),
            Color(0xFFF5F7FF),
          ],
          stops: [0.0, 0.423, 1.0],
        );
        break;
      case 'screenshot':
      case 'image':
        contentGradient = const LinearGradient(
          begin: Alignment(-1.0, -1.0),
          end: Alignment(1.0, 1.0),
          colors: [Color(0xFFF9DDE4), Color(0xFFF4ECD9)],
        );
        break;
      default:
        contentGradient = const LinearGradient(
          begin: Alignment(-0.35, -1.0),
          end: Alignment(0.35, 1.0),
          colors: [Color(0xFFE3F1FF), Color(0xFFEAF7F1)],
        );
        break;
    }

    final footerBgColor =
        isDark ? const Color(0xFFF5F5F5) : const Color(0xFFFAFAFA);
    final footerTextColor = const Color(0xFF1F2937);
    final footerMutedColor = const Color(0xFF6B7280);
    final previewCandidates = _buildAspectRatioCandidates(previewImageUrl);

    return _ResolvedAspectRatio(
      imageCandidates: previewCandidates,
      fallbackAspectRatio: thumbAspect,
      builder: (resolvedThumbAspect) => GestureDetector(
        onTap: () {
          if (isOptimisticUpload) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 2),
                content: Text(
                  'Still preparing this snap...',
                  style: GoogleFonts.inter(fontSize: Responsive.sp(12)),
                ),
              ),
            );
            return;
          }
          if (isSelectionMode && !isShareMode) {
            HapticFeedback.selectionClick();
            ref.read(notesProvider.notifier).toggleNoteSelection(note.id);
          } else if (isShareMode) {
            HapticFeedback.selectionClick();
            _shareNoteToRequestedGroup(note);
          } else {
            context.push('/notes/${note.id}', extra: note);
          }
        },
        onLongPress: () {
          if (isOptimisticUpload) return;
          if (!isSelectionMode && !isShareMode) {
            HapticFeedback.mediumImpact();
            ref
                .read(notesProvider.notifier)
                .enterSelectionMode(initialNoteId: note.id);
          }
        },
        child: LayoutBuilder(
          builder: (context, cardConstraints) {
            final topRadius = Radius.circular(Responsive.wp(12));
            final outerRadius = BorderRadius.circular(Responsive.wp(14));
            final quickNoteFooterHeight =
                math.max(Responsive.pp(38), cardConstraints.maxHeight * 0.10);

            Widget buildFooterRow({required EdgeInsets padding}) {
              return Padding(
                padding: padding,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _formatUploadedDaysAgo(note.createdAt),
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(10),
                          fontWeight: FontWeight.w500,
                          color: footerMutedColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!isSelectionMode && !isShareMode) ...[
                      SizedBox(width: Responsive.wp(6)),
                      Container(
                        constraints: BoxConstraints(
                            maxWidth: cardConstraints.maxWidth * 0.42),
                        padding: EdgeInsets.symmetric(
                          horizontal: Responsive.pp(7),
                          vertical: Responsive.pp(3),
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111827).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(Responsive.wp(6)),
                        ),
                        child: Text(
                          tagLabel,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(9),
                            fontWeight: FontWeight.w700,
                            color: footerTextColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }

            return Container(
              decoration: BoxDecoration(
                color: footerBgColor,
                borderRadius: outerRadius,
                border: Border.all(
                  color: isSelected
                      ? _greenPrimary
                      : (isDark
                          ? const Color(0xFFE5E5E5)
                          : const Color(0xFFE2E8F0)),
                  width: isSelected ? Responsive.pp(2) : Responsive.pp(1),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: Responsive.wp(12),
                    offset: Offset(0, Responsive.wp(4)),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AspectRatio(
                    aspectRatio: resolvedThumbAspect,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: SnapPreviewSurface(
                            title: isQuickNote
                                ? quickNoteHeroText
                                : note.displayTitle,
                            description: note.description,
                            originalFilename: note.originalFilename,
                            contentType: isQuickNote
                                ? (note.contentType ?? 'quick_note')
                                : note.contentType,
                            imageUrl: previewImageUrl,
                            noteId: note.id,
                            socialSource: note.socialSource,
                            socialEmbedHtml: note.socialEmbedHtml,
                            sourceUrl: note.sourceUrl,
                            mode: SnapPreviewMode.grid,
                            imageFit: imageFit,
                          ),
                        ),

                        if (isSelectionMode)
                          Positioned(
                            top: Responsive.pp(8),
                            left: Responsive.pp(8),
                            child: SizedBox(
                              width: Responsive.wp(24),
                              height: Responsive.wp(24),
                              child: Checkbox(
                                value: isSelected,
                                onChanged: (_) {
                                  HapticFeedback.selectionClick();
                                  ref
                                      .read(notesProvider.notifier)
                                      .toggleNoteSelection(note.id);
                                },
                                activeColor: _greenPrimary,
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(Responsive.wp(4)),
                                ),
                                side: BorderSide(
                                  color: Colors.white.withOpacity(0.8),
                                  width: Responsive.pp(1.5),
                                ),
                              ),
                            ),
                          ),
                        if (!isSelectionMode &&
                            !isShareMode &&
                            note.isProcessing)
                          Positioned(
                            top: Responsive.pp(8),
                            left: Responsive.pp(8),
                            child: _buildProcessingBadge(),
                          ),

                        // Platform badge (YouTube / Instagram / LinkedIn) on
                        // bottom-left of the thumbnail. Only shown for
                        // social-source notes.
                        if (isYouTubeNote ||
                            isInstagramNote ||
                            isFacebookNote ||
                            isLinkedInNote ||
                            isTwitterNote ||
                            isRedditNote)
                          Positioned(
                            bottom: Responsive.pp(8),
                            left: Responsive.pp(8),
                            child: _PlatformBadge(
                              source: isYouTubeNote
                                  ? 'youtube'
                                  : isInstagramNote
                                      ? 'instagram'
                                      : isFacebookNote
                                          ? 'facebook'
                                          : isLinkedInNote
                                              ? 'linkedin'
                                              : isTwitterNote
                                                  ? 'twitter'
                                                  : 'reddit',
                            ),
                          ),

                        if (!isSelectionMode && !isShareMode)
                          Positioned(
                            top: Responsive.pp(8),
                            right: Responsive.pp(8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isQuickNote)
                                  GestureDetector(
                                    onTap: () => _showEditQuickNoteDialog(note),
                                    child: Container(
                                      width: Responsive.wp(30),
                                      height: Responsive.wp(30),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.30),
                                        borderRadius: BorderRadius.circular(
                                            Responsive.wp(7)),
                                      ),
                                      child: Icon(
                                        Icons.edit_outlined,
                                        size: Responsive.sp(15),
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                if (isQuickNote)
                                  SizedBox(width: Responsive.wp(6)),
                                Opacity(
                                  opacity: note.isProcessing ? 0.4 : 1.0,
                                  child: GestureDetector(
                                    onTap: note.isProcessing
                                        ? null
                                        : () => _confirmDeleteNote(note),
                                    child: Container(
                                      width: Responsive.wp(30),
                                      height: Responsive.wp(30),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.30),
                                        borderRadius: BorderRadius.circular(
                                            Responsive.wp(7)),
                                      ),
                                      child: Icon(
                                        Icons.delete_outline,
                                        size: Responsive.sp(16),
                                        color: Colors.white,
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
                  Padding(
                    padding: EdgeInsets.all(Responsive.pp(10)),
                    child: isImageCard
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Instagram posts have no real title — the scraped
                              // "title" is just the first line of the caption
                              // (often a likes/comments preamble). Skip the
                              // title row entirely and let the caption preview
                              // fill the text area.
                              if (isInstagramNote)
                                const SizedBox.shrink()
                              // For YouTube notes, allow up to 3 lines and
                              // auto-shrink so the full title fits without
                              // ellipsis (titles often exceed 50 chars).
                              else if (isYouTubeNote)
                                _AutoShrinkText(
                                  text: note.displayTitle,
                                  style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w700,
                                    fontSize: Responsive.sp(14),
                                    color: footerTextColor,
                                    height: 1.18,
                                  ),
                                  maxLines: 3,
                                  minFontSize: Responsive.sp(10),
                                )
                              else if (isTwitterNote || isRedditNote)
                                Text(
                                  isTwitterNote ? 'X post' : 'Reddit post',
                                  style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w800,
                                    fontSize: Responsive.sp(13),
                                    color: isTwitterNote
                                        ? const Color(0xFF111827)
                                        : const Color(0xFFFF4500),
                                    height: 1.15,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              else
                                Text(
                                  note.displayTitle,
                                  style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w700,
                                    fontSize: Responsive.sp(15),
                                    color: footerTextColor,
                                    height: 1.15,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              SizedBox(height: Responsive.wp(4)),
                              if (previewDisplay.isNotEmpty && !isYouTubeNote)
                                Text(
                                  previewDisplay,
                                  style: GoogleFonts.inter(
                                    color: footerMutedColor,
                                    fontSize: Responsive.sp(12),
                                    fontWeight: FontWeight.w400,
                                    height: 1.30,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              SizedBox(height: Responsive.wp(4)),
                              buildFooterRow(padding: EdgeInsets.zero),
                            ],
                          )
                        : Align(
                            alignment: Alignment.bottomLeft,
                            child: buildFooterRow(padding: EdgeInsets.zero),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 480.ms)
        .slideY(
            begin: 0.28, end: 0, curve: Curves.easeOutCubic, duration: 480.ms)
        .scale(
            begin: Offset(0.80, 0.80),
            end: Offset(1.0, 1.0),
            curve: Curves.easeOutBack,
            duration: 480.ms);
  }

  List<String> _buildAspectRatioCandidates(String? imageUrl) {
    final primary = imageUrl?.trim();
    if (primary == null || primary.isEmpty) return const [];

    final candidates = <String>[primary];
    if (primary.contains('maxresdefault')) {
      candidates.add(primary.replaceFirst('maxresdefault', 'hqdefault'));
    }
    return candidates;
  }

  double _fitQuickNoteFontSize({
    required BuildContext context,
    required String text,
    required double maxWidth,
    required double maxHeight,
    required TextStyle baseStyle,
    int maxLines = 5,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    const minFontSize = 16.0;
    final safeMaxWidth = math.max(1.0, maxWidth).toDouble();
    final safeMaxHeight = math.max(1.0, maxHeight).toDouble();
    double low = minFontSize;
    double high = 140.0;
    double best = minFontSize;

    bool fits(double fontSize) {
      final painter = TextPainter(
        text:
            TextSpan(text: text, style: baseStyle.copyWith(fontSize: fontSize)),
        textAlign: TextAlign.center,
        textDirection: Directionality.of(context),
        maxLines: maxLines,
        textScaler: scaler,
      )..layout(maxWidth: safeMaxWidth);
      return !painter.didExceedMaxLines && painter.height <= safeMaxHeight;
    }

    for (var i = 0; i < 18; i++) {
      final mid = (low + high) / 2;
      if (fits(mid)) {
        best = mid;
        low = mid;
      } else {
        high = mid;
      }
    }

    return best;
  }

  /// Small spinner badge shown top-left on a card while the note is still
  /// being indexed (chunking/embedding/vectorize). Cleared once the worker
  /// flips `notes.status` to `'active'`.
  Widget _buildProcessingBadge() {
    return Container(
      width: Responsive.wp(28),
      height: Responsive.wp(28),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(Responsive.wp(7)),
      ),
      padding: EdgeInsets.all(Responsive.wp(6)),
      child: CircularProgressIndicator(
        strokeWidth: 2,
        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
      ),
    );
  }

  // Uses emojis like the web dashboard
  String _getThemeIcon(String type) {
    switch (type.toLowerCase()) {
      case 'pdf':
        return '📄';
      case 'word':
        return '📝';
      case 'email':
        return '📧';
      case 'image':
        return '🖼️';
      case 'note':
        return '📋';
      case 'quick_note':
        return '📝';
      case 'uploaded_file':
        return '📁';
      case 'screenshot':
        return '🖼️';
      case 'webpage':
        return '🌐';
      default:
        return '�';
    }
  }

  Future<void> _showEditQuickNoteDialog(Note note) async {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final controller =
        TextEditingController(text: 'Loading your quick note content...');
    bool fetchCancelled = false;
    bool dialogOpen = true;
    bool isContentLoading = true;
    bool isSaving = false;
    bool isSaveRequestInFlight = false;
    bool isCancelling = false;
    bool editCancelRequested = false;
    String saveBtnLabel = 'Save';
    String cancelBtnLabel = 'Cancel';
    String? editTraceId;
    Timer? editPollTimer;
    StateSetter? setDialogState;
    bool dialogClosed = false;

    void safelySetDialogState(VoidCallback fn) {
      if (!mounted || fetchCancelled || !dialogOpen) return;
      final setter = setDialogState;
      if (setter == null) return;
      try {
        setter(fn);
      } catch (_) {
        // Dialog state may already be disposed during async cancel/save transitions.
      }
    }

    void safelyCloseDialog(BuildContext dialogContext) {
      if (dialogClosed) return;
      dialogClosed = true;
      dialogOpen = false;
      editPollTimer?.cancel();
      editPollTimer = null;
      if (dialogContext.mounted && Navigator.of(dialogContext).canPop()) {
        Navigator.of(dialogContext).pop();
      }
    }

    // Fetch content asynchronously and update controller when ready
    ApiService()
        .getQuickNoteContentForEditing(
      note.id,
      fallback: (note.contentPreview ?? '').trim(),
    )
        .then((initialContent) {
      if (mounted && !fetchCancelled && dialogOpen) {
        controller.text =
            _sanitizeEditableQuickNoteContent(initialContent, note.title);
        isContentLoading = false;
        safelySetDialogState(() {});
      }
    }).catchError((_) {
      if (mounted && !fetchCancelled && dialogOpen) {
        isContentLoading = false;
        safelySetDialogState(() {});
      }
    });

    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, modalSetState) {
              setDialogState = modalSetState;
              return AlertDialog(
                backgroundColor:
                    isDark ? const Color(0xFF1E1E24) : Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Responsive.wp(12))),
                title: Row(
                  children: [
                    Icon(Icons.edit_outlined,
                        color: AppColors.primary, size: Responsive.sp(22)),
                    SizedBox(width: Responsive.wp(8)),
                    Expanded(
                      child: Text(
                        'Edit Quick Note',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          fontSize: Responsive.sp(16),
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: MediaQuery.of(context).size.width > 600
                      ? Responsive.wp(420)
                      : MediaQuery.of(context).size.width * 0.9,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        note.title,
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(12),
                          color: theme.colorScheme.onSurface.withOpacity(0.7),
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: Responsive.wp(10)),
                      TextField(
                        controller: controller,
                        maxLines: 8,
                        minLines: 5,
                        enabled: !isSaving && !isContentLoading,
                        readOnly: isContentLoading,
                        decoration: InputDecoration(
                          hintText: isContentLoading
                              ? 'Loading your quick note content...'
                              : 'Edit quick note content...',
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(Responsive.wp(8)),
                          ),
                          contentPadding: EdgeInsets.all(Responsive.pp(12)),
                        ),
                        style: GoogleFonts.inter(fontSize: Responsive.sp(13)),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      if (isCancelling) return;

                      final traceId = editTraceId;
                      if (traceId == null &&
                          !isSaving &&
                          !isSaveRequestInFlight) {
                        safelyCloseDialog(ctx);
                        return;
                      }

                      safelySetDialogState(() {
                        isCancelling = true;
                        cancelBtnLabel = 'Cancelling...';
                      });

                      if (traceId == null) {
                        // Request is still in-flight (pre-trace). Queue cancel and keep button locked.
                        editCancelRequested = true;
                        return;
                      }

                      final cancelResult =
                          await ApiService().cancelUploadDetailed(traceId);
                      if (!mounted || !ctx.mounted) return;

                      if (cancelResult['success'] == true) {
                        editPollTimer?.cancel();
                        editPollTimer = null;
                        editTraceId = null;
                        safelyCloseDialog(ctx);
                        await ref.read(notesProvider.notifier).refresh();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Update cancelled',
                              style: GoogleFonts.inter(
                                  fontSize: Responsive.sp(13)),
                            ),
                            backgroundColor: Colors.orange.shade700,
                          ),
                        );
                        return;
                      }

                      if (cancelResult['too_late'] == true) {
                        safelySetDialogState(() {
                          isCancelling = false;
                          cancelBtnLabel = 'Cancel';
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Too late to cancel. Your update is finalizing now.',
                              style: GoogleFonts.inter(
                                  fontSize: Responsive.sp(13)),
                            ),
                            backgroundColor: Colors.blue.shade700,
                          ),
                        );
                        return;
                      }

                      safelySetDialogState(() {
                        isCancelling = false;
                        cancelBtnLabel = 'Cancel';
                      });
                      final errMsg =
                          (cancelResult['message']?.toString().isNotEmpty ==
                                  true)
                              ? cancelResult['message'].toString()
                              : 'Unable to cancel right now. Still updating...';
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            errMsg,
                            style:
                                GoogleFonts.inter(fontSize: Responsive.sp(13)),
                          ),
                          backgroundColor: Colors.red.shade600,
                        ),
                      );
                    },
                    child: Text(
                      isSaving ? cancelBtnLabel : 'Cancel',
                      style: GoogleFonts.inter(
                        color: theme.colorScheme.onSurface.withOpacity(0.65),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: (isSaving || isContentLoading)
                        ? null
                        : () async {
                            final edited = controller.text.trim();
                            if (edited.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Content cannot be empty',
                                    style: GoogleFonts.inter(
                                        fontSize: Responsive.sp(13)),
                                  ),
                                  backgroundColor: Colors.red.shade600,
                                ),
                              );
                              return;
                            }

                            safelySetDialogState(() {
                              isSaving = true;
                              isSaveRequestInFlight = true;
                              isCancelling = false;
                              cancelBtnLabel = 'Cancel';
                              saveBtnLabel = 'Saving...';
                            });

                            final result = await ApiService().recreateQuickNote(
                              noteId: note.id,
                              content: edited,
                              title: note.title,
                              tag:
                                  note.tags.isNotEmpty ? note.tags.first : null,
                            );

                            if (!mounted || !ctx.mounted) return;

                            isSaveRequestInFlight = false;

                            if (result['success'] != true) {
                              safelySetDialogState(() {
                                isSaving = false;
                                saveBtnLabel = 'Save';
                              });
                              final err = result['error']?.toString() ??
                                  'Failed to update quick note';
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(children: [
                                    Icon(Icons.error_outline,
                                        color: Colors.white,
                                        size: Responsive.sp(18)),
                                    SizedBox(width: Responsive.wp(10)),
                                    Expanded(
                                        child: Text(err,
                                            style: GoogleFonts.inter(
                                                fontSize: Responsive.sp(13)))),
                                  ]),
                                  duration: const Duration(seconds: 3),
                                  backgroundColor: Colors.red.shade600,
                                ),
                              );
                              return;
                            }

                            final traceId = result['trace_id'] as String?;
                            if (traceId == null) {
                              safelySetDialogState(() {
                                isSaving = false;
                                saveBtnLabel = 'Save';
                              });
                              return;
                            }

                            editTraceId = traceId;
                            safelySetDialogState(
                                () => saveBtnLabel = 'Updating...');

                            if (editCancelRequested) {
                              editCancelRequested = false;
                              final cancelResult = await ApiService()
                                  .cancelUploadDetailed(traceId);
                              if (!mounted || !ctx.mounted) return;

                              if (cancelResult['success'] == true) {
                                editTraceId = null;
                                safelyCloseDialog(ctx);
                                await ref
                                    .read(notesProvider.notifier)
                                    .refresh();
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Update cancelled',
                                      style: GoogleFonts.inter(
                                          fontSize: Responsive.sp(13)),
                                    ),
                                    backgroundColor: Colors.orange.shade700,
                                  ),
                                );
                                return;
                              }

                              if (cancelResult['too_late'] == true) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Too late to cancel. Your update is finalizing now.',
                                      style: GoogleFonts.inter(
                                          fontSize: Responsive.sp(13)),
                                    ),
                                    backgroundColor: Colors.blue.shade700,
                                  ),
                                );
                              } else {
                                final errMsg = (cancelResult['message']
                                            ?.toString()
                                            .isNotEmpty ==
                                        true)
                                    ? cancelResult['message'].toString()
                                    : 'Unable to cancel right now. Still updating...';
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      errMsg,
                                      style: GoogleFonts.inter(
                                          fontSize: Responsive.sp(13)),
                                    ),
                                    backgroundColor: Colors.red.shade600,
                                  ),
                                );
                              }
                            }

                            int polls = 0;
                            editPollTimer = Timer.periodic(
                                const Duration(seconds: 1), (timer) async {
                              polls++;
                              if (polls > 60) {
                                timer.cancel();
                                editPollTimer = null;
                                editTraceId = null;
                                if (mounted && ctx.mounted) {
                                  safelySetDialogState(() {
                                    isSaving = false;
                                    saveBtnLabel = 'Save';
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Update timed out — please try again',
                                        style: GoogleFonts.inter(
                                            fontSize: Responsive.sp(13)),
                                      ),
                                      backgroundColor: Colors.red.shade600,
                                    ),
                                  );
                                }
                                return;
                              }

                              if (editPollTimer == null) return;

                              final status =
                                  await ApiService().getUploadStatus(traceId);
                              if (status == null) return;

                              if (editPollTimer == null) return;

                              final step =
                                  status['current_step'] as String? ?? '';
                              final st = status['status'] as String? ?? '';
                              if (step == 'completed' || st == 'completed') {
                                timer.cancel();
                                editPollTimer = null;
                                editTraceId = null;
                                if (!mounted || !ctx.mounted) return;
                                safelyCloseDialog(ctx);
                                ApiService().invalidateTagsCache();
                                await ref
                                    .read(notesProvider.notifier)
                                    .refresh();
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Row(children: [
                                      Icon(Icons.check_circle,
                                          color: Colors.white,
                                          size: Responsive.sp(18)),
                                      SizedBox(width: Responsive.wp(10)),
                                      Text('Quick note updated',
                                          style: GoogleFonts.inter(
                                              fontSize: Responsive.sp(13))),
                                    ]),
                                    duration: const Duration(seconds: 2),
                                    backgroundColor: Colors.green.shade600,
                                  ),
                                );
                              } else if (step == 'failed' || st == 'failed') {
                                timer.cancel();
                                editPollTimer = null;
                                editTraceId = null;
                                if (!mounted || !ctx.mounted) return;
                                safelySetDialogState(() {
                                  isSaving = false;
                                  saveBtnLabel = 'Save';
                                });
                                final err =
                                    status['error_message']?.toString() ??
                                        'Failed to update quick note';
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Row(children: [
                                      Icon(Icons.error_outline,
                                          color: Colors.white,
                                          size: Responsive.sp(18)),
                                      SizedBox(width: Responsive.wp(10)),
                                      Expanded(
                                          child: Text(err,
                                              style: GoogleFonts.inter(
                                                  fontSize:
                                                      Responsive.sp(13)))),
                                    ]),
                                    duration: const Duration(seconds: 3),
                                    backgroundColor: Colors.red.shade600,
                                  ),
                                );
                              } else if (step == 'cancelled' ||
                                  st == 'cancelled') {
                                timer.cancel();
                                editPollTimer = null;
                                editTraceId = null;
                              }
                            });
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                          horizontal: Responsive.pp(16),
                          vertical: Responsive.pp(8)),
                      shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(Responsive.wp(6))),
                    ),
                    child: isSaving
                        ? SizedBox(
                            width: Responsive.wp(16),
                            height: Responsive.wp(16),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                  Colors.white),
                            ),
                          )
                        : Text(
                            saveBtnLabel,
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w500,
                              fontSize: Responsive.sp(13),
                            ),
                          ),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      editPollTimer?.cancel();
      fetchCancelled = true;
      dialogOpen = false;
      setDialogState = null;
      controller.dispose();
    }
  }

  String _sanitizeEditableQuickNoteContent(String raw, String noteTitle) {
    var text = raw.trim();
    final normalizedTitle = noteTitle.trim().toLowerCase();
    if (normalizedTitle.isEmpty || text.isEmpty) return text;

    final lines = text.split('\n');
    if (lines.isEmpty) return text;

    final firstLine = lines.first.trim().toLowerCase();
    if (firstLine == normalizedTitle) {
      lines.removeAt(0);
      while (lines.isNotEmpty && lines.first.trim().isEmpty) {
        lines.removeAt(0);
      }
      text = lines.join('\n').trim();
    }

    return text;
  }

  void _confirmDeleteNote(Note note) {
    // Block delete while the upload pipeline is still indexing this note.
    // The card already shows a processing badge; use the bottom strip on the
    // detail screen to cancel an in-flight upload instead.
    if (note.isProcessing) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            'Still indexing this snap. Open it and tap ✕ to cancel.',
            style: GoogleFonts.inter(fontSize: Responsive.sp(12)),
          ),
        ),
      );
      return;
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        bool isDeleting = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: isDark ? const Color(0xFF1E1E24) : Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(12))),
            title: Row(
              children: [
                Icon(Icons.delete_outline,
                    color: Colors.red.shade400, size: Responsive.sp(22)),
                SizedBox(width: Responsive.wp(8)),
                Text(
                  'Delete Note',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w600,
                    fontSize: Responsive.sp(16),
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Are you sure you want to delete this snap?',
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(13),
                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
                SizedBox(height: Responsive.wp(8)),
                Container(
                  padding: EdgeInsets.all(Responsive.pp(10)),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF2D2D35)
                        : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(Responsive.wp(6)),
                  ),
                  child: Text(
                    note.title,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(12),
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: isDeleting ? null : () => Navigator.pop(ctx),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.inter(
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: isDeleting
                    ? null
                    : () async {
                        setDialogState(() {
                          isDeleting = true;
                        });
                        final success = await _deleteNote(note);
                        if (!mounted) return;
                        if (success && ctx.mounted) {
                          Navigator.pop(ctx);
                          return;
                        }
                        if (ctx.mounted) {
                          setDialogState(() {
                            isDeleting = false;
                          });
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade500,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(
                      horizontal: Responsive.pp(16),
                      vertical: Responsive.pp(8)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Responsive.wp(6))),
                ),
                child: Text(
                  isDeleting ? 'Deleting...' : 'Delete',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w500, fontSize: Responsive.sp(13)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<bool> _deleteNote(Note note) async {
    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: Responsive.wp(16),
              height: Responsive.wp(16),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            SizedBox(width: Responsive.wp(12)),
            Text('Deleting note...',
                style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
          ],
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF374151),
      ),
    );

    final success = await ApiService().deleteNote(note.id);

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle,
                    color: Colors.white, size: Responsive.sp(18)),
                SizedBox(width: Responsive.wp(10)),
                Text('Note deleted',
                    style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
              ],
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.green.shade600,
          ),
        );
        // Invalidate tags cache and refresh notes list
        ApiService().invalidateTagsCache();
        ref.read(notesProvider.notifier).refresh();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.error_outline,
                    color: Colors.white, size: Responsive.sp(18)),
                SizedBox(width: Responsive.wp(10)),
                Text('Failed to delete note',
                    style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
              ],
            ),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }

    return success;
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateOnly = DateTime(date.year, date.month, date.day);
    final daysDiff = today.difference(dateOnly).inDays;
    if (daysDiff == 0) {
      final diff = now.difference(date);
      if (diff.inHours == 0) return '${diff.inMinutes}m ago';
      return '${diff.inHours}h ago';
    } else if (daysDiff == 1) {
      return 'Yesterday';
    } else if (daysDiff < 7) {
      return '${daysDiff}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  String _formatUploadedDaysAgo(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateOnly = DateTime(date.year, date.month, date.day);
    final daysDiff = today.difference(dateOnly).inDays;

    if (daysDiff <= 0) return 'Today';
    if (daysDiff == 1) return '1 day ago';
    return '$daysDiff days ago';
  }
}

class _ResolvedAspectRatio extends StatefulWidget {
  final List<String> imageCandidates;
  final double fallbackAspectRatio;
  final Widget Function(double aspectRatio) builder;

  const _ResolvedAspectRatio({
    required this.imageCandidates,
    required this.fallbackAspectRatio,
    required this.builder,
  });

  @override
  State<_ResolvedAspectRatio> createState() => _ResolvedAspectRatioState();
}

class _ResolvedAspectRatioState extends State<_ResolvedAspectRatio> {
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  int _candidateIndex = 0;
  double? _resolvedAspectRatio;

  @override
  void initState() {
    super.initState();
    _resolveAspectRatio();
  }

  @override
  void didUpdateWidget(covariant _ResolvedAspectRatio oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageCandidates.join('|') !=
        widget.imageCandidates.join('|')) {
      _candidateIndex = 0;
      _resolvedAspectRatio = null;
      _resolveAspectRatio();
    }
  }

  @override
  void dispose() {
    _clearImageListener();
    super.dispose();
  }

  void _clearImageListener() {
    final listener = _imageListener;
    final stream = _imageStream;
    if (listener != null && stream != null) {
      stream.removeListener(listener);
    }
    _imageListener = null;
    _imageStream = null;
  }

  void _advanceFallback() {
    if (_candidateIndex + 1 >= widget.imageCandidates.length) return;
    setState(() {
      _candidateIndex += 1;
    });
    _resolveAspectRatio();
  }

  void _resolveAspectRatio() {
    _clearImageListener();
    if (widget.imageCandidates.isEmpty ||
        _candidateIndex >= widget.imageCandidates.length) {
      return;
    }

    final provider = CachedNetworkImageProvider(
      widget.imageCandidates[_candidateIndex],
      cacheManager: ThumbnailCacheManager.instance,
    );
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final width = info.image.width;
        final height = info.image.height;
        if (!mounted || width <= 0 || height <= 0) return;
        setState(() {
          _resolvedAspectRatio =
              (width / height).clamp(9 / 16, 1.91).toDouble();
        });
      },
      onError: (_, __) {
        if (!mounted) return;
        _advanceFallback();
      },
    );
    _imageStream = stream;
    _imageListener = listener;
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(_resolvedAspectRatio ?? widget.fallbackAspectRatio);
  }
}

class _NoteSection {
  final String title;
  final List<Note> notes;

  _NoteSection(this.title, this.notes);
}

/// Auto-shrinking text that tries to fit 	ext within maxLines at the
/// provided style. If the text would overflow, it scales the font size down
/// (by binary search) until it fits or hits minFontSize, then ellipsizes.
class _AutoShrinkText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final int maxLines;
  final double minFontSize;

  const _AutoShrinkText({
    required this.text,
    required this.style,
    required this.maxLines,
    required this.minFontSize,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth = constraints.maxWidth;
      final baseSize = style.fontSize ?? 14.0;
      double lo = minFontSize;
      double hi = baseSize;
      double best = minFontSize;

      bool fits(double fs) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: style.copyWith(fontSize: fs)),
          textDirection: TextDirection.ltr,
          maxLines: maxLines,
          ellipsis: '...',
        )..layout(maxWidth: maxWidth);
        return !tp.didExceedMaxLines;
      }

      // Quick check: does base size fit?
      if (fits(hi)) {
        best = hi;
      } else {
        // Binary search for the largest fitting size.
        for (int i = 0; i < 8; i++) {
          final mid = (lo + hi) / 2;
          if (fits(mid)) {
            best = mid;
            lo = mid;
          } else {
            hi = mid;
          }
        }
      }

      return Text(
        text,
        style: style.copyWith(fontSize: best),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    });
  }
}

/// Small rounded badge overlaying the bottom-left of a thumbnail to show
/// which social platform a note came from (YouTube / Instagram).
class _PlatformBadge extends StatelessWidget {
  final String source;
  const _PlatformBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final s = source.toLowerCase();
    IconData? icon;
    String? text; // For platforms whose logo is a wordmark (e.g. LinkedIn 'in')
    late final List<Color> gradient;
    if (s == 'youtube') {
      icon = Icons.play_arrow_rounded;
      gradient = const [Color(0xFFE53935), Color(0xFFB71C1C)];
    } else if (s == 'instagram') {
      icon = Icons.camera_alt_rounded;
      gradient = const [
        Color(0xFFF58529),
        Color(0xFFDD2A7B),
        Color(0xFF8134AF),
      ];
    } else if (s == 'facebook') {
      icon = Icons.facebook_rounded;
      gradient = const [Color(0xFF1877F2), Color(0xFF0A58CA)];
    } else if (s == 'linkedin') {
      // LinkedIn's logo is the wordmark "in" — far more recognizable than any
      // Material icon (briefcase / business_center all look wrong).
      text = 'in';
      gradient = const [Color(0xFF0077B5), Color(0xFF005885)];
    } else if (s == 'twitter' || s == 'tweet' || s == 'x') {
      // X's logo is the wordmark "𝕏" — the cleanest signal at small sizes.
      text = '𝕏';
      gradient = const [Color(0xFF0F1419), Color(0xFF000000)];
    } else if (s == 'reddit') {
      // Reddit's mark is a stylized alien face; the wordmark "r/" is the
      // cleanest, most recognizable substitute at badge size.
      text = 'r/';
      gradient = const [Color(0xFFFF4500), Color(0xFFCC3700)];
    } else {
      icon = Icons.link_rounded;
      gradient = const [Color(0xFF334155), Color(0xFF0F172A)];
    }
    return Container(
      width: Responsive.wp(26),
      height: Responsive.wp(26),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(Responsive.wp(7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: Responsive.wp(4),
            offset: Offset(0, Responsive.wp(1)),
          ),
        ],
      ),
      child: Center(
        child: text != null
            ? Text(
                text,
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(14),
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  height: 1.0,
                  letterSpacing: -0.5,
                ),
              )
            : Icon(
                icon,
                size: Responsive.sp(15),
                color: Colors.white,
              ),
      ),
    );
  }
}
