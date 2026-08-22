import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/services/auth_service.dart';
import '../features/splash/intro_screen.dart';
import '../features/splash/splash_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/onboarding/feature_showcase_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/home/home_screen.dart';
import '../features/groups/group_detail_screen.dart';
import '../features/groups/groups_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/notes/notes_screen.dart';
import '../features/notes/note_detail_screen.dart';
import '../features/notes/snap_original_screen.dart';
import '../core/services/api_service.dart';
import '../features/upload/upload_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/newspaper/newspaper_screen.dart';
import '../features/recap/recap_screen.dart';
import '../features/recap/recap_models.dart';
import '../features/recap/recap_stories_screen.dart';
import 'main_shell.dart';

// Auth state provider - derived from actual auth state
final authStateProvider = Provider<bool>((ref) {
  final user = ref.watch(authUserProvider);
  return user != null;
});
final onboardingCompleteProvider = StateProvider<bool>((ref) => false);

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final isIntro = state.matchedLocation == '/';
      final isSplash = state.matchedLocation == '/splash';

      // Always allow intro and splash
      if (isIntro || isSplash) return null;

      // For UI preview purposes, allow all routes
      return null;
    },
    routes: [
      // Animated Intro
      GoRoute(
        path: '/',
        name: 'intro',
        builder: (context, state) => const IntroScreen(),
      ),

      // Splash/Welcome
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),

      // Onboarding
      GoRoute(
        path: '/onboarding',
        name: 'onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),

      // Feature Showcase (can be accessed from settings or onboarding)
      GoRoute(
        path: '/features',
        name: 'features',
        builder: (context, state) => const FeatureShowcaseScreen(),
      ),

      // Login
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),

      // Main app shell with bottom nav (all main screens including home)
      ShellRoute(
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          // Home screen - now inside shell for consistent footer
          GoRoute(
            path: '/home',
            name: 'home',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: '/notes',
            name: 'notes',
            pageBuilder: (context, state) => NoTransitionPage(
              child: NotesScreen(
                shareToGroupId: state.uri.queryParameters['share_to_group'],
                shareToGroupName: state.uri.queryParameters['group_name'],
                initialTag: state.uri.queryParameters['tag'],
                initialType: state.uri.queryParameters['type'],
              ),
            ),
            routes: [
              GoRoute(
                path: ':noteId',
                name: 'note-detail',
                builder: (context, state) => NoteDetailScreen(
                  noteId: state.pathParameters['noteId']!,
                  note: state.extra as Note?,
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/chat',
            name: 'chat',
            pageBuilder: (context, state) {
              final query = state.uri.queryParameters['q'];
              final tagsParam = state.uri.queryParameters['tags'];
              final initialTags = tagsParam != null && tagsParam.isNotEmpty
                  ? tagsParam.split(',')
                  : <String>[];
              final anchoredNoteId = state.uri.queryParameters['note_id'];
              final anchoredNoteTitle = state.uri.queryParameters['note_title'];
              return NoTransitionPage(
                  child: ChatScreen(
                initialQuery: query,
                initialTags: initialTags,
                anchoredNoteId: anchoredNoteId,
                anchoredNoteTitle: anchoredNoteTitle,
              ));
            },
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: SettingsScreen()),
          ),
          GoRoute(
            path: '/newspaper',
            name: 'newspaper',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: NewspaperScreen()),
          ),
          GoRoute(
            path: '/recap',
            name: 'recap',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: RecapScreen()),
            routes: [
              GoRoute(
                path: 'stories',
                name: 'recap-stories',
                builder: (context, state) {
                  final cat = state.extra as RecapCategory;
                  return RecapStoriesScreen(category: cat);
                },
              ),
            ],
          ),
          GoRoute(
            path: '/groups',
            name: 'groups',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: GroupsScreen()),
            routes: [
              GoRoute(
                path: ':groupId',
                name: 'group-detail',
                builder: (context, state) => GroupDetailScreen(
                  groupId: state.pathParameters['groupId']!,
                ),
              ),
            ],
          ),
        ],
      ),

      // Upload (modal/standalone)
      GoRoute(
        path: '/upload',
        name: 'upload',
        builder: (context, state) => const UploadScreen(),
      ),

      // Snap original reader — full-screen WebView, no bottom nav
      GoRoute(
        path: '/notes/:noteId/original',
        name: 'snap-original',
        builder: (context, state) => SnapOriginalScreen(
          noteId: state.pathParameters['noteId']!,
          note: state.extra as Note?,
        ),
      ),
    ],
  );
});
