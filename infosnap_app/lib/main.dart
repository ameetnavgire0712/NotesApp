import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/services/auth_service.dart';
import 'core/services/push_notification_service.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/app_messenger.dart';
import 'core/utils/responsive.dart';
import 'navigation/app_router.dart';

/// Tracks if user was already logged in at app start
final initialAuthStateProvider = StateProvider<bool>((ref) => false);

/// Theme mode provider - controls dark/light mode across app
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.light);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase from android/app/google-services.json.
  await Firebase.initializeApp();

  // Load persisted theme mode
  final prefs = await SharedPreferences.getInstance();
  // One-time migration: reset any pre-saved 'dark' default to 'light'
  final themeVersion = prefs.getInt('theme_version') ?? 0;
  if (themeVersion < 1) {
    // First launch after this update — default to light unless user had explicitly set dark via settings
    // (old default was dark, new default is light; reset to light for everyone)
    await prefs.setString('theme_mode', 'light');
    await prefs.setInt('theme_version', 1);
  }
  final savedTheme = prefs.getString('theme_mode') ?? 'light';
  final initialThemeMode =
      savedTheme == 'dark' ? ThemeMode.dark : ThemeMode.light;

  // Initialize Supabase
  await AuthService.initialize();
  await PushNotificationService.initialize();

  // Check if user is already logged in
  final isLoggedIn = Supabase.instance.client.auth.currentSession != null;

  runApp(ProviderScope(
    overrides: [
      initialAuthStateProvider.overrideWith((ref) => isLoggedIn),
      themeModeProvider.overrideWith((ref) => initialThemeMode),
    ],
    child: const InfoSnapApp(),
  ));
}

class InfoSnapApp extends ConsumerWidget {
  const InfoSnapApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'infoSnap.ai',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      themeAnimationDuration: Duration.zero,
      routerConfig: router,
      builder: (context, child) {
        Responsive.init(context);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
