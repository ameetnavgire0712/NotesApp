// ignore_for_file: deprecated_member_use
// Recap mosaic screen: a Google-Photos-style tile grid of LLM-categorized
// notes from the last day / week / month. Tapping a tile opens the stories
// player (recap_stories_screen.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';
import '../../core/utils/responsive.dart';

import 'recap_api.dart';
import 'recap_models.dart';
import 'recap_stories_screen.dart';

final _recapPeriodProvider =
    StateProvider<RecapPeriod>((_) => RecapPeriod.week);

final _recapPayloadProvider =
    FutureProvider.autoDispose<RecapPayload?>((ref) async {
  final period = ref.watch(_recapPeriodProvider);
  return RecapApi().fetch(period);
});

class RecapScreen extends ConsumerStatefulWidget {
  /// If non-null, render this payload directly (e.g. when opening a saved
  /// recap from the profile page). Otherwise we fetch from the worker.
  final RecapPayload? prebuilt;
  const RecapScreen({super.key, this.prebuilt});

  @override
  ConsumerState<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends ConsumerState<RecapScreen> {
  // Light theme aligned with home screen.
  static const Color _bg = Color(0xFFF8FAF9); // AppColors.lightBackground
  static const Color _surface = Color(0xFFFFFFFF); // white cards
  static const Color _ink = Color(0xFF1F2937); // textDark
  static const Color _inkMuted = Color(0xFF6B7280);
  static const Color _border = Color(0xFFE5E7EB);
  static const Color _primary = Color(0xFF22B573); // brand green

  // Variable tile heights are derived from the image's native aspect ratio
  // (see `_CategoryTile` — true Pinterest-style masonry).

  @override
  Widget build(BuildContext context) {
    if (widget.prebuilt != null) {
      return _scaffold(_renderPayload(widget.prebuilt!));
    }
    final period = ref.watch(_recapPeriodProvider);
    final async = ref.watch(_recapPayloadProvider);

    return _scaffold(
      async.when(
        loading: () => _loading(period),
        error: (e, _) => _errorState(e.toString()),
        data: (p) {
          if (p == null) return _errorState('Could not load recap');
          if (p.empty) return _emptyState(period);
          return _renderPayload(p);
        },
      ),
    );
  }

  Widget _scaffold(Widget body) {
    return Scaffold(
      backgroundColor: _bg,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.85),
            radius: 1.2,
            colors: [
              Color(0xFFFFF7E6), // warm amber wash at top
              Color(0xFFEAF7F1), // soft mint mid
              Color(0xFFF8FAF9), // base
            ],
            stops: [0.0, 0.45, 1.0],
          ),
        ),
        child: SafeArea(child: body),
      ),
    );
  }

  // ───────────────────────── header ─────────────────────────
  Widget _header(BuildContext context,
      {required String windowLabel, required int total}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(Responsive.pp(8), Responsive.pp(4),
          Responsive.pp(8), Responsive.pp(6)),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: _ink),
            onPressed: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/home');
              }
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your recap',
                    style: TextStyle(
                        color: _ink,
                        fontSize: Responsive.sp(22),
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5)),
                Text('$windowLabel · $total snaps',
                    style: TextStyle(
                        color: _inkMuted, fontSize: Responsive.sp(12))),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh, color: _ink),
            onPressed: () => ref.invalidate(_recapPayloadProvider),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── period switcher ─────────────────────────
  Widget _periodSwitcher() {
    final selected = ref.watch(_recapPeriodProvider);
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(16), vertical: Responsive.pp(4)),
      child: Container(
        padding: EdgeInsets.all(Responsive.pp(4)),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(Responsive.wp(14)),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: RecapPeriod.values.map((p) {
            final isSel = p == selected;
            return Expanded(
              child: GestureDetector(
                onTap: () => ref.read(_recapPeriodProvider.notifier).state = p,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: isSel ? _ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(Responsive.wp(10)),
                  ),
                  child: Center(
                    child: Text(
                      p.shortLabel,
                      style: TextStyle(
                        color: isSel ? Colors.white : _ink,
                        fontSize: Responsive.sp(13),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ───────────────────────── payload renderer ─────────────────────────
  Widget _renderPayload(RecapPayload p) {
    final windowLabel = _formatWindow(p);
    return Column(
      children: [
        _header(context, windowLabel: windowLabel, total: p.totalNotes),
        if (widget.prebuilt == null) _periodSwitcher(),
        Expanded(
          child: _mosaic(p.categories),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: Text(
            'Tap any tile · Categories by AI',
            style: TextStyle(
                color: _inkMuted.withOpacity(0.7), fontSize: Responsive.sp(11)),
          ),
        ),
      ],
    );
  }

  Widget _mosaic(List<RecapCategory> cats) {
    if (cats.isEmpty) {
      return const SizedBox.shrink();
    }
    return MasonryGridView.count(
      padding: EdgeInsets.fromLTRB(Responsive.pp(10), Responsive.pp(6),
          Responsive.pp(10), Responsive.pp(24)),
      crossAxisCount: 2,
      mainAxisSpacing: 14,
      crossAxisSpacing: 10,
      itemCount: cats.length,
      itemBuilder: (ctx, i) => _CategoryTile(
        category: cats[i],
        onTap: () => _openStories(cats[i]),
      ),
    );
  }

  // ───────────────────────── interactions ─────────────────────────
  void _openStories(RecapCategory cat) {
    // Push as an in-shell route so the bottom footer remains accessible.
    context.push('/recap/stories', extra: cat);
  }

  // ───────────────────────── helpers ─────────────────────────
  String _formatWindow(RecapPayload p) {
    String human(String ymd) {
      final d = DateTime.tryParse(ymd);
      if (d == null) return ymd;
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
      return '${months[d.month - 1]} ${d.day}';
    }

    if (p.period == RecapPeriod.day) return human(p.periodStart);
    return '${human(p.periodStart)} – ${human(p.periodEnd)}';
  }

  // ───────────────────────── states ─────────────────────────
  Widget _loading(RecapPeriod period) {
    return Column(
      children: [
        _header(context, windowLabel: period.label, total: 0),
        _periodSwitcher(),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: _primary),
                SizedBox(height: Responsive.wp(16)),
                Text('Categorizing your snaps…',
                    style: TextStyle(
                        color: _inkMuted, fontSize: Responsive.sp(13))),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorState(String msg) {
    return Column(
      children: [
        _header(context, windowLabel: '—', total: 0),
        _periodSwitcher(),
        Expanded(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(Responsive.pp(32)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_off,
                    color: _inkMuted,
                    size: Responsive.sp(48),
                  ),
                  SizedBox(height: Responsive.wp(12)),
                  Text('Could not load your recap',
                      style: TextStyle(
                          color: _ink,
                          fontSize: Responsive.sp(16),
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: Responsive.wp(6)),
                  Text(msg,
                      style: TextStyle(
                          color: _inkMuted, fontSize: Responsive.sp(12)),
                      textAlign: TextAlign.center),
                  SizedBox(height: Responsive.wp(16)),
                  TextButton(
                    onPressed: () => ref.invalidate(_recapPayloadProvider),
                    child: Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyState(RecapPeriod period) {
    return Column(
      children: [
        _header(context, windowLabel: period.label, total: 0),
        _periodSwitcher(),
        Expanded(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(Responsive.pp(32)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('🌱', style: TextStyle(fontSize: Responsive.sp(56))),
                  SizedBox(height: Responsive.wp(16)),
                  Text('Nothing to recap yet',
                      style: TextStyle(
                          color: _ink,
                          fontSize: Responsive.sp(18),
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: Responsive.wp(6)),
                  Text(
                    'Save some snaps in this window and check back. Your recap writes itself.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: _inkMuted,
                        fontSize: Responsive.sp(13),
                        height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Category tile — true Pinterest-style masonry. The tile sizes itself by the
// thumbnail's native aspect ratio (portrait IG reels stay tall, landscape
// YouTube thumbs stay wide). The category label sits inside the image as a
// glassy overlay so the tile is one cohesive piece of artwork.
// ─────────────────────────────────────────────────────────────────────────────
class _CategoryTile extends StatefulWidget {
  final RecapCategory category;
  final VoidCallback onTap;
  const _CategoryTile({required this.category, required this.onTap});

  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
  static const Color _ink = Color(0xFF1F2937);
  static const Color _inkMuted = Color(0xFF6B7280);
  static const Color _surface = Color(0xFFFFFFFF);
  static const Color _border = Color(0xFFE5E7EB);

  // Default aspect ratio used while the image is loading or if it fails.
  // 4:5 reads as a balanced portrait card — works for both wide and tall
  // content and keeps the grid visually pleasant during initial paint.
  static const double _placeholderAspect = 0.82; // portrait-ish for empty tiles

  // A small boost keeps thumbnails lively without making the wall feel blown out.
  static const ColorFilter _vibrancy = ColorFilter.matrix(<double>[
    1.05,
    0.0,
    0.0,
    0,
    8,
    0.0,
    1.05,
    0.0,
    0,
    8,
    0.0,
    0.0,
    1.05,
    0,
    8,
    0.0,
    0.0,
    0.0,
    1,
    0,
  ]);

  double? _aspect; // image width / height once resolved
  bool _imageFailed = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageProvider? _provider;

  Color get _tint {
    final hex = widget.category.color.replaceAll('#', '');
    if (hex.length != 6) return const Color(0xFF3B82F6);
    return Color(int.parse('FF$hex', radix: 16));
  }

  String? get _thumbUrl {
    final t = widget.category.coverThumb;
    return (t == null || t.isEmpty) ? null : t;
  }

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _CategoryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category.coverThumb != widget.category.coverThumb) {
      _disposeStream();
      _aspect = null;
      _imageFailed = false;
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _disposeStream();
    super.dispose();
  }

  void _disposeStream() {
    if (_listener != null && _stream != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  void _resolveImage() {
    final url = _thumbUrl;
    if (url == null) return;
    final provider = NetworkImage(url);
    _provider = provider;
    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!mounted) return;
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (h > 0) {
          // Clamp aspect so tiles never look skinny. Min 0.78 keeps even
          // 16:9 thumbnails noticeably tall; max 1.4 prevents super-portrait
          // images from making one tile dwarf the rest.
          setState(() => _aspect = (w / h).clamp(0.78, 1.4));
        }
      },
      onError: (Object _, StackTrace? __) {
        if (!mounted) return;
        setState(() => _imageFailed = true);
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  Widget build(BuildContext context) {
    final aspect =
        _imageFailed ? _placeholderAspect : (_aspect ?? _placeholderAspect);
    return Material(
      color: _surface,
      borderRadius: BorderRadius.circular(Responsive.wp(18)),
      child: InkWell(
        borderRadius: BorderRadius.circular(Responsive.wp(18)),
        onTap: widget.onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(Responsive.wp(18)),
            border: Border.all(
                color: _tint.withOpacity(0.25), width: Responsive.wp(1)),
            boxShadow: [
              // Colored ambient glow keyed to the category tint — gives each
              // tile its own "personality" and makes the wall feel lively.
              BoxShadow(
                color: _tint.withOpacity(0.28),
                blurRadius: Responsive.wp(22),
                spreadRadius: -2,
                offset: Offset(0, Responsive.wp(10)),
              ),
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: Responsive.wp(10),
                offset: Offset(0, Responsive.wp(4)),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Responsive.wp(18)),
            child: AspectRatio(
              aspectRatio: aspect,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Backdrop: real image when available, tinted gradient otherwise.
                  if (_thumbUrl != null && !_imageFailed)
                    ColorFiltered(
                      colorFilter: _vibrancy,
                      child: Image(
                        image: _provider!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => _emojiBackdrop(),
                      ),
                    )
                  else
                    _emojiBackdrop(),

                  // Top sheen — adds a warm tinted "lighting" wash on the
                  // upper third of every tile, even over photos. Subtle
                  // enough to never wash out the content.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: Responsive.wp(90),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              _tint.withOpacity(0.45),
                              _tint.withOpacity(0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Bottom gradient → keeps the label readable on any image.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: Responsive.wp(170),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x00000000),
                            Color(0x80000000),
                            Color(0xF2000000),
                          ],
                          stops: [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  ),

                  // Count chip — top-right, filled with the category tint
                  // and white bold text for vibrant pop.
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _tint,
                        borderRadius: BorderRadius.circular(Responsive.wp(22)),
                        border: Border.all(
                            color: Colors.white.withOpacity(0.9),
                            width: Responsive.wp(1.4)),
                        boxShadow: [
                          BoxShadow(
                            color: _tint.withOpacity(0.55),
                            blurRadius: Responsive.wp(12),
                            offset: Offset(0, Responsive.wp(3)),
                          ),
                        ],
                      ),
                      child: Text(
                        '${widget.category.count}',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: Responsive.sp(11.5),
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),

                  // Label — bottom-left, sitting on the gradient.
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 14,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.category.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: Responsive.sp(15.5),
                            fontWeight: FontWeight.w800,
                            height: 1.18,
                            letterSpacing: -0.15,
                            shadows: [
                              Shadow(
                                  color: Color(0xCC000000),
                                  blurRadius: Responsive.wp(8),
                                  offset: Offset(0, 1)),
                            ],
                          ),
                        ),
                        SizedBox(height: Responsive.wp(4)),
                        Text(
                          '${widget.category.count} ${widget.category.count == 1 ? 'snap' : 'snaps'}',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.92),
                            fontSize: Responsive.sp(12.5),
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                            shadows: [
                              Shadow(
                                  color: Color(0xAA000000),
                                  blurRadius: Responsive.wp(4)),
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
            Color.lerp(_tint, Colors.white, 0.15) ?? _tint,
            _tint,
            Color.lerp(_tint, Colors.black, 0.25) ?? _tint,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Center(
        child: Opacity(
          opacity: 0.55,
          child: Text(
            widget.category.name.characters.isEmpty
                ? '·'
                : widget.category.name.characters.first,
            style: TextStyle(
              fontSize: Responsive.sp(110),
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
