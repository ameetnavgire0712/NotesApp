import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;
import '../../core/services/auth_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';

class IntroScreen extends ConsumerStatefulWidget {
  const IntroScreen({super.key});

  @override
  ConsumerState<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends ConsumerState<IntroScreen> {
  bool _navigated = false;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();

    // Listen directly to Supabase auth state changes for OAuth callback
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      debugPrint('IntroScreen: Auth event: ${data.event}');
      if (data.event == AuthChangeEvent.signedIn && data.session != null) {
        debugPrint('IntroScreen: signedIn event received, navigating to home');
        _navigateToHome();
      }
    });

    // Check auth state and navigate accordingly (with delay for animation)
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted && !_navigated) {
        _checkAuthAndNavigate();
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  void _navigateToHome() {
    if (_navigated || !mounted) return;
    _navigated = true;
    context.go('/home');
  }

  void _checkAuthAndNavigate() {
    if (_navigated) return;

    // Check Riverpod state first
    final user = ref.read(authUserProvider);
    if (user != null) {
      debugPrint(
          'IntroScreen: User logged in via authUserProvider, navigating to home');
      _navigateToHome();
      return;
    }

    // Also check actual Supabase session
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      debugPrint('IntroScreen: User has active session, navigating to home');
      _navigateToHome();
    } else {
      // On web, check if URL contains auth tokens (OAuth redirect)
      if (kIsWeb) {
        final uri = Uri.base;
        final hasAuthParams = uri.fragment.contains('access_token') ||
            uri.queryParameters.containsKey('code');
        if (hasAuthParams) {
          debugPrint('IntroScreen: Auth params in URL, waiting for session...');
          // Wait a bit more for Supabase to process the tokens
          Future.delayed(const Duration(milliseconds: 1000), () {
            if (mounted && !_navigated) {
              final newSession = Supabase.instance.client.auth.currentSession;
              if (newSession != null) {
                debugPrint(
                    'IntroScreen: Session restored from URL, navigating to home');
                _navigateToHome();
              } else {
                debugPrint(
                    'IntroScreen: No session after waiting, navigating to splash');
                _navigated = true;
                context.go('/splash');
              }
            }
          });
          return;
        }
      }
      debugPrint('IntroScreen: No auth, navigating to splash');
      _navigated = true;
      context.go('/splash');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen for auth state changes (handles OAuth callback redirect)
    ref.listen<AuthUser?>(authUserProvider, (previous, next) {
      if (next != null && mounted && !_navigated) {
        debugPrint(
            'IntroScreen: Auth state changed, user logged in, navigating to home');
        _navigated = true;
        context.go('/home');
      }
    });

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: Stack(
        children: [
          // Hexagon background with amber at 20% opacity
          const HexagonBackground().animate().fadeIn(duration: 800.ms),

          // Centered Zoom & Focus animation
          Center(
            child: _buildZoomFocusAnimation(),
          ),
        ],
      ),
    );
  }

  Widget _buildZoomFocusAnimation() {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Blurred version that fades out as it zooms in
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: _buildLogo(),
        )
            .animate()
            .scale(
              begin: Offset(3, 3),
              end: Offset(1, 1),
              duration: 1200.ms,
              curve: Curves.easeOutExpo,
            )
            .fadeOut(delay: 600.ms, duration: 600.ms),

        // Sharp version that fades in
        _buildLogo()
            .animate()
            .scale(
              begin: Offset(3, 3),
              end: Offset(1, 1),
              duration: 1200.ms,
              curve: Curves.easeOutExpo,
            )
            .fadeIn(delay: 400.ms, duration: 600.ms),
      ],
    );
  }

  Widget _buildLogo() {
    return SizedBox(
      width: Responsive.wp(100),
      height: Responsive.wp(100),
      child: Stack(
        children: [
          // Box 1 - Solid green
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              width: Responsive.wp(55),
              height: Responsive.wp(55),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF22C55E), Color(0xFF15803D)],
                ),
                borderRadius: BorderRadius.circular(Responsive.wp(14)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF22C55E).withAlpha(100),
                    blurRadius: Responsive.wp(20),
                    spreadRadius: Responsive.wp(2),
                  ),
                ],
              ),
            ),
          ),
          // Box 2 - Translucent green
          Positioned(
            left: Responsive.wp(18),
            top: Responsive.wp(18),
            child: Container(
              width: Responsive.wp(55),
              height: Responsive.wp(55),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x9922C55E), Color(0xCC16A34A)],
                ),
                borderRadius: BorderRadius.circular(Responsive.wp(14)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF22C55E).withAlpha(60),
                    blurRadius: Responsive.wp(15),
                    spreadRadius: Responsive.wp(1),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
