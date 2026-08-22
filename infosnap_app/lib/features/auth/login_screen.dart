import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/services/auth_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _isLoading = false;

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);

    try {
      final user = await ref.read(authUserProvider.notifier).signInWithGoogle();
      if (user != null && mounted) {
        context.go('/home');
      } else if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sign-in was cancelled'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(10))),
          ),
        );
      }
    } catch (e) {
      debugPrint('Sign-in error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Sign-in failed: ${e.toString().split("Exception:").last.trim()}'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(10))),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: Stack(
        children: [
          // Hexagon background
          const Positioned.fill(child: HexagonBackground()),
          // Background gradient orbs
          Positioned(
            top: -Responsive.wp(100),
            left: -Responsive.wp(100),
            child: Container(
              width: Responsive.wp(300),
              height: Responsive.wp(300),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.primary.withOpacity(0.15),
                    AppColors.primary.withOpacity(0.05),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -Responsive.wp(50),
            right: -Responsive.wp(50),
            child: Container(
              width: Responsive.wp(200),
              height: Responsive.wp(200),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.primary.withOpacity(0.1),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Main content
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: Responsive.pp(28)),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: Responsive.isShort ? 24 : 50),

                      // Brand header
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'info',
                              style: GoogleFonts.spaceGrotesk(
                                color: AppColors.textPrimary,
                                fontSize: Responsive.sp(36),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Snap',
                              style: GoogleFonts.spaceGrotesk(
                                color: AppColors.primary,
                                fontSize: Responsive.sp(36),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '.ai',
                              style: GoogleFonts.spaceGrotesk(
                                color: AppColors.textSecondary,
                                fontSize: Responsive.sp(36),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ).animate().fadeIn(duration: 600.ms).scale(
                            begin: Offset(0.8, 0.8), curve: Curves.easeOutBack),
                      ),

                      SizedBox(height: Responsive.isShort ? 24 : 40),

                      // Welcome text
                      Center(
                        child: Column(
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'Welcome to ',
                                    style: GoogleFonts.spaceGrotesk(
                                      fontSize: Responsive.sp(28),
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  ShaderMask(
                                    shaderCallback: (bounds) =>
                                        const LinearGradient(
                                      colors: [
                                        AppColors.primary,
                                        AppColors.primaryLight
                                      ],
                                    ).createShader(bounds),
                                    child: Text(
                                      'infoSnap',
                                      style: GoogleFonts.spaceGrotesk(
                                        fontSize: Responsive.sp(28),
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: Responsive.wp(12)),
                            Text(
                              'Sign in to access your snaps\nacross all devices.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: Responsive.sp(15),
                                color: AppColors.textSecondary,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ).animate(delay: 200.ms).fadeIn().slideY(begin: 0.1),

                      SizedBox(height: Responsive.isShort ? 30 : 50),

                      // Google Sign-In button
                      _PremiumAuthButton(
                        onPressed: _isLoading ? null : _signInWithGoogle,
                        icon: 'G',
                        iconWidget: SvgPicture.string(
                          '''<svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <path d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844c-.209 1.125-.843 2.078-1.796 2.717v2.258h2.908c1.702-1.567 2.684-3.874 2.684-6.615z" fill="#4285F4"/>
                        <path d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 009 18z" fill="#34A853"/>
                        <path d="M3.964 10.71A5.41 5.41 0 013.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 000 9c0 1.452.348 2.827.957 4.042l3.007-2.332z" fill="#FBBC05"/>
                        <path d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 00.957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58z" fill="#EA4335"/>
                      </svg>''',
                          width: Responsive.wp(18),
                          height: Responsive.wp(18),
                        ),
                        label: 'Continue with Google',
                        isPrimary: false,
                        isLoading: _isLoading,
                      ).animate(delay: 400.ms).fadeIn().slideY(begin: 0.2),

                      SizedBox(height: Responsive.wp(50)),

                      // Terms
                      Center(
                        child: Text(
                          'By continuing, you agree to our Terms of Service\nand Privacy Policy.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(12),
                            color: AppColors.textMuted,
                            height: 1.5,
                          ),
                        ),
                      ).animate(delay: 700.ms).fadeIn(),

                      SizedBox(height: Responsive.wp(30)),
                    ],
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

class _PremiumAuthButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String icon;
  final Widget? iconWidget;
  final String label;
  final bool isPrimary;
  final bool isLoading;

  const _PremiumAuthButton({
    required this.onPressed,
    required this.icon,
    this.iconWidget,
    required this.label,
    this.isPrimary = true,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: Responsive.wp(58),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Responsive.wp(16)),
        color: isPrimary ? null : Colors.white,
        gradient: isPrimary ? AppColors.premiumGradient : null,
        boxShadow: [
          if (isPrimary)
            BoxShadow(
              color: AppColors.primary.withOpacity(0.3),
              blurRadius: Responsive.wp(20),
              offset: Offset(0, Responsive.wp(8)),
            ),
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: Responsive.wp(10),
            offset: Offset(0, Responsive.wp(4)),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(Responsive.wp(16)),
          child: Center(
            child: isLoading
                ? SizedBox(
                    width: Responsive.wp(24),
                    height: Responsive.wp(24),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(
                        isPrimary ? Colors.white : AppColors.dark,
                      ),
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Google icon
                      Container(
                        width: Responsive.wp(28),
                        height: Responsive.wp(28),
                        decoration: BoxDecoration(
                          color:
                              isPrimary ? Colors.white.withOpacity(0.2) : null,
                          borderRadius: BorderRadius.circular(Responsive.wp(6)),
                        ),
                        child: Center(
                          child: iconWidget ??
                              Text(
                                icon,
                                style: GoogleFonts.inter(
                                  fontSize: Responsive.sp(18),
                                  fontWeight: FontWeight.w700,
                                  color:
                                      isPrimary ? Colors.white : AppColors.dark,
                                ),
                              ),
                        ),
                      ),
                      SizedBox(width: Responsive.wp(12)),
                      Text(
                        label,
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(16),
                          fontWeight: FontWeight.w600,
                          color: isPrimary ? Colors.white : AppColors.dark,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
