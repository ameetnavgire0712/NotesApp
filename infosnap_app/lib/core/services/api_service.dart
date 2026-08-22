import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../../features/newspaper/newspaper_models.dart';

/// Hosts whose image URLs are signed/short-lived or block third-party
/// fetches (Instagram, Facebook, LinkedIn, Twitter, Reddit, TikTok CDNs).
/// Route them through wsrv.nl so the bytes are re-fetched and cached
/// server-side — gives us stable thumbnails everywhere.
String? stabilizeImageUrl(String? url) {
  if (url == null || url.isEmpty) return url;
  if (url.startsWith('https://wsrv.nl/')) return url;
  try {
    final u = Uri.parse(url);
    final host = u.host.toLowerCase();
    const unstable = [
      'cdninstagram.com',
      'fbcdn.net',
      'fbsbx.com',
      'twimg.com',
      'licdn.com',
      'redditmedia.com',
      'redd.it',
      'tiktokcdn.com',
      'tiktokcdn-us.com',
    ];
    final isUnstable = unstable.any((h) => host == h || host.endsWith('.$h'));
    if (!isUnstable) return url;
    final stripped =
        url.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    final encoded = Uri.encodeComponent(stripped);
    return 'https://wsrv.nl/?url=ssl:$encoded&w=1200&output=jpg&we=1&l=6';
  } catch (_) {
    return url;
  }
}

String? _inferSocialSourceFromValues(Iterable<String?> values) {
  final combined = values
      .whereType<String>()
      .map((value) => value.trim().toLowerCase())
      .where((value) => value.isNotEmpty)
      .join(' ');
  if (combined.isEmpty) return null;

  if (combined.contains('instagram.com') || combined.contains('instagram')) {
    return 'instagram';
  }
  if (combined.contains('facebook.com') ||
      combined.contains('fb.watch') ||
      combined.contains('facebook')) {
    return 'facebook';
  }
  if (combined.contains('youtube.com') ||
      combined.contains('youtu.be') ||
      combined.contains('youtube')) {
    return 'youtube';
  }
  if (combined.contains('linkedin.com') || combined.contains('linkedin')) {
    return 'linkedin';
  }
  if (combined.contains('twitter.com') ||
      combined.contains('x.com') ||
      combined.contains('tweet') ||
      combined.contains('twitter')) {
    return 'twitter';
  }
  if (combined.contains('reddit.com') ||
      combined.contains('redd.it') ||
      combined.contains('reddit')) {
    return 'reddit';
  }

  return null;
}

/// Note model matching backend response
class Note {
  final String id;
  final String title;
  final String? shortTitle;
  final String? contentType;
  final String? sourceUrl;
  final String? blobUrl;
  final String? sourceDomain;
  final int? wordCount;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final List<String> tags;
  final String? thumbnailUrl;
  final String? contentPreview;
  final String? originalFilename;
  final String? description;

  /// Full untruncated description from the source platform (e.g. YouTube
  /// video description). Surfaced under metadata.social.description by the
  /// social-share enricher. Null for non-social notes.
  final String? socialDescription;

  /// Platform identifier from metadata.social.source (e.g. 'youtube'). Null
  /// for non-social notes. Used by the UI to pick platform-specific card
  /// layouts (e.g. portrait thumbnail for YouTube Shorts).
  final String? socialSource;

  /// metadata.social.post_type, e.g. 'short' or 'video' for YouTube. Null
  /// for non-social notes.
  final String? socialPostType;

  /// Official social embed HTML captured by the backend when available.
  final String? socialEmbedHtml;

  /// Lifecycle status from backend: 'active' (indexed & searchable),
  /// 'incomplete' (just inserted, still chunking/embedding/vectorising),
  /// or null for older rows. Anything other than 'active' should be
  /// treated as still processing.
  final String? status;

  Note({
    required this.id,
    required this.title,
    this.shortTitle,
    this.contentType,
    this.sourceUrl,
    this.blobUrl,
    this.sourceDomain,
    this.wordCount,
    required this.createdAt,
    this.updatedAt,
    this.tags = const [],
    this.thumbnailUrl,
    this.contentPreview,
    this.originalFilename,
    this.description,
    this.socialDescription,
    this.socialSource,
    this.socialPostType,
    this.socialEmbedHtml,
    this.status,
  });

  factory Note.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'] is Map ? (json['metadata'] as Map) : null;

    String? firstNonEmpty(List<dynamic> values) {
      for (final value in values) {
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
      return null;
    }

    // Use top-level stabilizeImageUrl helper for proxying unstable CDN hosts.
    String? stabilizeThumb(String? url) => stabilizeImageUrl(url);

    // Handle both 'tag' (singular from backend) and 'tags' (array)
    List<String> parsedTags = [];
    if (json['tags'] != null && json['tags'] is List) {
      parsedTags =
          (json['tags'] as List<dynamic>).map((e) => e.toString()).toList();
    } else if (json['tag'] != null && json['tag'].toString().isNotEmpty) {
      parsedTags = [json['tag'].toString()];
    } else if (json['file_type'] != null &&
        json['file_type'].toString().isNotEmpty) {
      parsedTags = [json['file_type'].toString()];
    }

    // Detect content type based on file_type, original_filename, or metadata
    String? rawContentType = json['content_type'] ?? json['file_type'];
    String? sourceUrl = json['source_url'];
    String? originalFilename = json['original_filename'];
    String? blobUrl = json['blob_url'];
    final originalFilenameLower = originalFilename?.toLowerCase() ?? '';
    final isImageFilename = originalFilenameLower.endsWith('.jpg') ||
        originalFilenameLower.endsWith('.jpeg') ||
        originalFilenameLower.endsWith('.png') ||
        originalFilenameLower.endsWith('.gif') ||
        originalFilenameLower.endsWith('.webp') ||
        originalFilenameLower.endsWith('.heic') ||
        originalFilenameLower.endsWith('.bmp') ||
        originalFilenameLower.endsWith('.svg');

    // Extract source_url from metadata if not at top level.
    if (sourceUrl == null && metadata != null) {
      sourceUrl = metadata['source_url']?.toString();
    }
    if (metadata?['social'] is Map) {
      final social = metadata!['social'] as Map;
      final socialUrl = social['source_url']?.toString().trim();
      final socialSource =
          (social['source'] ?? social['source_app'])?.toString().toLowerCase();
      final redditPostId = social['post_id']?.toString().trim();
      final redditSubreddit = social['subreddit']?.toString().trim();
      // For social posts, the top-level source_url can be the Android share
      // URL (for Reddit often /s/<code>). The social metadata may contain the
      // canonical URL resolved by the worker, which is what embeds need.
      if (socialSource == 'reddit' &&
          redditPostId != null &&
          redditPostId.isNotEmpty &&
          redditSubreddit != null &&
          redditSubreddit.isNotEmpty) {
        sourceUrl =
            'https://www.reddit.com/r/$redditSubreddit/comments/$redditPostId/';
      } else if (sourceUrl == null ||
          (socialSource == 'reddit' &&
              socialUrl != null &&
              socialUrl.isNotEmpty)) {
        sourceUrl = socialUrl;
      }
    }

    // If file_type is uploaded_file, detect actual type from filename.
    // (Newer uploads already arrive as 'image' / 'webpage' / 'screenshot' /
    // 'uploaded_file' from the worker; this branch keeps legacy 'uploaded_file'
    // rows correctly classified.)
    if (rawContentType == 'uploaded_file' || rawContentType == 'screenshot') {
      if (isImageFilename || rawContentType == 'screenshot') {
        // Screenshots are images
        rawContentType = 'image';
      } else if (originalFilenameLower.endsWith('.pdf')) {
        rawContentType = 'pdf';
      } else if (sourceUrl != null && sourceUrl.isNotEmpty) {
        // If there is a source URL but the filename does not identify a file type,
        // treat it as a webpage capture.
        rawContentType = 'webpage';
      }
    }

    // Resolve thumbnail_url — the worker computes it for list responses,
    // but we also compute it client-side as a fallback for cached or
    // older API responses. Storage blob URLs are opaque UUIDs (no extension),
    // so we check original_filename for image type detection.
    final socialMeta = metadata?['social'];
    String? thumbnailUrl = firstNonEmpty([
      json['thumbnail_url'],
      metadata?['thumbnail_url'],
      metadata?['preview_image_url'],
      metadata?['thumbnail_blob_url'],
      metadata?['screenshot_url'],
      socialMeta is Map ? socialMeta['thumbnail_url'] : null,
    ]);
    if (thumbnailUrl == null || thumbnailUrl.isEmpty) {
      final fileType2 = (json['file_type'] as String?) ?? '';
      final origFname =
          ((json['original_filename'] as String?) ?? '').toLowerCase();
      const imageExts = [
        '.jpg',
        '.jpeg',
        '.png',
        '.gif',
        '.webp',
        '.heic',
        '.bmp',
        '.svg'
      ];
      if ((fileType2 == 'screenshot' || fileType2 == 'image') &&
          blobUrl != null &&
          blobUrl.isNotEmpty) {
        thumbnailUrl = blobUrl;
      } else if (fileType2 == 'uploaded_file' &&
          blobUrl != null &&
          blobUrl.isNotEmpty) {
        if (imageExts.any((ext) => origFname.endsWith(ext))) {
          thumbnailUrl = blobUrl;
        }
      }
    }

    // Stabilize thumbnails from unstable CDN hosts (Instagram, Facebook,
    // LinkedIn, Twitter, Reddit) by routing them through wsrv.nl, which
    // re-fetches with proper headers and caches the bytes. These CDN URLs
    // are signed with short expiries / referrer policies, so direct fetches
    // from the Flutter client routinely fail for snaps older than a few days.
    thumbnailUrl = stabilizeThumb(thumbnailUrl);

    final shortTitleValue = firstNonEmpty([
      json['short_title'],
      metadata?['short_title'],
    ]);
    if ((json['title'] as String?)?.toLowerCase().contains('python') ?? false) {
      debugPrint(
          '[Note.fromJson] id=${json['id']}, json[short_title]=${json['short_title']}, parsed shortTitle=$shortTitleValue');
    }

    final inferredSocialSource = _inferSocialSourceFromValues([
      sourceUrl,
      json['source_domain']?.toString(),
      rawContentType,
      json['file_type']?.toString(),
    ]);

    return Note(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      shortTitle: shortTitleValue,
      contentType: rawContentType,
      sourceUrl: sourceUrl,
      blobUrl: blobUrl,
      sourceDomain: json['source_domain'],
      wordCount: json['word_count'],
      createdAt:
          (DateTime.tryParse(json['created_at'] ?? json['uploaded_at'] ?? '') ??
                  DateTime.now())
              .toLocal(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'])?.toLocal()
          : null,
      tags: parsedTags,
      thumbnailUrl: thumbnailUrl,
      contentPreview: firstNonEmpty([
        json['content_preview'],
        json['content'],
        json['content_markdown'], // For quick notes stored as markdown
        json['snippet'],
        metadata?['content_preview'],
        metadata?['excerpt'],
        metadata?['summary'],
      ]),
      originalFilename: originalFilename,
      description: firstNonEmpty([
        json['description'],
        metadata?['description'],
      ]),
      socialDescription: firstNonEmpty([
        (metadata?['social'] is Map)
            ? (metadata!['social'] as Map)['description']
            : null,
        // Instagram stores the post caption under `caption`, not `description`.
        // Surface it as socialDescription so the detail screen renders it.
        (metadata?['social'] is Map)
            ? (metadata!['social'] as Map)['caption']
            : null,
      ]),
      socialSource: firstNonEmpty([
        (metadata?['social'] is Map)
            ? (metadata!['social'] as Map)['source']
            : null,
        (metadata?['social'] is Map)
            ? (metadata!['social'] as Map)['source_app']
            : null,
        inferredSocialSource,
      ]),
      socialPostType: firstNonEmpty([
        (metadata?['social'] is Map)
            ? (metadata!['social'] as Map)['post_type']
            : null,
      ]),
      socialEmbedHtml: firstNonEmpty([
        (metadata?['social'] is Map)
            ? (metadata!['social'] as Map)['embed_html']
            : null,
      ]),
      status:
          (json['status'] is String && (json['status'] as String).isNotEmpty)
              ? json['status'] as String
              : null,
    );
  }

  /// True while the upload pipeline is still indexing this note for search.
  /// Returned in My Snaps listing but should NOT be searchable yet.
  bool get isProcessing => status != null && status != 'active';

  /// Instagram posts/reels don't have a separate title; the scraped "title"
  /// is just the first line of the caption (often garbage like
  /// "22K likes, 182 comments - <author> on <date>: ..."). Use this flag
  /// to suppress title rendering on cards and the detail screen.
  bool get isInstagram => (socialSource ?? '').toLowerCase() == 'instagram';

  /// LinkedIn post / article / video share. Cards show a LinkedIn badge and
  /// use the LinkedIn share-card aspect ratio (1.91:1).
  bool get isLinkedIn => (socialSource ?? '').toLowerCase() == 'linkedin';

  /// Twitter / X post. Cards show an X badge.
  bool get isTwitter => (socialSource ?? '').toLowerCase() == 'twitter';

  /// Reddit post. Cards show a Reddit badge.
  bool get isReddit => (socialSource ?? '').toLowerCase() == 'reddit';

  /// Facebook post. Cards show a Facebook badge and use Meta official embed.
  bool get isFacebook => (socialSource ?? '').toLowerCase() == 'facebook';

  String get displayTitle {
    // Prefer the full title. Fall back to shortTitle only when title is missing
    // or blank. (Previously this preferred shortTitle which collapsed most
    // thumbnails to a 2-3 word LLM label and hid the real filename / heading.)
    if (title.trim().isNotEmpty) return title;
    if (shortTitle != null && shortTitle!.trim().isNotEmpty) return shortTitle!;
    return 'Untitled';
  }

  /// Get icon based on content type
  String get icon {
    switch (contentType) {
      case 'article':
      case 'webpage':
        return '🌐';
      case 'youtube':
        return '🎬';
      case 'pdf':
        return '📕';
      case 'tweet':
        return '🐦';
      case 'image':
      case 'screenshot':
        return '🖼️';
      case 'quick_note':
        return '📝';
      default:
        return '📝';
    }
  }
}

/// Notes stats model - matches web frontend stats
class NotesStats {
  final int totalNotes;
  final int totalWords;
  final int googleSearches;
  final int dashboardSearches;
  final Map<String, int> byContentType;

