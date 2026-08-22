/// Note model
class Note {
  final String id;
  final String userId;
  final String? title;
  final String? content;
  final String? sourceFilename;
  final String? sourceType;
  final String? tag;
  final String? blobUrl;
  final int? fileSizeBytes;
  final DateTime createdAt;
  final DateTime? updatedAt;

  Note({
    required this.id,
    required this.userId,
    this.title,
    this.content,
    this.sourceFilename,
    this.sourceType,
    this.tag,
    this.blobUrl,
    this.fileSizeBytes,
    required this.createdAt,
    this.updatedAt,
  });

  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      title: json['title'] as String?,
      content: json['content'] as String?,
      sourceFilename: json['source_filename'] as String?,
      sourceType: json['source_type'] as String?,
      tag: json['tag'] as String?,
      blobUrl: json['blob_url'] as String?,
      fileSizeBytes: json['file_size_bytes'] as int?,
      createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String).toLocal()
          : null,
    );
  }

  String get displayTitle => title ?? sourceFilename ?? 'Untitled Note';

  String get displayType {
    if (sourceType == 'quick_note') return 'Quick Note';
    if (sourceType == 'screenshot') return 'Screenshot';
    if (sourceType == 'file') return 'Document';
    return 'Note';
  }

  String get fileExtension {
    if (sourceFilename == null) return '';
    final parts = sourceFilename!.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : '';
  }

  bool get isImage =>
      ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'].contains(fileExtension);
  bool get isPdf => fileExtension == 'pdf';
  bool get isDocument => ['doc', 'docx', 'txt'].contains(fileExtension);
}

/// User stats model
class UserStats {
  final int totalNotes;
  final int totalStorageBytes;
  final Map<String, int> notesByTag;

  UserStats({
    required this.totalNotes,
    required this.totalStorageBytes,
    required this.notesByTag,
  });

  factory UserStats.fromJson(Map<String, dynamic> json) {
    return UserStats(
      totalNotes: json['total_notes'] as int? ?? 0,
      totalStorageBytes: json['total_storage_bytes'] as int? ?? 0,
      notesByTag: Map<String, int>.from(json['notes_by_tag'] ?? {}),
    );
  }

  double get storageMB => totalStorageBytes / (1024 * 1024);
  double get storagePercent => (totalStorageBytes / (100 * 1024 * 1024)) * 100;
}

/// Upload response model
class UploadResponse {
  final bool success;
  final String? traceId;
  final String? message;
  final String? error;

  UploadResponse({
    required this.success,
    this.traceId,
    this.message,
    this.error,
  });

  factory UploadResponse.fromJson(Map<String, dynamic> json) {
    return UploadResponse(
      success: json['success'] as bool? ?? false,
      traceId: json['trace_id'] as String?,
      message: json['message'] as String?,
      error: json['error'] as String?,
    );
  }
}

/// Upload status model
class UploadStatus {
  final String traceId;
  final String status; // pending, processing, completed, failed, cancelled
  final String? currentStep;
  final String? errorMessage;
  final DateTime? completedAt;
  final String? noteId;

  UploadStatus({
    required this.traceId,
    required this.status,
    this.currentStep,
    this.errorMessage,
    this.completedAt,
    this.noteId,
  });

  factory UploadStatus.fromJson(Map<String, dynamic> json) {
    return UploadStatus(
      traceId: json['trace_id'] as String,
      status: json['status'] as String,
      currentStep: json['current_step'] as String?,
      errorMessage: json['error_message'] as String?,
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String).toLocal()
          : null,
      noteId: json['note_id'] as String?,
    );
  }

  bool get isComplete => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isCancelled => status == 'cancelled';
  bool get isProcessing => status == 'processing' || status == 'pending';

  String get displayStep {
    switch (currentStep) {
      case 'init':
        return 'Starting...';
      case 'blob_upload':
        return 'Uploading file...';
      case 'tensorlake_parse':
        return 'Converting document...';
      case 'tensorlake_poll':
        return 'Processing...';
      case 'html_cleanup':
        return 'Cleaning up content...';
      case 'title_gen':
        return 'Generating title...';
      case 'chunking':
        return 'Analyzing content...';
      case 'embedding':
        return 'Creating embeddings...';
      case 'db_insert':
        return 'Saving to database...';
      case 'vectorize':
        return 'Indexing for search...';
      case 'completed':
        return 'Complete!';
      case 'failed':
        return 'Failed';
      case 'cancelled':
        return 'Cancelled';
      default:
        return currentStep ?? 'Processing...';
    }
  }
}

/// Chat message model
class ChatMessage {
  final String id;
  final String role;
  final String content;
  final bool isUser;
  final DateTime timestamp;
  final List<SearchResult>? sources;
  final bool isStreaming;

  ChatMessage({
    String? id,
    String? role,
    required this.content,
    bool? isUser,
    DateTime? timestamp,
    this.sources,
    this.isStreaming = false,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        role = role ?? (isUser == true ? 'user' : 'assistant'),
        isUser = isUser ?? (role == 'user'),
        timestamp = timestamp ?? DateTime.now();

  ChatMessage copyWith({
    String? content,
    List<SearchResult>? sources,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      isUser: isUser,
      timestamp: timestamp,
      sources: sources ?? this.sources,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
}

/// Search result (source document)
class SearchResult {
  final String noteId;
  final String title;
  final String snippet;
  final double relevanceScore;
  final String? viewUrl;

  SearchResult({
    required this.noteId,
    required this.title,
    required this.snippet,
    required this.relevanceScore,
    this.viewUrl,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      noteId: json['note_id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      snippet: json['snippet'] as String? ?? '',
      relevanceScore: (json['relevance_score'] as num?)?.toDouble() ?? 0.0,
      viewUrl: json['view_url'] as String?,
    );
  }
}

/// User model
class User {
  final String id;
  final String email;
  final String? name;
  final String? avatarUrl;

  User({
    required this.id,
    required this.email,
    this.name,
    this.avatarUrl,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String? ?? json['user_id'] as String,
      email: json['email'] as String,
      name: json['name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }

  String get displayName => name ?? email.split('@').first;
  String get initials => displayName.substring(0, 1).toUpperCase();
}
