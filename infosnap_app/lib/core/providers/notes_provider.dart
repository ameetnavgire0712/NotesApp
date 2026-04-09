import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api_service.dart';

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
    loadNotes();
  }

  final ApiService _api = ApiService();

  /// Get sort parameter based on view mode
  String? get _sortParam => state.viewMode == 'tags' ? 'tag' : 'date';

  /// Load first page of notes
  Future<void> loadNotes({bool showLoading = true}) async {
    if (showLoading) {
      state = state.copyWith(isLoading: true, error: null);
    }

    try {
      print('[NotesProvider] Loading notes with sort=${_sortParam}...');
      final notes = await _api.fetchNotesPaginated(
        limit: notesPageSize, 
        offset: 0, 
        sort: _sortParam,
      );
      print('[NotesProvider] Loaded ${notes.length} notes');
      state = state.copyWith(
        notes: notes,
        isLoading: false,
        hasMore: notes.length >= notesPageSize,
      );
    } catch (e) {
      print('[NotesProvider] Error: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Load more notes (next page)
  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore) return;

    state = state.copyWith(isLoadingMore: true);

    try {
      final offset = state.notes.length;
      final newNotes = await _api.fetchNotesPaginated(
        limit: notesPageSize, 
        offset: offset,
        sort: _sortParam,
      );
      state = state.copyWith(
        notes: [...state.notes, ...newNotes],
        isLoadingMore: false,
        hasMore: newNotes.length >= notesPageSize,
      );
    } catch (e) {
      state = state.copyWith(isLoadingMore: false, error: e.toString());
    }
  }

  /// Change view mode and reload notes
  Future<void> setViewMode(String mode) async {
    if (state.viewMode == mode) return;
    state = state.copyWith(viewMode: mode, notes: [], hasMore: true);
    await loadNotes();
  }

  /// Refresh notes (reload from start)
  Future<void> refresh() async {
    await loadNotes();
  }
  
  // ═══════════════════════════════════════════════════════════════════════
  // Selection Mode Methods
  // ═══════════════════════════════════════════════════════════════════════
  
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
        final updatedNotes = state.notes.where((n) => !deletedIds.contains(n.id)).toList();
        
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
