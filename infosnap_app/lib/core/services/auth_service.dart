import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';

/// Auth service provider
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// Auth state provider
final authUserProvider = StateNotifierProvider<AuthNotifier, AuthUser?>((ref) {
  return AuthNotifier(ref.read(authServiceProvider));
});

/// Simple user model
class AuthUser {
  final String id;
  final String email;
  final String? displayName;
  final String? photoUrl;

  AuthUser({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
  });

  factory AuthUser.fromSupabaseUser(User user) {
    final metadata = user.userMetadata;
    return AuthUser(
      id: user.id,
      email: user.email ?? '',
      displayName: metadata?['full_name'] ?? metadata?['name'],
      photoUrl: metadata?['avatar_url'] ?? metadata?['picture'],
    );
  }
}

/// Auth state notifier
class AuthNotifier extends StateNotifier<AuthUser?> {
  final AuthService _authService;

  AuthNotifier(this._authService) : super(null) {
    _checkCurrentUser();
    _listenToAuthChanges();
  }

  void _listenToAuthChanges() {
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final session = data.session;
      if (session != null) {
        state = AuthUser.fromSupabaseUser(session.user);
      } else {
        state = null;
      }
    });
  }

  Future<void> _checkCurrentUser() async {
    final user = await _authService.getCurrentUser();
    state = user;
  }

  Future<AuthUser?> signInWithGoogle() async {
    final user = await _authService.signInWithGoogle();
    state = user;
    return user;
  }

  Future<void> signOut() async {
    await _authService.signOut();
    state = null;
  }

  /// Refresh local state from the current Supabase session. Call this after
  /// updating user metadata (e.g. avatar_url) so listeners see the new value.
  void refresh() {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      state = AuthUser.fromSupabaseUser(user);
    }
  }

  /// Override the current user's photo URL locally (e.g. immediately after
  /// uploading a new avatar) so UIs reading `authUserProvider` reflect it.
  void setPhotoUrl(String? photoUrl) {
    final current = state;
    if (current == null) return;
    state = AuthUser(
      id: current.id,
      email: current.email,
      displayName: current.displayName,
      photoUrl: photoUrl,
    );
  }
}

/// Supabase Auth service with Native Google Sign-In
///
/// Uses google_sign_in package for native Google authentication.
/// This never leaves the app - no browser, no network issues!
class AuthService {
  static bool _initialized = false;

  // Web Client ID from Google Cloud Console / Supabase Dashboard
  // Get this from: Supabase Dashboard > Authentication > Providers > Google > Client ID (Web)
  static const String _webClientId =
      '18034238863-ne2h8e6lepv7k1f2o1dgpfv995uq1n4g.apps.googleusercontent.com';

  /// Initialize Supabase and Google Sign-In
  static Future<void> initialize() async {
    if (_initialized) return;

    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        autoRefreshToken: true,
      ),
    );

    // Initialize native Google Sign-In for mobile
    if (!kIsWeb) {
      await GoogleSignIn.instance.initialize(
        serverClientId: _webClientId,
      );
      debugPrint('NATIVE_GOOGLE: GoogleSignIn initialized');
    }

    _initialized = true;
    debugPrint('NATIVE_GOOGLE: Supabase initialized');
  }

  SupabaseClient get _client => Supabase.instance.client;

  /// Sign in with Google using native SDK
  /// This uses the device's Google account - no browser needed!
  Future<AuthUser?> signInWithGoogle() async {
    try {
      debugPrint('NATIVE_GOOGLE: Starting native Google Sign-In...');

      // For web, use OAuth flow
      if (kIsWeb) {
        final uri = Uri.base;
        final origin =
            '${uri.scheme}://${uri.host}${uri.port != 80 && uri.port != 443 ? ':${uri.port}' : ''}';
        debugPrint('OAuth redirect URL (web): $origin');

        final response = await _client.auth.signInWithOAuth(
          OAuthProvider.google,
          redirectTo: origin,
          queryParams: {'prompt': 'select_account'},
        );
        debugPrint('OAuth signInWithOAuth returned: $response');
        return null; // Web will redirect
      }

      // Native Google Sign-In for mobile with timeout
      debugPrint('NATIVE_GOOGLE: Calling authenticate()...');

      GoogleSignInAccount? googleUser;
      try {
        googleUser = await GoogleSignIn.instance
            .authenticate()
            .timeout(const Duration(seconds: 60), onTimeout: () {
          debugPrint('NATIVE_GOOGLE: authenticate() timed out after 60s');
          throw Exception('Google Sign-In timed out');
        });
      } catch (authError, authStack) {
        debugPrint('NATIVE_GOOGLE: authenticate() threw: $authError');
        debugPrint('NATIVE_GOOGLE: authenticate() stack: $authStack');
        rethrow;
      }

      debugPrint('NATIVE_GOOGLE: authenticate() returned: $googleUser');

      if (googleUser == null) {
        debugPrint('NATIVE_GOOGLE: User cancelled or no account selected');
        return null;
      }

      debugPrint('NATIVE_GOOGLE: Got Google user: ${googleUser.email}');

      // Get the ID token
      debugPrint('NATIVE_GOOGLE: Getting authentication...');
      final auth = await googleUser.authentication;
      final idToken = auth.idToken;

      debugPrint(
          'NATIVE_GOOGLE: idToken is ${idToken != null ? "present" : "NULL"}');

      if (idToken == null) {
        debugPrint('NATIVE_GOOGLE: No ID token received');
        throw Exception('No ID token received from Google');
      }

      debugPrint('NATIVE_GOOGLE: Got ID token, signing in to Supabase...');

      // Sign in to Supabase with the Google ID token
      final response = await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );

      final user = response.user;

      if (user != null) {
        debugPrint('NATIVE_GOOGLE: Success! User: ${user.email}');
        return AuthUser.fromSupabaseUser(user);
      } else {
        debugPrint('NATIVE_GOOGLE: signInWithIdToken returned null user');
        return null;
      }
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        debugPrint('NATIVE_GOOGLE: User cancelled sign in');
        return null;
      }
      debugPrint(
          'NATIVE_GOOGLE: GoogleSignIn error: ${e.code} - ${e.description}');
      rethrow;
    } catch (e, stack) {
      debugPrint('NATIVE_GOOGLE: Error: $e');
      debugPrint('NATIVE_GOOGLE: Stack trace: $stack');
      rethrow;
    }
  }

  /// Get current signed in user
  Future<AuthUser?> getCurrentUser() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      return AuthUser.fromSupabaseUser(user);
    } catch (e) {
      debugPrint('Get current user error: $e');
      return null;
    }
  }

  /// Sign out from both Supabase and Google
  Future<void> signOut() async {
    try {
      if (!kIsWeb) {
        await GoogleSignIn.instance.disconnect();
      }
      await _client.auth.signOut();
    } catch (e) {
      debugPrint('Sign out error: $e');
    }
  }

  /// Get current access token for API calls
  String? get accessToken => _client.auth.currentSession?.accessToken;
}
