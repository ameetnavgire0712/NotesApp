import 'package:flutter/material.dart';

/// Responsive scaling utility based on a 375dp design width (iPhone SE baseline).
/// Use [sp] for font sizes, [wp] for widths/heights, [pp] for padding/margins.
class Responsive {
  Responsive._();

  static double _textScale = 1.0;
  static double _scaleFactor = 1.0;
  static double _paddingScale = 1.0;
  static double _width = 375;
  static double _height = 812;

  /// Call once at the top of your build method or in MaterialApp builder.
  static void init(BuildContext context) {
    final size = MediaQuery.of(context).size;
    _width = size.width;
    _height = size.height;
    _scaleFactor = (_width / 375).clamp(0.8, 1.3);
    _textScale = (_width / 375).clamp(0.85, 1.15);
    _paddingScale = (_width / 375).clamp(0.75, 1.2);
  }

  /// Scale font sizes (scales less aggressively to stay readable).
  static double sp(double size) => size * _textScale;

  /// Scale widths / heights.
  static double wp(double size) => size * _scaleFactor;

  /// Scale padding / margins.
  static double pp(double size) => size * _paddingScale;

  /// Screen width.
  static double get width => _width;

  /// Screen height.
  static double get height => _height;

  /// True for narrow phones (< 360dp).
  static bool get isNarrow => _width < 360;

  /// True for short phones (< 700dp).
  static bool get isShort => _height < 700;
}
