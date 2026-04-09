import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_colors.dart';
import '../../core/providers/notes_provider.dart';
import '../../core/services/api_service.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';

class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Set<String> _collapsedSections = {};

  static const Color _greenPrimary = Color(0xFF22c55e);

  @override
  void initState() {
    super.initState();
    // Schedule load after first frame to show loading spinner
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notesProvider.notifier).loadNotes();
    });
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.toLowerCase());
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notesState = ref.watch(notesProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          const Positioned.fill(child: HexagonBackground()),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header - matching dashboard.html view-header
                _buildHeader(theme, isDark),
                // Toolbar - search box + Date|Tags toggle
                _buildToolbar(theme, isDark),
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
      onRefresh: () => ref.read(notesProvider.notifier).refresh(),
      color: AppColors.primary,
      child: _buildNotesContentInner(state),
    );
  }

  /// Inner content without RefreshIndicator
  Widget _buildNotesContentInner(NotesState state) {
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
    
    // Selection mode header
    if (notesState.isSelectionMode) {
      return _buildSelectionHeader(theme, isDark, notesState);
    }
    
    // Normal header
    return Padding(
      padding: EdgeInsets.fromLTRB(Responsive.pp(20), Responsive.pp(16), Responsive.pp(20), Responsive.pp(8)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'My Snaps',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: Responsive.sp(24),
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: Responsive.wp(2)),
                Text(
                  'All your saved documents in one place',
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(13),
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: theme.colorScheme.onSurface.withOpacity(0.6)),
            onPressed: () => ref.read(notesProvider.notifier).refresh(),
            tooltip: 'Refresh',
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms);
  }
  
  /// Selection mode header with count, cancel, select all, and delete buttons
  Widget _buildSelectionHeader(ThemeData theme, bool isDark, NotesState notesState) {
    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.pp(12), Responsive.pp(12), Responsive.pp(12), Responsive.pp(8)),
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
            onPressed: () => ref.read(notesProvider.notifier).exitSelectionMode(),
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
              padding: EdgeInsets.symmetric(horizontal: Responsive.pp(12), vertical: Responsive.pp(8)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: notesState.isDeleting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Icon(Icons.delete_outline, size: 18),
            label: Text(
              notesState.isDeleting ? 'Deleting...' : 'Delete',
              style: GoogleFonts.inter(fontWeight: FontWeight.w500, fontSize: Responsive.sp(13)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.red.shade400, size: 22),
            const SizedBox(width: 8),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: Text(
              'Delete All',
              style: GoogleFonts.inter(fontWeight: FontWeight.w500, fontSize: Responsive.sp(13)),
            ),
          ),
        ],
      ),
    );
  }
  
  /// Perform the bulk delete operation
  Future<void> _performBulkDelete() async {
    final count = ref.read(notesProvider).selectedCount;
    
    final success = await ref.read(notesProvider.notifier).deleteSelectedNotes();
    
    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Text('$count snaps deleted', style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
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
                const Icon(Icons.error_outline, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Text('Failed to delete some snaps', style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
              ],
            ),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }
  }

  /// Toolbar: Search box + Date|Tags toggle (matching dashboard.html notes-toolbar)
  Widget _buildToolbar(ThemeData theme, bool isDark) {
    final borderColor = isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
    final surfaceColor = theme.colorScheme.surface;

    return Padding(
      padding: EdgeInsets.fromLTRB(Responsive.pp(20), 4, Responsive.pp(20), Responsive.pp(12)),
      child: Row(
        children: [
          // Search box
          Expanded(
            child: Container(
              height: Responsive.wp(38),
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(Responsive.wp(10)),
                border: Border.all(color: borderColor),
              ),
              child: Row(
                children: [
                  SizedBox(width: Responsive.wp(10)),
                  Icon(Icons.search_rounded, size: Responsive.sp(16), color: theme.colorScheme.onSurface.withOpacity(0.4)),
                  SizedBox(width: Responsive.wp(6)),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(13),
                        color: theme.colorScheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search notes...',
                        hintStyle: GoogleFonts.inter(
                          fontSize: Responsive.sp(13),
                          color: theme.colorScheme.onSurface.withOpacity(0.4),
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (_searchQuery.isNotEmpty)
                    GestureDetector(
                      onTap: () => _searchController.clear(),
                      child: Padding(
                        padding: EdgeInsets.only(right: Responsive.pp(8)),
                        child: Icon(Icons.close_rounded, size: Responsive.sp(14), color: theme.colorScheme.onSurface.withOpacity(0.4)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(width: Responsive.wp(10)),
          // Date | Tags toggle
          Container(
            height: Responsive.wp(38),
            decoration: BoxDecoration(
              color: surfaceColor,
              borderRadius: BorderRadius.circular(Responsive.wp(10)),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildToggleBtn('📅 Date', 'date', isDark),
                Container(width: 1, height: Responsive.wp(20), color: borderColor),
                _buildToggleBtn('🏷️ Tags', 'tags', isDark),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms, delay: 100.ms);
  }

  Widget _buildToggleBtn(String label, String mode, bool isDark) {
    final notesState = ref.watch(notesProvider);
    final isActive = notesState.viewMode == mode;
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        ref.read(notesProvider.notifier).setViewMode(mode);
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: Responsive.pp(10), vertical: Responsive.pp(6)),
        decoration: BoxDecoration(
          color: isActive
              ? (isDark ? _greenPrimary.withOpacity(0.15) : const Color(0xFFDCFCE7))
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

  /// Filter notes by search query
  List<Note> _filterNotes(List<Note> notes) {
    var filtered = notes;
    
    // Filter by search query
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((n) =>
        n.title.toLowerCase().contains(_searchQuery) ||
        (n.contentPreview?.toLowerCase().contains(_searchQuery) ?? false) ||
        n.tags.any((t) => t.toLowerCase().contains(_searchQuery))
      ).toList();
    }
    
    return filtered;
  }

  Widget _buildLoadingState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 48,
            height: 48,
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
            Icon(Icons.error_outline, size: Responsive.sp(48), color: Colors.red.shade400),
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
              style: GoogleFonts.inter(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: Responsive.sp(13)),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: Responsive.wp(16)),
            ElevatedButton.icon(
              onPressed: () => ref.read(notesProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
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
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Responsive.pp(20)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note_add_outlined, size: Responsive.sp(64), color: theme.colorScheme.onSurface.withOpacity(0.5)),
            SizedBox(height: Responsive.wp(16)),
            Text(
              'No notes yet',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(18),
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: Responsive.wp(8)),
            Text(
              'Save your first note using the Chrome Extension\nor tap the + button to add a quick note.',
              style: GoogleFonts.inter(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: Responsive.sp(14)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesList(List<Note> notes, bool hasMore, bool isLoadingMore) {
    final notesState = ref.watch(notesProvider);
    // Group notes by date or tags based on view mode
    final grouped = notesState.viewMode == 'tags'
        ? _groupNotesByTag(notes)
        : _groupNotesByDate(notes);
    
    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(), // Enable pull-to-refresh
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(16), vertical: Responsive.pp(12)),
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
              _buildSectionTitle(section.title, section.notes.length, isCollapsed),
              if (!isCollapsed) ...[
              SizedBox(height: Responsive.wp(8)),
              // Responsive grid - 2 cards per row on mobile
              LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = (constraints.maxWidth / Responsive.wp(170)).floor().clamp(2, 3);
                  final cardHeight = Responsive.isShort ? Responsive.wp(155) : Responsive.wp(170);
                  final cardWidth = (constraints.maxWidth - (crossAxisCount - 1) * Responsive.wp(8)) / crossAxisCount;
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: Responsive.wp(8),
                      mainAxisSpacing: Responsive.wp(8),
                      childAspectRatio: cardWidth / cardHeight,
                    ),
                    itemCount: section.notes.length,
                    itemBuilder: (context, i) {
                      return _buildNoteCard(section.notes[i], delay: 50 + i * 20);
                    },
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
      padding: const EdgeInsets.symmetric(vertical: 24),
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
                  padding: EdgeInsets.symmetric(horizontal: Responsive.pp(24), vertical: Responsive.pp(12)),
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
      } else if (noteDate.isAtSameMomentAs(yesterday) || (noteDate.isAfter(yesterday) && noteDate.isBefore(today))) {
        yesterdayNotes.add(note);
      } else if (noteDate.isAtSameMomentAs(thisWeekStart) || (noteDate.isAfter(thisWeekStart) && noteDate.isBefore(yesterday))) {
        thisWeekNotes.add(note);
      } else if (noteDate.isAtSameMomentAs(lastWeekStart) || (noteDate.isAfter(lastWeekStart) && noteDate.isBefore(thisWeekStart))) {
        lastWeekNotes.add(note);
      } else if (noteDate.isAtSameMomentAs(thisMonthStart) || noteDate.isAfter(thisMonthStart)) {
        earlierThisMonthNotes.add(note);
      } else {
        // Group by month
        final monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
          'July', 'August', 'September', 'October', 'November', 'December'];
        final key = '${monthNames[note.createdAt.month - 1]} ${note.createdAt.year}';
        if (!monthlyNotes.containsKey(key)) {
          monthlyNotes[key] = [];
          monthKeys.add(key);
        }
        monthlyNotes[key]!.add(note);
      }
    }
    
    final sections = <_NoteSection>[];
    if (todayNotes.isNotEmpty) sections.add(_NoteSection('Today', todayNotes));
    if (yesterdayNotes.isNotEmpty) sections.add(_NoteSection('Yesterday', yesterdayNotes));
    if (thisWeekNotes.isNotEmpty) sections.add(_NoteSection('This Week', thisWeekNotes));
    if (lastWeekNotes.isNotEmpty) sections.add(_NoteSection('Last Week', lastWeekNotes));
    if (earlierThisMonthNotes.isNotEmpty) sections.add(_NoteSection('Earlier This Month', earlierThisMonthNotes));
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
    
    return tagMap.entries
        .map((e) => _NoteSection(e.key, e.value))
        .toList()
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

  Widget _buildNoteCard(Note note, {required int delay}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final notesState = ref.watch(notesProvider);
    final isSelectionMode = notesState.isSelectionMode;
    final isSelected = notesState.isSelected(note.id);
    
    // Match web icon logic
    final icon = _getThemeIcon(note.contentType ?? 'default');
    final color = _getColorForNote(note);
    final previewText = note.contentPreview ?? note.contentPreview ?? note.title;
    final preview = previewText.length > 80 
        ? '${previewText.substring(0, 80)}...' 
        : previewText;
    
    // Match web colors
    final cardColor = isDark 
        ? const Color(0xFF1E1E24)
        : Colors.white;
    final borderColor = isSelected 
        ? _greenPrimary 
        : (isDark ? const Color(0xFF2D2D35) : const Color(0xFFE2E8F0));
    final iconBgColor = isDark ? const Color(0xFF2D2D35) : const Color(0xFFE2F0EA);
    final tagBgColor = isDark ? const Color(0xFF2D2D35) : const Color(0xFFEDF2F7);
    
    return GestureDetector(
      onTap: () {
        if (isSelectionMode) {
          HapticFeedback.selectionClick();
          ref.read(notesProvider.notifier).toggleNoteSelection(note.id);
        } else {
          _openNote(note);
        }
      },
      onLongPress: () {
        if (!isSelectionMode) {
          HapticFeedback.mediumImpact();
          ref.read(notesProvider.notifier).enterSelectionMode(initialNoteId: note.id);
        }
      },
      child: Container(
        padding: EdgeInsets.all(Responsive.pp(10)),
        decoration: BoxDecoration(
          color: isSelected ? (isDark ? const Color(0xFF1A2E1A) : const Color(0xFFF0FDF4)) : cardColor,
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.2 : 0.04),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header: Checkbox (selection mode) or Icon, Tag, and Delete
            Row(
              children: [
                // Checkbox in selection mode
                if (isSelectionMode) ...[
                  SizedBox(
                    width: Responsive.wp(24),
                    height: Responsive.wp(24),
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) {
                        HapticFeedback.selectionClick();
                        ref.read(notesProvider.notifier).toggleNoteSelection(note.id);
                      },
                      activeColor: _greenPrimary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      side: BorderSide(
                        color: isDark ? const Color(0xFF4B5563) : const Color(0xFFD1D5DB),
                        width: 1.5,
                      ),
                    ),
                  ),
                ] else ...[
                  Container(
                    width: Responsive.wp(24),
                    height: Responsive.wp(24),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: iconBgColor,
                      borderRadius: BorderRadius.circular(Responsive.wp(6)),
                    ),
                    child: Text(icon, style: TextStyle(fontSize: Responsive.sp(11))),
                  ),
                ],
                SizedBox(width: Responsive.wp(4)),

                if (note.tags.isNotEmpty) ...[
                  Flexible(
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(5), vertical: Responsive.pp(1)),
                      decoration: BoxDecoration(
                        color: tagBgColor,
                        borderRadius: BorderRadius.circular(Responsive.wp(4)),
                      ),
                      child: Text(
                        note.tags.first.toUpperCase(),
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(7),
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                // Delete button (hidden in selection mode)
                if (!isSelectionMode)
                  GestureDetector(
                    onTap: () => _confirmDeleteNote(note),
                    child: Container(
                      padding: EdgeInsets.all(Responsive.pp(4)),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF2D2D35) : Colors.white,
                        borderRadius: BorderRadius.circular(Responsive.wp(6)),
                      ),
                      child: Icon(
                        Icons.delete_outline,
                        size: Responsive.sp(14),
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: Responsive.wp(6)),
            // Title
            Text(
              note.title,
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w500,
                fontSize: Responsive.sp(11),
                color: theme.colorScheme.onSurface,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            SizedBox(height: Responsive.wp(3)),
            // Preview
            Expanded(
              child: Text(
                preview,
                style: GoogleFonts.inter(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                  fontSize: Responsive.sp(9),
                  height: 1.4,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Footer: Date and Type
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDate(note.createdAt),
                  style: GoogleFonts.inter(
                  fontSize: Responsive.sp(8),
                    color: theme.colorScheme.onSurface.withOpacity(0.55),
                  ),
                ),
                if (note.contentType != null)
                  Text(
                    note.contentType!.toUpperCase(),
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(7),
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: delay.ms).scale(begin: const Offset(0.95, 0.95), curve: Curves.easeOut);
  }

  // Uses emojis like the web dashboard
  String _getThemeIcon(String type) {
    switch (type.toLowerCase()) {
      case 'pdf': return '📄';
      case 'word': return '📝';
      case 'email': return '📧';
      case 'image': return '🖼️';
      case 'note': return '📋';
      case 'quick_note': return '📝';
      case 'uploaded_file': return '📁';
      case 'screenshot': return '🖼️';
      case 'webpage': return '🌐';
      default: return '�';
    }
  }

  void _confirmDeleteNote(Note note) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E24) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.red.shade400, size: 22),
            const SizedBox(width: 8),
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
              'Are you sure you want to delete this note?',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(13),
                color: theme.colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2D2D35) : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(6),
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
              _deleteNote(note);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade500,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: Text(
              'Delete',
              style: GoogleFonts.inter(fontWeight: FontWeight.w500, fontSize: Responsive.sp(13)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteNote(Note note) async {
    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            Text('Deleting note...', style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
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
                const Icon(Icons.check_circle, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Text('Note deleted', style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
              ],
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.green.shade600,
          ),
        );
        // Refresh notes list
        ref.read(notesProvider.notifier).refresh();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Text('Failed to delete note', style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
              ],
            ),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  /// Open note document - same as web dashboard openNote() and chat document links
  Future<void> _openNote(Note note) async {
    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            Text('Opening document...', style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
          ],
        ),
        duration: const Duration(seconds: 5),
        backgroundColor: const Color(0xFF374151),
      ),
    );

    final viewUrl = await ApiService().getViewUrl(note.id);

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (viewUrl != null) {
      // Open in browser - same as chat document links using launchUrl
      await launchUrl(Uri.parse(viewUrl), mode: LaunchMode.externalApplication);
    } else if (note.sourceUrl != null && note.sourceUrl!.isNotEmpty) {
      // Fallback to source URL if view-token API fails
      await launchUrl(Uri.parse(note.sourceUrl!), mode: LaunchMode.externalApplication);
    } else {
      // No URL available - show the content preview
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text('No document URL available for this note.',
                    style: GoogleFonts.inter(fontSize: Responsive.sp(13))),
              ),
            ],
          ),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.orange.shade700,
        ),
      );
    }
  }

  IconData _getIconForNote(Note note) {
    switch (note.contentType) {
      case 'article':
      case 'webpage':
        return Icons.article_outlined;
      case 'youtube':
        return Icons.play_circle_outline;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'tweet':
        return Icons.alternate_email;
      case 'image':
      case 'screenshot':
        return Icons.image_outlined;
      case 'quick_note':
        return Icons.notes_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  Color _getColorForNote(Note note) {
    switch (note.contentType) {
      case 'article':
      case 'webpage':
        return Colors.blue;
      case 'youtube':
        return Colors.red;
      case 'pdf':
        return Colors.redAccent;
      case 'tweet':
        return Colors.lightBlue;
      case 'image':
      case 'screenshot':
        return AppColors.primary;
      case 'quick_note':
        return AppColors.accent;
      default:
        return Colors.grey;
    }
  }
}

class _NoteSection {
  final String title;
  final List<Note> notes;
  
  _NoteSection(this.title, this.notes);
}
