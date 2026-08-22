import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/api_service.dart';
import '../services/app_cache_warmer.dart';

/// Page size for pagination
const int notesPageSize = 200;

/// Notes state with pagination info and selection
class NotesState {
  final List<Note> notes;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? error;
  final String viewMode; // 'date' or 'tags'
  final bool isSelectionMode;
  final Set<String> selectedNoteIds;
  final bool isDeleting;

  const NotesState({
    this.notes = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
    this.viewMode = 'date',
    this.isSelectionMode = false,
    this.selectedNoteIds = const {},
    this.isDeleting = false,
  });

  NotesState copyWith({
    List<Note>? notes,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? error,
    String? viewMode,
    bool? isSelectionMode,
    Set<String>? selectedNoteIds,
    bool? isDeleting,
  }) {
    return NotesState(
      notes: notes ?? this.notes,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: error,
      viewMode: viewMode ?? this.viewMode,
      isSelectionMode: isSelectionMode ?? this.isSelectionMode,
      selectedNoteIds: selectedNoteIds ?? this.selectedNoteIds,
      isDeleting: isDeleting ?? this.isDeleting,
    );
  }

  /// Get count of selected notes
  int get selectedCount => selectedNoteIds.length;

  /// Check if a note is selected
  bool isSelected(String noteId) => selectedNoteIds.contains(noteId);
}

/// Notes list state provider with pagination
final notesProvider = StateNotifierProvider<NotesNotifier, NotesState>((ref) {
  return NotesNotifier();
});

/// Notes stats provider
final notesStatsProvider = FutureProvider<NotesStats?>((ref) async {
  return ApiService().fetchNotesStats();
});

