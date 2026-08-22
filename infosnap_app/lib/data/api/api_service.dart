import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/models.dart';
import '../../core/constants/app_constants.dart';

class ApiService {
  late final Dio _dio;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  ApiService() {
    _dio = Dio(BaseOptions(
      baseUrl: ApiConstants.baseUrl,
      connectTimeout: ApiConstants.connectTimeout,
      receiveTimeout: ApiConstants.receiveTimeout,
      headers: {
        'Content-Type': 'application/json',
      },
    ));

    // Add auth interceptor
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _storage.read(key: AppConstants.keyApiToken);
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) {
        // Handle 401 - redirect to login
        if (error.response?.statusCode == 401) {
          // Token expired, clear storage
          _storage.deleteAll();
        }
        handler.next(error);
      },
    ));
  }

  // =========================================================================
  // Auth
  // =========================================================================

  Future<void> setApiKey(String apiKey) async {
    await _storage.write(key: AppConstants.keyApiToken, value: apiKey);
  }

  Future<void> setGoogleIdToken(String idToken) async {
    await _storage.write(key: AppConstants.keyApiToken, value: idToken);
  }

  Future<User?> getCurrentUser() async {
    try {
      final response = await _dio.get(ApiConstants.authMe);
      return User.fromJson(response.data);
    } catch (e) {
      return null;
    }
  }

  Future<bool> validateApiKey(String apiKey) async {
    try {
      final response = await _dio.get(
        ApiConstants.authMe,
        options: Options(headers: {'X-API-Key': apiKey}),
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<void> logout() async {
    await _storage.deleteAll();
  }

  // =========================================================================
  // Notes
  // =========================================================================

  Future<List<Note>> getNotes(
      {String? tag, int page = 1, int limit = 20}) async {
    try {
      final response = await _dio.get(
        ApiConstants.notes,
        queryParameters: {
          if (tag != null) 'tag': tag,
          'page': page,
          'limit': limit,
        },
      );

      final List<dynamic> data = response.data is List
          ? response.data
          : (response.data['notes'] ?? []);

      return data.map((json) => Note.fromJson(json)).toList();
    } catch (e) {
      rethrow;
    }
  }

  Future<Note?> getNote(String noteId) async {
    try {
      final response = await _dio.get('${ApiConstants.notes}/$noteId');
      return Note.fromJson(response.data);
    } catch (e) {
      return null;
    }
  }

  Future<bool> deleteNote(String noteId) async {
    try {
      await _dio.delete('${ApiConstants.notes}/$noteId');
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<List<String>> getTags() async {
    try {
      final response = await _dio.get(ApiConstants.notesTags);
      final List<dynamic> data = response.data['tags'] ?? [];
      return data.map((t) => t.toString()).toList();
    } catch (e) {
      return [];
    }
  }

  Future<UserStats> getStats() async {
    try {
      final response = await _dio.get(ApiConstants.notesStats);
      return UserStats.fromJson(response.data);
    } catch (e) {
      return UserStats(totalNotes: 0, totalStorageBytes: 0, notesByTag: {});
    }
  }

  // =========================================================================
  // Upload
  // =========================================================================

  Future<UploadResponse> uploadFile({
    required File file,
    required String filename,
    String tag = 'General',
    void Function(int, int)? onProgress,
  }) async {
    try {
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path, filename: filename),
        'tag': tag,
      });

      final response = await _dio.post(
        ApiConstants.uploadFile,
        data: formData,
        options: Options(
          receiveTimeout: ApiConstants.uploadTimeout,
          headers: {'Content-Type': 'multipart/form-data'},
        ),
        onSendProgress: onProgress,
      );

      return UploadResponse.fromJson(response.data);
    } on DioException catch (e) {
      return UploadResponse(
        success: false,
        error: e.response?.data?['error'] ?? e.message,
      );
    }
  }

  Future<UploadResponse> uploadScreenshot({
    required List<int> imageBytes,
    required String filename,
    String tag = 'General',
    String? sourceUrl,
  }) async {
    try {
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(imageBytes, filename: filename),
        'tag': tag,
        if (sourceUrl != null) 'source_url': sourceUrl,
      });

      final response = await _dio.post(
        ApiConstants.uploadScreenshot,
        data: formData,
        options: Options(
          receiveTimeout: ApiConstants.uploadTimeout,
          headers: {'Content-Type': 'multipart/form-data'},
        ),
      );

      return UploadResponse.fromJson(response.data);
    } on DioException catch (e) {
      return UploadResponse(
        success: false,
        error: e.response?.data?['error'] ?? e.message,
      );
    }
  }

  Future<UploadResponse> uploadQuickNote({
    required String content,
    String tag = 'General',
  }) async {
    try {
      final response = await _dio.post(
        ApiConstants.uploadQuickNote,
        data: {
          'content': content,
          'tag': tag,
        },
      );

      return UploadResponse.fromJson(response.data);
    } on DioException catch (e) {
      return UploadResponse(
        success: false,
        error: e.response?.data?['error'] ?? e.message,
      );
    }
  }

  Future<UploadStatus> getUploadStatus(String traceId) async {
    try {
      final response = await _dio.get('${ApiConstants.uploadStatus}/$traceId');
      return UploadStatus.fromJson(response.data);
    } catch (e) {
      return UploadStatus(
        traceId: traceId,
        status: 'failed',
        errorMessage: e.toString(),
      );
    }
  }

  Future<bool> cancelUpload(String traceId) async {
    try {
      await _dio.post('${ApiConstants.uploadCancel}/$traceId');
      return true;
    } catch (e) {
      return false;
    }
  }

  // =========================================================================
  // Chat / RAG Search
  // =========================================================================

  Future<Stream<String>> searchWithStreaming(String query) async {
    // For streaming responses, we use SSE
    final response = await _dio.post<ResponseBody>(
      ApiConstants.ragSearch,
      data: {
        'query': query,
        'stream': true,
      },
      options: Options(responseType: ResponseType.stream),
    );

    return response.data!.stream
        .transform(StreamTransformer.fromBind((stream) async* {
      await for (final chunk in stream) {
        yield String.fromCharCodes(chunk);
      }
    }));
  }

  Future<Map<String, dynamic>> search(String query) async {
    try {
      final response = await _dio.post(
        ApiConstants.ragSearch,
        data: {
          'query': query,
          'stream': false,
        },
      );
      return response.data;
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
