import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/services/api_service.dart';
import '../../core/services/thumbnail_cache_manager.dart';
import '../../core/providers/notes_provider.dart';
import '../../core/providers/upload_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';
import 'widgets/snap_preview_surface.dart';
import 'widgets/text_card_thumbnail.dart';

/// Gradient colour pairs per content type — (topColor, bottomColor)
final Map<String, List<Color>> _contentTypeGradients = {
  'webpage': [const Color(0xFF1565C0), const Color(0xFF42A5F5)],
  'article': [const Color(0xFF2E7D32), const Color(0xFF66BB6A)],
  'youtube': [const Color(0xFFC62828), const Color(0xFFEF5350)],
  'facebook': [const Color(0xFF0A58CA), const Color(0xFF1877F2)],
  'pdf': [const Color(0xFF6A1B9A), const Color(0xFFAB47BC)],
  'tweet': [const Color(0xFF0277BD), const Color(0xFF29B6F6)],
  'image': [const Color(0xFF00695C), const Color(0xFF26A69A)],
  'screenshot': [const Color(0xFF00695C), const Color(0xFF26A69A)],
  'quick_note': [const Color(0xFF283593), const Color(0xFF5C6BC0)],
};

List<Color> _gradientForNote(Note note) {
  final key = note.contentType?.toLowerCase() ?? '';
  return _contentTypeGradients[key] ??
      [const Color(0xFF263238), const Color(0xFF37474F)];
}

class NoteDetailScreen extends ConsumerStatefulWidget {
  final String noteId;
  final Note? note; // passed via GoRouter extra

  const NoteDetailScreen({super.key, required this.noteId, this.note});

