/// App configuration - matches web frontend config.js
class AppConfig {
  AppConfig._();

  /// Supabase configuration
  static const String supabaseUrl = 'https://vnpqsmiuismvwsynpmfu.supabase.co';
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZucHFzbWl1aXNtdndzeW5wbWZ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc5NDM3OTUsImV4cCI6MjA4MzUxOTc5NX0.D-U6mkNHxh8mGYwgQy9-qEKh3e2wLNirppV2ASivrUg';

  /// Worker URL - handles all API endpoints directly with Supabase
  /// Same as web frontend config.js WORKER_URL
  static const String workerUrl =
      'https://notesapp-vector-search.monocle0712.workers.dev';

  /// API Endpoints - same as web frontend
  static const String apiNotesEndpoint = '/api/v1/notes/';
  static const String apiNotesStatsEndpoint = '/api/v1/notes/stats';
  static const String apiNotesTagsEndpoint = '/api/v1/notes/tags/all';
  static const String apiAuthMeEndpoint = '/api/v1/auth/me';
  static const String apiAppBootstrapEndpoint = '/api/v1/app/bootstrap';
  static const String apiChatEndpoint = '/api/v1/chat/';
  static const String ragSearchEndpoint = '/rag-search-auth';
  static const String ragSearchContinueEndpoint = '/rag-search-continue-auth';
  static const String agentSearchEndpoint = '/agent-search-auth';

  /// Toggle: when true, search calls go through the new agent endpoint
  /// (which forwards unsupported queries to /rag-search-auth automatically).
  static const bool useAgentSearch = true;
  static const String apiBillingStatusEndpoint = '/api/v1/billing/status';
  static const String apiBillingUpgradeDevEndpoint =
      '/api/v1/billing/upgrade-dev';
  static const String apiBillingCancelEndpoint = '/api/v1/billing/cancel';
  static const String apiBillingReactivateEndpoint =
      '/api/v1/billing/reactivate';
  static const String apiBillingHistoryEndpoint = '/api/v1/billing/history';
  static const String apiGroupsEndpoint = '/api/v1/groups';
  static const String apiUserSearchEndpoint = '/api/v1/users/search';
  static const String apiNotificationsEndpoint = '/api/v1/notifications';
  static const String apiDeviceTokensEndpoint = '/api/v1/device-tokens';

  /// Upload endpoints
  static const String apiUploadWebpageEndpoint = '/api/v1/upload/webpage';
  static const String apiUploadSharedUrlEndpoint = '/api/v1/upload/shared-url';
  static const String apiUploadStatusEndpoint =
      '/api/v1/upload/status/'; // append trace_id
  static const String apiUploadCancelEndpoint =
      '/api/v1/upload/cancel/'; // append trace_id

  /// Build full API URL
  static String buildUrl(String endpoint) {
    return '$workerUrl$endpoint';
  }

  /// Notes endpoints
  static String get notesUrl => buildUrl(apiNotesEndpoint);
  static String get notesStatsUrl => buildUrl(apiNotesStatsEndpoint);
  static String get notesTagsUrl => buildUrl(apiNotesTagsEndpoint);
  static String get authMeUrl => buildUrl(apiAuthMeEndpoint);
  static String appBootstrapUrl({int notesLimit = 80}) =>
      buildUrl('$apiAppBootstrapEndpoint?notes_limit=$notesLimit');
  static String get chatUrl => buildUrl(apiChatEndpoint);
  static String get ragSearchUrl => buildUrl(ragSearchEndpoint);
  static String get ragSearchContinueUrl => buildUrl(ragSearchContinueEndpoint);
  static String get agentSearchUrl => buildUrl(agentSearchEndpoint);

  /// Returns the active search URL based on [useAgentSearch].
  static String get activeSearchUrl =>
      useAgentSearch ? agentSearchUrl : ragSearchUrl;
  static String get billingStatusUrl => buildUrl(apiBillingStatusEndpoint);
  static String get billingUpgradeDevUrl =>
      buildUrl(apiBillingUpgradeDevEndpoint);
  static String get billingCancelUrl => buildUrl(apiBillingCancelEndpoint);
  static String get billingReactivateUrl =>
      buildUrl(apiBillingReactivateEndpoint);
  static String get billingHistoryUrl => buildUrl(apiBillingHistoryEndpoint);
  static String get groupsUrl => buildUrl(apiGroupsEndpoint);
  static String groupUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId');
  static String groupInviteUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/invite');
  static String groupDiscoverUrl(String query) =>
      buildUrl('$apiGroupsEndpoint/discover?q=${Uri.encodeQueryComponent(query)}');
  static String groupJoinUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/join');
  static String groupAcceptUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/accept');
  static String groupDeclineUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/decline');
  static String groupApproveRequestUrl(String groupId, String requestId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/requests/$requestId/approve');
  static String groupDenyRequestUrl(String groupId, String requestId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/requests/$requestId/deny');
  static String groupTransferAdminUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/admin');
  static String groupAvatarUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/avatar');
  static String userAvatarUrl() => buildUrl('/api/v1/users/me/avatar');
  static String groupSnapsUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/snaps');
  static String groupSnapReactionUrl(String groupId, String snapId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/snaps/$snapId/reaction');
  static String groupSeenUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/seen');
  static String groupLeaveUrl(String groupId) =>
      buildUrl('$apiGroupsEndpoint/$groupId/leave');
  static String userSearchUrl(String query) =>
      buildUrl('$apiUserSearchEndpoint?q=${Uri.encodeQueryComponent(query)}');
  static String get notificationsUrl => buildUrl(apiNotificationsEndpoint);
  static String get deviceTokensUrl => buildUrl(apiDeviceTokensEndpoint);

  /// Upload URLs
  static String get uploadWebpageUrl => buildUrl(apiUploadWebpageEndpoint);
  static String get uploadSharedUrlUrl => buildUrl(apiUploadSharedUrlEndpoint);
  static String uploadStatusUrl(String traceId) =>
      buildUrl('$apiUploadStatusEndpoint$traceId');
  static String uploadCancelUrl(String traceId) =>
      buildUrl('$apiUploadCancelEndpoint$traceId');

  /// Paginated notes URL with optional sort parameter
  /// sort: 'tag' for alphabetical tag sorting, 'date' for date sorting (default)
  static String notesPaginatedUrl(
    int limit,
    int offset, {
    String? sort,
    String? tag,
    String? fileType,
  }) {
    final params = <String>[
      'limit=$limit',
      'offset=$offset',
      if (sort != null) 'sort=$sort',
      if (tag != null && tag.isNotEmpty)
        'tag=${Uri.encodeQueryComponent(tag)}',
      if (fileType != null && fileType.isNotEmpty)
        'file_type=${Uri.encodeQueryComponent(fileType)}',
    ];
    return '$notesUrl?${params.join('&')}';
  }

  /// Highlights URL for a specific note
  static String noteHighlightsUrl(String noteId) =>
      buildUrl('$apiNotesEndpoint$noteId/highlights');

  /// Newspaper edition URL.
  /// `days` is the look-back window (1 = "yesterday only", 7 = "last week").
  static String newspaperUrl({int days = 1}) =>
      buildUrl('/api/v1/newspaper?days=$days');
}
