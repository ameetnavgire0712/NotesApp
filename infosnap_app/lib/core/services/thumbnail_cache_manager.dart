import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class ThumbnailCacheManager {
  ThumbnailCacheManager._();

  static const key = 'infosnap_thumbnail_cache_v1';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 900,
      repo: JsonCacheInfoRepository(databaseName: key),
      fileService: HttpFileService(),
    ),
  );
}