  NotesStats({
    required this.totalNotes,
    required this.totalWords,
    this.googleSearches = 0,
    this.dashboardSearches = 0,
    required this.byContentType,
  });

  factory NotesStats.fromJson(Map<String, dynamic> json) {
    return NotesStats(
      totalNotes: json['total_notes'] ?? 0,
      totalWords: json['total_words'] ?? 0,
      googleSearches: json['google_searches'] ?? 0,
      dashboardSearches: json['dashboard_searches'] ?? 0,
      byContentType: (json['by_content_type'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as int)) ??
          {},
    );
  }
}

class BillingUsage {
  final int used;
  final int limit;
  final int remaining;

  const BillingUsage({
    required this.used,
    required this.limit,
    required this.remaining,
  });

  double get fraction => limit <= 0 ? 0 : (used / limit).clamp(0.0, 1.0);

  factory BillingUsage.fromJson(Map<String, dynamic>? json) {
    return BillingUsage(
      used: (json?['used'] as num?)?.toInt() ?? 0,
      limit: (json?['limit'] as num?)?.toInt() ?? 0,
      remaining: (json?['remaining'] as num?)?.toInt() ?? 0,
    );
  }
}

class BillingStatus {
  final String planCode;
  final String effectivePlanCode;
  final String status;
  final bool cancelAtPeriodEnd;
  final DateTime? currentPeriodEnd;
  final DateTime? resetAt;
  final BillingUsage uploads;
  final BillingUsage snapbotSearches;
  final BillingUsage googleSearches;

  const BillingStatus({
    required this.planCode,
    required this.effectivePlanCode,
    required this.status,
    required this.cancelAtPeriodEnd,
    required this.currentPeriodEnd,
    required this.resetAt,
    required this.uploads,
    required this.snapbotSearches,
    required this.googleSearches,
  });

  bool get isPremium => effectivePlanCode == 'premium';
  bool get isCancelledPremium => isPremium && cancelAtPeriodEnd;

  factory BillingStatus.fromJson(Map<String, dynamic> json) {
    final usage = json['usage'] is Map<String, dynamic>
        ? json['usage'] as Map<String, dynamic>
        : <String, dynamic>{};
    return BillingStatus(
      planCode: json['plan_code']?.toString() ?? 'free',
      effectivePlanCode: json['effective_plan_code']?.toString() ?? 'free',
      status: json['status']?.toString() ??
          json['relationship_status']?.toString() ??
          'active',
      cancelAtPeriodEnd: json['cancel_at_period_end'] == true,
      currentPeriodEnd:
          DateTime.tryParse(json['current_period_end']?.toString() ?? ''),
      resetAt: DateTime.tryParse(json['reset_at']?.toString() ?? ''),
      uploads: BillingUsage.fromJson(
        usage['upload'] is Map<String, dynamic>
            ? usage['upload'] as Map<String, dynamic>
            : null,
      ),
      snapbotSearches: BillingUsage.fromJson(
        usage['snapbot_search'] is Map<String, dynamic>
            ? usage['snapbot_search'] as Map<String, dynamic>
            : null,
      ),
      googleSearches: BillingUsage.fromJson(
        usage['google_search'] is Map<String, dynamic>
            ? usage['google_search'] as Map<String, dynamic>
            : null,
      ),
    );
  }
}

class GroupSummary {
  final String id;
  final String name;
  final String role;
  final String status;
  final int memberCount;
  final int unreadCount;
  final GroupUser? invitedBy;
  final String? avatarUrl;
  final GroupUser? latestActivityActor;
  final DateTime? latestActivityAt;
  final String? latestActivityType;
  final String? latestActivityTitle;
  final String? latestActivityDescription;
  final String? latestActivityFileType;
  final DateTime createdAt;

  const GroupSummary({
    required this.id,
    required this.name,
    required this.role,
    required this.status,
    required this.memberCount,
    required this.unreadCount,
    this.invitedBy,
    this.avatarUrl,
    this.latestActivityActor,
    this.latestActivityAt,
    this.latestActivityType,
    this.latestActivityTitle,
    this.latestActivityDescription,
    this.latestActivityFileType,
    required this.createdAt,
  });

