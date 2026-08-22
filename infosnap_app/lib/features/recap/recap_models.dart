// ignore_for_file: deprecated_member_use
/// Data models for the Recap feature.
///
/// Recap = a daily / weekly / monthly slideshow of the user's saved notes,
/// LLM-categorized into 6–9 themes. Source of truth lives in
/// `cloudflare-worker/src/recap.ts` (the worker returns `RecapPayload`).

enum RecapPeriod { day, week, month }

extension RecapPeriodX on RecapPeriod {
  String get apiValue => switch (this) {
        RecapPeriod.day => 'day',
        RecapPeriod.week => 'week',
        RecapPeriod.month => 'month',
      };
  String get label => switch (this) {
        RecapPeriod.day => 'Yesterday',
        RecapPeriod.week => 'This week',
        RecapPeriod.month => 'This month',
      };
  String get shortLabel => switch (this) {
        RecapPeriod.day => 'Day',
        RecapPeriod.week => 'Week',
        RecapPeriod.month => 'Month',
      };
}

RecapPeriod recapPeriodFromString(String? s) {
  switch (s) {
    case 'day':
      return RecapPeriod.day;
    case 'month':
      return RecapPeriod.month;
    case 'week':
    default:
      return RecapPeriod.week;
  }
}

String? stableRecapThumbnailUrl(String? value) {
  final clean = value?.trim();
  if (clean == null || clean.isEmpty) return null;
  if (clean.startsWith('https://wsrv.nl/')) return clean;

  final uri = Uri.tryParse(clean);
  if (uri?.host == 'www.google.com' && uri?.path == '/s2/favicons') {
    final domain = uri?.queryParameters['domain']?.toLowerCase() ?? '';
    final isSocialFavicon = domain.contains('instagram.com') ||
        domain.contains('facebook.com') ||
        domain.contains('linkedin.com') ||
        domain.contains('twitter.com') ||
        domain.contains('x.com') ||
        domain.contains('reddit.com');
    if (isSocialFavicon) return null;
  }

  if (uri?.host == 's.wordpress.com' &&
      uri?.path.startsWith('/mshots/v1/') == true) {
    final decoded =
        Uri.decodeComponent(uri!.path.substring('/mshots/v1/'.length))
            .toLowerCase();
    final isSocialScreenshot = decoded.contains('instagram.com') ||
        decoded.contains('facebook.com') ||
        decoded.contains('linkedin.com') ||
        decoded.contains('twitter.com') ||
        decoded.contains('x.com') ||
        decoded.contains('reddit.com');
    if (isSocialScreenshot) return null;
  }

  final host = uri?.host.toLowerCase() ?? '';
  final shouldProxy = host.contains('cdninstagram.com') ||
      host.contains('fbcdn.net') ||
      host.contains('fbsbx.com') ||
      host.contains('twimg.com') ||
      host.contains('licdn.com') ||
      host.contains('redditmedia.com') ||
      host.contains('redd.it');

  if (!shouldProxy) return clean;

  final withoutScheme = clean.replaceFirst(
    RegExp(r'^https?://', caseSensitive: false),
    '',
  );
  return 'https://wsrv.nl/?url=ssl:${Uri.encodeComponent(withoutScheme)}&w=1200&output=jpg&we=1&l=6';
}

class RecapSlide {
  final String id;
  final String title;
  final String fullTitle;
  final String description;
  final String tag;
  final String fileType;
  final String? thumbnail;
  final String? blobUrl;
  final String? originalFilename;
  final String sourceUrl;
  final DateTime? createdAt;

  const RecapSlide({
    required this.id,
    required this.title,
    required this.fullTitle,
    required this.description,
    required this.tag,
    required this.fileType,
    required this.thumbnail,
    required this.blobUrl,
    required this.originalFilename,
    required this.sourceUrl,
    required this.createdAt,
  });