/// Notes state notifier with pagination support
class NotesNotifier extends StateNotifier<NotesState> {
  NotesNotifier() : super(const NotesState(isLoading: true)) {
    // Subscribe to Supabase auth events so a cold-open that beats session
    // restoration still ends up loading notes once the session is hydrated.
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        final event = data.event;
        if (event == AuthChangeEvent.signedOut) {
          state = const NotesState(isLoading: false);
        }
      });
    } catch (_) {
      // Supabase not initialised (e.g. tests) – ignore.
    }
  }

  final ApiService _api = ApiService();
  StreamSubscription<AuthState>? _authSub;

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  // State for tags view - holds notes from potentially incomplete tag
  List<Note> _pendingTagNotes = [];
  int _tagsViewOffset = 0;

  /// Get sort parameter based on view mode
  String? get _sortParam => state.viewMode == 'tags' ? 'tag' : 'date';

  void seedFromBootstrap(List<Note> notes, {required bool hasMore}) {
    if (state.viewMode != 'date') return;
    final mergedNotes = _mergeOptimisticNotes(notes);
    unawaited(AppCacheWarmer.warmThumbnailUrls(
      mergedNotes.map((note) => note.thumbnailUrl),
      reason: 'bootstrap-notes',
    ));
    state = state.copyWith(
      notes: mergedNotes,
      isLoading: false,
      isLoadingMore: false,
      hasMore: hasMore,
      error: null,
    );
  }

  /// Load first page of notes
  Future<void> loadNotes({bool showLoading = true}) async {
    if (showLoading) {
      state = state.copyWith(isLoading: true, error: null);
    }

    // Cold-open guard: Supabase session may not be restored yet when the
    // provider is first constructed. If we fire the fetch now the API call
    // returns [] (401), the UI flips to the "No snaps yet" empty state, and
    // the user has to pull-to-refresh. Poll briefly for a session before
    // giving up – the auth listener in the constructor will also retry if
    // restoration finishes later.
    if (!_api.isAuthenticated) {
      state = state.copyWith(isLoading: true, error: null);
      return;
    }

    try {
      // In tags view, load complete tags only (no partial tags split across pages)
      // In date view, use standard pagination
      if (state.viewMode == 'tags') {
        _pendingTagNotes = [];
        _tagsViewOffset = 0;
        await _loadNotesWithCompleteTags(isFirstPage: true);
      } else {
        await _loadNotesWithPagination();
      }
    } catch (e) {
      print('[NotesProvider] Error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Load notes ensuring complete tags only (no tag split across pages)
  /// If a tag would be incomplete, hold it for the next "Load More"
  Future<void> _loadNotesWithCompleteTags({bool isFirstPage = false}) async {
    print(
        '[NotesProvider] Loading complete tags, offset=$_tagsViewOffset, pending=${_pendingTagNotes.length}');

    final fetchedNotes = await _api.fetchNotesPaginated(
      limit: notesPageSize,
      offset: _tagsViewOffset,
      sort: 'tag',
    );

    print('[NotesProvider] Fetched ${fetchedNotes.length} notes');

    // If no more notes from server
    if (fetchedNotes.isEmpty) {
      // Flush any pending notes (they're complete since we reached the end)
      if (_pendingTagNotes.isNotEmpty) {
        final allNotes = isFirstPage
            ? _mergeOptimisticNotes(_pendingTagNotes)
            : [...state.notes, ..._pendingTagNotes];
        state = state.copyWith(
          notes: allNotes,
          isLoading: false,
          isLoadingMore: false,
          hasMore: false,
        );
        _pendingTagNotes = [];
      } else {
        state = state.copyWith(
          isLoading: false,
          isLoadingMore: false,
          hasMore: false,
        );
      }
      return;
    }

    // Combine pending notes from previous load with newly fetched
    final allNewNotes = [..._pendingTagNotes, ...fetchedNotes];
    _pendingTagNotes = [];

    final gotFullBatch = fetchedNotes.length >= notesPageSize;

    List<Note> notesToAdd;
    bool hasMore;

    if (!gotFullBatch) {
      // Last page - all tags are complete
      notesToAdd = allNewNotes;
      hasMore = false;
      print('[NotesProvider] Last page, added all ${allNewNotes.length} notes');
    } else {
      // Got full batch - the last tag might be incomplete (split across pages)
      // Find the last tag in the fetched batch
      final lastTag = fetchedNotes.last.tags.isNotEmpty
          ? fetchedNotes.last.tags.first
          : 'Other';

      // Separate complete tags from the potentially incomplete last tag
      final completeNotes = <Note>[];
      final lastTagNotes = <Note>[];

      for (final note in allNewNotes) {
        final noteTag = note.tags.isNotEmpty ? note.tags.first : 'Other';
        if (noteTag == lastTag) {
          lastTagNotes.add(note);
        } else {
          completeNotes.add(note);
        }
      }

      notesToAdd = completeNotes;
      _pendingTagNotes = lastTagNotes; // Hold back for next load
      hasMore = true;

      print(
          '[NotesProvider] Added ${completeNotes.length} notes, holding ${lastTagNotes.length} from tag "$lastTag"');
    }

    // Update offset for next fetch
    _tagsViewOffset += fetchedNotes.length;

    final finalNotes = isFirstPage
        ? _mergeOptimisticNotes(notesToAdd)
        : [...state.notes, ...notesToAdd];
    unawaited(AppCacheWarmer.warmThumbnailUrls(
      finalNotes.map((note) => note.thumbnailUrl),
      reason: 'notes-tags',
    ));
    state = state.copyWith(
      notes: finalNotes,
      isLoading: false,
      isLoadingMore: false,
      hasMore: hasMore,
    );
  }

  /// Load notes with pagination (for date view)
  Future<void> _loadNotesWithPagination() async {
    print('[NotesProvider] Loading notes with pagination, sort=$_sortParam...');
    final notes = await _api.fetchNotesPaginated(
      limit: notesPageSize,
      offset: 0,
      sort: _sortParam,
    );
    print('[NotesProvider] Loaded ${notes.length} notes');
    if (notes.isEmpty && state.notes.isNotEmpty) {
      state = state.copyWith(isLoading: false, hasMore: state.hasMore);
      return;
    }
    final mergedNotes = _mergeOptimisticNotes(notes);
    unawaited(AppCacheWarmer.warmThumbnailUrls(
      mergedNotes.map((note) => note.thumbnailUrl),
      reason: 'notes-page',
    ));
    state = state.copyWith(
      notes: mergedNotes,
      isLoading: false,
      hasMore: notes.length >= notesPageSize,
    );
  }

  /// Load more notes (next page)
  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore) return;

    state = state.copyWith(isLoadingMore: true);

    try {
      if (state.viewMode == 'tags') {
        // Tags view - continue loading complete tags
        await _loadNotesWithCompleteTags(isFirstPage: false);
      } else {
        // Date view - standard pagination
        final offset = state.notes
            .where((note) => !note.id.startsWith('optimistic-upload-'))
            .length;
        final newNotes = await _api.fetchNotesPaginated(
          limit: notesPageSize,
          offset: offset,
          sort: _sortParam,
        );
        final allNotes = [...state.notes, ...newNotes];
        unawaited(AppCacheWarmer.warmThumbnailUrls(
          newNotes.map((note) => note.thumbnailUrl),
          reason: 'notes-more',
        ));
        state = state.copyWith(
          notes: allNotes,
          isLoadingMore: false,
          hasMore: newNotes.length >= notesPageSize,
        );
      }
    } catch (e) {
      state = state.copyWith(isLoadingMore: false, error: e.toString());
    }
  }

  /// Change view mode and reload notes
  Future<void> setViewMode(String mode) async {
    if (state.viewMode == mode) return;
    final optimisticNotes = state.notes
        .where((note) => note.id.startsWith('optimistic-upload-'))
        .toList(growable: false);
    _pendingTagNotes = [];
    _tagsViewOffset = 0;
    state =
        state.copyWith(viewMode: mode, notes: optimisticNotes, hasMore: true);
    await loadNotes();
  }

  /// Refresh notes (reload from start)
  Future<void> refresh() async {
    await loadNotes();
  }

  /// Silent refresh used by the optimistic-upload status poller. Does not
  /// flip `isLoading`, so the existing card list stays visible while we
  /// re-fetch in the background.
  Future<void> refreshSilent() async {
    await loadNotes(showLoading: false);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Selection Mode Methods
  // ═══════════════════════════════════════════════════════════════════════

  /// Insert a local-only processing card as soon as the user starts a share or
  /// upload. The Worker creates the real `incomplete` note later in the
  /// pipeline, so this bridges that visible gap in My Snaps.
  String addOptimisticUpload({
    required String itemName,
    String? contentType,
    String? title,
  }) {
    final now = DateTime.now();
    final normalizedType = contentType ?? _contentTypeForItem(itemName);
    final optimisticId = 'optimistic-upload-${now.microsecondsSinceEpoch}';
    final optimisticNote = Note(
      id: optimisticId,
      title: title?.trim().isNotEmpty == true
          ? title!.trim()
          : 'Saving ${itemName.toLowerCase()}...',
      contentType: normalizedType,
      createdAt: now,
      tags: [normalizedType],
      description: 'Processing...',
      status: 'incomplete',
    );

    final withoutExisting = state.notes
        .where((note) => note.id != optimisticId)
        .toList(growable: false);
    state = state.copyWith(
      notes: [optimisticNote, ...withoutExisting],
      isLoading: false,
      error: null,
    );
    return optimisticId;
  }

  /// Remove a local optimistic upload card once the server note exists or the
  /// upload fails/cancels.
  void removeOptimisticUpload(String? optimisticId) {
    if (optimisticId == null || optimisticId.isEmpty) return;
    final updated = state.notes
        .where((note) => note.id != optimisticId)
        .toList(growable: false);
    if (updated.length == state.notes.length) return;
    state = state.copyWith(notes: updated);
  }

  String _contentTypeForItem(String itemName) {
    switch (itemName.toLowerCase()) {
      case 'image':
        return 'image';
      case 'url':
        return 'webpage';
      case 'note':
        return 'quick_note';
      case 'file':
        return 'uploaded_file';
      default:
        return 'uploaded_file';
    }
  }

  List<Note> _mergeOptimisticNotes(List<Note> fetchedNotes) {
    final optimisticNotes = state.notes
        .where((note) => note.id.startsWith('optimistic-upload-'))
        .toList(growable: false);
    if (optimisticNotes.isEmpty) return fetchedNotes;

    final fetchedIds = fetchedNotes.map((note) => note.id).toSet();
    final stillLocal = optimisticNotes
        .where((note) => !fetchedIds.contains(note.id))
        .toList(growable: false);
    return [...stillLocal, ...fetchedNotes];
  }

  /// Enter selection mode, optionally selecting a note
  void enterSelectionMode({String? initialNoteId}) {
    final selected = <String>{};
    if (initialNoteId != null) {
      selected.add(initialNoteId);
    }
    state = state.copyWith(
      isSelectionMode: true,
      selectedNoteIds: selected,
    );
  }

  /// Exit selection mode and clear selection
  void exitSelectionMode() {
    state = state.copyWith(
      isSelectionMode: false,
      selectedNoteIds: {},
    );
  }

  /// Toggle selection of a note
  void toggleNoteSelection(String noteId) {
    final selected = Set<String>.from(state.selectedNoteIds);
    if (selected.contains(noteId)) {
      selected.remove(noteId);
      // Exit selection mode if no notes selected
      if (selected.isEmpty) {
        state = state.copyWith(
          isSelectionMode: false,
          selectedNoteIds: {},
        );
        return;
      }
    } else {
      selected.add(noteId);
    }
    state = state.copyWith(selectedNoteIds: selected);
  }

  /// Select all notes
  void selectAll() {
    final allIds = state.notes.map((n) => n.id).toSet();
    state = state.copyWith(selectedNoteIds: allIds);
  }

  /// Clear all selections (but stay in selection mode)
  void clearSelection() {
    state = state.copyWith(selectedNoteIds: {});
  }

  /// Delete selected notes
  Future<bool> deleteSelectedNotes() async {
    if (state.selectedNoteIds.isEmpty) return true;

    state = state.copyWith(isDeleting: true);

    try {
      final result = await _api.deleteNotes(state.selectedNoteIds.toList());

      if (result['success'] == true) {
        final deletedIds = Set<String>.from(result['deleted'] ?? []);

        // Remove deleted notes from state
        final updatedNotes =
            state.notes.where((n) => !deletedIds.contains(n.id)).toList();

        // Invalidate tags cache so home screen reflects the deletion
        ApiService().invalidateTagsCache();

        state = state.copyWith(
          notes: updatedNotes,
          isDeleting: false,
          isSelectionMode: false,
          selectedNoteIds: {},
        );

        return true;
      } else {
        state = state.copyWith(isDeleting: false);
        return false;
      }
    } catch (e) {
      print('[NotesProvider] Error deleting notes: $e');
      state = state.copyWith(isDeleting: false);
      return false;
    }
  }
}