  GroupSummary copyWith({
    String? id,
    String? name,
    String? role,
    String? status,
    int? memberCount,
    int? unreadCount,
    GroupUser? invitedBy,
    String? avatarUrl,
    GroupUser? latestActivityActor,
    DateTime? latestActivityAt,
    String? latestActivityType,
    String? latestActivityTitle,
    String? latestActivityDescription,
    String? latestActivityFileType,
    DateTime? createdAt,
  }) {
    return GroupSummary(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      status: status ?? this.status,
      memberCount: memberCount ?? this.memberCount,
      unreadCount: unreadCount ?? this.unreadCount,
      invitedBy: invitedBy ?? this.invitedBy,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      latestActivityActor: latestActivityActor ?? this.latestActivityActor,
      latestActivityAt: latestActivityAt ?? this.latestActivityAt,
      latestActivityType: latestActivityType ?? this.latestActivityType,
      latestActivityTitle: latestActivityTitle ?? this.latestActivityTitle,
      latestActivityDescription:
          latestActivityDescription ?? this.latestActivityDescription,
      latestActivityFileType:
          latestActivityFileType ?? this.latestActivityFileType,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory GroupSummary.fromJson(Map<String, dynamic> json) {
    final normalizedRole = json['role']?.toString() == 'owner'
        ? 'admin'
        : json['role']?.toString() ?? 'member';
    return GroupSummary(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Group',
      role: normalizedRole,
      status: json['status']?.toString() ??
          json['relationship_status']?.toString() ??
          'active',
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      invitedBy: json['invited_by_profile'] is Map<String, dynamic>
          ? GroupUser.fromJson(
              json['invited_by_profile'] as Map<String, dynamic>,
            )
          : null,
      avatarUrl: json['avatar_url']?.toString(),
      latestActivityActor:
          json['latest_activity_actor_profile'] is Map<String, dynamic>
              ? GroupUser.fromJson(
                  json['latest_activity_actor_profile'] as Map<String, dynamic>,
                )
              : null,
      latestActivityAt:
          DateTime.tryParse(json['latest_activity_at']?.toString() ?? ''),
      latestActivityType: json['latest_activity_type']?.toString(),
      latestActivityTitle: json['latest_activity_title']?.toString(),
      latestActivityDescription:
          json['latest_activity_description']?.toString(),
      latestActivityFileType: json['latest_activity_file_type']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'role': role,
      'status': status,
      'member_count': memberCount,
      'unread_count': unreadCount,
      'avatar_url': avatarUrl,
      'latest_activity_at': latestActivityAt?.toIso8601String(),
      'latest_activity_type': latestActivityType,
      'latest_activity_title': latestActivityTitle,
      'latest_activity_description': latestActivityDescription,
      'latest_activity_file_type': latestActivityFileType,
      'created_at': createdAt.toIso8601String(),
      if (invitedBy != null)
        'invited_by_profile': {
          'user_id': invitedBy!.id,
          'email': invitedBy!.email,
          'display_name': invitedBy!.displayName,
        },
      if (latestActivityActor != null)
        'latest_activity_actor_profile': {
          'user_id': latestActivityActor!.id,
          'email': latestActivityActor!.email,
          'display_name': latestActivityActor!.displayName,
          'avatar_url': latestActivityActor!.avatarUrl,
        },
    };
  }

  String get latestActivitySummary {
    final actor = latestActivityActor?.displayName.trim().isNotEmpty == true
        ? latestActivityActor!.displayName.trim()
        : 'Someone';
    final fileType = (latestActivityFileType ?? '').trim().toLowerCase();
    switch (latestActivityType) {
      case 'group_snap':
        final kind = fileType.isNotEmpty ? fileType : 'post';
        return '$actor shared a $kind';
      case 'group_reaction':
        return '$actor reacted to a shared snap';
      case 'group_join_request':
        return '$actor requested to join';
      case 'group_join_accepted':
        return '$actor accepted a join request';
      case 'group_admin_transfer':
        return '$actor changed the admin';
      default:
        return latestActivityTitle?.trim().isNotEmpty == true
            ? latestActivityTitle!.trim()
            : 'No recent activity yet';
    }
  }
}

class GroupUser {
  final String id;
  final String email;
  final String displayName;
  final String? avatarUrl;

  const GroupUser({
    required this.id,
    required this.email,
    required this.displayName,
    this.avatarUrl,
  });

  factory GroupUser.fromJson(Map<String, dynamic> json) {
    return GroupUser(
      id: json['user_id']?.toString() ?? json['id']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      displayName: json['display_name']?.toString().trim().isNotEmpty == true
          ? json['display_name'].toString()
          : (json['email']?.toString().split('@').first ?? 'User'),
      avatarUrl: json['avatar_url']?.toString(),
    );
  }
}

class GroupMember {
  final String id;
  final String? userId;
  final String? invitedEmail;
  final String role;
  final String status;
  final GroupUser? profile;

  const GroupMember({
    required this.id,
    this.userId,
    this.invitedEmail,
    required this.role,
    required this.status,
    this.profile,
  });

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    final profileJson = json['profile'];
    return GroupMember(
      id: json['id']?.toString() ?? '',
      userId: json['user_id']?.toString(),
      invitedEmail: json['invited_email']?.toString(),
      role: json['role']?.toString() == 'owner'
          ? 'admin'
          : json['role']?.toString() ?? 'member',
      status: json['status']?.toString() ?? 'pending',
      profile: profileJson is Map<String, dynamic>
          ? GroupUser.fromJson(profileJson)
          : null,
    );
  }

  String get displayName =>
      profile?.displayName ?? invitedEmail ?? userId ?? 'Pending user';
  String get displayNameOnly {
    final raw = profile?.displayName.trim();
    if (raw != null && raw.isNotEmpty) return raw;
    final email = (profile?.email ?? invitedEmail ?? '').trim();
    if (email.contains('@')) return email.split('@').first;
    if (email.isNotEmpty) return email;
    return 'Pending user';
  }

  String get displayEmail => profile?.email ?? invitedEmail ?? '';
}

const Object _sentinel = Object();

class GroupSnap {
  final String id;
  final String noteId;
  final String title;
  final String? fileType;
  final String? tag;
  final String? thumbnailUrl;
  final String? description;
  final String? sourceUrl;
  final String? originalFilename;
  final String? blobUrl;
  final String? contentPreview;
  final String sharedBy;
  final String? sharedByName;
  final DateTime sharedAt;
  final String? myReaction;
  final Map<String, int> reactions;

  const GroupSnap({
    required this.id,
    required this.noteId,
    required this.title,
    this.fileType,
    this.tag,
    this.thumbnailUrl,
    this.description,
    this.sourceUrl,
    this.originalFilename,
    this.blobUrl,
    this.contentPreview,
    required this.sharedBy,
    this.sharedByName,
    required this.sharedAt,
    this.myReaction,
    this.reactions = const {},
  });

  GroupSnap copyWith({
    String? id,
    String? noteId,
    String? title,
    String? fileType,
    String? tag,
    String? thumbnailUrl,
    String? description,
    String? sourceUrl,
    String? originalFilename,
    String? blobUrl,
    String? contentPreview,
    String? sharedBy,
    String? sharedByName,
    DateTime? sharedAt,
    Object? myReaction = _sentinel,
    Map<String, int>? reactions,
  }) {
    return GroupSnap(
      id: id ?? this.id,
      noteId: noteId ?? this.noteId,
      title: title ?? this.title,
      fileType: fileType ?? this.fileType,
      tag: tag ?? this.tag,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      description: description ?? this.description,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      originalFilename: originalFilename ?? this.originalFilename,
      blobUrl: blobUrl ?? this.blobUrl,
      contentPreview: contentPreview ?? this.contentPreview,
      sharedBy: sharedBy ?? this.sharedBy,
      sharedByName: sharedByName ?? this.sharedByName,
      sharedAt: sharedAt ?? this.sharedAt,
      myReaction: identical(myReaction, _sentinel)
          ? this.myReaction
          : myReaction as String?,
      reactions: reactions ?? this.reactions,
    );
  }

  factory GroupSnap.fromJson(Map<String, dynamic> json) {
    return GroupSnap(
      id: json['id']?.toString() ?? '',
      noteId: json['note_id']?.toString() ?? '',
      title: json['title_snapshot']?.toString() ?? 'Untitled snap',
      fileType: json['file_type_snapshot']?.toString(),
      tag: json['tag_snapshot']?.toString(),
      thumbnailUrl: json['thumbnail_url']?.toString(),
      description: json['description_snapshot']?.toString(),
      sourceUrl: json['source_url_snapshot']?.toString(),
      originalFilename: json['original_filename_snapshot']?.toString(),
      blobUrl: json['blob_url_snapshot']?.toString(),
      contentPreview: json['content_preview_snapshot']?.toString(),
      sharedBy: json['shared_by']?.toString() ?? '',
      sharedByName: json['shared_by_profile'] is Map<String, dynamic>
          ? GroupUser.fromJson(
              json['shared_by_profile'] as Map<String, dynamic>,
            ).displayName
          : null,
      sharedAt: DateTime.tryParse(json['shared_at']?.toString() ?? '') ??
          DateTime.now(),
      myReaction: json['my_reaction']?.toString(),
      reactions: json['reactions'] is Map
          ? (json['reactions'] as Map).map(
              (key, value) => MapEntry(
                key.toString(),
                (value as num?)?.toInt() ?? 0,
              ),
            )
          : const {},
    );
  }

  Note toNote() {
    return Note(
      id: noteId,
      title: title,
      shortTitle: title,
      contentType: fileType,
      sourceUrl: sourceUrl,
      blobUrl: blobUrl,
      createdAt: sharedAt,
      tags: tag == null || tag!.isEmpty ? const [] : [tag!],
      thumbnailUrl: thumbnailUrl,
      contentPreview: contentPreview ?? description,
      originalFilename: originalFilename,
      description: description,
      socialSource: platformSource,
      socialPostType: fileType,
      socialEmbedHtml: null,
      status: 'active',
    );
  }

  String? get platformSource {
    return _inferSocialSourceFromValues([
      sourceUrl,
      fileType,
      originalFilename,
    ]);
  }
}

class GroupDetail {
  final GroupSummary group;
  final List<GroupMember> members;
  final List<GroupMember> joinRequests;
  final List<GroupSnap> snaps;

  const GroupDetail({
    required this.group,
    required this.members,
    required this.joinRequests,
    required this.snaps,
  });

