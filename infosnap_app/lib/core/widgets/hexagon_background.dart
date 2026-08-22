import 'package:flutter/material.dart';

/// Honeycomb hexagon background matching the web dashboard SVG pattern exactly.
///
/// Web CSS (dashboard-loveable.css .main-content):
///   SVG viewBox 60×52, 3 hexagons per tile creating a sparse honeycomb:
///     Path 1: M20 9l10-5.77 10 5.77v11.55L30 26.3 20 20.55V9z
///     Path 2: M50 35l10-5.77 10 5.77v11.55L60 52.3 50 46.55V35z
///     Path 3: M-10 35l10-5.77 10 5.77v11.55L0 52.3-10 46.55V35z
///   color: #f59e0b  stroke-opacity: 0.15  stroke-width: Responsive.wp(1)
class HexagonBackground extends StatelessWidget {
  final Color? color;
  final double? opacity;
  final bool showGradient;

  const HexagonBackground({
    super.key,
    this.color,
    this.opacity,
    this.showGradient = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Higher opacity for light mode so hexagons are more visible
    final effectiveOpacity = opacity ?? (isDark ? 0.07 : 0.15);
    final effectiveColor =
        (color ?? const Color(0xFFF59E0B)).withOpacity(effectiveOpacity);
    return CustomPaint(
      painter: _HexagonPainter(
        color: effectiveColor,
        showGradient: showGradient,
        isDark: isDark,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _HexagonPainter extends CustomPainter {
  final Color color;
  final bool showGradient;
  final bool isDark;

  _HexagonPainter({
    required this.color,
    required this.showGradient,
    required this.isDark,
  });

  // Exact web SVG tile size: 60×52
  static const double _tileW = 60.0;
  static const double _tileH = 52.0;

  // 3 hexagons per tile — exact vertices from the web SVG paths.
  // Each hexagon is ~20 wide × ~23 tall, spaced within the 60×52 tile.
  //
  // Path 1 (top-center): M20,9 → (30,3.23) → (40,9) → (40,20.55) → (30,26.3) → (20,20.55)
  static const List<Offset> _hex1 = [
    Offset(20, 9),
    Offset(30, 3.23),
    Offset(40, 9),
    Offset(40, 20.55),
    Offset(30, 26.3),
    Offset(20, 20.55),
  ];

  // Path 2 (bottom-right, extends past tile edge — tiling handles overlap):
  // M50,35 → (60,29.23) → (70,35) → (70,46.55) → (60,52.3) → (50,46.55)
  static const List<Offset> _hex2 = [
    Offset(50, 35),
    Offset(60, 29.23),
    Offset(70, 35),
    Offset(70, 46.55),
    Offset(60, 52.3),
    Offset(50, 46.55),
  ];

  // Path 3 (bottom-left, extends past tile edge):
  // M-10,35 → (0,29.23) → (10,35) → (10,46.55) → (0,52.3) → (-10,46.55)
  static const List<Offset> _hex3 = [
    Offset(-10, 35),
    Offset(0, 29.23),
    Offset(10, 35),
    Offset(10, 46.55),
    Offset(0, 52.3),
    Offset(-10, 46.55),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (showGradient) {
      final rect = Offset.zero & size;
      final gradientPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [
                  Color(0x2210B981),
                  Color(0x08000000),
                  Color(0x1814B8A6),
                ]
              : const [
                  Color(0x28E1F8EB),
                  Color(0x18FFF7E6),
                  Color(0x20F0FDF4),
                ],
        ).createShader(rect);
      canvas.drawRect(rect, gradientPaint);
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final int cols = (size.width / _tileW).ceil() + 2;
    final int rows = (size.height / _tileH).ceil() + 2;

    for (int row = -1; row < rows; row++) {
      for (int col = -1; col < cols; col++) {
        final double tx = col * _tileW;
        final double ty = row * _tileH;
        // Clip to tile bounds so edge hexagons don't overlap adjacent tiles
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(tx, ty, _tileW, _tileH));
        _drawHexagon(canvas, tx, ty, _hex1, paint);
        _drawHexagon(canvas, tx, ty, _hex2, paint);
        _drawHexagon(canvas, tx, ty, _hex3, paint);
        canvas.restore();
      }
    }
  }

  void _drawHexagon(
      Canvas canvas, double tx, double ty, List<Offset> points, Paint paint) {
    final path = Path();
    for (int i = 0; i < points.length; i++) {
      final double x = tx + points[i].dx;
      final double y = ty + points[i].dy;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _HexagonPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.showGradient != showGradient ||
      oldDelegate.isDark != isDark;
}

class SoftGridBackground extends StatelessWidget {
  final List<Color>? colors;
  final double opacity;

  const SoftGridBackground({
    super.key,
    this.colors,
    this.opacity = 1,
  });

  @override
  Widget build(BuildContext context) {
    // Grid removed from all screens (2026-08). Kept as a no-op widget so
    // every existing `SoftGridBackground()` call site continues to compile
    // and layout the same — the background is now just transparent. If the
    // grid ever needs to come back, restore the CustomPaint here.
    return const SizedBox.expand();
  }
}

class _SoftGridPainter extends CustomPainter {
  final List<Color> colors;
  final bool isDark;
  final double opacity;

  const _SoftGridPainter({
    required this.colors,
    required this.isDark,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final gradientPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors.map((color) => color.withOpacity(opacity)).toList(),
      ).createShader(rect);
    canvas.drawRect(rect, gradientPaint);

    final gridPaint = Paint()
      ..color = (isDark ? Colors.white : Colors.black).withOpacity(
        isDark ? 0.045 : 0.04,
      )
      ..strokeWidth = 1;
    const step = 28.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SoftGridPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.isDark != isDark ||
      oldDelegate.opacity != opacity;
}
