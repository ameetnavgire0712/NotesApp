// ignore_for_file: deprecated_member_use
// Stories-style slideshow for one recap category.
// - 6 seconds per slide, auto-advance with a progress bar per slide.
// - Tap left/right sides or swipe horizontally to navigate.
// - Tap-and-hold to pause. Swipe down to dismiss.
// - "Open original" opens the snap's source_url.
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/responsive.dart';
import '../notes/widgets/snap_preview_surface.dart';
import 'recap_models.dart';

enum _StorySlideKind { image, video, note, document }

class RecapStoriesScreen extends StatefulWidget {
  final RecapCategory category;
  const RecapStoriesScreen({super.key, required this.category});

  @override
  State<RecapStoriesScreen> createState() => _RecapStoriesScreenState();
}

class _RecapStoriesScreenState extends State<RecapStoriesScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _slideDuration = Duration(seconds: 6);

  int _index = 0;
  late AnimationController _progress;
  bool _paused = false;
  double? _resolvedPreviewAspect;
  String? _resolvedPreviewUrl;
  ImageStream? _previewStream;
  ImageStreamListener? _previewListener;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this, duration: _slideDuration)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _next();
      });
    _startSlide();
  }

  @override
  void dispose() {
    _disposePreviewStream();
    _progress.dispose();
    super.dispose();
  }

  void _disposePreviewStream() {
    if (_previewStream != null && _previewListener != null) {
      _previewStream!.removeListener(_previewListener!);
    }
    _previewStream = null;
    _previewListener = null;
  }

  void _startSlide() {
    _progress.reset();
    _progress.forward();
  }

  void _next() {
    if (_index < widget.category.slides.length - 1) {
      setState(() => _index++);
      _startSlide();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _prev() {
    if (_index > 0) {
      setState(() => _index--);
      _startSlide();
    } else {
      _progress.reset();
      _progress.forward();
    }
  }

  void _pause(bool v) {
    if (_paused == v) return;
    setState(() => _paused = v);
    if (v) {
      _progress.stop();
    } else {
      _progress.forward();
    }
  }

  Future<void> _openOriginal(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    _pause(true);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Color get _tint {
    final hex = widget.category.color.replaceAll('#', '');
    if (hex.length != 6) return const Color(0xFF3B82F6);
    return Color(int.parse('FF$hex', radix: 16));
  }

  String? _resolvePreviewUrl(RecapSlide slide) {
    final blob = slide.blobUrl?.trim();
    final rawPrimary = slide.thumbnail?.trim();
    final primary =
        _isGeneratedSocialScreenshot(rawPrimary) ? null : rawPrimary;
    final fileType = slide.fileType.toLowerCase();
    final originalFilename = (slide.originalFilename ?? '').toLowerCase();
    const imageExts = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.heic',
      '.bmp',
      '.svg'
    ];

    final isImageLike = fileType == 'image' ||
        fileType == 'screenshot' ||
        (fileType == 'uploaded_file' &&
            imageExts.any(originalFilename.endsWith));

    if (isImageLike) {
      if (blob != null && blob.isNotEmpty) return blob;
      if (primary != null && primary.isNotEmpty) return primary;
      return null;
    }

    if (fileType == 'uploaded_file') {
      return primary != null && primary.isNotEmpty ? primary : null;
    }

    if (primary != null && primary.isNotEmpty) return primary;
    if (blob != null && blob.isNotEmpty) return blob;
    return null;
  }

  bool _isGeneratedSocialScreenshot(String? url) {
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host != 's.wordpress.com' ||
        !uri.path.startsWith('/mshots/v1/')) {
      return false;
    }
    final decoded =
        Uri.decodeComponent(uri.path.substring('/mshots/v1/'.length))
            .toLowerCase();
    return decoded.contains('instagram.com') ||
        decoded.contains('facebook.com') ||
        decoded.contains('linkedin.com') ||
        decoded.contains('twitter.com') ||
        decoded.contains('x.com') ||
        decoded.contains('reddit.com');
  }

  _StorySlideKind _slideKind(RecapSlide slide) {
    final fileType = slide.fileType.toLowerCase();
    final originalFilename = (slide.originalFilename ?? '').toLowerCase();
    const imageExts = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.heic',
      '.bmp',
      '.svg'
    ];

    final isImageUpload = fileType == 'image' ||
        fileType == 'screenshot' ||
        (fileType == 'uploaded_file' &&
            imageExts.any(originalFilename.endsWith));

    if (isImageUpload) return _StorySlideKind.image;
    if (fileType == 'youtube' || fileType == 'video') {
      return _StorySlideKind.video;
    }
    if (fileType == 'quick_note') return _StorySlideKind.note;
    return _StorySlideKind.document;
  }

  bool _isShortsLike(RecapSlide slide) {
    final haystack = [
      slide.sourceUrl,
      slide.title,
      slide.fullTitle,
      slide.originalFilename ?? '',
    ].join(' ').toLowerCase();
    return haystack.contains('/shorts/') ||
        haystack.contains('youtube.com/shorts') ||
        haystack.contains('youtu.be/shorts') ||
        haystack.contains(' shorts ') ||
        haystack.endsWith(' shorts');
  }

  double _storyAspectRatio(RecapSlide slide) {
    switch (_slideKind(slide)) {
      case _StorySlideKind.image:
        return 1.0;
      case _StorySlideKind.video:
        if (_isShortsLike(slide)) return 9 / 16;
        return 16 / 10;
      case _StorySlideKind.note:
        return 5 / 6;
      case _StorySlideKind.document:
        return 4 / 5;
    }
  }

  Size _fitStage(Size available, double aspectRatio) {
    final widthByHeight = available.height * aspectRatio;
    final heightByWidth = available.width / aspectRatio;
    if (widthByHeight <= available.width) {
      return Size(widthByHeight, available.height);
    }
    return Size(available.width, heightByWidth);
  }

  void _resolvePreviewAspect(String? url) {
    final cleanUrl = url?.trim();
    if (cleanUrl == null ||
        cleanUrl.isEmpty ||
        cleanUrl == _resolvedPreviewUrl) {
      return;
    }

    _disposePreviewStream();
    _resolvedPreviewUrl = cleanUrl;
    _resolvedPreviewAspect = null;

    final provider = NetworkImage(cleanUrl);
    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!mounted || cleanUrl != _resolvedPreviewUrl) return;
        final width = info.image.width.toDouble();
        final height = info.image.height.toDouble();
        if (height <= 0) return;
        setState(() {
          _resolvedPreviewAspect = (width / height).clamp(0.56, 1.78);
        });
      },
      onError: (_, __) {
        if (!mounted || cleanUrl != _resolvedPreviewUrl) return;
        setState(() => _resolvedPreviewAspect = null);
      },
    );
    stream.addListener(listener);
    _previewStream = stream;
    _previewListener = listener;
  }

  double _stageAspectRatio(RecapSlide slide, String? previewUrl) {
    final kind = _slideKind(slide);
    if (kind == _StorySlideKind.image && _resolvedPreviewUrl == previewUrl) {
      return _resolvedPreviewAspect ?? _storyAspectRatio(slide);
    }
    if (kind == _StorySlideKind.video &&
        !_isShortsLike(slide) &&
        _resolvedPreviewUrl == previewUrl) {
      return _resolvedPreviewAspect ?? _storyAspectRatio(slide);
    }
    return _storyAspectRatio(slide);
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

  String _titleFor(RecapSlide slide) =>
      slide.fullTitle.isNotEmpty ? slide.fullTitle : slide.title;

  String _sourceLabel(RecapSlide slide) {
    switch (slide.fileType.toLowerCase()) {
      case 'youtube':
        return 'YouTube';
      case 'video':
        return 'Video';
      case 'webpage':
        return 'Webpage';
      case 'article':
        return 'Article';
      case 'quick_note':
        return 'Note';
      case 'screenshot':
        return 'Screenshot';
      case 'image':
        return 'Photo';
      case 'pdf':
        return 'PDF';
      case 'uploaded_file':
        final name = slide.originalFilename?.trim();
        if (name != null && name.isNotEmpty && name.contains('.')) {
          final ext = name.split('.').last.toUpperCase();
          return ext.length <= 5 ? ext : 'File';
        }
        return 'File';
      default:
        final type = slide.fileType.trim();
        if (type.isEmpty) return 'Snap';
        return type
            .split('_')
            .where((part) => part.isNotEmpty)
            .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
            .join(' ');
    }
  }

  String? _savedLabel(RecapSlide slide) {
    final createdAt = slide.createdAt;
    if (createdAt == null) return null;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return 'Saved ${months[createdAt.month - 1]} ${createdAt.day}';
  }

  List<String> _metadataFor(RecapSlide slide) {
    final labels = <String>[_sourceLabel(slide)];
    final tag = slide.tag.trim();
    if (tag.isNotEmpty &&
        !labels.any((item) => item.toLowerCase() == tag.toLowerCase())) {
      labels.add(tag);
    }
    final saved = _savedLabel(slide);
    if (saved != null) labels.add(saved);
    return labels.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.category.slides;
    if (slides.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.category.emoji,
                  style: TextStyle(fontSize: Responsive.sp(56))),
              SizedBox(height: Responsive.wp(12)),
              Text('No snaps in this category',
                  style: TextStyle(
                      color: Colors.white70, fontSize: Responsive.sp(14))),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text('Close'),
              ),
            ],
          ),
        ),
      );
    }

    final slide = slides[_index];
    final previewUrl = _resolvePreviewUrl(slide);
    final title = _titleFor(slide);
    _resolvePreviewAspect(previewUrl);
    final storyAspectRatio = _stageAspectRatio(slide, previewUrl);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 250) {
              Navigator.of(context).maybePop();
            }
          },
          onHorizontalDragEnd: (d) {
            final velocity = d.primaryVelocity ?? 0;
            if (velocity < -180) _next();
            if (velocity > 180) _prev();
          },
          onLongPressStart: (_) => _pause(true),
          onLongPressEnd: (_) => _pause(false),
          child: Stack(
            children: [
              Positioned.fill(
                child: _StoryBackdrop(
                  tint: _tint,
                  imageUrl: previewUrl,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final availableStage = Size(
                        (constraints.maxWidth - 36).clamp(240.0, 860.0),
                        (constraints.maxHeight - 372).clamp(220.0, 900.0),
                      );
                      final stageSize =
                          _fitStage(availableStage, storyAspectRatio);

                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                          Responsive.pp(18),
                          Responsive.wp(128),
                          Responsive.pp(18),
                          Responsive.wp(218),
                        ),
                        child: Center(
                          child: SizedBox(
                            width: stageSize.width,
                            height: stageSize.height,
                            child: SnapPreviewSurface(
                              title: title,
                              description: slide.description,
                              originalFilename: slide.originalFilename,
                              contentType: slide.fileType,
                              imageUrl: previewUrl,
                              socialSource: _socialSourceFor(slide),
                              sourceUrl: slide.sourceUrl,
                              mode: SnapPreviewMode.story,
                              accentColor: _tint,
                              imageFit: BoxFit.contain,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                top: 8,
                child: Row(
                  children: List.generate(slides.length, (i) {
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.5),
                        child: _ProgressBar(
                          animation: _progress,
                          filled: i < _index,
                          active: i == _index,
                          tint: _tint,
                          paused: _paused,
                        ),
                      ),
                    );
                  }),
                ),
              ),
              Positioned(
                left: 14,
                right: 8,
                top: 26,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Responsive.wp(18)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Row(
                      children: [
                        Container(
                          width: Responsive.wp(36),
                          height: Responsive.wp(36),
                          decoration: BoxDecoration(
                            color: _tint,
                            borderRadius:
                                BorderRadius.circular(Responsive.wp(12)),
                            boxShadow: [
                              BoxShadow(
                                color: _tint.withOpacity(0.38),
                                blurRadius: Responsive.wp(16),
                                offset: Offset(0, Responsive.wp(6)),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Text(widget.category.emoji,
                                style: TextStyle(fontSize: Responsive.sp(18))),
                          ),
                        ),
                        SizedBox(width: Responsive.wp(10)),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.category.nameWithoutEmoji,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: Responsive.sp(14),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              SizedBox(height: Responsive.wp(2)),
                              Text(
                                '${_index + 1} of ${slides.length} - ${_sourceLabel(slide)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.68),
                                  fontSize: Responsive.sp(11),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: Responsive.wp(8)),
                        IconButton(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.12),
                            side: BorderSide(
                                color: Colors.white.withOpacity(0.18)),
                          ),
                          icon: Icon(Icons.close,
                              color: Colors.white, size: Responsive.sp(20)),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 88,
                child: _SlideCaption(
                  title: title,
                  description: slide.description,
                  labels: _metadataFor(slide),
                  tint: _tint,
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: Responsive.pp(16)),
                    child: Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: slide.sourceUrl.isEmpty
                                ? null
                                : () => _openOriginal(slide.sourceUrl),
                            icon:
                                Icon(Icons.north_east, size: Responsive.sp(16)),
                            label: Text(slide.sourceUrl.isEmpty
                                ? 'Original unavailable'
                                : 'Open original'),
                            style: ElevatedButton.styleFrom(
                              disabledBackgroundColor:
                                  Colors.white.withOpacity(0.16),
                              disabledForegroundColor:
                                  Colors.white.withOpacity(0.46),
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF05070B),
                              elevation: 0,
                              padding: EdgeInsets.symmetric(
                                  horizontal: Responsive.pp(16),
                                  vertical: Responsive.pp(13)),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(Responsive.wp(16))),
                              textStyle: TextStyle(
                                  fontSize: Responsive.sp(13),
                                  fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                        SizedBox(width: Responsive.wp(10)),
                        _StoryIconButton(
                          icon: _paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          onPressed: () => _pause(!_paused),
                        ),
                        SizedBox(width: Responsive.wp(10)),
                        _StoryIconButton(
                          icon: Icons.info_outline,
                          onPressed: () => _showSlideInfo(slide),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 112,
                bottom: 82,
                width: MediaQuery.of(context).size.width * 0.34,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _prev,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned(
                right: 0,
                top: 112,
                bottom: 82,
                width: MediaQuery.of(context).size.width * 0.34,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _next,
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSlideInfo(RecapSlide slide) {
    _pause(true);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF10131A),
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Responsive.wp(24))),
      ),
      builder: (context) {
        final filename = slide.originalFilename?.trim();
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              Responsive.pp(20),
              Responsive.pp(18),
              Responsive.pp(20),
              Responsive.pp(22),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: Responsive.wp(34),
                      height: Responsive.wp(34),
                      decoration: BoxDecoration(
                        color: _tint,
                        borderRadius: BorderRadius.circular(Responsive.wp(12)),
                      ),
                      child: Icon(Icons.auto_awesome,
                          color: Colors.white, size: Responsive.sp(18)),
                    ),
                    SizedBox(width: Responsive.wp(10)),
                    Expanded(
                      child: Text(
                        'Snap details',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: Responsive.sp(16),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Responsive.wp(16)),
                _InfoRow(label: 'Type', value: _sourceLabel(slide)),
                if (slide.tag.trim().isNotEmpty)
                  _InfoRow(label: 'Tag', value: slide.tag.trim()),
                if (_savedLabel(slide) != null)
                  _InfoRow(label: 'Saved', value: _savedLabel(slide)!),
                if (filename != null && filename.isNotEmpty)
                  _InfoRow(label: 'File', value: filename),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      if (mounted) _pause(false);
    });
  }
}

class _SlideCaption extends StatelessWidget {
  final String title;
  final String description;
  final List<String> labels;
  final Color tint;

  const _SlideCaption({
    required this.title,
    required this.description,
    required this.labels,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: Responsive.wp(7),
            runSpacing: Responsive.wp(7),
            children: [
              for (var i = 0; i < labels.length; i++)
                _MetaChip(
                  label: labels[i],
                  tint: tint,
                  filled: i == 0,
                ),
            ],
          ),
          SizedBox(height: Responsive.wp(10)),
          Text(
            title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: Responsive.sp(27),
              fontWeight: FontWeight.w900,
              height: 1.03,
              letterSpacing: 0,
              shadows: [
                Shadow(
                    color: Color(0xAA000000),
                    blurRadius: Responsive.wp(18),
                    offset: Offset(0, 2)),
              ],
            ),
          ),
          if (description.isNotEmpty) ...[
            SizedBox(height: Responsive.wp(8)),
            Text(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.82),
                fontSize: Responsive.sp(13.5),
                fontWeight: FontWeight.w500,
                height: 1.38,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final Color tint;
  final bool filled;

  const _MetaChip({
    required this.label,
    required this.tint,
    required this.filled,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Responsive.wp(999)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(10), vertical: Responsive.pp(6)),
          decoration: BoxDecoration(
            color: filled ? tint : Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(Responsive.wp(999)),
            border: Border.all(
              color:
                  filled ? Colors.transparent : Colors.white.withOpacity(0.18),
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: Responsive.sp(11),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _StoryIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _StoryIconButton({
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Responsive.wp(16)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: IconButton(
          onPressed: onPressed,
          style: IconButton.styleFrom(
            fixedSize: Size(Responsive.wp(46), Responsive.wp(46)),
            backgroundColor: Colors.white.withOpacity(0.12),
            side: BorderSide(color: Colors.white.withOpacity(0.20)),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(16))),
          ),
          icon: Icon(icon, color: Colors.white, size: Responsive.sp(22)),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.pp(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: Responsive.wp(72),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.52),
                fontSize: Responsive.sp(12),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: Responsive.sp(13),
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final Animation<double> animation;
  final bool filled;
  final bool active;
  final Color tint;
  final bool paused;

  const _ProgressBar({
    required this.animation,
    required this.filled,
    required this.active,
    required this.tint,
    required this.paused,
  });

  @override
  Widget build(BuildContext context) {
    final trackColor = active
        ? Color.lerp(tint, Colors.white, 0.18)!
            .withOpacity(paused ? 0.48 : 0.34)
        : Colors.white.withOpacity(filled ? 0.34 : 0.14);

    return ClipRRect(
      borderRadius: BorderRadius.circular(Responsive.wp(3)),
      child: SizedBox(
        height: active ? 5 : 4,
        child: Stack(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: trackColor,
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: tint.withOpacity(0.32),
                          blurRadius: Responsive.wp(8),
                          spreadRadius: Responsive.wp(1),
                        ),
                      ]
                    : null,
              ),
              child: const SizedBox.expand(),
            ),
            AnimatedBuilder(
              animation: animation,
              builder: (_, __) {
                final v = filled ? 1.0 : (active ? animation.value : 0.0);
                return FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: v,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white,
                          Color.lerp(tint, Colors.white, 0.28) ?? tint,
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (active)
              AnimatedBuilder(
                animation: animation,
                builder: (_, __) {
                  return Align(
                    alignment: Alignment(
                      ((animation.value.clamp(0.0, 1.0) * 2) - 1),
                      0,
                    ),
                    child: Container(
                      width: Responsive.wp(5),
                      height: Responsive.wp(5),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(Responsive.wp(999)),
                        boxShadow: [
                          BoxShadow(
                            color: tint.withOpacity(0.6),
                            blurRadius: Responsive.wp(8),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _StoryBackdrop extends StatelessWidget {
  final Color tint;
  final String? imageUrl;

  const _StoryBackdrop({required this.tint, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(tint, const Color(0xFF10131A), 0.64) ??
                    const Color(0xFF10131A),
                const Color(0xFF05070B),
              ],
            ),
          ),
        ),
        if (imageUrl != null && imageUrl!.isNotEmpty)
          Positioned.fill(
            child: Transform.scale(
              scale: 1.08,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Image.network(
                  imageUrl!,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  color: Colors.white.withOpacity(0.22),
                  colorBlendMode: BlendMode.lighten,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tint.withOpacity(0.18),
                  const Color(0x3305070B),
                  const Color(0xEE05070B),
                ],
                stops: const [0.0, 0.42, 1.0],
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: IgnorePointer(
            child: Container(
              height: Responsive.wp(180),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xCC000000),
                    Color(0x33000000),
                    Colors.transparent
                  ],
                  stops: [0.0, 0.56, 1.0],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: Responsive.wp(330),
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.0, 0.42, 1.0],
                  colors: [
                    Colors.transparent,
                    Color(0x99000000),
                    Color(0xF2000000),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.6, -0.76),
                radius: 0.9,
                colors: [
                  tint.withOpacity(0.24),
                  Colors.transparent,
                ],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
