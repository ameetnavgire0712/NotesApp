import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';

/// Note model matching backend response
class Note {
  final String id;
  final String title;
  final String? contentType;
  final String? sourceUrl;
  final String? sourceDomain;
  final int? wordCount;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final List<String> tags;
  final String? thumbnailUrl;
  final String? contentPreview;

  Note({
    required this.id,
    required this.title,
    this.contentType,
    this.sourceUrl,
    this.sourceDomain,
    this.wordCount,
    required this.createdAt,
    this.updatedAt,
    this.tags = const [],
    this.thumbnailUrl,
    this.contentPreview,
  });

  factory Note.fromJson(Map<String, dynamic> json) {
    // Handle both 'tag' (singular from backend) and 'tags' (array)
    List<String> parsedTags = [];
    if (json['tags'] != null && json['tags'] is List) {
      parsedTags = (json['tags'] as List<dynamic>).map((e) => e.toString()).toList();
    } else if (json['tag'] != null && json['tag'].toString().isNotEmpty) {
      parsedTags = [json['tag'].toString()];
    } else if (json['file_type'] != null && json['file_type'].toString().isNotEmpty) {
      parsedTags = [json['file_type'].toString()];
    }
    
    // Detect webpage type: file_type is 'uploaded_file' but metadata.source_url exists
    String? rawContentType = json['content_type'] ?? json['file_type'];
    String? sourceUrl = json['source_url'];
    
    // Extract source_url from metadata if not at top level
    if (sourceUrl == null && json['metadata'] is Map) {
      sourceUrl = (json['metadata'] as Map)['source_url']?.toString();
    }
    
    // If file_type is uploaded_file but has a source_url, it's actually a webpage
    if (rawContentType == 'uploaded_file' && sourceUrl != null && sourceUrl.isNotEmpty) {
      rawContentType = 'webpage';
    }

    return Note(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      contentType: rawContentType,
      sourceUrl: sourceUrl,
      sourceDomain: json['source_domain'],
      wordCount: json['word_count'],
      createdAt: DateTime.tryParse(json['created_at'] ?? json['uploaded_at'] ?? '') ?? DateTime.now(),
      updatedAt: json['updated_at'] != null ? DateTime.tryParse(json['updated_at']) : null,
      tags: parsedTags,
      thumbnailUrl: json['thumbnail_url'],
      contentPreview: json['content_preview'] ?? json['content'] ?? json['snippet'],
    );
  }

  /// Get icon based on content type
  String get icon {
    switch (contentType) {
      case 'article':
        return '📄';
      case 'youtube':
        return '🎬';
      case 'pdf':
        return '📕';
      case 'tweet':
        return '🐦';
      case 'image':
        return '🖼️';
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

/// API Service for backend calls - mirrors web frontend API usage
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // Tags cache — refreshed at most every 5 minutes
  List<String>? _cachedTags;
  DateTime? _tagsCachedAt;
  static const _tagsCacheDuration = Duration(minutes: 5);

  /// Invalidate the tags cache (call after creating a new tag)
  void invalidateTagsCache() {
    _cachedTags = null;
    _tagsCachedAt = null;
  }

  /// Get Supabase client
  SupabaseClient get _client => Supabase.instance.client;

  /// Get current access token for API calls
  String? get _accessToken => _client.auth.currentSession?.accessToken;

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

  /// Fetch all notes for the user (no pagination)
  Future<List<Note>> fetchNotes() async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated, returning empty list');
      return [];
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

  /// Fetch notes with pagination and optional sorting
  Future<List<Note>> fetchNotesPaginated({required int limit, required int offset, String? sort}) async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated, returning empty list');
      return [];
    }

    final url = AppConfig.notesPaginatedUrl(limit, offset, sort: sort);
    debugPrint('API: Fetching paginated notes from $url');

    try {
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
          debugPrint('API: Response is direct list with ${data.length} items');
        } else {
          debugPrint('API: Unexpected response format: ${decoded.runtimeType}');
          debugPrint('API: Response keys: ${decoded is Map ? decoded.keys.toList() : "not a map"}');
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
    if (!forceRefresh && _cachedTags != null && _tagsCachedAt != null &&
        DateTime.now().difference(_tagsCachedAt!) < _tagsCacheDuration) {
      debugPrint('API: Returning cached tags (${_cachedTags!.length} tags)');
      return _cachedTags!;
    }

    final url = AppConfig.notesTagsUrl;
    debugPrint('API: Fetching tags from $url');

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> tags = data['tags'] ?? [];
        _cachedTags = tags.map((e) => e.toString()).toList();
        _tagsCachedAt = DateTime.now();
        return _cachedTags!;
      } else {
        return [];
      }
    } catch (e) {
      debugPrint('API: Exception fetching tags: $e');
      return [];
    }
  }

  /// Search notes using RAG
  Future<List<Note>> searchNotes(String query) async {
    if (!isAuthenticated || query.trim().isEmpty) {
      return [];
    }

    final url = AppConfig.ragSearchUrl;
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

  /// Delete multiple notes at once
  /// Returns a map with {success, deleted: List<String>, failed: List<{id, error}>}
  Future<Map<String, dynamic>> deleteNotes(List<String> noteIds) async {
    if (!isAuthenticated) {
      debugPrint('API: Not authenticated');
      return {'success': false, 'error': 'Not authenticated', 'deleted': [], 'failed': noteIds.map((id) => {'id': id, 'error': 'Not authenticated'}).toList()};
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
        debugPrint('API: Bulk delete completed - ${data['total_deleted']} deleted, ${data['total_failed']} failed');
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
          'failed': noteIds.map((id) => {'id': id, 'error': 'API error'}).toList(),
        };
      }
    } catch (e) {
      debugPrint('API: Exception bulk deleting notes: $e');
      return {
        'success': false,
        'error': e.toString(),
        'deleted': [],
        'failed': noteIds.map((id) => {'id': id, 'error': e.toString()}).toList(),
      };
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Upload: Save Webpage
  // ═══════════════════════════════════════════════════════════════════════

  /// Save a webpage URL - worker fetches the page and processes it
  /// Returns a map with {success, trace_id, error} 
  Future<Map<String, dynamic>> saveWebpage(String url, {String? tag, String? description}) async {
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
          if (description != null && description.isNotEmpty) 'description': description,
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

  /// Cancel an in-progress upload by trace_id
  Future<bool> cancelUpload(String traceId) async {
    if (!isAuthenticated) return false;

    final url = AppConfig.uploadCancelUrl(traceId);

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: _getAuthHeaders(),
      );

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('API: Exception cancelling upload: $e');
      return false;
    }
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
}