  @override
  ConsumerState<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends ConsumerState<NoteDetailScreen> {
  List<String>? _highlights;
  bool _highlightsLoading = true;
  bool _groupSheetOpen = false;
  bool _sharingToGroup = false;
  int _heroRefreshNonce = 0;

  /// Tracks the last seen processing status so we can re-fetch highlights
  /// the moment the note flips from 'incomplete' to 'active'.
  bool? _lastSeenProcessing;

  /// Polls the notes list every 4s while the displayed note is still indexing,
  /// so the bottom strip disappears as soon as the worker flips status to
  /// `'active'`.
  Timer? _statusPollTimer;

  /// Returns the freshest version of this note. The route's `extra` may be
  /// stale (e.g. `status='incomplete'` at the time of navigation), so we
  /// prefer the entry from `notesProvider` if available.
  Note? _currentNote() {
    final notes = ref.read(notesProvider).notes;
    for (final n in notes) {
      if (n.id == widget.noteId) return n;
    }
    return widget.note;
  }

  @override
  void initState() {
    super.initState();
    _loadHighlights();
  }

  Future<void> _loadHighlights() async {
    if (mounted) {
      setState(() {
        _highlightsLoading = true;
      });
    }
    // Bust any stale cache (e.g. empty fallback cached while still processing).
    ApiService().invalidateHighlightsCache(widget.noteId);
    final highlights = await ApiService().getHighlights(
      widget.noteId,
      fallbackPreview:
          _currentNote()?.contentPreview ?? widget.note?.contentPreview,
    );
    if (mounted) {
      setState(() {
        _highlights = highlights;
        _highlightsLoading = false;
      });
    }
  }

  Future<void> _refreshSnapDetail() async {
    ApiService().invalidateHighlightsCache(widget.noteId);
    setState(() {
      _heroRefreshNonce++;
    });
    await ref.read(notesProvider.notifier).refreshSilent();
    await _loadHighlights();
  }

  @override
  void dispose() {
    _statusPollTimer?.cancel();
    super.dispose();
  }

  void _syncStatusPoll(Note? note) {
    final processing = note?.isProcessing ?? false;
    // Re-fetch highlights the moment the note transitions from
    // processing -> active, otherwise the screen would keep showing the empty
    // fallback loaded at initState time.
    if (_lastSeenProcessing == true && !processing) {
      _loadHighlights();
    }
    _lastSeenProcessing = processing;
    if (processing && _statusPollTimer == null) {
      _statusPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted) return;
        ref.read(notesProvider.notifier).refreshSilent();
      });
    } else if (!processing && _statusPollTimer != null) {
      _statusPollTimer?.cancel();
      _statusPollTimer = null;
    }
  }

  /// Maps the worker's pipeline step into a short, user-facing label so the
  /// bottom strip reflects what's actually happening (instead of always
  /// saying "Indexing for search...").
  String _stepLabel(String? step) {
    switch (step) {
      case 'blob_upload':
        return 'Uploading file\u2026';
      case 'tensorlake_parse':
      case 'tensorlake_poll':
        return 'Extracting text\u2026';
      case 'html_cleanup':
        return 'Cleaning content\u2026';
      case 'title_gen':
        return 'Generating title\u2026';
      case 'db_insert':
        return 'Saving snap\u2026';
      case 'chunking':
        return 'Preparing for search\u2026';
      case 'embedding':
        return 'Building search index\u2026';
      case 'vectorize_upsert':
        return 'Indexing for search\u2026';
      case 'finalize':
        return 'Almost done\u2026';
      case 'init':
      case null:
        return 'Starting\u2026';
      default:
        return 'Processing\u2026';
    }
  }

  Future<void> _confirmCancel() async {
    final upload = ref.read(uploadProvider);
    final hasActiveUpload =
        upload.traceId != null && (upload.isUploading || upload.bannerHidden);

    if (hasActiveUpload) {
      // Normal case: active upload in progress — offer to cancel it
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(20),
            vertical: Responsive.pp(24),
          ),
          title: Text('Cancel upload?',
              style: TextStyle(fontSize: Responsive.sp(18))),
          content: Text(
            'This snap is still being indexed for search. Cancel and discard it?',
            style: TextStyle(fontSize: Responsive.sp(14)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child:
                  Text('Keep', style: TextStyle(fontSize: Responsive.sp(14))),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                'Cancel upload',
                style:
                    TextStyle(color: Colors.red, fontSize: Responsive.sp(14)),
              ),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await ref.read(uploadProvider.notifier).cancel();
      if (!mounted) return;
      await ref.read(notesProvider.notifier).refresh();
      if (!mounted) return;
      context.pop();
    } else {
      // Stuck note: incomplete status but no active upload tracking it.
      // Offer to delete the orphaned note.
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(20),
            vertical: Responsive.pp(24),
          ),
          title: Text('Remove stuck snap?',
              style: TextStyle(fontSize: Responsive.sp(18))),
          content: Text(
            'This snap didn\'t finish processing. Remove it from your library?',
            style: TextStyle(fontSize: Responsive.sp(14)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child:
                  Text('Keep', style: TextStyle(fontSize: Responsive.sp(14))),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                'Remove',
                style:
                    TextStyle(color: Colors.red, fontSize: Responsive.sp(14)),
              ),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await ApiService().deleteNote(widget.noteId);
      if (!mounted) return;
      await ref.read(notesProvider.notifier).refresh();
      if (!mounted) return;
      context.pop();
    }
  }

  void _viewOriginal() {
    final note = _currentNote();
    if (note?.isProcessing ?? false) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Still processing — available once indexing completes.'),
      ));
      return;
    }
    context.push('/notes/${widget.noteId}/original', extra: widget.note);
  }

  void _shareNote() {
    final note = _currentNote();
    if (note == null) return;
    if (note.isProcessing) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Still processing — you can share once it\'s ready.'),
      ));
      return;
    }
    _shareNoteSmart(note);
  }

  Future<void> _shareToGroup() async {
    final note = _currentNote();
    if (note == null || note.isProcessing) return;
    if (_groupSheetOpen) return;
    _groupSheetOpen = true;
    try {
      final group = await showModalBottomSheet<GroupSummary>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => _ShareToGroupSheet(
          groupsFuture: ApiService().fetchGroups(),
          onOpenGroups: () {
            Navigator.of(ctx).pop();
            context.push('/groups');
          },
        ),
      );
      if (group == null) return;
      if (_sharingToGroup) return;
      _sharingToGroup = true;
      showRootSnackBar('Sharing to ${group.name}...');
      unawaited(_shareToGroupInBackground(group, note.id));
    } finally {
      _groupSheetOpen = false;
    }
  }

  Future<void> _shareToGroupInBackground(
      GroupSummary group, String noteId) async {
    try {
      final ok = await ApiService().shareSnapToGroup(group.id, noteId);
      showRootSnackBar(ok ? 'Shared to ${group.name}' : 'Could not share snap');
    } finally {
      _sharingToGroup = false;
    }
  }

  Future<void> _shareNoteSmart(note) async {
    final contentType = note.contentType as String?;
    final noteId = note.id as String;
    final sourceUrl = note.sourceUrl as String?;
    final title = note.title as String;
    final originalFilename = note.originalFilename as String?;
    final contentMarkdown = note.contentPreview as String?;

    final isImage = contentType == 'image' || contentType == 'screenshot';
    final isPdf = contentType == 'pdf' ||
        (originalFilename?.toLowerCase().endsWith('.pdf') ?? false);
    final isWebpage = contentType == 'webpage';
    const socialTypes = {
      'youtube',
      'twitter',
      'tweet',
      'x',
      'instagram',
      'facebook',
      'linkedin',
      'pinterest',
      'tiktok',
      'reddit',
    };
    final isSocial = contentType != null && socialTypes.contains(contentType);
    final hasBlob = note.blobUrl != null && (note.blobUrl as String).isNotEmpty;

    // Webpages and social shares: share the original URL.
    if ((isWebpage || isSocial) && sourceUrl != null && sourceUrl.isNotEmpty) {
      Share.share(sourceUrl, subject: title);
      return;
    }

    // Images, PDFs, and other uploaded files: fetch signed URL from backend then download
    if (hasBlob && (isImage || isPdf || contentType == 'uploaded_file')) {
      _shareAsFile(
        noteId: noteId,
        filename: originalFilename ??
            (isImage ? '${_safeFilename(title)}.jpg' : _safeFilename(title)),
        title: title,
      );
      return;
    }

    // Quick notes / text: share content as .txt file
    if (contentMarkdown != null && contentMarkdown.isNotEmpty) {
      _shareAsTextFile(title: title, content: contentMarkdown);
      return;
    }

    // Fallback: share title + URL
    Share.share('$title${sourceUrl != null ? '\n\n$sourceUrl' : ''}',
        subject: title);
  }

  Future<void> _shareAsFile({
    required String noteId,
    required String filename,
    required String title,
  }) async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      duration: Duration(seconds: 30),
      content: Text('Preparing file to share…'),
    ));
    try {
      // Fetch the authenticated view URL from backend, then follow its redirect.
      final apiService = ApiService();
      final signedUrl = await apiService.getViewUrl(noteId);
      if (signedUrl == null || signedUrl.isEmpty) {
        throw Exception(
            'Could not get a signed download link. Please sign in again.');
      }

      final dir = await getTemporaryDirectory();
      final safeFilename = filename.contains('.') ? filename : '$filename';
      final filepath = '${dir.path}/$safeFilename';

      // Use Dio for faster download with timeout and streaming
      final dio = Dio();
      await dio.download(
        signedUrl,
        filepath,
        onReceiveProgress: (count, total) {
          // Log progress; you can update UI if needed
          debugPrint(
              '[Share] Download: ${(count / total * 100).toStringAsFixed(0)}%');
        },
        options: Options(
          responseType: ResponseType.bytes,
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 60),
          followRedirects: true,
          validateStatus: (status) => status! < 400,
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      await Share.shareXFiles([XFile(filepath)], subject: title);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      final errMsg = e is DioException
          ? 'Download error (${e.response?.statusCode ?? "network"}): ${e.message}'
          : 'Could not prepare file: $e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(errMsg),
      ));
      debugPrint('[Share] Error: $e');
    }
  }

  Future<void> _shareAsTextFile({
    required String title,
    required String content,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${_safeFilename(title)}.txt');
      await file.writeAsString('$title\n\n$content');
      await Share.shareXFiles([XFile(file.path)], subject: title);
    } catch (e) {
      Share.share('$title\n\n$content', subject: title);
    }
  }

  String _safeFilename(String title) => title
      .replaceAll(RegExp(r'[^\w\s\-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');

  @override
  Widget build(BuildContext context) {
    // Watch notesProvider so the screen rebuilds when the worker flips this
    // note's status from 'incomplete' to 'active'.
    ref.watch(notesProvider);
    final note = _currentNote();
    _syncStatusPoll(note);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Responsive.init(context);
    final gradientColors = note != null
        ? _gradientForNote(note)
        : [const Color(0xFF263238), const Color(0xFF37474F)];

    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: (note?.isProcessing ?? false)
          ? _IndexingStrip(
              onCancel: _confirmCancel,
              stepLabel: _stepLabel(ref.watch(uploadProvider).currentStep),
            )
          : null,
      body: Stack(
        children: [
          const Positioned.fill(
            child: HexagonBackground(
              color: Color(0xFFF59E0B),
              opacity: 0.12,
            ),
          ),
          RefreshIndicator(
            onRefresh: _refreshSnapDetail,
            color: AppColors.primary,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // ── Hero gradient header ──────────────────────────────────────
                SliverAppBar(
                  // Hero height: scale with screen but keep a sane min/max so the
                  // thumbnail reads well on small phones and doesn't dominate on
                  // tablets. ~42% of screen height on a typical phone.
                  expandedHeight: ((note?.isInstagram ?? false) ||
                          (note?.isFacebook ?? false) ||
                          (note?.isLinkedIn ?? false) ||
                          ((note?.socialSource ?? '').toLowerCase() ==
                              'youtube') ||
                          (note?.isTwitter ?? false) ||
                          (note?.isReddit ?? false))
                      ? (Responsive.height * 0.58).clamp(420.0, 620.0)
                      : (Responsive.height * 0.42).clamp(280.0, 480.0),
                  pinned: true,
                  backgroundColor: Colors.white,
                  leading: IconButton(
                    icon: Icon(Icons.arrow_back_rounded,
                        color: Color(0xFF0F172A)),
                    onPressed: () => context.pop(),
                  ),
                  actions: [
                    IconButton(
                      icon: Icon(
                        Icons.share_rounded,
                        color: (note?.isProcessing ?? false)
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF0F172A),
                      ),
                      onPressed:
                          (note?.isProcessing ?? false) ? null : _shareNote,
                    ),
                  ],
                  flexibleSpace: FlexibleSpaceBar(
                    collapseMode: CollapseMode.parallax,
                    background: _HeroSection(
                      refreshNonce: _heroRefreshNonce,
                      note: note,
                      gradientColors: gradientColors,
                    ),
                  ),
                ),

                // ── Body content ─────────────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      Responsive.pp(20),
                      Responsive.pp(24),
                      Responsive.pp(20),
                      MediaQuery.of(context).padding.bottom + Responsive.pp(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Show full title above the meta row for content types where
                        // cards ellipsize it (YouTube, LinkedIn, webpages). Instagram
                        // is skipped on purpose — IG posts have no real title; the
                        // scraped value is just the first line of the caption and
                        // tends to be a likes/comments preamble.
                        if (note != null &&
                            !note.isInstagram &&
                            ((note.socialSource ?? '').toLowerCase() ==
                                    'youtube' ||
                                (note.socialSource ?? '').toLowerCase() ==
                                    'linkedin' ||
                                (note.contentType ?? '').toLowerCase() ==
                                    'webpage') &&
                            (note.displayTitle).trim().isNotEmpty) ...[
                          Text(
                            note.displayTitle,
                            style: GoogleFonts.inter(
                              fontSize: Responsive.sp(20),
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF0F172A),
                              height: 1.25,
                            ),
                          ),
                          SizedBox(height: Responsive.wp(14)),
                        ],

                        // Meta row: content type chip + date
                        if (note != null) _MetaRow(note: note),

                        SizedBox(height: Responsive.wp(28)),

                        // User-entered description (typed when uploading). Shown
                        // immediately below the hero so the user's own context is
                        // the first thing they see when opening the card.
                        if ((note?.description ?? '').trim().isNotEmpty) ...[
                          _UserDescriptionSection(
                            description: note!.description!.trim(),
                            isDark: isDark,
                          ),
                          SizedBox(height: Responsive.wp(28)),
                        ],

                        // Source description (e.g. YouTube video description).
                        // Rendered as-is, above key highlights, when present.
                        if ((note?.socialDescription ?? '')
                            .trim()
                            .isNotEmpty) ...[
                          _SocialDescriptionSection(
                            description: note!.socialDescription!.trim(),
                            isDark: isDark,
                          ),
                          SizedBox(height: Responsive.wp(28)),
                        ],

                        // Key highlights section
                        Text(
                          'Key Highlights',
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(16),
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                            letterSpacing: 0.2,
                          ),
                        ),
                        SizedBox(height: Responsive.wp(14)),

                        _HighlightsSection(
                          loading: _highlightsLoading,
                          highlights: _highlights,
                          isDark: isDark,
                        ),

                        SizedBox(height: Responsive.wp(32)),

                        // Action row
                        _ActionRow(
                          onShare: _shareNote,
                          onShareToGroup: _shareToGroup,
                          onAskSnapBot: () {
                            final title =
                                Uri.encodeQueryComponent(note?.title ?? '');
                            context.push(
                                '/chat?note_id=${widget.noteId}&note_title=$title');
                          },
                          disabled: note?.isProcessing ?? false,
                        ),

                        SizedBox(height: Responsive.wp(24)),

                        // View Original CTA
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: (note?.isProcessing ?? false)
                                ? null
                                : _viewOriginal,
                            icon: Icon(Icons.open_in_new_rounded,
                                size: Responsive.sp(18)),
                            label: Text(
                              (note?.isProcessing ?? false)
                                  ? 'Available once ready'
                                  : 'View Original',
                              style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w600,
                                  fontSize: Responsive.sp(15)),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFFCBD5E1),
                              disabledForegroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(
                                  vertical: Responsive.pp(16)),
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(Responsive.wp(14)),
                              ),
                              elevation: 0,
                            ),
                          ),
                        ).animate().fadeIn(delay: 200.ms),

                        SizedBox(height: Responsive.wp(40)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero section (gradient background + thumbnail + icon)
// ─────────────────────────────────────────────────────────────────────────────

class _HeroSection extends StatelessWidget {
  final Note? note;
  final List<Color> gradientColors;
  final int refreshNonce;

  const _HeroSection({
    required this.note,
    required this.gradientColors,
    required this.refreshNonce,
  });

  String _iconForContentType(String? ct) {
    switch (ct) {
      case 'webpage':
      case 'article':
        return '🌐';
      case 'youtube':
        return '🎬';
      case 'pdf':
        return '📕';
      case 'tweet':
        return '🐦';
      case 'image':
      case 'screenshot':
        return '🖼️';
      default:
        return '📝';
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasHeroImage =
        note?.thumbnailUrl != null && note!.thumbnailUrl!.isNotEmpty;
    final isInstagram = note?.isInstagram ?? false;
    final isFacebook = note?.isFacebook ?? false;
    final isLinkedIn = note?.isLinkedIn ?? false;
    final isTwitter = note?.isTwitter ?? false;
    final isReddit = note?.isReddit ?? false;
    final isYouTube = (note?.socialSource ?? '').toLowerCase() == 'youtube';
    final useSocialEmbed = isInstagram ||
        isFacebook ||
        isLinkedIn ||
        isTwitter ||
        isReddit ||
        isYouTube;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (useSocialEmbed)
            SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  Responsive.pp(18),
                  kToolbarHeight + Responsive.pp(4),
                  Responsive.pp(18),
                  Responsive.pp(8),
                ),
                child: SnapPreviewSurface(
                  key: ValueKey(
                      'social-hero-${note?.id}-${note?.socialSource}-$refreshNonce'),
                  title: note?.displayTitle ?? 'Instagram snap',
                  description: note?.description,
                  originalFilename: note?.originalFilename,
                  contentType: note?.contentType,
                  imageUrl: null,
                  noteId: note?.id,
                  socialSource: note?.socialSource,
                  socialEmbedHtml: note?.socialEmbedHtml,
                  sourceUrl: note?.sourceUrl,
                  mode: SnapPreviewMode.story,
                  interactive: true,
                  accentColor: isLinkedIn
                      ? const Color(0xFF0A66C2)
                      : isYouTube
                          ? const Color(0xFFFF0000)
                          : isFacebook
                              ? const Color(0xFF1877F2)
                              : isTwitter
                                  ? const Color(0xFF111827)
                                  : isReddit
                                      ? const Color(0xFFFF4500)
                                      : const Color(0xFFDD2A7B),
                ),
              ),
            )
          else if (hasHeroImage)
            // Pad the top of the hero only by the status-bar inset so the
            // image stretches close to the top of the screen. The
            // SliverAppBar's back button floats over the image (it has its
            // own contrast — black icon on white background of the appbar
            // when scrolled, and over the image edge while expanded).
            Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top,
              ),
              child: SizedBox.expand(
                child: CachedNetworkImage(
                  imageUrl: note!.thumbnailUrl!,
                  cacheManager: ThumbnailCacheManager.instance,
                  // Reddit image posts are often tall screenshots/resumes.
                  // Preserve the full image there; other hero images still
                  // fill the space for a richer detail header.
                  fit: note!.isReddit ? BoxFit.contain : BoxFit.cover,
                  alignment: Alignment.center,
                  fadeInDuration: Duration.zero,
                  placeholderFadeInDuration: Duration.zero,
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          if (hasHeroImage && !useSocialEmbed)
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withOpacity(0.0),
                    Colors.white.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          if (!hasHeroImage && !useSocialEmbed)
            SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  Responsive.pp(20),
                  kToolbarHeight + Responsive.pp(8),
                  Responsive.pp(20),
                  Responsive.pp(20),
                ),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Responsive.wp(16)),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0F172A).withOpacity(0.10),
                            blurRadius: Responsive.wp(14),
                            offset: Offset(0, Responsive.wp(4)),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Responsive.wp(16)),
                        child: TextCardThumbnail(
                          title: note?.displayTitle ?? 'Untitled',
                          description: note?.description,
                          originalFilename: note?.originalFilename,
                          contentType: note?.contentType,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Meta row: content-type chip + date
// ─────────────────────────────────────────────────────────────────────────────

class _MetaRow extends StatelessWidget {
  final Note note;
  const _MetaRow({required this.note});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dateStr = DateFormat('MMM d, yyyy').format(note.createdAt);
    final ct = (note.contentType ?? 'note').toUpperCase();

    return Wrap(
      spacing: Responsive.wp(10),
      runSpacing: Responsive.wp(6),
      children: [
        Container(
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(10), vertical: Responsive.pp(5)),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.12),
            borderRadius: BorderRadius.circular(Responsive.wp(8)),
          ),
          child: Text(
            ct,
            style: GoogleFonts.inter(
              color: AppColors.primary,
              fontSize: Responsive.sp(11),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
        for (final tag in note.tags.take(2))
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Responsive.pp(10), vertical: Responsive.pp(5)),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.08)
                  : Colors.black.withOpacity(0.05),
              borderRadius: BorderRadius.circular(Responsive.wp(8)),
            ),
            child: Text(
              tag,
              style: GoogleFonts.inter(
                color: isDark ? Colors.white70 : AppColors.textDark,
                fontSize: Responsive.sp(11),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(top: Responsive.pp(2)),
          child: Text(
            dateStr,
            style: GoogleFonts.inter(
              color: isDark ? Colors.white38 : AppColors.textLight,
              fontSize: Responsive.sp(12),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Social description section — collapsible verbatim source description.
// ─────────────────────────────────────────────────────────────────────────────

class _SocialDescriptionSection extends StatefulWidget {
  final String description;
  final bool isDark;

  const _SocialDescriptionSection({
    required this.description,
    required this.isDark,
  });

  @override
  State<_SocialDescriptionSection> createState() =>
      _SocialDescriptionSectionState();
}

class _SocialDescriptionSectionState extends State<_SocialDescriptionSection> {
  static const int _collapsedChars = 320;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final desc = widget.description;
    final isLong = desc.length > _collapsedChars;
    final shown = (_expanded || !isLong)
        ? desc
        : '${desc.substring(0, _collapsedChars).trimRight()}…';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Responsive.pp(16)),
      decoration: BoxDecoration(
        color:
            widget.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(Responsive.wp(14)),
        border: Border.all(
          color:
              widget.isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Description',
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(16),
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
              letterSpacing: 0.2,
            ),
          ),
          SizedBox(height: Responsive.wp(10)),
          SelectableText(
            shown,
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(14),
              height: 1.5,
              color: widget.isDark
                  ? const Color(0xFFCBD5E1)
                  : const Color(0xFF334155),
            ),
          ),
          if (isLong) ...[
            SizedBox(height: Responsive.wp(8)),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              behavior: HitTestBehavior.opaque,
              child: Text(
                _expanded ? 'Show less' : 'Show more',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(13),
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// User description section — the note the user typed at upload time.
// ─────────────────────────────────────────────────────────────────────────────

class _UserDescriptionSection extends StatefulWidget {
  final String description;
  final bool isDark;

  const _UserDescriptionSection({
    required this.description,
    required this.isDark,
  });

  @override
  State<_UserDescriptionSection> createState() =>
      _UserDescriptionSectionState();
}

class _UserDescriptionSectionState extends State<_UserDescriptionSection> {
  static const int _collapsedChars = 320;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final desc = widget.description;
    final isLong = desc.length > _collapsedChars;
    final shown = (_expanded || !isLong)
        ? desc
        : '${desc.substring(0, _collapsedChars).trimRight()}…';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Responsive.pp(16)),
      decoration: BoxDecoration(
        color:
            widget.isDark ? const Color(0xFF1E293B) : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(Responsive.wp(14)),
        border: Border.all(
          color:
              widget.isDark ? const Color(0xFF334155) : const Color(0xFFFDE68A),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.edit_note_rounded,
                size: Responsive.sp(18),
                color: AppColors.primary,
              ),
              SizedBox(width: Responsive.wp(6)),
              Text(
                'Your Note',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(16),
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          SizedBox(height: Responsive.wp(10)),
          SelectableText(
            shown,
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(14),
              height: 1.5,
              color: widget.isDark
                  ? const Color(0xFFCBD5E1)
                  : const Color(0xFF334155),
            ),
          ),
          if (isLong) ...[
            SizedBox(height: Responsive.wp(8)),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              behavior: HitTestBehavior.opaque,
              child: Text(
                _expanded ? 'Show less' : 'Show more',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(13),
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Highlights section — shimmer → bullet list
// ─────────────────────────────────────────────────────────────────────────────

class _HighlightsSection extends StatelessWidget {
  final bool loading;
  final List<String>? highlights;
  final bool isDark;

  const _HighlightsSection({
    required this.loading,
    required this.highlights,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Shimmer.fromColors(
        baseColor: isDark ? const Color(0xFF2D2D35) : const Color(0xFFE0E0E0),
        highlightColor:
            isDark ? const Color(0xFF3D3D45) : const Color(0xFFF5F5F5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(
            4,
            (i) => Padding(
              padding: EdgeInsets.only(bottom: Responsive.pp(12)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: Responsive.wp(6),
                    height: Responsive.wp(6),
                    margin: EdgeInsets.only(
                        top: Responsive.pp(7), right: Responsive.pp(10)),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: Responsive.wp(14),
                      width: i.isEven ? double.infinity : 220,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(Responsive.wp(6)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (highlights == null || highlights!.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Responsive.pp(8)),
        child: Text(
          'No highlights available.',
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(14),
            color: isDark ? Colors.white38 : AppColors.textLight,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: highlights!
          .asMap()
          .entries
          .map(
            (entry) => Padding(
              padding: EdgeInsets.only(bottom: Responsive.pp(14)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: Responsive.wp(6),
                    height: Responsive.wp(6),
                    margin: EdgeInsets.only(
                        top: Responsive.pp(7), right: Responsive.pp(12)),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primary,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(14.5),
                        height: 1.55,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.87)
                            : AppColors.textDark,
                      ),
                    ),
                  ),
                ],
              ),
            )
                .animate(delay: Duration(milliseconds: 100 + entry.key * 60))
                .fadeIn()
                .slideX(begin: -0.05),
          )
          .toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Action row: Share, Copy Link, Ask SnapBot
// ─────────────────────────────────────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  final VoidCallback onShare;
  final VoidCallback onShareToGroup;
  final VoidCallback onAskSnapBot;
  final bool disabled;

  const _ActionRow({
    required this.onShare,
    required this.onShareToGroup,
    required this.onAskSnapBot,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        _ActionButton(
          icon: Icons.share_rounded,
          label: 'Share',
          onTap: onShare,
          isDark: isDark,
          disabled: disabled,
        ),
        SizedBox(width: Responsive.wp(12)),
        _ActionButton(
          icon: Icons.groups_rounded,
          label: 'Group',
          onTap: onShareToGroup,
          isDark: isDark,
          disabled: disabled,
        ),
        SizedBox(width: Responsive.wp(12)),
        _ActionButton(
          icon: Icons.auto_awesome_rounded,
          label: 'Ask AI',
          onTap: onAskSnapBot,
          isDark: isDark,
          accent: true,
          disabled: disabled,
        ),
      ],
    );
  }
}

class _ShareToGroupSheet extends StatelessWidget {
  final Future<List<GroupSummary>> groupsFuture;
  final VoidCallback onOpenGroups;

  const _ShareToGroupSheet({
    required this.groupsFuture,
    required this.onOpenGroups,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Responsive.pp(14),
          Responsive.pp(4),
          Responsive.pp(14),
          Responsive.pp(18),
        ),
        child: FutureBuilder<List<GroupSummary>>(
          future: groupsFuture,
          builder: (context, snapshot) {
            final groups = (snapshot.data ?? [])
                .where((group) => group.status == 'active')
                .toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Share to group',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: Responsive.sp(20),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: onOpenGroups,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Groups'),
                    ),
                  ],
                ),
                SizedBox(height: Responsive.wp(8)),
                if (snapshot.connectionState == ConnectionState.waiting)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: Responsive.pp(28)),
                    child: const Center(child: CircularProgressIndicator()),
                  )
                else if (groups.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: Responsive.pp(18)),
                    child: Text(
                      'No active groups yet. Create a group first.',
                      style: GoogleFonts.inter(color: Colors.grey.shade600),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: groups.length,
                      separatorBuilder: (_, __) =>
                          Divider(color: Colors.grey.shade200),
                      itemBuilder: (context, index) {
                        final group = groups[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Container(
                            width: Responsive.wp(42),
                            height: Responsive.wp(42),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCFCE7),
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(12)),
                            ),
                            child: const Icon(Icons.groups_rounded,
                                color: AppColors.primary),
                          ),
                          title: Text(
                            group.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                GoogleFonts.inter(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text('${group.memberCount} members'),
                          onTap: () => Navigator.of(context).pop(group),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDark;
  final bool accent;
  final bool disabled;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.isDark,
    this.accent = false,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = disabled
        ? (isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.black.withOpacity(0.03))
        : (accent
            ? AppColors.primary.withOpacity(0.15)
            : (isDark
                ? Colors.white.withOpacity(0.07)
                : Colors.black.withOpacity(0.05)));
    final fg = disabled
        ? (isDark ? Colors.white24 : const Color(0xFF94A3B8))
        : (accent
            ? AppColors.primary
            : (isDark ? Colors.white70 : AppColors.textDark));

    return Expanded(
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          padding: EdgeInsets.symmetric(vertical: Responsive.pp(14)),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(Responsive.wp(12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg, size: Responsive.sp(20)),
              SizedBox(height: Responsive.wp(6)),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(11),
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Persistent bottom strip shown on detail screen while a note is still
/// being indexed in the background. Tapping the close icon triggers an
/// upload cancel via [uploadProvider.cancel].
class _IndexingStrip extends StatelessWidget {
  final VoidCallback onCancel;
  final String stepLabel;

  const _IndexingStrip({required this.onCancel, required this.stepLabel});

  @override
  Widget build(BuildContext context) {
    final bg = const Color(0xFF0F172A);
    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.fromLTRB(
          Responsive.pp(12),
          0,
          Responsive.pp(12),
          Responsive.pp(12),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(14),
          vertical: Responsive.pp(12),
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(Responsive.wp(14)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: Responsive.wp(16),
              offset: Offset(0, Responsive.wp(6)),
            ),
          ],
        ),
        child: Row(
          children: [
            SizedBox(
              width: Responsive.wp(18),
              height: Responsive.wp(18),
              child: CircularProgressIndicator(
                strokeWidth: Responsive.wp(2),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            SizedBox(width: Responsive.wp(12)),
            Expanded(
              child: Text(
                stepLabel,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: Responsive.sp(13),
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Cancel upload',
              icon: Icon(Icons.close_rounded,
                  color: Colors.white70, size: Responsive.sp(22)),
              onPressed: onCancel,
              splashRadius: Responsive.wp(20),
            ),
          ],
        ),
      ),
    );
  }
}
