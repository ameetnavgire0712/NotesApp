import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'thumbnail_cache_manager.dart';

class AppCacheWarmer {
  AppCacheWarmer._();

  static bool _warming = false;
  static DateTime? _lastWarmAt;

  static Future<void> warmRecentThumbnails({String reason = 'home'}) async {
    final now = DateTime.now();
    if (_warming) return;
    if (_lastWarmAt != null &&
        now.difference(_lastWarmAt!) < const Duration(minutes: 3)) {
      return;
    }

    final api = ApiService();
    if (!api.isAuthenticated) return;

    _warming = true;
    _lastWarmAt = now;

    try {
      debugPrint('[CacheWarmer] warming thumbnails ($reason)');
      final notes = api.cachedRecentNotes;
      final thumbnailUrls = notes
          .map((note) => note.thumbnailUrl?.trim())
          .whereType<String>()
          .where((url) => url.isNotEmpty)
          .toSet()
          .take(32)
          .toList(growable: false);

      await _warmThumbnails(thumbnailUrls);
    } catch (e) {
      debugPrint('[CacheWarmer] warm failed: $e');
    } finally {
      _warming = false;
    }
  }

  static Future<void> warmThumbnailUrls(
    Iterable<String?> urls, {
    String reason = 'notes',
    int limit = 64,
  }) async {
    try {
      final thumbnailUrls = urls
          .map((url) => url?.trim())
          .whereType<String>()
          .where((url) => url.isNotEmpty)
          .toSet()
          .take(limit)
          .toList(growable: false);
      if (thumbnailUrls.isEmpty) return;
      debugPrint(
          '[CacheWarmer] warming ${thumbnailUrls.length} thumbnails ($reason)');
      await _warmThumbnails(thumbnailUrls);
    } catch (e) {
      debugPrint('[CacheWarmer] warm urls failed: $e');
    }
  }

  static Future<void> _warmThumbnails(List<String> urls) async {
    if (urls.isEmpty) return;
    const batchSize = 4;
    final cache = ThumbnailCacheManager.instance;
    for (var i = 0; i < urls.length; i += batchSize) {
      final batch = urls.skip(i).take(batchSize);
      await Future.wait(
        batch.map((url) async {
          try {
            final cached = await cache.getFileFromCache(url);
            if (cached != null) return;
            await cache.downloadFile(url);
          } catch (_) {
            // Best-effort only; visible widgets will retry/fallback as usual.
          }
        }),
      );
    }
  }
}
