/// API Configuration for infoSnap.ai
class ApiConstants {
  ApiConstants._();

  // Base URL
  static const String baseUrl =
      'https://notesapp-vector-search.monocle0712.workers.dev';

  // Auth Endpoints
  static const String authMe = '/api/v1/auth/me';
  static const String apiKeys = '/api/v1/auth/api-keys';
  static const String revokeAllSessions = '/api/v1/auth/revoke-all-sessions';

  // Upload Endpoints
  static const String uploadFile = '/api/v1/upload/file';
  static const String uploadScreenshot = '/api/v1/upload/screenshot';
  static const String uploadQuickNote = '/api/v1/upload/quick-note';
  static const String uploadStatus = '/api/v1/upload/status'; // + /:trace_id
  static const String uploadCancel = '/api/v1/upload/cancel'; // + /:trace_id
  static const String uploadQuota = '/api/v1/upload/quota';

  // Notes Endpoints
  static const String notes = '/api/v1/notes';
  static const String notesStats = '/api/v1/notes/stats';
  static const String notesTags = '/api/v1/notes/tags/all';

  // Search / Chat (RAG)
  static const String ragSearch = '/rag-search-auth';

  // Timeouts
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 60);
  static const Duration uploadTimeout = Duration(minutes: 5);
}

/// App-wide constants
class AppConstants {
  AppConstants._();

  // Storage Keys
  static const String keyApiToken = 'api_token';
  static const String keyUserEmail = 'user_email';
  static const String keyUserId = 'user_id';
  static const String keyOnboardingComplete = 'onboarding_complete';
  static const String keyThemeMode = 'theme_mode';

  // File Upload Limits
  static const int maxFileSizeMB = 10;
  static const int maxFileSizeBytes = maxFileSizeMB * 1024 * 1024;
  static const int maxStorageMB = 100;

  // Supported File Types
  static const List<String> supportedFileTypes = [
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'md',
    'markdown',
    'rtf',
    'html',
    'htm',
    'csv',
    'tsv',
    'xml',
    'json',
    'yaml',
    'yml',
    'toml',
    'log',
    'ini',
    'cfg',
    'conf',
    'tex',
    'rst',
    'org',
    'odt',
    'py',
    'js',
    'ts',
    'css',
    'sql',
    'sh',
    'bat',
    'ps1',
    'env',
    'gitignore',
    'dockerignore',
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'tif',
    'tiff',
  ];

  // Animation Durations
  static const Duration animationFast = Duration(milliseconds: 200);
  static const Duration animationNormal = Duration(milliseconds: 300);
  static const Duration animationSlow = Duration(milliseconds: 500);
  static const Duration splashDuration = Duration(seconds: 2);
}
