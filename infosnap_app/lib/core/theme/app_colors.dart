import 'package:flutter/material.dart';

/// infoSnap.ai Brand Colors - Matching Website Theme
class AppColors {
  AppColors._();

  // Primary Green - hsl(155, 70%, 45%) = #22B573
  static const Color primary = Color(0xFF22B573);
  static const Color primaryLight = Color(0xFF4DD88C);
  static const Color primaryDark = Color(0xFF1A8A58);
  static const Color primaryDarker = Color(0xFF126640);
  static const Color primaryGlow = Color(0x4022B573);

  // Amber/Gold Accent
  static const Color accent = Color(0xFFF59E0B);
  static const Color amber = Color(0xFFF59E0B);
  static const Color gold = Color(0xFFFFD700);
  static const Color accentLight = Color(0xFFFBBF24);
  static const Color accentLighter = Color(0xFFFEF3C7);

  // Brand text - light mint green for "Snap" on dark backgrounds
  static const Color snapText = Color(0xFF86EFAC);

  // Dark Theme - Matching email template #18181b
  static const Color dark = Color(0xFF18181B);
  static const Color darkBackground = Color(0xFF18181B);
  static const Color darkSurface = Color(0xFF141A17);
  static const Color darkCard = Color(0xFF1A2420);
  static const Color darkElevated = Color(0xFF202924);
  static const Color darkInput = Color(0xFF182018);

  // Light Theme
  // Flat cream — RGB(253, 252, 248). Replaces the prior mint tint + grid so
  // every screen shows a single warm off-white background.
  static const Color background = Color(0xFFFDFCF8);
  static const Color lightBackground = Color(0xFFFDFCF8);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFAFCFB);

  // Text Colors - Dark theme text
  static const Color text = Color(0xFFE8ECE9);
  static const Color textDark = Color(0xFF1F2937);
  static const Color textPrimary = Color(0xFFE8ECE9);
  static const Color textSecondary = Color(0xFF8A9A8F);
  static const Color textMedium = Color(0xFFB5C4BA);
  static const Color textLight = Color(0xFF6B7B70);
  static const Color textMuted = Color(0xFF5A6A5F);

  // Status Colors
  static const Color success = Color(0xFF22B573);
  static const Color error = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);
  static const Color info = Color(0xFF3B82F6);

  // Borders
  static const Color border = Color(0xFF2A3A30);
  static const Color borderLight = Color(0xFFE5E5E5);
  static const Color borderDark = Color(0xFF2A3A30);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, primaryDark],
  );

  static const LinearGradient darkGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [darkBackground, darkSurface],
  );

  static const LinearGradient premiumGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF22B573), Color(0xFF1A8A58), Color(0xFF126640)],
  );

  static const LinearGradient glowGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x2022B573), Color(0x0022B573)],
  );
}
