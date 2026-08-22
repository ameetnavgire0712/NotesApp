import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'recap_api.dart';
import 'recap_models.dart';

/// In-memory cache for the "this week" recap shown on the Home screen.
///
/// Why this exists: HomeScreen is behind a GoRouter `NoTransitionPage`, so
/// tapping the Home bottom-nav tab rebuilds `_HomeScreenState` from scratch.
/// Before this provider, the recap was held in a `Future<RecapPayload?>` field
/// on that State — which meant every Home tab tap re-hit
/// `/api/v1/recap?period=week`. Storing it in a Riverpod StateNotifier keeps
/// the payload alive across widget rebuilds, so:
///   - First Home visit → fetch once, cache.
///   - Subsequent tab taps → reuse cached payload, no network call.
///   - Pull-to-refresh → explicit `refresh()` re-fetches.
///
/// This is memory-only. On a cold app launch the cache is empty and we fetch
/// again, which is fine — recap generation is cheap and the worker itself has
/// server-side caching keyed by period_start.
class HomeRecapState {
  final RecapPayload? payload;
  final bool isLoading;
  final Object? error;

  const HomeRecapState({
    this.payload,
    this.isLoading = false,
    this.error,
  });

  HomeRecapState copyWith({
    RecapPayload? payload,
    bool? isLoading,
    Object? error,
    bool clearError = false,
  }) {
    return HomeRecapState(
      payload: payload ?? this.payload,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  bool get hasPayload => payload != null;
}

class HomeRecapNotifier extends StateNotifier<HomeRecapState> {
  HomeRecapNotifier() : super(const HomeRecapState());

  final RecapApi _api = RecapApi();

  /// Fetch only if we don't already have a payload cached. Safe to call from
  /// every HomeScreen.initState — it's a no-op after the first successful load.
  Future<void> loadIfNeeded() async {
    if (state.hasPayload || state.isLoading) return;
    await _fetch(refresh: false);
  }

  /// Force a re-fetch. Called from pull-to-refresh on Home.
  Future<void> refresh() async {
    await _fetch(refresh: true);
  }

  Future<void> _fetch({required bool refresh}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final payload = await _api.fetch(RecapPeriod.week, refresh: refresh);
      // Preserve the previous payload if the network call returned null
      // (e.g. unauthenticated cold-open) so we don't clear the strip.
      state = HomeRecapState(
        payload: payload ?? state.payload,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }
}

final homeRecapProvider =
    StateNotifierProvider<HomeRecapNotifier, HomeRecapState>(
  (ref) => HomeRecapNotifier(),
);
