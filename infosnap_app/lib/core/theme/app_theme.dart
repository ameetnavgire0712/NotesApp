import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/responsive.dart';
import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  // Text Styles using Space Grotesk for headings, Inter for body
  static TextTheme get _textTheme {
    return TextTheme(
      // Display
      displayLarge: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(57),
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      displayMedium: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(45),
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      displaySmall: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(36),
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      // Headlines
      headlineLarge: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(32),
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      headlineMedium: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(28),
        fontWeight: FontWeight.w600,
        letterSpacing: -0.25,
      ),
      headlineSmall: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(24),
        fontWeight: FontWeight.w600,
      ),
      // Titles
      titleLarge: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(22),
        fontWeight: FontWeight.w600,
      ),
      titleMedium: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(18),
        fontWeight: FontWeight.w600,
      ),
      titleSmall: GoogleFonts.spaceGrotesk(
        fontSize: Responsive.sp(14),
        fontWeight: FontWeight.w600,
      ),
      // Body - Using Inter for readability
      bodyLarge: GoogleFonts.inter(
        fontSize: Responsive.sp(16),
        fontWeight: FontWeight.w400,
        height: 1.6,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: Responsive.sp(14),
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: Responsive.sp(12),
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      // Labels
      labelLarge: GoogleFonts.inter(
        fontSize: Responsive.sp(14),
        fontWeight: FontWeight.w500,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: Responsive.sp(12),
        fontWeight: FontWeight.w500,
      ),
      labelSmall: GoogleFonts.inter(
        fontSize: Responsive.sp(11),
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      ),
    );
  }

  // Light Theme
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primary,
        onPrimary: Colors.white,
        secondary: AppColors.accent,
        onSecondary: Colors.white,
        surface: AppColors.lightSurface,
        onSurface: AppColors.textDark,
        error: AppColors.error,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: AppColors.lightBackground,
      textTheme: _textTheme.apply(
        bodyColor: AppColors.textDark,
        displayColor: AppColors.textDark,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.lightSurface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: Responsive.sp(20),
          fontWeight: FontWeight.w600,
          color: AppColors.textDark,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.lightCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          side: BorderSide(color: AppColors.borderLight),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(24), vertical: Responsive.pp(14)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(8)),
          ),
          textStyle: GoogleFonts.spaceGrotesk(
            fontSize: Responsive.sp(15),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: BorderSide(color: AppColors.primary),
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(24), vertical: Responsive.pp(14)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(8)),
          ),
          textStyle: GoogleFonts.spaceGrotesk(
            fontSize: Responsive.sp(15),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.lightCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(8)),
          borderSide: BorderSide(color: AppColors.borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(8)),
          borderSide: BorderSide(color: AppColors.borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(8)),
          borderSide:
              BorderSide(color: AppColors.primary, width: Responsive.wp(2)),
        ),
        contentPadding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(16), vertical: Responsive.pp(14)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.lightSurface,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.lightCard,
        selectedColor: AppColors.primaryLight.withOpacity(0.3),
        labelStyle: GoogleFonts.inter(fontSize: Responsive.sp(13)),
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(12), vertical: Responsive.pp(8)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(20)),
          side: BorderSide(color: AppColors.borderLight),
        ),
      ),
    );
  }

  // Dark Theme
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        onPrimary: Colors.white,
        secondary: AppColors.accent,
        onSecondary: Colors.white,
        surface: AppColors.darkSurface,
        onSurface: Colors.white,
        error: AppColors.error,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: AppColors.darkBackground,
      textTheme: _textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.darkSurface,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: Responsive.sp(20),
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          side: BorderSide(color: AppColors.borderDark),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(24), vertical: Responsive.pp(14)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(8)),
          ),
          textStyle: GoogleFonts.spaceGrotesk(
            fontSize: Responsive.sp(15),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.darkSurface,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
    );
  }
}