  factory GroupDetail.fromJson(Map<String, dynamic> json) {
    final groupJson = json['group'] as Map<String, dynamic>? ?? {};
    return GroupDetail(
      group: GroupSummary.fromJson({
        ...groupJson,
        'member_count': (json['members'] as List?)?.length ?? 0,
        'unread_count': 0,
        'role': groupJson['role'] ?? 'member',
        'status': groupJson['status'] ?? 'active',
      }),
      members: ((json['members'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(GroupMember.fromJson)
          .toList(),
      joinRequests: ((json['join_requests'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(GroupMember.fromJson)
          .toList(),
      snaps: ((json['snaps'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(GroupSnap.fromJson)
          .toList(),
    );
  }
}

class AppNotificationCounts {
  final int groupUnreadCount;
  final int pendingGroupInvites;
  final int totalGroupBadgeCount;

  const AppNotificationCounts({
    required this.groupUnreadCount,
    required this.pendingGroupInvites,
    required this.totalGroupBadgeCount,
  });

  factory AppNotificationCounts.fromJson(Map<String, dynamic>? json) {
    final groupUnread = (json?['group_unread_count'] as num?)?.toInt() ?? 0;
    final pendingInvites =
        (json?['pending_group_invites'] as num?)?.toInt() ?? 0;
    return AppNotificationCounts(
      groupUnreadCount: groupUnread,
      pendingGroupInvites: pendingInvites,
      totalGroupBadgeCount:
          (json?['total_group_badge_count'] as num?)?.toInt() ??
              groupUnread + pendingInvites,
    );
  }
}

class CollectionSummary {
  final String value;
  final int count;
  final String? coverThumbnailUrl;

  const CollectionSummary({
    required this.value,
    required this.count,
    required this.coverThumbnailUrl,
  });

  factory CollectionSummary.fromJson(Map<String, dynamic> json) {
    final cover = json['cover_thumb_url'];
    final raw = (cover is String && cover.isNotEmpty) ? cover : null;
    return CollectionSummary(
      value: (json['value'] ?? '').toString(),
      count: (json['count'] as num?)?.toInt() ?? 0,
      coverThumbnailUrl: stabilizeImageUrl(raw),
    );
  }
}

class BootstrapUserProfile {
  final String? email;
  final String? displayName;
  final String? avatarUrl;

  const BootstrapUserProfile({this.email, this.displayName, this.avatarUrl});

  factory BootstrapUserProfile.fromJson(Map<String, dynamic> json) {
    String? str(dynamic v) =>
        (v is String && v.trim().isNotEmpty) ? v.trim() : null;
    return BootstrapUserProfile(
      email: str(json['email']),
      displayName: str(json['display_name']),
      avatarUrl: str(json['avatar_url']),
    );
  }
}

class AppBootstrap {
  final List<String> tags;
  final BillingStatus? billing;
  final List<GroupSummary> groups;
  final AppNotificationCounts notificationCounts;
  final List<Note> recentNotes;
  final bool recentNotesHasMore;
  final List<CollectionSummary> tagCollections;
  final List<CollectionSummary> typeCollections;
  final BootstrapUserProfile? profile;
  final DateTime generatedAt;

  const AppBootstrap({
    required this.tags,
    required this.billing,
    required this.groups,
    required this.notificationCounts,
    required this.recentNotes,
    required this.recentNotesHasMore,
    required this.tagCollections,
    required this.typeCollections,
    required this.profile,
    required this.generatedAt,
  });

  factory AppBootstrap.fromJson(Map<String, dynamic> json) {
    final collectionsRaw = json['collections'];
    final collectionsMap =
        collectionsRaw is Map<String, dynamic> ? collectionsRaw : const {};
    List<CollectionSummary> parseCollections(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(CollectionSummary.fromJson)
          .where((entry) => entry.value.isNotEmpty)
          .toList(growable: false);
    }

    return AppBootstrap(
      tags: ((json['tags'] as List?) ?? [])
          .map((item) => item.toString())
          .toList(growable: false),
      billing: json['billing'] is Map<String, dynamic>
          ? BillingStatus.fromJson(json['billing'] as Map<String, dynamic>)
          : null,
      groups: ((json['groups'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(GroupSummary.fromJson)
          .toList(growable: false),
      notificationCounts: AppNotificationCounts.fromJson(
        json['notification_counts'] is Map<String, dynamic>
            ? json['notification_counts'] as Map<String, dynamic>
            : null,
      ),
      recentNotes: ((json['recent_notes'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(Note.fromJson)
          .toList(growable: false),
      recentNotesHasMore: json['recent_notes_has_more'] == true,
      tagCollections: parseCollections(collectionsMap['tags']),
      typeCollections: parseCollections(collectionsMap['types']),
      profile: json['profile'] is Map<String, dynamic>
          ? BootstrapUserProfile.fromJson(
              json['profile'] as Map<String, dynamic>)
          : null,
      generatedAt: DateTime.tryParse(json['generated_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class _SingleFlight {
  final Map<String, Future<dynamic>> _inFlight = {};

  Future<T> run<T>(String key, Future<T> Function() load) {
    final existing = _inFlight[key];
    if (existing != null) {
      debugPrint('API: Single-flight joined $key');
      return existing.then((value) => value as T);
    }
    final future = load();
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }
}

/// API Service for backend calls - mirrors web frontend API usage
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  SupabaseClient get _supabase => Supabase.instance.client;

  final ValueNotifier<int> tagsCacheVersion = ValueNotifier<int>(0);

  // Tags cache — refreshed at most every 5 minutes
  List<String>? _cachedTags;
  DateTime? _tagsCachedAt;
  static const _tagsCacheDuration = Duration(minutes: 5);
  BillingStatus? _cachedBillingStatus;
  DateTime? _billingCachedAt;
  static const _billingCacheDuration = Duration(minutes: 2);
  List<GroupSummary>? _cachedGroups;
  DateTime? _groupsCachedAt;
  static const _groupsCacheDuration = Duration(seconds: 45);
  List<Note>? _cachedRecentNotes;
  bool _cachedRecentNotesHasMore = false;
  DateTime? _recentNotesCachedAt;
  static const _recentNotesCacheDuration = Duration(seconds: 20);
  // Full-DB tag/type collection aggregates from the bootstrap RPC. Used by
  // the snaps screen chip strip so it shows EVERY tag/type the user owns,
  // not just the ones present in the currently-loaded page of notes.
  List<CollectionSummary>? _cachedTagCollections;
  List<CollectionSummary>? _cachedTypeCollections;
  DateTime? _collectionsCachedAt;
  static const _collectionsCacheDuration = Duration(minutes: 5);
  final _singleFlight = _SingleFlight();
  static const _persistedTagsPrefix = 'infosnap.cached_tags.';
  static const _persistedGroupsPrefix = 'infosnap.cached_groups.';

  // In-memory highlights cache (session-only, keyed by noteId)
  final Map<String, List<String>> _highlightsCache = {};

  /// Invalidate the tags cache (call after creating a new tag)
  void invalidateTagsCache() {
    _cachedTags = null;
    _tagsCachedAt = null;
    tagsCacheVersion.value++;
  }

  void invalidateGroupsCache() {
    _cachedGroups = null;
    _groupsCachedAt = null;
  }

  void invalidateBillingCache() {
    _cachedBillingStatus = null;
    _billingCachedAt = null;
  }

  void invalidateRecentNotesCache() {
    _cachedRecentNotes = null;
    _cachedRecentNotesHasMore = false;
    _recentNotesCachedAt = null;
  }

  void invalidateCollectionsCache() {
    _cachedTagCollections = null;
    _cachedTypeCollections = null;
    _collectionsCachedAt = null;
  }

  List<String> get cachedTags =>
      List<String>.unmodifiable(_cachedTags ?? const <String>[]);

  List<GroupSummary> get cachedGroups =>
      List<GroupSummary>.unmodifiable(_cachedGroups ?? const <GroupSummary>[]);

  List<CollectionSummary> get cachedTagCollections =>
      List<CollectionSummary>.unmodifiable(
          _cachedTagCollections ?? const <CollectionSummary>[]);

  List<CollectionSummary> get cachedTypeCollections =>
      List<CollectionSummary>.unmodifiable(
          _cachedTypeCollections ?? const <CollectionSummary>[]);

  bool get hasFreshCollections =>
      _collectionsCachedAt != null &&
      DateTime.now().difference(_collectionsCachedAt!) <
          _collectionsCacheDuration;

  String? get _currentUserId {
    try {
      return _supabase.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> loadPersistedTags() async {
    if (_cachedTags != null && _cachedTags!.isNotEmpty) return cachedTags;
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_persistedTagsPrefix$userId');
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is! List) return const [];
      _cachedTags = decoded.map((item) => item.toString()).toList();
      _tagsCachedAt = DateTime.now();
      return cachedTags;
    } catch (_) {
      return const [];
    }
  }

  Future<List<GroupSummary>> loadPersistedGroups() async {
    if (_cachedGroups != null && _cachedGroups!.isNotEmpty) {
      return cachedGroups;
    }
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_persistedGroupsPrefix$userId');
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is! List) return const [];
      _cachedGroups = decoded
          .whereType<Map<String, dynamic>>()
          .map(GroupSummary.fromJson)
          .toList();
      _groupsCachedAt = DateTime.now();
      return cachedGroups;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistTags(List<String> tags) async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_persistedTagsPrefix$userId', jsonEncode(tags));
    } catch (_) {}
  }

  Future<void> _persistGroups(List<GroupSummary> groups) async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_persistedGroupsPrefix$userId',
        jsonEncode(groups.map((group) => group.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// Invalidate all highlights cache (call after uploads complete so a
  /// previously-processing note re-fetches its real highlights).
  void invalidateHighlightsCache([String? noteId]) {
    if (noteId == null) {
      _highlightsCache.clear();
    } else {
      _highlightsCache.remove(noteId);
    }
  }

  /// Get current access token for API calls.
  ///
  /// In tests (or very early app startup) Supabase may not be initialized yet.
  /// Return null instead of throwing so callers can gracefully treat as unauthenticated.
  String? get _accessToken {
    try {
      return _supabase.auth.currentSession?.accessToken;
    } catch (_) {
      return null;
    }
  }

  /// Check if user is authenticated
  bool get isAuthenticated => _accessToken != null;

  /// Get auth headers for API calls (same as web frontend getAuthHeaders)
  Map<String, String> _getAuthHeaders() {
    final token = _accessToken;
    if (token == null) {
      return {'Content-Type': 'application/json'};
    }
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  List<Map<String, dynamic>> _rowsToMaps(Object? rows) {
    if (rows is! List) return const <Map<String, dynamic>>[];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  bool _isVisibleNote(Map<String, dynamic> row) {
    final status = row['status']?.toString();
    return status == null ||
        status.isEmpty ||
        status == 'active' ||
        status == 'incomplete';
  }

  Future<List<Note>> _fetchNotesDirect({
    required int limit,
    required int offset,
    String? tag,
    String? fileType,
  }) async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return [];

    var query = _supabase
        .from('notes')
        .select()
        .eq('user_id', userId)
        .or('status.is.null,status.eq.active,status.eq.incomplete');
    if (tag != null && tag.isNotEmpty) {
      query = query.eq('tag', tag);
    }
    if (fileType != null && fileType.isNotEmpty) {
      query = query.eq('file_type', fileType);
    }

    final rows = await query
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return _rowsToMaps(rows).map(Note.fromJson).toList(growable: false);
  }

  Future<List<String>> _fetchTagsDirect() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return [];
    final rows = await _supabase
        .from('notes')
        .select('tag,status')
        .eq('user_id', userId)
        .or('status.is.null,status.eq.active,status.eq.incomplete');
    final tags = <String>{};
    for (final row in _rowsToMaps(rows)) {
      final tag = row['tag']?.toString().trim();
      if (tag != null && tag.isNotEmpty && _isVisibleNote(row)) {
        tags.add(tag);
      }
    }
    final sorted = tags.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  Future<NotesStats> _fetchNotesStatsDirect() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      return NotesStats(totalNotes: 0, totalWords: 0, byContentType: {});
    }
      final rows = await _supabase
        .from('notes')
        .select('file_type,status')
        .eq('user_id', userId)
        .or('status.is.null,status.eq.active,status.eq.incomplete');
    final byContentType = <String, int>{};
    for (final row in _rowsToMaps(rows)) {
      if (!_isVisibleNote(row)) continue;
      final type = (row['file_type'] ?? 'unknown')
          .toString()
          .trim();
      byContentType[type.isEmpty ? 'unknown' : type] =
          (byContentType[type.isEmpty ? 'unknown' : type] ?? 0) + 1;
    }
    return NotesStats(
      totalNotes:
          byContentType.values.fold<int>(0, (sum, count) => sum + count),
      totalWords: 0,
      byContentType: byContentType,
    );
  }

  Future<BillingStatus?> _fetchBillingStatusDirect() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return null;

    final planRows = _rowsToMaps(await _supabase
        .from('user_plans')
        .select()
        .eq('user_id', userId)
        .limit(1));
    final plan = planRows.isNotEmpty ? planRows.first : <String, dynamic>{};
    final planCode = plan['plan_code']?.toString() ?? 'free';
    final status = plan['status']?.toString() ?? 'active';
    final currentPeriodEnd = plan['current_period_end']?.toString();
    final cancelAtPeriodEnd = plan['cancel_at_period_end'] == true;
    final effectivePlanCode =
        planCode == 'premium' && status != 'expired' ? 'premium' : 'free';

    final limitRows = _rowsToMaps(await _supabase
        .from('plan_limits')
        .select('metric,monthly_limit')
        .eq('plan_code', effectivePlanCode));
    final usageRows = _rowsToMaps(await _supabase
        .from('user_monthly_usage')
        .select('metric,used_count')
        .eq('user_id', userId));

    final usedByMetric = <String, int>{
      for (final row in usageRows)
        if (row['metric'] != null)
          row['metric'].toString(): (row['used_count'] as num?)?.toInt() ?? 0,
    };
    final usage = <String, dynamic>{};
    for (final row in limitRows) {
      final metric = row['metric']?.toString();
      if (metric == null || metric.isEmpty) continue;
      final limit = (row['monthly_limit'] as num?)?.toInt() ?? 0;
      final used = usedByMetric[metric] ?? 0;
      usage[metric] = {
        'used': used,
        'limit': limit,
        'remaining': (limit - used).clamp(0, limit),
      };
    }

    final now = DateTime.now();
    final resetAt = DateTime(now.year, now.month + 1, 1).toIso8601String();
    return BillingStatus.fromJson({
      'plan_code': planCode,
      'effective_plan_code': effectivePlanCode,
      'status': status,
      'cancel_at_period_end': cancelAtPeriodEnd,
      'current_period_end': currentPeriodEnd,
      'reset_at': resetAt,
      'usage': usage,
    });
  }

  /// Fetch all notes for the user (no pagination)
  Future<List<Note>> fetchNotes() async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated, returning empty list');
      return [];
    }

    try {
      final notes = await _fetchNotesDirect(limit: 500, offset: 0);
      debugPrint('API: Got ${notes.length} notes directly from Supabase');
      return notes;
    } catch (e) {
      debugPrint('API: Direct Supabase notes failed, falling back: $e');
    }

    final url = AppConfig.notesUrl;
    debugPrint('API: Fetching notes from $url');

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        // API returns { notes: [...], hasMore: bool } - extract the notes array
        List<dynamic> data;
        if (decoded is Map && decoded['notes'] != null) {
          data = decoded['notes'] as List<dynamic>;
        } else if (decoded is List) {
          data = decoded;
        } else {
          debugPrint('API: Unexpected response format: $decoded');
          return [];
        }
        debugPrint('API: Got ${data.length} notes');
        return data.map((json) => Note.fromJson(json)).toList();
      } else if (response.statusCode == 401) {
        debugPrint('API: Unauthorized - token may be expired');
        return [];
      } else {
        debugPrint('API: Error ${response.statusCode}: ${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('API: Exception fetching notes: $e');
      return [];
    }
  }

  /// Fetch notes with pagination and optional sorting / server-side filters
  Future<List<Note>> fetchNotesPaginated({
    required int limit,
    required int offset,
    String? sort,
    String? tag,
    String? fileType,
  }) async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated, returning empty list');
      return [];
    }

    final hasFilter = (tag != null && tag.isNotEmpty) ||
        (fileType != null && fileType.isNotEmpty);

    if (!hasFilter &&
        (sort == null || sort == 'date') &&
        offset == 0 &&
        _cachedRecentNotes != null &&
        _recentNotesCachedAt != null &&
        _cachedRecentNotes!.isNotEmpty &&
        DateTime.now().difference(_recentNotesCachedAt!) <
            _recentNotesCacheDuration &&
        (_cachedRecentNotes!.length >= limit || !_cachedRecentNotesHasMore)) {
      debugPrint(
          'API: Returning bootstrap-cached notes (${_cachedRecentNotes!.length})');
      return _cachedRecentNotes!.take(limit).toList(growable: false);
    }

    final url = AppConfig.notesPaginatedUrl(
      limit,
      offset,
      sort: sort,
      tag: tag,
      fileType: fileType,
    );
    final key =
        'notes:$limit:$offset:${sort ?? 'date'}:${tag ?? ''}:${fileType ?? ''}';
    return _singleFlight.run<List<Note>>(key, () async {
      if (sort == null || sort == 'date') {
        try {
          final notes = await _fetchNotesDirect(
            limit: limit,
            offset: offset,
            tag: tag,
            fileType: fileType,
          );
          debugPrint(
              'API: Got ${notes.length} paginated notes directly from Supabase');
          return notes;
        } catch (e) {
          debugPrint(
              'API: Direct Supabase paginated notes failed, falling back: $e');
        }
      }

      try {
        debugPrint('API: Fetching paginated notes from $url');
        final response = await http.get(
          Uri.parse(url),
          headers: _getAuthHeaders(),
        );

        if (response.statusCode == 200) {
          final decoded = json.decode(response.body);
          debugPrint('API: Raw response type: ${decoded.runtimeType}');
          // API returns { notes: [...], hasMore: bool } - extract the notes array
          List<dynamic> data;
          if (decoded is Map && decoded['notes'] != null) {
            data = decoded['notes'] as List<dynamic>;
            debugPrint('API: Found notes array with ${data.length} items');
          } else if (decoded is List) {
            data = decoded;
            debugPrint(
                'API: Response is direct list with ${data.length} items');
          } else {
            debugPrint(
                'API: Unexpected response format: ${decoded.runtimeType}');
            debugPrint(
                'API: Response keys: ${decoded is Map ? decoded.keys.toList() : "not a map"}');
            return [];
          }
          debugPrint('API: Got ${data.length} notes (offset=$offset)');
          try {
            final notes = data.map((json) => Note.fromJson(json)).toList();
            debugPrint('API: Successfully parsed ${notes.length} notes');
            return notes;
          } catch (e) {
            debugPrint('API: Error parsing notes: $e');
            return [];
          }
        } else if (response.statusCode == 401) {
          debugPrint('API: Unauthorized - token may be expired');
          return [];
        } else {
          debugPrint('API: Error ${response.statusCode}: ${response.body}');
          return [];
        }
      } catch (e) {
        debugPrint('API: Exception fetching notes: $e');
        return [];
      }
    });
  }

  /// Fetch notes stats
  /// Matches web frontend: fetch(AppConfig.notesStatsUrl, { headers: authHeaders })
  Future<NotesStats?> fetchNotesStats() async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated');
      return null;
    }

    final url = AppConfig.notesStatsUrl;
    debugPrint('API: Fetching stats from $url');

    try {
      final stats = await _fetchNotesStatsDirect();
      debugPrint('API: Got stats directly from Supabase');
      return stats;
    } catch (e) {
      debugPrint('API: Direct Supabase stats failed, falling back: $e');
    }

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint('API: Got stats: $data');
        return NotesStats.fromJson(data);
      } else {
        debugPrint('API: Error ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('API: Exception fetching stats: $e');
      return null;
    }
  }

  /// Fetch all tags
  Future<List<String>> fetchTags({bool forceRefresh = false}) async {
    if (!isAuthenticated) {
      return [];
    }

    // Return cached tags if still fresh
    if (!forceRefresh &&
        _cachedTags != null &&
        _tagsCachedAt != null &&
        DateTime.now().difference(_tagsCachedAt!) < _tagsCacheDuration) {
      debugPrint('API: Returning cached tags (${_cachedTags!.length} tags)');
      return _cachedTags!;
    }

    final url = AppConfig.notesTagsUrl;
    return _singleFlight.run<List<String>>(
        'tags:${forceRefresh ? 'fresh' : 'cached'}', () async {
      try {
        _cachedTags = await _fetchTagsDirect();
        _tagsCachedAt = DateTime.now();
        await _persistTags(_cachedTags!);
        debugPrint(
            'API: Got ${_cachedTags!.length} tags directly from Supabase');
        return _cachedTags!;
      } catch (e) {
        debugPrint('API: Direct Supabase tags failed, falling back: $e');
      }

      try {
        debugPrint('API: Fetching tags from $url');
        final response = await http.get(
          Uri.parse(url),
          headers: _getAuthHeaders(),
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final List<dynamic> tags = data['tags'] ?? [];
          _cachedTags = tags.map((e) => e.toString()).toList();
          _tagsCachedAt = DateTime.now();
          await _persistTags(_cachedTags!);
          return _cachedTags!;
        } else {
          return [];
        }
      } catch (e) {
        debugPrint('API: Exception fetching tags: $e');
        return [];
      }
    });
  }

  Future<BillingStatus?> fetchBillingStatus({bool forceRefresh = false}) async {
    if (!isAuthenticated) return null;
    if (!forceRefresh &&
        _cachedBillingStatus != null &&
        _billingCachedAt != null &&
        DateTime.now().difference(_billingCachedAt!) < _billingCacheDuration) {
      return _cachedBillingStatus;
    }

    try {
      final status = await _fetchBillingStatusDirect();
      if (status != null) {
        _cachedBillingStatus = status;
        _billingCachedAt = DateTime.now();
        return _cachedBillingStatus;
      }
    } catch (e) {
      debugPrint('API: Direct Supabase billing failed, falling back: $e');
    }

    try {
      final response = await http.get(
        Uri.parse(AppConfig.billingStatusUrl),
        headers: _getAuthHeaders(),
      );
      if (response.statusCode == 200) {
        _cachedBillingStatus = BillingStatus.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
        _billingCachedAt = DateTime.now();
        return _cachedBillingStatus;
      }
      debugPrint(
          'API: Billing status error ${response.statusCode}: ${response.body}');
      return null;
    } catch (e) {
      debugPrint('API: Exception fetching billing status: $e');
      return null;
    }
  }

  Future<AppBootstrap?> fetchAppBootstrap({int notesLimit = 80}) async {
    if (!isAuthenticated) return null;
    return _singleFlight.run<AppBootstrap?>(
      'bootstrap:$notesLimit',
      () => _fetchAppBootstrapInternal(notesLimit: notesLimit),
    );
  }

  Future<AppBootstrap?> _fetchAppBootstrapInternal(
      {required int notesLimit}) async {
    if (!isAuthenticated) return null;

    try {
      final response = await http.get(
        Uri.parse(AppConfig.appBootstrapUrl(notesLimit: notesLimit)),
        headers: _getAuthHeaders(),
      );
      if (response.statusCode != 200) {
        debugPrint(
            'API: Bootstrap error ${response.statusCode}: ${response.body}');
        return null;
      }

      final bootstrap = AppBootstrap.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      _cachedTags = bootstrap.tags;
      _tagsCachedAt = DateTime.now();
      _cachedBillingStatus = bootstrap.billing;
      _billingCachedAt = DateTime.now();
      _cachedGroups = bootstrap.groups;
      _groupsCachedAt = DateTime.now();
      // Only overwrite the collections cache when the worker actually
      // returned data (the legacy fan-out fallback sends back empty lists,
      // which would otherwise blank out the snaps screen chip strip).
      if (bootstrap.tagCollections.isNotEmpty ||
          bootstrap.typeCollections.isNotEmpty) {
        _cachedTagCollections = bootstrap.tagCollections;
        _cachedTypeCollections = bootstrap.typeCollections;
        _collectionsCachedAt = DateTime.now();
      }
      if (notesLimit > 0 || bootstrap.recentNotes.isNotEmpty) {
        _cachedRecentNotes = bootstrap.recentNotes;
        _cachedRecentNotesHasMore = bootstrap.recentNotesHasMore;
        _recentNotesCachedAt = DateTime.now();
      }
      await Future.wait([
        _persistTags(bootstrap.tags),
        _persistGroups(bootstrap.groups),
      ]);
      return bootstrap;
    } catch (e) {
      debugPrint('API: Exception fetching bootstrap: $e');
      return null;
    }
  }

  List<Note> get cachedRecentNotes =>
      List<Note>.unmodifiable(_cachedRecentNotes ?? const <Note>[]);

  Future<BillingStatus?> upgradeToPremiumDev() async {
    final status = await _postBillingAction(AppConfig.billingUpgradeDevUrl);
    if (status != null) {
      _cachedBillingStatus = status;
      _billingCachedAt = DateTime.now();
    }
    return status;
  }

  Future<BillingStatus?> cancelPremium() async {
    final status = await _postBillingAction(AppConfig.billingCancelUrl);
    if (status != null) {
      _cachedBillingStatus = status;
      _billingCachedAt = DateTime.now();
    }
    return status;
  }

  Future<BillingStatus?> reactivatePremium() async {
    final status = await _postBillingAction(AppConfig.billingReactivateUrl);
    if (status != null) {
      _cachedBillingStatus = status;
      _billingCachedAt = DateTime.now();
    }
    return status;
  }

  Future<BillingStatus?> _postBillingAction(String url) async {
    if (!isAuthenticated) return null;

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );
      if (response.statusCode == 200) {
        return BillingStatus.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
      }
      debugPrint(
          'API: Billing action error ${response.statusCode}: ${response.body}');
      return null;
    } catch (e) {
      debugPrint('API: Exception posting billing action: $e');
      return null;
    }
  }

  /// Search notes using RAG
  Future<List<Note>> searchNotes(String query) async {
    if (!isAuthenticated || query.trim().isEmpty) {
      return [];
    }

    // Task C: route through activeSearchUrl (agent v2 by default) instead
    // of hard-coding the legacy /rag-search-auth endpoint. Prevents a
    // future caller of this helper from silently reintroducing classic
    // pipeline traffic.
    final url = AppConfig.activeSearchUrl;
    debugPrint('API: Searching notes: $query');

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: _getAuthHeaders(),
        body: json.encode({'query': query, 'limit': 10}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = data['results'] as List<dynamic>? ?? [];
        return results.map((json) => Note.fromJson(json)).toList();
      } else {
        return [];
      }
    } catch (e) {
      debugPrint('API: Exception searching: $e');
      return [];
    }
  }

  /// Get view URL for a note (matches web openNote function)
  /// Calls: GET ${API_BASE}/notes/${noteId}/view-token
  Future<String?> getViewUrl(String noteId) async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated');
      return null;
    }

    final url = '${AppConfig.notesUrl}$noteId/view-token';
    debugPrint('API: Getting view URL for note $noteId');

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final viewUrl = data['view_url'] as String?;
        debugPrint('API: Got view URL: $viewUrl');
        return viewUrl;
      } else {
        debugPrint('API: Error ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('API: Exception getting view URL: $e');
      return null;
    }
  }

  /// Get AI-generated highlights for a note.
  /// Returns cached result if available, otherwise calls backend and falls back
  /// to splitting [note]'s contentPreview into sentences.
  Future<List<String>> getHighlights(String noteId,
      {String? fallbackPreview}) async {
    if (_highlightsCache.containsKey(noteId)) {
      return _highlightsCache[noteId]!;
    }

    if (isAuthenticated) {
      try {
        final url = AppConfig.noteHighlightsUrl(noteId);
        debugPrint('API: Fetching highlights from $url');
        final response =
            await http.get(Uri.parse(url), headers: _getAuthHeaders());
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final rawList = data['highlights'] as List<dynamic>?;
          if (rawList != null && rawList.isNotEmpty) {
            final highlights = rawList.map((e) => e.toString()).toList();
            _highlightsCache[noteId] = highlights;
            debugPrint('API: Got ${highlights.length} highlights for $noteId');
            return highlights;
          }
        } else {
          debugPrint(
              'API: Highlights error ${response.statusCode}: ${response.body}');
        }
      } catch (e) {
        debugPrint('API: Exception fetching highlights: $e');
      }
    }

    // Fallback: split contentPreview into sentences
    final bullets = _previewToBullets(fallbackPreview);
    // Only cache non-empty fallbacks. An empty result usually means the note
    // is still being processed and content hasn't landed yet — caching an
    // empty list would prevent re-fetch once the upload finishes.
    if (bullets.isNotEmpty) {
      _highlightsCache[noteId] = bullets;
    }
    return bullets;
  }

  /// Fetch the generated "The infoSnap Times" edition for the user.
  ///
  /// [days] = look-back window in days (1 = yesterday only).
  /// Returns null if unauthenticated or the backend errors. Caller is expected
  /// to fall back to the baked sample edition in that case.
  Future<NewspaperEdition?> fetchNewspaperEdition({int days = 1}) async {
    if (!isAuthenticated) {
      debugPrint('API: Newspaper — not authenticated');
      return null;
    }
    final url = AppConfig.newspaperUrl(days: days);
    debugPrint('API: Fetching newspaper edition from $url');
    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: _getAuthHeaders(),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        debugPrint(
            'API: Newspaper error ${response.statusCode}: ${response.body}');
        return null;
      }
      final decoded = json.decode(response.body);
      if (decoded is! Map) {
        debugPrint('API: Newspaper — unexpected payload shape');
        return null;
      }
      if (decoded.containsKey('error')) {
        debugPrint('API: Newspaper backend error: ${decoded['error']}');
        return null;
      }
      return NewspaperEditionJson.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      debugPrint('API: Exception fetching newspaper edition: $e');
      return null;
    }
  }

  /// Split a content preview string into 3-5 bullet sentence strings.
  List<String> _previewToBullets(String? preview) {
    if (preview == null || preview.trim().isEmpty) return [];
    final sentences = preview
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.length > 10)
        .take(5)
        .toList();
    if (sentences.isNotEmpty) return sentences;
    // Fallback: return the whole preview trimmed as a single bullet
    final trimmed = preview.trim();
    return [trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed];
  }

  /// Fetch full quick-note content for edit prefill.
  /// Uses signed view URL HTML and extracts the note body when available.
  Future<String> getQuickNoteContentForEditing(String noteId,
      {String fallback = ''}) async {
    if (!isAuthenticated) {
      return fallback;
    }

    try {
      final viewUrl = await getViewUrl(noteId);
      if (viewUrl == null || viewUrl.isEmpty) {
        return fallback;
      }

      final response = await http.get(Uri.parse(viewUrl));
      if (response.statusCode != 200) {
        return fallback;
      }

      final html = response.body;
      final match =
          RegExp(r'<div class="note-content">(.*?)</div>', dotAll: true)
              .firstMatch(html);
      if (match == null || match.groupCount == 0) {
        return fallback;
      }

      var content = match.group(1) ?? '';
      content =
          content.replaceAll(RegExp(r'<br\\s*/?>', caseSensitive: false), '\n');
      content = content.replaceAll(RegExp(r'<[^>]+>'), '');
      content = _decodeBasicHtmlEntities(content).trim();
      return content.isNotEmpty ? content : fallback;
    } catch (e) {
      debugPrint('API: Exception fetching quick note edit content: $e');
      return fallback;
    }
  }

  String _decodeBasicHtmlEntities(String input) {
    return input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  /// Delete a note
  /// Matches web frontend: DELETE ${API_BASE}/notes/${noteId}
  Future<bool> deleteNote(String noteId) async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated');
      return false;
    }

    final url = '${AppConfig.notesUrl}$noteId';
    debugPrint('API: Deleting note $noteId');

    try {
      final response = await http.delete(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('API: Note deleted successfully');
        return true;
      } else {
        debugPrint('API: Error ${response.statusCode}: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('API: Exception deleting note: $e');
      return false;
    }
  }

  /// Edit a quick note via async DO pipeline.
  /// Returns {success: true, trace_id: '...'} on 202 (processing started).
  Future<Map<String, dynamic>> recreateQuickNote({
    required String noteId,
    required String content,
    String? title,
    String? tag,
    String? description,
  }) async {
    if (!isAuthenticated) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    final url = '${AppConfig.notesUrl}$noteId/recreate';
    debugPrint('API: Edit quick note $noteId (DO async)');

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: _getAuthHeaders(),
        body: jsonEncode({
          'content': content,
          if (title != null && title.isNotEmpty) 'title': title,
          if (tag != null && tag.isNotEmpty) 'tag': tag,
          if (description != null && description.isNotEmpty)
            'description': description,
        }),
      );

      if (response.statusCode == 202) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return {
          'success': true,
          'pending': true,
          'trace_id': data['trace_id'] as String?,
        };
      }

      final data = jsonDecode(response.body);
      return {
        'success': false,
        'error': data is Map<String, dynamic>
            ? (data['error']?.toString() ?? 'Failed to update quick note')
            : 'Failed to update quick note',
      };
    } catch (e) {
      debugPrint('API: Exception editing quick note: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Delete multiple notes at once
  /// Returns a map with {success, deleted: List<String>, failed: List<{id, error}>}
  Future<Map<String, dynamic>> deleteNotes(List<String> noteIds) async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated');
      return {
        'success': false,
        'error': 'Not authenticated',
        'deleted': [],
        'failed': noteIds
            .map((id) => {'id': id, 'error': 'Not authenticated'})
            .toList()
      };
    }

    if (noteIds.isEmpty) {
      return {'success': true, 'deleted': [], 'failed': []};
    }

    final url = '${AppConfig.notesUrl}bulk';
    debugPrint('API: Bulk deleting ${noteIds.length} notes');

    try {
      final response = await http.delete(
        Uri.parse(url),
        headers: {
          ..._getAuthHeaders(),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'ids': noteIds}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint(
            'API: Bulk delete completed - ${data['total_deleted']} deleted, ${data['total_failed']} failed');
        return {
          'success': true,
          'deleted': List<String>.from(data['deleted'] ?? []),
          'failed': data['failed'] ?? [],
          'total_deleted': data['total_deleted'] ?? 0,
          'total_failed': data['total_failed'] ?? 0,
        };
      } else {
        debugPrint('API: Error ${response.statusCode}: ${response.body}');
        return {
          'success': false,
          'error': 'Failed to delete notes',
          'deleted': [],
          'failed':
              noteIds.map((id) => {'id': id, 'error': 'API error'}).toList(),
        };
      }
    } catch (e) {
      debugPrint('API: Exception bulk deleting notes: $e');
      return {
        'success': false,
        'error': e.toString(),
        'deleted': [],
        'failed':
            noteIds.map((id) => {'id': id, 'error': e.toString()}).toList(),
      };
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Upload: Save Webpage
  // ═══════════════════════════════════════════════════════════════════════

  /// Save a webpage URL - worker fetches the page and processes it
  /// Returns a map with {success, trace_id, error}
  Future<Map<String, dynamic>> saveWebpage(String url,
      {String? tag, String? description}) async {
    if (!isAuthenticated) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    final apiUrl = AppConfig.uploadWebpageUrl;
    debugPrint('API: Saving webpage $url');

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          ..._getAuthHeaders(),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'url': url,
          if (tag != null && tag.isNotEmpty) 'tag': tag,
          if (description != null && description.isNotEmpty)
            'description': description,
        }),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 202 && data['success'] == true) {
        debugPrint('API: Webpage accepted, trace_id=${data['trace_id']}');
        return {
          'success': true,
          'trace_id': data['trace_id'],
          'page_title': data['page_title'],
        };
      } else {
        final error = data['error'] ?? 'Failed to save webpage';
        debugPrint('API: Webpage save error: $error');
        return {'success': false, 'error': error, 'code': data['code']};
      }
    } catch (e) {
      debugPrint('API: Exception saving webpage: $e');
      return {'success': false, 'error': 'Network error: $e'};
    }
  }

