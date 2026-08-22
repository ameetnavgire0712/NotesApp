import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;
import '../../core/services/auth_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _isSigningIn = false;
  bool _navigated = false;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();

    // Listen to Supabase auth state changes for OAuth callback
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.signedIn && data.session != null) {
        _navigateToHome();
      }
    });

    // Check if already logged in
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkExistingSession();
    });
  }

  void _checkExistingSession() {
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null && mounted) {
      _navigateToHome();
    }
  }

  void _navigateToHome() {
    if (_navigated || !mounted) return;
    _navigated = true;
    context.go('/home');
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleGoogleSignIn() async {
    if (_isSigningIn || _navigated) return;

    setState(() => _isSigningIn = true);
    HapticFeedback.mediumImpact();

    try {
      // Start OAuth flow - this opens browser
      final user = await ref.read(authUserProvider.notifier).signInWithGoogle();

      // If we got a user immediately, navigate
      if (user != null && mounted && !_navigated) {
        _navigateToHome();
        return;
      }

      // On mobile, wait for OAuth callback via deep link (max 30 seconds)
      for (int i = 0; i < 60 && mounted && !_navigated; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final session = Supabase.instance.client.auth.currentSession;
        if (session != null) {
          _navigateToHome();
          return;
        }
      }

      // Timeout
      if (mounted && !_navigated) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sign in timed out. Please try again.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sign in error: $e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSigningIn = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch for auth state changes via Riverpod - backup for direct Supabase subscription
    ref.listen<AuthUser?>(authUserProvider, (previous, next) {
      if (next != null && mounted && !_navigated) {
        debugPrint(
            'SplashScreen: Riverpod auth state changed, user logged in, navigating to home');
        _navigateToHome();
      }
    });

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: Stack(
        children: [
          Positioned.fill(
            child: const HexagonBackground()
                .animate(onPlay: (controller) => controller.repeat())
                .shimmer(
                    duration: 4000.ms, color: AppColors.amber.withOpacity(0.3)),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: Responsive.pp(24)),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(height: Responsive.isShort ? 24 : 48),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildLogo()
                              .animate()
                              .fadeIn(duration: 400.ms)
                              .scale(
                                  begin: Offset(0.5, 0.5),
                                  curve: Curves.easeOutBack,
                                  duration: 600.ms)
                              .callback(
                                  callback: (_) =>
                                      HapticFeedback.mediumImpact())
                              .then()
                              .animate(
                                  onPlay: (controller) =>
                                      controller.repeat(reverse: true))
                              .moveY(
                                  begin: -4,
                                  end: 4,
                                  duration: 2000.ms,
                                  curve: Curves.easeInOut),
                          SizedBox(width: Responsive.wp(16)),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('info',
                                      style: GoogleFonts.spaceGrotesk(
                                          fontSize: Responsive.sp(42),
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                          letterSpacing: -1.0)),
                                  Text('Snap',
                                      style: GoogleFonts.spaceGrotesk(
                                          fontSize: Responsive.sp(42),
                                          fontWeight: FontWeight.w700,
                                          color: const Color(0xFF86EFAC),
                                          letterSpacing: -1.0)),
                                  Text('.ai',
                                      style: GoogleFonts.spaceGrotesk(
                                          fontSize: Responsive.sp(42),
                                          fontWeight: FontWeight.w300,
                                          color: const Color(0xFF71717A),
                                          letterSpacing: -1.0)),
                                ],
                              ),
                            ),
                          )
                              .animate()
                              .fadeIn(duration: 400.ms, delay: 200.ms)
                              .slideX(
                                  begin: 0.15,
                                  curve: Curves.easeOutBack,
                                  duration: 600.ms,
                                  delay: 200.ms)
                              .callback(
                                  callback: (_) =>
                                      HapticFeedback.lightImpact()),
                        ],
                      ),

                      SizedBox(height: Responsive.wp(16)),

                      // Tagline
                      RichText(
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: GoogleFonts.inter(
                              fontSize: Responsive.sp(18),
                              fontWeight: FontWeight.w500,
                              height: 1.4),
                          children: const [
                            TextSpan(
                                text: 'Save anything, ',
                                style: TextStyle(color: Colors.white)),
                            TextSpan(
                                text: 'Find it instantly.',
                                style: TextStyle(color: Color(0xFF86EFAC))),
                          ],
                        ),
                      )
                          .animate()
                          .fadeIn(duration: 400.ms, delay: 400.ms)
                          .slideY(
                              begin: 0.2,
                              curve: Curves.easeOut,
                              duration: 500.ms,
                              delay: 400.ms),

                      SizedBox(height: Responsive.isShort ? 32 : 56),

                      Column(
                        children: [
                          // Explore Features button with glow
                          Container(
                            width: Responsive.wp(240).clamp(200, 280),
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(12)),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withOpacity(0.4),
                                  blurRadius: Responsive.wp(20),
                                  spreadRadius: Responsive.wp(2),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: () => context.go('/features'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.symmetric(
                                    vertical: Responsive.pp(16)),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                        Responsive.wp(12))),
                                elevation: 0,
                              ),
                              child: Text('Explore Features',
                                  style: GoogleFonts.inter(
                                      fontSize: Responsive.sp(16),
                                      fontWeight: FontWeight.w700)),
                            ),
                          )
                              .animate()
                              .fadeIn(duration: 400.ms, delay: 600.ms)
                              .scale(
                                  begin: Offset(0.9, 0.9),
                                  curve: Curves.easeOutBack,
                                  duration: 600.ms,
                                  delay: 600.ms)
                              .callback(
                                  callback: (_) =>
                                      HapticFeedback.lightImpact()),

                          SizedBox(height: Responsive.wp(16)),

                          // Google Sign in button with subtle glow
                          Container(
                            width: Responsive.wp(240).clamp(200, 280),
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(12)),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withOpacity(0.2),
                                  blurRadius: Responsive.wp(16),
                                  spreadRadius: Responsive.wp(1),
                                ),
                              ],
                            ),
                            child: OutlinedButton(
                              onPressed:
                                  _isSigningIn ? null : _handleGoogleSignIn,
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.symmetric(
                                    vertical: Responsive.pp(16)),
                                side: BorderSide(
                                    color: AppColors.primary.withOpacity(0.5),
                                    width: Responsive.wp(1.5)),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                        Responsive.wp(12))),
                              ),
                              child: _isSigningIn
                                  ? SizedBox(
                                      width: Responsive.wp(20),
                                      height: Responsive.wp(20),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.white),
                                      ),
                                    )
                                  : Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SvgPicture.string(
                                          '''<svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg">
                                        <path d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844c-.209 1.125-.843 2.078-1.796 2.717v2.258h2.908c1.702-1.567 2.684-3.874 2.684-6.615z" fill="#4285F4"/>
                                        <path d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 009 18z" fill="#34A853"/>
                                        <path d="M3.964 10.71A5.41 5.41 0 013.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 000 9c0 1.452.348 2.827.957 4.042l3.007-2.332z" fill="#FBBC05"/>
                                        <path d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 00.957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58z" fill="#EA4335"/>
                                      </svg>''',
                                          width: Responsive.wp(20),
                                          height: Responsive.wp(20),
                                        ),
                                        SizedBox(width: Responsive.wp(10)),
                                        Text('Sign in with Google',
                                            style: GoogleFonts.inter(
                                                fontSize: Responsive.sp(15),
                                                fontWeight: FontWeight.w600,
                                                color: Colors.white)),
                                      ],
                                    ),
                            ),
                          )
                              .animate()
                              .fadeIn(duration: 400.ms, delay: 700.ms)
                              .scale(
                                  begin: Offset(0.9, 0.9),
                                  curve: Curves.easeOutBack,
                                  duration: 600.ms,
                                  delay: 700.ms),
                        ],
                      ),
                      SizedBox(height: Responsive.isShort ? 24 : 48),
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

  Widget _buildLogo() {
    return SizedBox(
      width: Responsive.wp(56),
      height: Responsive.wp(56),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              width: Responsive.wp(40),
              height: Responsive.wp(40),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF22C55E), Color(0xFF15803D)],
                ),
                borderRadius: BorderRadius.circular(Responsive.wp(10)),
              ),
            ),
          ),
          Positioned(
            left: Responsive.wp(12),
            top: Responsive.wp(12),
            child: Container(
              width: Responsive.wp(40),
              height: Responsive.wp(40),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x9922C55E), Color(0xCC16A34A)],
                ),
                borderRadius: BorderRadius.circular(Responsive.wp(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