  factory RecapSlide.fromJson(Map<String, dynamic> j) => RecapSlide(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        fullTitle: (j['full_title'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        tag: (j['tag'] ?? '').toString(),
        fileType: (j['file_type'] ?? '').toString(),
        thumbnail: stableRecapThumbnailUrl(j['thumbnail']?.toString()),
        blobUrl: j['blob_url']?.toString(),
        originalFilename: j['original_filename']?.toString(),
        sourceUrl: (j['source_url'] ?? '').toString(),
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'].toString())
            : null,
      );
}

class RecapCategory {
  final String name;
  final String color; // hex
  final int count;
  final String? coverThumb;
  final List<RecapSlide> slides;

  const RecapCategory({
    required this.name,
    required this.color,
    required this.count,
    required this.coverThumb,
    required this.slides,
  });

  /// Strip leading emoji + trailing label
  String get emoji {
    final m = RegExp(
      r'^(\p{Extended_Pictographic}\uFE0F?(?:\u200D\p{Extended_Pictographic}\uFE0F?)*)',
      unicode: true,
    ).firstMatch(name);
    return m?.group(1) ?? '✨';
  }

  String get nameWithoutEmoji {
    final m = RegExp(
      r'^(\p{Extended_Pictographic}\uFE0F?(?:\u200D\p{Extended_Pictographic}\uFE0F?)*)\s*(.*)$',
      unicode: true,
    ).firstMatch(name);
    return m?.group(2)?.trim().isNotEmpty == true ? m!.group(2)!.trim() : name;
  }

  factory RecapCategory.fromJson(Map<String, dynamic> j) => RecapCategory(
        name: (j['name'] ?? '').toString(),
        color: (j['color'] ?? '#3b82f6').toString(),
        count: (j['count'] as num?)?.toInt() ?? 0,
        coverThumb: stableRecapThumbnailUrl(j['cover_thumb']?.toString()),
        slides: ((j['slides'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => RecapSlide.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
}

class RecapPayload {
  final String userId;
  final RecapPeriod period;
  final String periodStart; // YYYY-MM-DD
  final String periodEnd; // YYYY-MM-DD
  final DateTime? generatedAt;
  final int totalNotes;
  final bool empty;
  final List<RecapCategory> categories;

  const RecapPayload({
    required this.userId,
    required this.period,
    required this.periodStart,
    required this.periodEnd,
    required this.generatedAt,
    required this.totalNotes,
    required this.empty,
    required this.categories,
  });

  factory RecapPayload.fromJson(Map<String, dynamic> j) => RecapPayload(
        userId: (j['user_id'] ?? '').toString(),
        period: recapPeriodFromString(j['period']?.toString()),
        periodStart: (j['period_start'] ?? '').toString(),
        periodEnd: (j['period_end'] ?? '').toString(),
        generatedAt: j['generated_at'] != null
            ? DateTime.tryParse(j['generated_at'].toString())
            : null,
        totalNotes: (j['total_notes'] as num?)?.toInt() ?? 0,
        empty: j['empty'] == true,
        categories: ((j['categories'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => RecapCategory.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );

  Map<String, dynamic> toJsonForSave() {
    return {
      'user_id': userId,
      'period': period.apiValue,
      'period_start': periodStart,
      'period_end': periodEnd,
      'generated_at': generatedAt?.toIso8601String(),
      'total_notes': totalNotes,
      'empty': empty,
      'categories': categories
          .map((c) => {
                'name': c.name,
                'color': c.color,
                'count': c.count,
                'cover_thumb': c.coverThumb,
                'slides': c.slides
                    .map((s) => {
                          'id': s.id,
                          'title': s.title,
                          'full_title': s.fullTitle,
                          'description': s.description,
                          'tag': s.tag,
                          'file_type': s.fileType,
                          'thumbnail': s.thumbnail,
                          'blob_url': s.blobUrl,
                          'original_filename': s.originalFilename,
                          'source_url': s.sourceUrl,
                          'created_at': s.createdAt?.toIso8601String(),
                        })
                    .toList(),
              })
          .toList(),
    };
  }
}

/// Lightweight summary for the "saved recaps" list on the profile page.
class SavedRecapSummary {
  final String id;
  final RecapPeriod period;
  final String periodStart;
  final String periodEnd;
  final String? title;
  final String? coverThumb;
  final int totalNotes;
  final DateTime? savedAt;

  const SavedRecapSummary({
    required this.id,
    required this.period,
    required this.periodStart,
    required this.periodEnd,
    required this.title,
    required this.coverThumb,
    required this.totalNotes,
    required this.savedAt,
  });

  factory SavedRecapSummary.fromJson(Map<String, dynamic> j) =>
      SavedRecapSummary(
        id: (j['id'] ?? '').toString(),
        period: recapPeriodFromString(j['period']?.toString()),
        periodStart: (j['period_start'] ?? '').toString(),
        periodEnd: (j['period_end'] ?? '').toString(),
        title: j['title']?.toString(),
        coverThumb: stableRecapThumbnailUrl(j['cover_thumb']?.toString()),
        totalNotes: (j['total_notes'] as num?)?.toInt() ?? 0,
        savedAt: j['saved_at'] != null
            ? DateTime.tryParse(j['saved_at'].toString())
            : null,
      );
}