  /// Cancel an in-progress upload by trace_id with detailed result.
  Future<Map<String, dynamic>> cancelUploadDetailed(String traceId) async {
    if (!isAuthenticated) {
      return {
        'success': false,
        'statusCode': 401,
        'too_late': false,
        'message': 'Not authenticated',
      };
    }

    final url = AppConfig.uploadCancelUrl(traceId);

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );

      Map<String, dynamic> data = {};
      try {
        data = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        data = {};
      }

      final message = (data['message'] ?? data['error'] ?? '').toString();
      final messageLower = message.toLowerCase();
      final tooLate = response.statusCode == 409 ||
          messageLower.contains('too late to cancel') ||
          messageLower.contains('already completed');

      return {
        'success': response.statusCode == 200,
        'statusCode': response.statusCode,
        'too_late': tooLate,
        'message': message,
      };
    } catch (e) {
      debugPrint('API: Exception cancelling upload: $e');
      return {
        'success': false,
        'statusCode': 0,
        'too_late': false,
        'message': 'Network error while cancelling upload',
      };
    }
  }

  /// Cancel an in-progress upload by trace_id.
  Future<bool> cancelUpload(String traceId) async {
    final result = await cancelUploadDetailed(traceId);
    return result['success'] == true;
  }

  /// Poll upload status by trace_id
  /// Returns a map with {status, current_step, error_message, ...}
  Future<Map<String, dynamic>?> getUploadStatus(String traceId) async {
    if (!isAuthenticated) return null;

    final url = AppConfig.uploadStatusUrl(traceId);

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('API: Exception polling upload status: $e');
      return null;
    }
  }

  Future<List<GroupSummary>> fetchGroups() async {
    return fetchGroupsCached();
  }

  Future<List<GroupSummary>> fetchGroupsCached(
      {bool forceRefresh = false}) async {
    if (!isAuthenticated) return [];
    if (!forceRefresh &&
        _cachedGroups != null &&
        _groupsCachedAt != null &&
        DateTime.now().difference(_groupsCachedAt!) < _groupsCacheDuration) {
      return _cachedGroups!;
    }
    return _singleFlight.run<List<GroupSummary>>(
        'groups:${forceRefresh ? 'fresh' : 'cached'}', () async {
      try {
        final response = await http.get(
          Uri.parse(AppConfig.groupsUrl),
          headers: _getAuthHeaders(),
        );
        if (response.statusCode != 200) return [];
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        _cachedGroups = ((decoded['groups'] as List?) ?? [])
            .whereType<Map<String, dynamic>>()
            .map(GroupSummary.fromJson)
            .toList();
        _groupsCachedAt = DateTime.now();
        await _persistGroups(_cachedGroups!);
        return _cachedGroups!;
      } catch (e) {
        debugPrint('API: Exception fetching groups: $e');
        return [];
      }
    });
  }

  Future<GroupDetail?> fetchGroup(String groupId) async {
    if (!isAuthenticated) return null;
    try {
      final response = await http.get(
        Uri.parse(AppConfig.groupUrl(groupId)),
        headers: _getAuthHeaders(),
      );
      if (response.statusCode != 200) return null;
      return GroupDetail.fromJson(jsonDecode(response.body));
    } catch (e) {
      debugPrint('API: Exception fetching group: $e');
      return null;
    }
  }

  Future<GroupSummary?> createGroup(String name) async {
    if (!isAuthenticated) return null;
    try {
      final response = await http.post(
        Uri.parse(AppConfig.groupsUrl),
        headers: _getAuthHeaders(),
        body: jsonEncode({'name': name}),
      );
      if (response.statusCode != 201 && response.statusCode != 200) {
        return null;
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final group = GroupSummary.fromJson({
        ...(decoded['group'] as Map<String, dynamic>? ?? {}),
        'member_count': 1,
        'unread_count': 0,
        'role': 'admin',
      });
      _cachedGroups = [
        group,
        ...?_cachedGroups?.where((item) => item.id != group.id),
      ];
      _groupsCachedAt = DateTime.now();
      await _persistGroups(_cachedGroups!);
      return group;
    } catch (e) {
      debugPrint('API: Exception creating group: $e');
      return null;
    }
  }

  Future<List<GroupUser>> searchUsers(String query) async {
    if (!isAuthenticated || query.trim().length < 2) return [];
    try {
      final response = await http.get(
        Uri.parse(AppConfig.userSearchUrl(query)),
        headers: _getAuthHeaders(),
      );
      if (response.statusCode != 200) return [];
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return ((decoded['users'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(GroupUser.fromJson)
          .toList();
    } catch (e) {
      debugPrint('API: Exception searching users: $e');
      return [];
    }
  }

  Future<List<GroupSummary>> discoverGroups(String query) async {
    if (!isAuthenticated || query.trim().length < 2) return [];
    try {
      final response = await http.get(
        Uri.parse(AppConfig.groupDiscoverUrl(query)),
        headers: _getAuthHeaders(),
      );
      if (response.statusCode != 200) return [];
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return ((decoded['groups'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(GroupSummary.fromJson)
          .toList();
    } catch (e) {
      debugPrint('API: Exception discovering groups: $e');
      return [];
    }
  }

  Future<bool> inviteToGroup(String groupId,
      {String? userId, String? email}) async {
    if (!isAuthenticated) return false;
    try {
      final response = await http.post(
        Uri.parse(AppConfig.groupInviteUrl(groupId)),
        headers: _getAuthHeaders(),
        body: jsonEncode({
          if (userId != null) 'user_id': userId,
          if (email != null) 'email': email,
        }),
      );
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (ok) invalidateGroupsCache();
      return ok;
    } catch (e) {
      debugPrint('API: Exception inviting to group: $e');
      return false;
    }
  }

  Future<bool> acceptGroupInvite(String groupId) async {
    final ok = await _postOk(AppConfig.groupAcceptUrl(groupId));
    if (ok) invalidateGroupsCache();
    return ok;
  }

  Future<bool> declineGroupInvite(String groupId) async {
    final ok = await _postOk(AppConfig.groupDeclineUrl(groupId));
    if (ok) invalidateGroupsCache();
    return ok;
  }

  Future<bool> requestJoinGroup(String groupId) async {
    final ok = await _postOk(AppConfig.groupJoinUrl(groupId));
    if (ok) invalidateGroupsCache();
    return ok;
  }

  Future<bool> approveJoinRequest(String groupId, String requestId) async {
    final ok =
        await _postOk(AppConfig.groupApproveRequestUrl(groupId, requestId));
    if (ok) invalidateGroupsCache();
    return ok;
  }

  Future<bool> denyJoinRequest(String groupId, String requestId) async {
    final ok = await _postOk(AppConfig.groupDenyRequestUrl(groupId, requestId));
    if (ok) invalidateGroupsCache();
    return ok;
  }

  Future<bool> transferGroupAdmin(String groupId, String userId) async {
    if (!isAuthenticated) return false;
    try {
      final response = await http.post(
        Uri.parse(AppConfig.groupTransferAdminUrl(groupId)),
        headers: _getAuthHeaders(),
        body: jsonEncode({'user_id': userId}),
      );
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (ok) invalidateGroupsCache();
      return ok;
    } catch (e) {
      debugPrint('API: Exception transferring admin: $e');
      return false;
    }
  }

  Future<String?> uploadGroupAvatar(
    String groupId, {
    required List<int> bytes,
    required String filename,
    required String contentType,
  }) async {
    if (!isAuthenticated) return null;
    try {
      final response = await http.post(
        Uri.parse(AppConfig.groupAvatarUrl(groupId)),
        headers: _getAuthHeaders(),
        body: jsonEncode({
          'filename': filename,
          'content_type': contentType,
          'bytes_base64': base64Encode(bytes),
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      invalidateGroupsCache();
      return decoded['avatar_url']?.toString();
    } catch (e) {
      debugPrint('API: Exception uploading group avatar: $e');
      return null;
    }
  }

  Future<String?> uploadUserAvatar({
    required List<int> bytes,
    required String filename,
    required String contentType,
  }) async {
    if (!isAuthenticated) return null;
    try {
      final response = await http.post(
        Uri.parse(AppConfig.userAvatarUrl()),
        headers: _getAuthHeaders(),
        body: jsonEncode({
          'filename': filename,
          'content_type': contentType,
          'bytes_base64': base64Encode(bytes),
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
            'API: uploadUserAvatar failed ${response.statusCode}: ${response.body}');
        return null;
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return decoded['avatar_url']?.toString();
    } catch (e) {
      debugPrint('API: Exception uploading user avatar: $e');
      return null;
    }
  }

  Future<bool> shareSnapToGroup(String groupId, String noteId) async {
    if (!isAuthenticated) return false;
    try {
      final response = await http.post(
        Uri.parse(AppConfig.groupSnapsUrl(groupId)),
        headers: _getAuthHeaders(),
        body: jsonEncode({'note_id': noteId}),
      );
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (ok) invalidateGroupsCache();
      return ok;
    } catch (e) {
      debugPrint('API: Exception sharing snap to group: $e');
      return false;
    }
  }

  Future<bool> reactToGroupSnap(
    String groupId,
    String snapId,
    String? emoji,
  ) async {
    if (!isAuthenticated) return false;
    try {
      final response = await http.post(
        Uri.parse(AppConfig.groupSnapReactionUrl(groupId, snapId)),
        headers: _getAuthHeaders(),
        body: jsonEncode({'emoji': emoji}),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('API: Exception reacting to group snap: $e');
      return false;
    }
  }

  Future<bool> markGroupSeen(String groupId) async {
    final ok = await _postOk(AppConfig.groupSeenUrl(groupId));
    if (ok && _cachedGroups != null) {
      _cachedGroups = _cachedGroups!
          .map((group) =>
              group.id == groupId ? group.copyWith(unreadCount: 0) : group)
          .toList(growable: false);
      _groupsCachedAt = DateTime.now();
      await _persistGroups(_cachedGroups!);
    }
    return ok;
  }

  Future<bool> leaveGroup(String groupId, {String? successorUserId}) async {
    if (!isAuthenticated) return false;
    final url = successorUserId?.trim().isNotEmpty == true
        ? '${AppConfig.groupLeaveUrl(groupId)}?successor_user_id=${Uri.encodeQueryComponent(successorUserId!.trim())}'
        : AppConfig.groupLeaveUrl(groupId);
    final ok = await _postOk(
      url,
      body: successorUserId?.trim().isNotEmpty == true
          ? {'successor_user_id': successorUserId!.trim()}
          : null,
    );
    if (ok && _cachedGroups != null) {
      _cachedGroups =
          _cachedGroups!.where((group) => group.id != groupId).toList();
      _groupsCachedAt = DateTime.now();
      await _persistGroups(_cachedGroups!);
    } else if (ok) {
      invalidateGroupsCache();
    }
    return ok;
  }

  Future<bool> registerDeviceToken({
    required String token,
    String platform = 'android',
    String? appVersion,
    String? deviceId,
  }) async {
    if (!isAuthenticated || token.trim().isEmpty) return false;
    try {
      final response = await http.post(
        Uri.parse(AppConfig.deviceTokensUrl),
        headers: _getAuthHeaders(),
        body: jsonEncode({
          'token': token.trim(),
          'platform': platform,
          if (appVersion != null) 'app_version': appVersion,
          if (deviceId != null) 'device_id': deviceId,
        }),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('API: Exception registering device token: $e');
      return false;
    }
  }

  Future<bool> _postOk(String url, {Map<String, dynamic>? body}) async {
    if (!isAuthenticated) return false;
    try {
      final response = await http.post(
        Uri.parse(url),
        headers: _getAuthHeaders(),
        body: body == null ? null : jsonEncode(body),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('API: Exception POST $url: $e');
      return false;
    }
  }
}
