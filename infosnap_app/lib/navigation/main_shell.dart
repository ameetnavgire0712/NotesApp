import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/providers/upload_provider.dart';
import '../core/services/api_service.dart';
import '../core/services/share_intent_service.dart';
import '../core/utils/responsive.dart';
import '../core/widgets/hexagon_background.dart';
import '../core/widgets/tag_input_field.dart';

class MainShell extends ConsumerStatefulWidget {
  final Widget child;

  const MainShell({super.key, required this.child});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  static const Color _greenPrimary = Color(0xFF22c55e);
  static const Color _greenDark = Color(0xFF15803d);
  static const Color _amber = Color(0xFFF59E0B);
  static const int _maxTagChars = 20;
  static const int _maxDescriptionChars = 50;

  static bool _uploadCancelled = false;

  final ShareIntentService _shareIntentService = ShareIntentService();

  @override
  void initState() {
    super.initState();
    // Initialize share intent service to handle media/text shared from other apps.
    _shareIntentService.onImagesShared = _handleSharedImages;
    _shareIntentService.onFilesShared = _handleSharedFiles;
    _shareIntentService.onUrlShared = _handleSharedUrl;
    _shareIntentService.onTextShared = _handleSharedText;
    _shareIntentService.initialize();
  }

  @override
  void dispose() {
    _shareIntentService.dispose();
    super.dispose();
  }

  /// Handle images shared from other apps (e.g., camera share button)
  void _handleSharedImages(List<SharedImageData> images) {
    if (images.isEmpty) return;

    // Use a small delay to ensure the context is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // Handle first image (most common case from camera share)
      final image = images.first;
      _showSharedImageUploadDialog(context, image.bytes, image.fileName);
    });
  }

  /// Handle non-image files shared from other apps.
  void _handleSharedFiles(List<SharedFileData> files) {
    if (files.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final file = files.first;
      _showSharedFileUploadDialog(context, file.bytes, file.fileName);
    });
  }

  /// Handle webpage/text share from browsers and apps.
  void _handleSharedUrl(SharedUrlData data) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      _showSaveUrlDialog(
        context,
        initialUrl: data.url,
        initialDescription:
            _extractDescriptionFromSharedText(data.rawText, data.url),
        viaShareIntent: true,
      );
    });
  }

  /// Handle plain text shared from apps such as WhatsApp and Gmail.
  void _handleSharedText(SharedTextData data) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      _showQuickNoteDialog(
        context,
        initialContent: data.content,
        dialogTitle: 'Save Shared Note',
      );
    });
  }

  String _extractDescriptionFromSharedText(String rawText, String url) {
    final cleaned = rawText.replaceAll(url, '').trim();
    if (cleaned.isEmpty) return '';
    if (cleaned.length <= _maxDescriptionChars) return cleaned;
    return cleaned.substring(0, _maxDescriptionChars).trim();
  }

  /// Show upload dialog for a shared image (directly to save screen with tag/description)
  Future<void> _showSharedImageUploadDialog(
      BuildContext context, Uint8List fileBytes, String fileName) async {
    // Validate that the file is actually an image
    final allowedImageExtensions = [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'bmp',
      'webp',
      'heic',
      'heif',
      'tiff',
      'tif'
    ];
    final ext = fileName.split('.').last.toLowerCase();
    if (!allowedImageExtensions.contains(ext)) {
      _showResultSnackBar(context,
          'Invalid file type: .$ext — Please share an image file', false);
      return;
    }

    // Check file size (max 10MB)
    if (fileBytes.length > 10 * 1024 * 1024) {
      _showResultSnackBar(context, 'Image too large. Max 10MB allowed.', false);
      return;
    }

    // Show tag input dialog directly
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tagController = TextEditingController(text: 'photo');
    final descriptionController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _UploadDialog(
        isDark: isDark,
        title: 'Save Shared Image',
        icon: Icons.share_rounded,
        iconColor: Colors.purple,
        children: [
          Container(
            padding: EdgeInsets.all(Responsive.pp(12)),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(Responsive.wp(12)),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(Responsive.wp(8)),
                  child: Image.memory(
                    fileBytes,
                    width: Responsive.wp(60),
                    height: Responsive.wp(60),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: Responsive.wp(60),
                      height: Responsive.wp(60),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF4B5563)
                            : const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(Responsive.wp(8)),
                      ),
                      child: Icon(Icons.broken_image_rounded,
                          color: Colors.grey[500], size: Responsive.sp(28)),
                    ),
                  ),
                ),
                SizedBox(width: Responsive.wp(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(13),
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${(fileBytes.length / 1024).toStringAsFixed(1)} KB',
                        style: GoogleFonts.inter(
                            fontSize: Responsive.sp(11), color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Responsive.wp(12)),
          _buildTagDialogField(tagController, 'Tag (e.g. photo, screenshot)',
              Icons.label_outline, isDark),
          SizedBox(height: Responsive.wp(12)),
          _buildDialogField(ctx, descriptionController,
              'Description (optional)', Icons.notes_rounded, isDark,
              maxLength: _maxDescriptionChars),
        ],
        onSubmit: () async {
          final t = _clampTag(tagController.text);
          final safeDescription = _clampDescription(descriptionController.text);
          if (t.isEmpty) return 'Please enter a tag';
          Navigator.pop(ctx, {'tag': t, 'description': safeDescription});
          return null;
        },
      ),
    );

    if (result == null || result['tag']?.isEmpty == true) return;
    final tag = result['tag']!;
    final description = result['description'];

    // Upload the shared image
    await _uploadImageBytes(context, fileBytes, fileName, tag, description);
  }

  /// Show upload dialog for a shared non-image file.
  Future<void> _showSharedFileUploadDialog(
      BuildContext context, Uint8List fileBytes, String fileName) async {
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    if (!_allowedFileExtensions.contains(ext)) {
      _showResultSnackBar(
        context,
        'Unsupported file type: .$ext — Please share a document (PDF, Word, TXT, HTML, etc.)',
        false,
      );
      return;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tagController = TextEditingController(text: 'general');
    final descriptionController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _UploadDialog(
        isDark: isDark,
        title: 'Save Shared File',
        icon: Icons.share_rounded,
        iconColor: _amber,
        children: [
          Container(
            padding: EdgeInsets.all(Responsive.pp(12)),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(Responsive.wp(12)),
            ),
            child: Row(
              children: [
                Icon(Icons.description, color: _amber, size: Responsive.sp(20)),
                SizedBox(width: Responsive.wp(10)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(13),
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${(fileBytes.length / 1024).toStringAsFixed(1)} KB',
                        style: GoogleFonts.inter(
                            fontSize: Responsive.sp(11), color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Responsive.wp(12)),
          _buildTagDialogField(tagController, 'Tag (e.g. work, personal)',
              Icons.label_outline, isDark),
          SizedBox(height: Responsive.wp(12)),
          _buildDialogField(ctx, descriptionController,
              'Description (optional)', Icons.notes_rounded, isDark,
              maxLength: _maxDescriptionChars),
        ],
        onSubmit: () async {
          final t = _clampTag(tagController.text);
          final safeDescription = _clampDescription(descriptionController.text);
          if (t.isEmpty) return 'Please enter a tag';
          Navigator.pop(ctx, {'tag': t, 'description': safeDescription});
          return null;
        },
      ),
    );

    if (result == null || result['tag']?.isEmpty == true) return;
    final tag = result['tag']!;
    final description = result['description'];

    await _uploadFileBytes(context, fileBytes, fileName, tag, description);
  }

  /// Upload image bytes to the server
  Future<void> _uploadImageBytes(BuildContext context, Uint8List fileBytes,
      String fileName, String tag, String? description) async {
    final headers = _getAuthHeaders();
    if (headers.isEmpty) {
      _showResultSnackBar(context, 'Not authenticated. Please sign in.', false);
      return;
    }

    // Show progress overlay immediately
    final uploadId = _showUploadOverlay(context, 'Image');

    try {
      const uploadBase =
          'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';

      // Multipart upload
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$uploadBase/upload/file'),
      );
      request.headers.addAll(headers);
      request.fields['tag'] = _clampTag(tag);
      final safeDescription = _clampDescription(description);
      if (safeDescription.isNotEmpty) {
        request.fields['description'] = safeDescription;
      }
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: fileName,
      ));

      final sendFuture = request.send();
      final (streamedResponse, originalFuture) =
          await _awaitOrCancel(sendFuture);

      // User cancelled while the upload was in-flight
      if (streamedResponse == null || _uploadCancelled) {
        _cleanupInFlightUpload(originalFuture);
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      final response = streamedResponse;
      final responseBody = await response.stream.bytesToString();

      if (_uploadCancelled) {
        if (response.statusCode == 200 || response.statusCode == 202) {
          final traceId = json.decode(responseBody)['trace_id'] as String?;
          if (traceId != null) ApiService().cancelUpload(traceId);
        }
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      if (response.statusCode == 200 || response.statusCode == 202) {
        final data = json.decode(responseBody);
        final traceId = data['trace_id'];
        if (traceId != null) {
          _pollUploadCompletion(context, traceId, 'Image', uploadId);
        } else {
          _dismissUploadOverlay(context, uploadId);
          _showResultSnackBar(context, 'Image uploaded successfully!', true);
        }
      } else {
        debugPrint('Upload error: ${response.statusCode} $responseBody');
        final errorMsg = _parseErrorMessage(responseBody) ?? 'Upload failed';
        _dismissUploadOverlay(context, uploadId);
        _showResultSnackBar(context, errorMsg, false);
      }
    } catch (e) {
      debugPrint('Image upload exception: $e');
      if (_uploadCancelled) {
        _showCancelledInOverlay(context, uploadId);
        return;
      }
      _dismissUploadOverlay(context, uploadId);
      _showResultSnackBar(context, 'Upload error. Check your internet.', false);
    }
  }

  /// Upload document/file bytes to the server.
  Future<void> _uploadFileBytes(BuildContext context, Uint8List fileBytes,
      String fileName, String tag, String? description) async {
    final headers = _getAuthHeaders();
    if (headers.isEmpty) {
      _showResultSnackBar(context, 'Not authenticated. Please sign in.', false);
      return;
    }

    final uploadId = _showUploadOverlay(context, 'File');
    try {
      const uploadBase =
          'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$uploadBase/upload/file'),
      );
      request.headers.addAll(headers);
      request.fields['tag'] = _clampTag(tag);
      final safeDescription = _clampDescription(description);
      if (safeDescription.isNotEmpty) {
        request.fields['description'] = safeDescription;
      }
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: fileName,
      ));

      final sendFuture = request.send();
      final (streamedResponse, originalFuture) =
          await _awaitOrCancel(sendFuture);

      if (streamedResponse == null || _uploadCancelled) {
        _cleanupInFlightUpload(originalFuture);
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      final response = streamedResponse;
      final responseBody = await response.stream.bytesToString();

      if (_uploadCancelled) {
        if (response.statusCode == 200 || response.statusCode == 202) {
          final traceId = json.decode(responseBody)['trace_id'] as String?;
          if (traceId != null) ApiService().cancelUpload(traceId);
        }
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      if (response.statusCode == 200 || response.statusCode == 202) {
        final data = json.decode(responseBody);
        final traceId = data['trace_id'];
        if (traceId != null) {
          _pollUploadCompletion(context, traceId, 'File', uploadId);
        } else {
          _dismissUploadOverlay(context, uploadId);
          _showResultSnackBar(context, 'File uploaded successfully!', true);
        }
      } else {
        debugPrint('Upload error: ${response.statusCode} $responseBody');
        final errorMsg = _parseErrorMessage(responseBody) ?? 'Upload failed';
        _dismissUploadOverlay(context, uploadId);
        _showResultSnackBar(context, errorMsg, false);
      }
    } catch (e) {
      debugPrint('File upload exception: $e');
      if (_uploadCancelled) {
        _showCancelledInOverlay(context, uploadId);
        return;
      }
      _dismissUploadOverlay(context, uploadId);
      _showResultSnackBar(context, 'Upload error. Check your internet.', false);
    }
  }

  /// Awaits [future] but checks [_uploadCancelled] every 500ms.
  /// Returns a record: (result, originalFuture).
  /// If cancelled before [future] completes, result is null but originalFuture
  /// is still live — the caller must attach a `.then()` to clean up server-side.
  static Future<(T?, Future<T>)> _awaitOrCancel<T>(Future<T> future) async {
    final completer = Completer<T>();
    future.then(completer.complete).catchError(completer.completeError);
    while (!completer.isCompleted) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (_uploadCancelled && !completer.isCompleted) return (null, future);
    }
    final result = await completer.future;
    return (result, future);
  }

  /// Fire-and-forget: wait for an in-flight upload future to finish, then
  /// cancel on the server using the trace_id from the response.
  static void _cleanupInFlightUpload(
      Future<http.StreamedResponse> uploadFuture) {
    uploadFuture.then((response) async {
      try {
        final body = await response.stream.bytesToString();
        if (response.statusCode == 200 || response.statusCode == 202) {
          final traceId = json.decode(body)['trace_id'] as String?;
          if (traceId != null) {
            debugPrint('Cancel cleanup: cancelling trace $traceId on server');
            await ApiService().cancelUpload(traceId);
          }
        }
      } catch (e) {
        debugPrint('Cancel cleanup error: $e');
      }
    }).catchError((e) {
      debugPrint(
          'Cancel cleanup: upload request failed (nothing to clean up): $e');
    });
  }

  /// Fire-and-forget: same as above but for non-streamed http.Response.
  static void _cleanupInFlightPost(Future<http.Response> postFuture) {
    postFuture.then((response) async {
      try {
        if (response.statusCode == 200 || response.statusCode == 202) {
          final traceId = json.decode(response.body)['trace_id'] as String?;
          if (traceId != null) {
            debugPrint('Cancel cleanup: cancelling trace $traceId on server');
            await ApiService().cancelUpload(traceId);
          }
        }
      } catch (e) {
        debugPrint('Cancel cleanup error: $e');
      }
    }).catchError((e) {
      debugPrint(
          'Cancel cleanup: post request failed (nothing to clean up): $e');
    });
  }

  int _getSelectedIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    if (location.startsWith('/home')) return 0;
    if (location.startsWith('/groups')) return 1;
    if (location.startsWith('/chat')) return 2;
    if (location.startsWith('/notes')) return 3;
    return -1; // chat/settings have no nav highlight
  }

  /// Get auth headers for API calls
  Map<String, String> _getAuthHeaders() {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) return {};
    return {'Authorization': 'Bearer $token'};
  }

  String _clampTag(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.length <= _maxTagChars) return normalized;
    return normalized.substring(0, _maxTagChars).trim();
  }

  String _clampDescription(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.length <= _maxDescriptionChars) return normalized;
    return normalized.substring(0, _maxDescriptionChars).trim();
  }

  void _showUploadBottomSheet(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: EdgeInsets.fromLTRB(
          Responsive.pp(24),
          0,
          Responsive.pp(24),
          Responsive.isShort ? 60 : 100,
        ),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF18181b) : Colors.white,
          borderRadius: BorderRadius.circular(Responsive.wp(20)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: Responsive.wp(20),
              offset: Offset(0, Responsive.wp(-4)),
            ),
          ],
        ),
        child: Stack(
          children: [
            const Positioned.fill(child: HexagonBackground()),
            Padding(
              padding: EdgeInsets.all(Responsive.pp(20)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: Responsive.wp(40),
                    height: Responsive.wp(4),
                    margin: EdgeInsets.only(bottom: Responsive.pp(12)),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.grey[600] : Colors.grey[300],
                      borderRadius: BorderRadius.circular(Responsive.wp(2)),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'What can I upload?',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: Responsive.sp(16),
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _showAndroidUploadHelpDialog(context),
                        icon: Icon(Icons.help_outline_rounded,
                            size: Responsive.sp(16)),
                        label: Text(
                          'Help',
                          style: TextStyle(fontSize: Responsive.sp(12)),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: Responsive.wp(16)),
                  _buildAddOption(
                    context,
                    ctx,
                    icon: Icons.link_rounded,
                    title: 'Save URL',
                    subtitle: 'Paste a link to save',
                    color: Colors.blue,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showSaveUrlDialog(context);
                    },
                  ),
                  SizedBox(height: Responsive.wp(10)),
                  _buildAddOption(
                    context,
                    ctx,
                    icon: Icons.edit_note_rounded,
                    title: 'Quick Note',
                    subtitle: 'Write a quick note',
                    color: _greenPrimary,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showQuickNoteDialog(context);
                    },
                  ),
                  SizedBox(height: Responsive.wp(10)),
                  _buildAddOption(
                    context,
                    ctx,
                    icon: Icons.upload_file_rounded,
                    title: 'Upload File',
                    subtitle:
                        'PDF, Word, TXT, HTML, Markdown, RTF, CSV, XML, JSON',
                    color: _amber,
                    onTap: () {
                      Navigator.pop(ctx);
                      _handleFileUpload(context);
                    },
                  ),
                  SizedBox(height: Responsive.wp(10)),
                  _buildAddOption(
                    context,
                    ctx,
                    icon: Icons.photo_library_rounded,
                    title: 'Upload Image',
                    subtitle: 'Gallery, camera, or screenshots',
                    color: Colors.purple,
                    onTap: () {
                      Navigator.pop(ctx);
                      _handleImageUpload(context);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Save URL dialog - user pastes a URL and picks a tag.
  ///
  /// When [viaShareIntent] is true, submissions are routed through the
  /// `/api/v1/upload/shared-url` endpoint which detects social platforms
  /// (YouTube, …) and runs platform-specific enrichers. Paste-URL flows
  /// keep the existing `/api/v1/upload/webpage` behaviour.
  void _showSaveUrlDialog(
    BuildContext context, {
    String? initialUrl,
    String? initialTag,
    String? initialDescription,
    bool viaShareIntent = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final urlController = TextEditingController(text: initialUrl ?? '');
    final tagController = TextEditingController(text: initialTag ?? 'general');
    final descriptionController =
        TextEditingController(text: initialDescription ?? '');

    showDialog(
      context: context,
      builder: (ctx) => _UploadDialog(
        isDark: isDark,
        title: initialUrl == null ? 'Save URL' : 'Save Shared URL',
        icon: Icons.link_rounded,
        iconColor: Colors.blue,
        socialShareHelp: viaShareIntent,
        children: [
          _buildDialogField(
              ctx, urlController, 'Paste URL here...', Icons.link, isDark),
          SizedBox(height: Responsive.wp(10)),
          _buildTagDialogField(tagController, 'Tag (e.g. work, personal)',
              Icons.label_outline, isDark),
          SizedBox(height: Responsive.wp(10)),
          _buildDialogField(ctx, descriptionController,
              'Description (optional)', Icons.notes_rounded, isDark,
              maxLength: _maxDescriptionChars),
          if (!viaShareIntent) ...[
            SizedBox(height: Responsive.wp(8)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Responsive.pp(4)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: Responsive.sp(13),
                      color: isDark ? Colors.grey[500] : Colors.grey[500]),
                  SizedBox(width: Responsive.wp(6)),
                  Expanded(
                    child: Text(
                      'Chrome extension does a better job for JS/graphics-heavy sites; for text-heavy pages, either option works.',
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(11),
                        color: isDark ? Colors.grey[500] : Colors.grey[500],
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
        onSubmit: () async {
          final url = urlController.text.trim();
          final tag = _clampTag(tagController.text);
          final description = _clampDescription(descriptionController.text);
          if (url.isEmpty) return 'Please enter a URL';
          if (tag.isEmpty) return 'Please enter a tag';
          Navigator.pop(ctx);
          await _doSaveUrl(
            context,
            url,
            tag,
            description: description.isNotEmpty ? description : null,
            viaShareIntent: viaShareIntent,
          );
          return null;
        },
      ),
    );
  }

  /// Quick Note dialog - user types a note and picks a tag
  void _showQuickNoteDialog(
    BuildContext context, {
    String? initialContent,
    String dialogTitle = 'Quick Note',
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final noteController = TextEditingController(text: initialContent ?? '');
    final tagController = TextEditingController(text: 'general');
    final descriptionController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => _UploadDialog(
        isDark: isDark,
        title: dialogTitle,
        icon: Icons.edit_note_rounded,
        iconColor: _greenPrimary,
        children: [
          _buildDialogField(
              ctx, noteController, 'Type your note...', Icons.notes, isDark,
              maxLines: 4),
          SizedBox(height: Responsive.wp(10)),
          _buildTagDialogField(tagController, 'Tag (e.g. work, personal)',
              Icons.label_outline, isDark),
          SizedBox(height: Responsive.wp(10)),
          _buildDialogField(ctx, descriptionController,
              'Description (optional)', Icons.notes_rounded, isDark,
              maxLength: _maxDescriptionChars),
        ],
        onSubmit: () async {
          final content = noteController.text.trim();
          final tag = _clampTag(tagController.text);
          final description = _clampDescription(descriptionController.text);
          if (content.isEmpty) return 'Please enter some text';
          if (tag.isEmpty) return 'Please enter a tag';
          Navigator.pop(ctx);
          await _doSaveQuickNote(
            context,
            content,
            tag,
            description: description.isNotEmpty ? description : null,
          );
          return null;
        },
      ),
    );
  }

  Widget _buildDialogField(BuildContext ctx, TextEditingController controller,
      String hint, IconData icon, bool isDark,
      {int maxLines = 1, int? maxLength}) {
    final field = TextField(
      controller: controller,
      maxLines: maxLines,
      maxLength: maxLength,
      inputFormatters: maxLength == null
          ? null
          : [LengthLimitingTextInputFormatter(maxLength)],
      style: GoogleFonts.inter(
        fontSize: Responsive.sp(14),
        color: isDark ? Colors.white : Colors.black,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(
            fontSize: Responsive.sp(14),
            color: isDark ? Colors.grey[500] : Colors.grey[400]),
        prefixIcon: maxLines == 1
            ? Icon(icon,
                size: Responsive.sp(18),
                color: isDark ? Colors.grey[400] : Colors.grey[500])
            : null,
        filled: true,
        fillColor: isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(10)),
          borderSide: BorderSide.none,
        ),
        contentPadding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(14), vertical: Responsive.pp(12)),
        counterText: '',
      ),
    );
    if (!hint.toLowerCase().startsWith('description')) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldHelpLabel(
          label: 'Description',
          isDark: isDark,
          onTap: () => _showDescriptionHelpDialog(ctx),
        ),
        SizedBox(height: Responsive.wp(6)),
        field,
      ],
    );
  }

  Widget _buildTagDialogField(TextEditingController controller, String hint,
      IconData icon, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldHelpLabel(
          label: 'Tag',
          isDark: isDark,
          onTap: () => _showTagHelpDialog(context),
        ),
        SizedBox(height: Responsive.wp(6)),
        TagInputField(
          controller: controller,
          hintText: hint,
          prefixIcon: icon,
          isDark: isDark,
          fillColor: isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(Responsive.wp(10)),
          contentPadding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(14), vertical: Responsive.pp(12)),
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(14),
            color: isDark ? Colors.white : Colors.black,
          ),
          hintStyle: GoogleFonts.inter(
            fontSize: Responsive.sp(14),
            color: isDark ? Colors.grey[500] : Colors.grey[400],
          ),
          maxLength: _maxTagChars,
        ),
      ],
    );
  }

  /// Actually save URL via API
  /// NOTE: Unlike Chrome extension which generates PDF locally, mobile sends URL to server for processing.
  ///
  /// When [viaShareIntent] is true we POST to `/api/v1/upload/shared-url`,
  /// which detects social platforms and runs enrichers (e.g. YouTube
  /// transcript fetch). Unknown URLs fall back to the standard webpage scrape
  /// path server-side. The paste-URL flow continues to use `/upload/webpage`.
  Future<void> _doSaveUrl(BuildContext context, String url, String tag,
      {bool force = false,
      String? description,
      bool viaShareIntent = false}) async {
    // Validate and normalize URL
    final normalizedUrl = _normalizeUrl(url);
    if (normalizedUrl == null) {
      _showResultSnackBar(context,
          'Please enter a valid URL (e.g., https://example.com)', false);
      return;
    }

    final headers = _getAuthHeaders();
    if (headers.isEmpty) {
      _showResultSnackBar(context, 'Not authenticated. Please sign in.', false);
      return;
    }

    // Show progress overlay immediately (before HTTP request)
    final uploadId = _showUploadOverlay(context, 'URL');

    try {
      const uploadBase =
          'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';
      final safeTag = _clampTag(tag);
      final safeDescription = _clampDescription(description);
      final uploadPath =
          viaShareIntent ? '/upload/shared-url' : '/upload/webpage';

      // For YouTube shares, try a client-side WebView scrape of the
      // transcript before uploading. Uses the user's residential IP, so it
      // succeeds in cases where the Worker (CF datacenter IP) gets blocked.
      // Capped at 20s — if it doesn't finish, we upload without a transcript
      // and the existing description-only fallback applies.
      if (viaShareIntent && _isInstagramUrl(normalizedUrl)) {
        // Client-side scrape from the user's residential IP (+ any IG cookies
        // they already have on this device). Caption/author/thumbnail get
        // posted up in the generic `prefetched_social` envelope; the worker
        // falls back to its own server-side scrape for whatever the client
        // couldn't fetch.
        final scrapeUrl =
            _canonicalInstagramUrl(normalizedUrl) ?? normalizedUrl;
        debugPrint('[Instagram] oEmbed-only upload url=$scrapeUrl');
        debugPrint(
            '[IGScraper] disabled; Instagram uses official oEmbed path only');
      }

      final postFuture = http.post(
        Uri.parse('$uploadBase$uploadPath'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: json.encode({
          'url': normalizedUrl,
          'tag': safeTag,
          if (force) 'force': true,
          if (safeDescription.isNotEmpty) 'description': safeDescription,
        }),
      );
      final (response, originalFuture) = await _awaitOrCancel(postFuture);

      // User cancelled while the request was in-flight — clean up on server when it finishes
      if (response == null || _uploadCancelled) {
        _cleanupInFlightPost(originalFuture);
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      // If user cancelled right after response
      if (_uploadCancelled) {
        if (response.statusCode == 200 || response.statusCode == 202) {
          final traceId = json.decode(response.body)['trace_id'] as String?;
          if (traceId != null) ApiService().cancelUpload(traceId);
        }
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      if (response.statusCode == 200 || response.statusCode == 202) {
        final data = json.decode(response.body);

        // Check for minimal content warning
        if (data['warning'] == true &&
            data['code'] == 'MINIMAL_CONTENT' &&
            !force) {
          _dismissUploadOverlay(context, uploadId);
          await _showMinimalContentWarning(
              context, data, normalizedUrl, safeTag);
          return;
        }

        final traceId = data['trace_id'];
        if (traceId != null) {
          // Continue polling — overlay is already visible
          _pollUploadCompletion(context, traceId, 'URL', uploadId);
        } else {
          _dismissUploadOverlay(context, uploadId);
          _showResultSnackBar(context, 'URL saved successfully!', true);
        }
      } else {
        debugPrint('Save URL error: ${response.statusCode} ${response.body}');
        final errorMsg = _parseErrorMessage(response.body) ?? 'Server error';
        _dismissUploadOverlay(context, uploadId);
        _showResultSnackBar(context, errorMsg, false);
      }
    } catch (e) {
      debugPrint('Save URL exception: $e');
      if (_uploadCancelled) {
        _showCancelledInOverlay(context, uploadId);
        return;
      }
      _dismissUploadOverlay(context, uploadId);
      _showResultSnackBar(
          context, 'Connection error. Check your internet.', false);
    }
  }

  /// Show warning dialog for minimal content webpages
  Future<void> _showMinimalContentWarning(
    BuildContext context,
    Map<String, dynamic> data,
    String url,
    String tag,
  ) async {
    final isSPA = data['is_spa_detected'] == true;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(20),
          vertical: Responsive.pp(24),
        ),
        title: Text(
          'Limited Content Detected',
          style: TextStyle(fontSize: Responsive.sp(18)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              data['message'] ?? 'This page has minimal extractable content.',
              style: TextStyle(fontSize: Responsive.sp(14)),
            ),
            if (isSPA) ...[
              SizedBox(height: Responsive.wp(12)),
              Container(
                padding: EdgeInsets.all(Responsive.pp(8)),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(Responsive.wp(4)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: Responsive.sp(16), color: Colors.amber),
                    SizedBox(width: Responsive.wp(8)),
                    Expanded(
                      child: Text(
                        'This appears to be a JavaScript-rendered page (SPA).',
                        style: TextStyle(
                            fontSize: Responsive.sp(12), color: Colors.amber),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child:
                Text('Cancel', style: TextStyle(fontSize: Responsive.sp(14))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'continue'),
            child: Text('Save Anyway',
                style: TextStyle(fontSize: Responsive.sp(14))),
          ),
        ],
      ),
    );

    if (result == 'continue' && context.mounted) {
      // User chose to save anyway - retry with force=true
      await _doSaveUrl(context, url, tag, force: true);
    }
  }

  /// Normalize and validate URL
  String? _normalizeUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // Add https:// if no scheme
    String urlStr = trimmed;
    if (!urlStr.startsWith('http://') && !urlStr.startsWith('https://')) {
      urlStr = 'https://$urlStr';
    }

    // Try to parse
    try {
      final uri = Uri.parse(urlStr);
      // Check valid host
      if (uri.host.isEmpty || !uri.host.contains('.')) {
        return null;
      }
      return urlStr;
    } catch (e) {
      return null;
    }
  }

  /// True if [url] points at an Instagram reel/post/IGTV page (any host
  /// flavour, including `instagr.am` and `m.instagram.com`).
  bool _isInstagramUrl(String url) {
    try {
      final host = Uri.parse(url).host.toLowerCase();
      return host == 'instagram.com' ||
          host == 'www.instagram.com' ||
          host == 'm.instagram.com' ||
          host == 'instagr.am' ||
          host.endsWith('.instagram.com');
    } catch (_) {
      return false;
    }
  }

  /// Canonicalize an Instagram URL to `https://www.instagram.com/{p|reel|tv}/<shortcode>/`.
  /// Strips locale prefixes, query params, and tracking suffixes (`igsh`, `utm_*`).
  /// Returns null if no shortcode can be extracted.
  String? _canonicalInstagramUrl(String url) {
    try {
      final u = Uri.parse(url);
      const markers = {'reel': 'reel', 'reels': 'reel', 'p': 'p', 'tv': 'tv'};
      final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
      for (var i = 0; i < segs.length - 1; i++) {
        final marker = markers[segs[i].toLowerCase()];
        if (marker == null) continue;
        final shortcode = segs[i + 1].replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
        if (shortcode.length < 5 || shortcode.length > 30) return null;
        return 'https://www.instagram.com/$marker/$shortcode/';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Parse error message from response body
  String? _parseErrorMessage(String body) {
    try {
      final data = json.decode(body);
      return data['error'] ?? data['message'];
    } catch (e) {
      return null;
    }
  }

  /// Save quick note via API (same as Chrome extension's saveNote)
  Future<void> _doSaveQuickNote(
    BuildContext context,
    String content,
    String tag, {
    String? description,
  }) async {
    final headers = _getAuthHeaders();
    if (headers.isEmpty) {
      _showResultSnackBar(context, 'Not authenticated. Please sign in.', false);
      return;
    }

    // Show progress overlay immediately
    final uploadId = _showUploadOverlay(context, 'Note');

    try {
      const uploadBase =
          'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';

      final postFuture = http.post(
        Uri.parse('$uploadBase/upload/quick-note'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: json.encode({
          'content': content,
          'tag': tag,
          if (description != null) 'description': description,
        }),
      );
      final (response, originalFuture) = await _awaitOrCancel(postFuture);

      // User cancelled while the request was in-flight — clean up on server when it finishes
      if (response == null || _uploadCancelled) {
        _cleanupInFlightPost(originalFuture);
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      if (_uploadCancelled) {
        if (response.statusCode == 200 || response.statusCode == 202) {
          final traceId = json.decode(response.body)['trace_id'] as String?;
          if (traceId != null) ApiService().cancelUpload(traceId);
        }
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      if (response.statusCode == 200 || response.statusCode == 202) {
        final data = json.decode(response.body);
        final traceId = data['trace_id'];
        if (traceId != null) {
          _pollUploadCompletion(context, traceId, 'Note', uploadId);
        } else {
          _dismissUploadOverlay(context, uploadId);
          _showResultSnackBar(context, 'Note saved successfully!', true);
        }
      } else {
        debugPrint('Save note error: ${response.statusCode} ${response.body}');
        final errorMsg =
            _parseErrorMessage(response.body) ?? 'Failed to save note';
        _dismissUploadOverlay(context, uploadId);
        _showResultSnackBar(context, errorMsg, false);
      }
    } catch (e) {
      debugPrint('Save note exception: $e');
      if (_uploadCancelled) {
        _showCancelledInOverlay(context, uploadId);
        return;
      }
      _dismissUploadOverlay(context, uploadId);
      _showResultSnackBar(
          context, 'Connection error. Check your internet.', false);
    }
  }

  /// File upload via file picker + API (documents only)
  // Allowed document/text file extensions for file upload
  static const _allowedFileExtensions = [
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
  ];

  Future<void> _handleFileUpload(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _allowedFileExtensions,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null) {
        _showResultSnackBar(context, 'Could not read file', false);
        return;
      }

      // Validate file extension (FilePicker on web can be unreliable)
      final ext = file.extension?.toLowerCase() ?? '';
      if (!_allowedFileExtensions.contains(ext)) {
        _showResultSnackBar(
          context,
          'Unsupported file type: .$ext — Please select a document (PDF, Word, TXT, HTML, etc.)',
          false,
        );
        return;
      }

      // Show tag input dialog
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final tagController = TextEditingController(text: 'general');
      final descriptionController = TextEditingController();

      final dialogResult = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => _UploadDialog(
          isDark: isDark,
          title: 'Upload: ${file.name}',
          icon: Icons.upload_file_rounded,
          iconColor: _amber,
          children: [
            Container(
              padding: EdgeInsets.all(Responsive.pp(12)),
              decoration: BoxDecoration(
                color:
                    isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(Responsive.wp(12)),
              ),
              child: Row(
                children: [
                  Icon(Icons.description,
                      color: _amber, size: Responsive.sp(20)),
                  SizedBox(width: Responsive.wp(10)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.name,
                          style: GoogleFonts.inter(
                              fontSize: Responsive.sp(13),
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text('${(file.size / 1024).toStringAsFixed(1)} KB',
                            style: GoogleFonts.inter(
                                fontSize: Responsive.sp(11),
                                color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: Responsive.wp(12)),
            _buildTagDialogField(tagController, 'Tag (e.g. work, personal)',
                Icons.label_outline, isDark),
            SizedBox(height: Responsive.wp(12)),
            _buildDialogField(ctx, descriptionController,
                'Description (optional)', Icons.notes_rounded, isDark,
                maxLength: _maxDescriptionChars),
          ],
          onSubmit: () async {
            final t = _clampTag(tagController.text);
            final safeDescription =
                _clampDescription(descriptionController.text);
            if (t.isEmpty) return 'Please enter a tag';
            Navigator.pop(ctx, {'tag': t, 'description': safeDescription});
            return null;
          },
        ),
      );

      if (dialogResult == null || dialogResult['tag']?.isEmpty == true) return;
      final tag = dialogResult['tag']!;
      final description = dialogResult['description'];

      await _uploadFileBytes(context, file.bytes!, file.name, tag, description);
    } catch (e) {
      debugPrint('File upload exception: $e');
      if (_uploadCancelled) {
        _showCancelledInOverlay(context);
        return;
      }
      _dismissUploadOverlay(context);
      _showResultSnackBar(context, 'Upload error. Check your internet.', false);
    }
  }

  /// Image upload - shows source chooser (gallery or camera)
  Future<void> _handleImageUpload(BuildContext context) async {
    // Show a minimal bottom sheet with Camera and Gallery options
    final picker = ImagePicker();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1F2937) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Responsive.wp(16))),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: EdgeInsets.only(
                  top: Responsive.pp(12), bottom: Responsive.pp(8)),
              width: Responsive.wp(40),
              height: Responsive.wp(4),
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(Responsive.wp(2)),
              ),
            ),
            ListTile(
              leading: Icon(Icons.camera_alt_rounded,
                  color: isDark ? Colors.white : Colors.black87,
                  size: Responsive.sp(24)),
              title: Text('Camera',
                  style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: Responsive.sp(16))),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_rounded,
                  color: isDark ? Colors.white : Colors.black87,
                  size: Responsive.sp(24)),
              title: Text('Gallery',
                  style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: Responsive.sp(16))),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            SizedBox(height: Responsive.wp(8)),
          ],
        ),
      ),
    );

    if (source == null) return;

    String? uploadId;
    try {
      final photo = await picker.pickImage(source: source, imageQuality: 90);
      if (photo == null) return;

      final fileBytes = await photo.readAsBytes();
      final fileName = photo.name;

      // Validate that the selected file is actually an image
      final allowedImageExtensions = [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'bmp',
        'webp',
        'heic',
        'heif',
        'tiff',
        'tif'
      ];
      final ext = fileName.split('.').last.toLowerCase();
      if (!allowedImageExtensions.contains(ext)) {
        _showResultSnackBar(
            context,
            'Invalid file type: .$ext — Please select an image file (JPG, PNG, GIF, etc.)',
            false);
        return;
      }

      // Check file size (max 10MB)
      if (fileBytes.length > 10 * 1024 * 1024) {
        _showResultSnackBar(
            context, 'Image too large. Max 10MB allowed.', false);
        return;
      }

      // Show tag input dialog
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final tagController = TextEditingController(text: 'photo');
      final descriptionController = TextEditingController();

      final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => _UploadDialog(
          isDark: isDark,
          title: 'Upload Image',
          icon: Icons.photo_library_rounded,
          iconColor: Colors.purple,
          children: [
            Container(
              padding: EdgeInsets.all(Responsive.pp(12)),
              decoration: BoxDecoration(
                color:
                    isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(Responsive.wp(12)),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Responsive.wp(8)),
                    child: Image.memory(
                      fileBytes!,
                      width: Responsive.wp(60),
                      height: Responsive.wp(60),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: Responsive.wp(60),
                        height: Responsive.wp(60),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF4B5563)
                              : const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(Responsive.wp(8)),
                        ),
                        child: Icon(Icons.broken_image_rounded,
                            color: Colors.grey[500], size: Responsive.sp(28)),
                      ),
                    ),
                  ),
                  SizedBox(width: Responsive.wp(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName!,
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(13),
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${(fileBytes!.length / 1024).toStringAsFixed(1)} KB',
                          style: GoogleFonts.inter(
                              fontSize: Responsive.sp(11), color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: Responsive.wp(12)),
            _buildTagDialogField(tagController,
                'Tag (e.g. screenshot, receipt)', Icons.label_outline, isDark),
            SizedBox(height: Responsive.wp(12)),
            _buildDialogField(ctx, descriptionController,
                'Description (optional)', Icons.notes_rounded, isDark,
                maxLength: _maxDescriptionChars),
          ],
          onSubmit: () async {
            final t = _clampTag(tagController.text);
            final safeDescription =
                _clampDescription(descriptionController.text);
            if (t.isEmpty) return 'Please enter a tag';
            Navigator.pop(ctx, {'tag': t, 'description': safeDescription});
            return null;
          },
        ),
      );

      if (result == null || result['tag']?.isEmpty == true) return;
      final tag = result['tag']!;
      final description = result['description'];

      final headers = _getAuthHeaders();
      if (headers.isEmpty) {
        _showResultSnackBar(
            context, 'Not authenticated. Please sign in.', false);
        return;
      }

      // Show progress overlay immediately
      uploadId = _showUploadOverlay(context, 'Image');

      const uploadBase =
          'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';

      // Multipart upload
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$uploadBase/upload/file'),
      );
      request.headers.addAll(headers);
      request.fields['tag'] = _clampTag(tag);
      final safeDescription = _clampDescription(description);
      if (safeDescription.isNotEmpty) {
        request.fields['description'] = safeDescription;
      }
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        fileBytes!,
        filename: fileName!,
      ));

      final sendFuture = request.send();
      final (streamedResponse, originalFuture) =
          await _awaitOrCancel(sendFuture);

      // User cancelled while the upload was in-flight — clean up on server when it finishes
      if (streamedResponse == null || _uploadCancelled) {
        _cleanupInFlightUpload(originalFuture);
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      final response = streamedResponse;
      final responseBody = await response.stream.bytesToString();

      if (_uploadCancelled) {
        if (response.statusCode == 200 || response.statusCode == 202) {
          final traceId = json.decode(responseBody)['trace_id'] as String?;
          if (traceId != null) ApiService().cancelUpload(traceId);
        }
        _showCancelledInOverlay(context, uploadId);
        return;
      }

      if (response.statusCode == 200 || response.statusCode == 202) {
        final data = json.decode(responseBody);
        final traceId = data['trace_id'];
        if (traceId != null) {
          _pollUploadCompletion(context, traceId, 'Image', uploadId);
        } else {
          _dismissUploadOverlay(context, uploadId);
          _showResultSnackBar(context, 'Image uploaded successfully!', true);
        }
      } else {
        debugPrint('Upload error: ${response.statusCode} $responseBody');
        final errorMsg = _parseErrorMessage(responseBody) ?? 'Upload failed';
        _dismissUploadOverlay(context, uploadId);
        _showResultSnackBar(context, errorMsg, false);
      }
    } catch (e) {
      debugPrint('Image upload exception: $e');
      if (_uploadCancelled) {
        _showCancelledInOverlay(context, uploadId);
        return;
      }
      _dismissUploadOverlay(context, uploadId);
      _showResultSnackBar(context, 'Upload error. Check your internet.', false);
    }
  }

  /// Show the upload progress - now non-blocking, uses provider + banner
  String _showUploadOverlay(BuildContext context, String itemName) {
    _uploadCancelled = false;
    // Start the provider-based upload tracking (non-blocking)
    return ref.read(uploadProvider.notifier).startUploading(itemName);
  }

  /// Dismiss the upload overlay and reset state.
  void _dismissUploadOverlay(BuildContext context, [String? uploadId]) {
    // Reset via provider - no dialog to dismiss anymore
    ref.read(uploadProvider.notifier).reset(clientUploadId: uploadId);
  }

  /// Show "Upload cancelled" via provider state, then auto-reset.
  void _showCancelledInOverlay(BuildContext context, [String? uploadId]) {
    // Provider handles the cancelled state and auto-reset
    // (cancel() was already called from the banner)
    _dismissUploadOverlay(context, uploadId);
  }

  void _showResultSnackBar(BuildContext context, String message, bool success) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Container(
              padding: EdgeInsets.all(Responsive.pp(6)),
              decoration: BoxDecoration(
                color: success
                    ? _greenPrimary.withOpacity(0.15)
                    : const Color(0xFFFB923C).withOpacity(0.15),
                borderRadius: BorderRadius.circular(Responsive.wp(8)),
              ),
              child: Icon(
                success
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                color: success ? _greenPrimary : const Color(0xFFFB923C),
                size: Responsive.sp(18),
              ),
            ),
            SizedBox(width: Responsive.wp(12)),
            Expanded(
              child: Text(
                message,
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(13),
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(12))),
        elevation: 4,
        duration: Duration(seconds: success ? 4 : 5),
      ),
    );
  }

  /// Fire-and-forget: Poll upload status until completion, then notify user & refresh notes list.
  /// Now delegates to the upload provider which handles polling internally.
  Future<void> _pollUploadCompletion(
      BuildContext context, String traceId, String itemName,
      [String? uploadId]) async {
    // Let the provider handle polling with the trace ID
    ref
        .read(uploadProvider.notifier)
        .setTraceId(traceId, clientUploadId: uploadId);
    // The provider's internal polling will handle completion/failure/timeout
    // and auto-refresh the notes list
  }

  Widget _buildAddOption(
    BuildContext context,
    BuildContext ctx, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(Responsive.pp(12)),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF374151) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          border: Border.all(
            color: isDark ? const Color(0xFF4B5563) : const Color(0xFFE2E8F0),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(Responsive.pp(10)),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(Responsive.wp(10)),
              ),
              child: Icon(icon, color: color, size: Responsive.sp(22)),
            ),
            SizedBox(width: Responsive.wp(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(15),
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(13),
                      color:
                          isDark ? Colors.grey[400] : const Color(0xFF374151),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: Responsive.sp(14),
              color: isDark ? Colors.grey[500] : const Color(0xFF374151),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = _getSelectedIndex(context);
    final location = GoRouterState.of(context).uri.path;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = theme.colorScheme.surface;
    final borderColor =
        isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);

    // Watch upload state for the banner
    final uploadState = ref.watch(uploadProvider);
    final hideBottomNav = RegExp(r'^/groups/[^/]+$').hasMatch(location);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: [
          // Main content
          Expanded(
              child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              // Non-blocking upload progress banner - positioned below header
              if (!uploadState.isIdle &&
                  !(uploadState.isUploading && uploadState.bannerHidden))
                Positioned(
                  top: MediaQuery.of(context).padding.top + 72,
                  left: 0,
                  right: 0,
                  child: _buildUploadBanner(context, uploadState, isDark),
                ),
            ],
          )),
          // Bottom nav bar
          if (!hideBottomNav)
            _buildCustomBottomNav(
                context, selectedIndex, isDark, surfaceColor, borderColor),
        ],
      ),
    );
  }

  /// Build the non-blocking upload progress banner
  String _uploadStepLabel(String? step) {
    switch (step) {
      case 'blob_upload':
        return 'Uploading file';
      case 'tensorlake_parse':
      case 'tensorlake_poll':
        return 'Extracting text';
      case 'html_cleanup':
        return 'Cleaning content';
      case 'title_gen':
        return 'Generating title';
      case 'db_insert':
        return 'Saving snap';
      case 'chunking':
        return 'Preparing for search';
      case 'embedding':
        return 'Building search index';
      case 'vectorize_upsert':
        return 'Indexing for search';
      case 'finalize':
        return 'Almost done';
      case 'init':
      case null:
        return 'Saving in progress';
      default:
        return 'Processing';
    }
  }

  Widget _buildUploadBanner(
      BuildContext context, UploadState uploadState, bool isDark) {
    Color bgColor;
    Color textColor;
    String message;
    IconData icon;
    bool showHide = false;
    bool showProgress = false;

    if (uploadState.isUploading) {
      bgColor = _greenPrimary;
      textColor = Colors.white;
      message = uploadState.hasMultipleActive
          ? '${uploadState.activeCount} uploads processing  -  check My Snaps for status'
          : '${_uploadStepLabel(uploadState.currentStep)}  -  check My Snaps for status';
      icon = Icons.cloud_upload_rounded;
      showHide = true;
      showProgress = true;
    } else if (uploadState.isCompleted) {
      bgColor = _greenPrimary;
      textColor = Colors.white;
      message = 'Snap saved!';
      icon = Icons.check_circle_rounded;
    } else if (uploadState.isFailed) {
      bgColor = Colors.red.shade600;
      textColor = Colors.white;
      message = uploadState.errorMessage ?? 'Upload failed';
      icon = Icons.error_outline_rounded;
    } else if (uploadState.isCancelled) {
      bgColor = Colors.orange;
      textColor = Colors.white;
      message = 'Upload cancelled';
      icon = Icons.cancel_rounded;
    } else {
      return const SizedBox.shrink();
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: EdgeInsets.fromLTRB(
        Responsive.pp(14),
        Responsive.pp(10),
        Responsive.pp(10),
        Responsive.pp(10),
      ),
      decoration: BoxDecoration(
        color: bgColor,
        boxShadow: [
          BoxShadow(
            color: bgColor.withOpacity(0.3),
            blurRadius: Responsive.wp(8),
            offset: Offset(0, Responsive.wp(2)),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showProgress)
            SizedBox(
              width: Responsive.wp(18),
              height: Responsive.wp(18),
              child: CircularProgressIndicator(
                strokeWidth: Responsive.wp(2),
                valueColor: AlwaysStoppedAnimation<Color>(textColor),
              ),
            )
          else
            Icon(icon, color: textColor, size: Responsive.sp(20)),
          SizedBox(width: Responsive.wp(12)),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(13),
                height: 1.3,
                fontWeight: FontWeight.w500,
                color: textColor,
              ),
            ),
          ),
          if (showHide) ...[
            SizedBox(width: Responsive.wp(10)),
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(Responsive.wp(8)),
              child: InkWell(
                borderRadius: BorderRadius.circular(Responsive.wp(8)),
                onTap: () => ref.read(uploadProvider.notifier).hide(),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: Responsive.pp(14),
                    vertical: Responsive.pp(7),
                  ),
                  child: Text(
                    'Hide',
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(13),
                      fontWeight: FontWeight.w700,
                      color: bgColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomBottomNav(BuildContext context, int selectedIndex,
      bool isDark, Color surfaceColor, Color borderColor) {
    final greenAccent =
        isDark ? _greenPrimary.withOpacity(0.15) : const Color(0xFFDCFCE7);
    final textMuted =
        isDark ? const Color(0xFF9CA3AF) : const Color(0xFF374151);
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final navHeight = Responsive.wp(72) + bottomInset;

    return SizedBox(
      height: navHeight,
      child: Container(
        padding: EdgeInsets.fromLTRB(Responsive.pp(8), Responsive.pp(6),
            Responsive.pp(8), Responsive.pp(12) + bottomInset),
        decoration: BoxDecoration(
          color: surfaceColor,
          border: Border(top: BorderSide(color: borderColor)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.15 : 0.05),
              blurRadius: Responsive.wp(10),
              offset: Offset(0, Responsive.wp(-2)),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Center(
                  child: _buildNavItem(
                      context,
                      Icons.home_rounded,
                      'Home',
                      selectedIndex == 0,
                      greenAccent,
                      _greenPrimary,
                      () => context.go('/home'))),
            ),
            Expanded(
              child: Center(
                  child: _buildNavItem(
                      context,
                      Icons.groups_rounded,
                      'Groups',
                      selectedIndex == 1,
                      greenAccent,
                      _greenPrimary,
                      () => context.go('/groups'))),
            ),
            _buildCenterAddButton(context),
            Expanded(
              child: Center(
                  child: _buildNavItem(
                      context,
                      Icons.auto_awesome_rounded,
                      'SnapBot',
                      selectedIndex == 2,
                      greenAccent,
                      _greenPrimary,
                      () => context.go('/chat'))),
            ),
            Expanded(
              child: Center(
                  child: _buildNavItem(
                      context,
                      Icons.photo_library_rounded,
                      'My Snaps',
                      selectedIndex == 3,
                      greenAccent,
                      _greenPrimary,
                      () => context.go('/notes'))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, IconData icon, String label,
      bool isSelected, Color greenAccent, Color iconColor, VoidCallback onTap) {
    final textMuted = Theme.of(context).brightness == Brightness.dark
        ? Colors.grey.shade400
        : Colors.grey.shade600;
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(8), vertical: Responsive.pp(5)),
        constraints: BoxConstraints(minHeight: Responsive.wp(50)),
        decoration: BoxDecoration(
          color: isSelected ? greenAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(Responsive.wp(10)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: iconColor,
              size: Responsive.sp(24),
            ),
            SizedBox(height: Responsive.wp(2)),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(11),
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? iconColor : textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterAddButton(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        _showUploadBottomSheet(context);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: Responsive.wp(46),
        height: Responsive.wp(46),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_greenPrimary, _greenDark],
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: _greenPrimary.withOpacity(0.4),
              blurRadius: Responsive.wp(12),
              offset: Offset(0, Responsive.wp(4)),
            ),
          ],
        ),
        child: Icon(Icons.add_rounded,
            color: Colors.white, size: Responsive.sp(24)),
      ),
    );
  }
}

/// Reusable upload dialog widget
class _UploadDialog extends StatefulWidget {
  final bool isDark;
  final String title;
  final IconData icon;
  final Color iconColor;
  final List<Widget> children;
  final Future<String?> Function() onSubmit;
  final bool socialShareHelp;

  const _UploadDialog({
    required this.isDark,
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.children,
    required this.onSubmit,
    this.socialShareHelp = false,
  });

  @override
  State<_UploadDialog> createState() => _UploadDialogState();
}

class _UploadDialogState extends State<_UploadDialog> {
  bool _isSubmitting = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark ? const Color(0xFF18181b) : Colors.white;
    final textColor = widget.isDark ? Colors.white : Colors.black;

    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(20))),
      insetPadding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(24), vertical: Responsive.pp(24)),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius:
                  BorderRadius.all(Radius.circular(Responsive.wp(20))),
              child: const HexagonBackground(),
            ),
          ),
          SingleChildScrollView(
            padding: EdgeInsets.all(Responsive.pp(20)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title row
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(Responsive.pp(6)),
                      decoration: BoxDecoration(
                        color: widget.iconColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(Responsive.wp(10)),
                      ),
                      child: Icon(widget.icon,
                          color: widget.iconColor, size: Responsive.sp(18)),
                    ),
                    SizedBox(width: Responsive.wp(10)),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: Responsive.sp(16),
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => widget.socialShareHelp
                          ? _showSocialShareHelpDialog(context)
                          : _showAndroidUploadHelpDialog(context),
                      icon: Icon(Icons.help_outline_rounded,
                          size: Responsive.sp(15)),
                      label: Text(
                        'Help',
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(11),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF22B573),
                        padding: EdgeInsets.symmetric(
                          horizontal: Responsive.pp(8),
                          vertical: Responsive.pp(4),
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Responsive.wp(16)),
                // Children (form fields)
                ...widget.children,
                // Error
                if (_error != null) ...[
                  SizedBox(height: Responsive.wp(8)),
                  Text(_error!,
                      style: GoogleFonts.inter(
                          fontSize: Responsive.sp(12), color: Colors.red[400])),
                ],
                SizedBox(height: Responsive.wp(16)),
                // Submit button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSubmitting
                        ? null
                        : () async {
                            setState(() {
                              _isSubmitting = true;
                              _error = null;
                            });
                            final err = await widget.onSubmit();
                            if (err != null && mounted) {
                              setState(() {
                                _error = err;
                                _isSubmitting = false;
                              });
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF22c55e),
                      foregroundColor: Colors.white,
                      padding:
                          EdgeInsets.symmetric(vertical: Responsive.pp(12)),
                      shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(Responsive.wp(10))),
                    ),
                    child: _isSubmitting
                        ? SizedBox(
                            width: Responsive.wp(18),
                            height: Responsive.wp(18),
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text('Save',
                            style: GoogleFonts.inter(
                                fontSize: Responsive.sp(14),
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldHelpLabel extends StatelessWidget {
  final String label;
  final bool isDark;
  final VoidCallback onTap;

  const _FieldHelpLabel({
    required this.label,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(12),
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
        SizedBox(width: Responsive.wp(5)),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Responsive.wp(999)),
          child: Container(
            width: Responsive.wp(16),
            height: Responsive.wp(16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF22B573).withOpacity(0.12),
              border: Border.all(
                color: const Color(0xFF22B573).withOpacity(0.45),
                width: 1,
              ),
            ),
            child: Text(
              '?',
              style: GoogleFonts.inter(
                color: const Color(0xFF22B573),
                fontSize: Responsive.sp(10),
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

void _showTagHelpDialog(BuildContext context) {
  _showSimpleHelpDialog(
    context,
    title: 'What are tags?',
    icon: Icons.sell_outlined,
    body:
        'Tags are like folders. Use a short reusable tag such as recipes, work, finance, travel, or design to organize similar snaps and filter searches later.',
  );
}

void _showDescriptionHelpDialog(BuildContext context) {
  _showSimpleHelpDialog(
    context,
    title: 'What is description?',
    icon: Icons.notes_rounded,
    body:
        'Descriptions add your own context. They are especially useful when a reel, screenshot, image, or webpage does not clearly say why you saved it. SnapBot can use this text to find the snap later.',
  );
}

void _showSimpleHelpDialog(
  BuildContext context, {
  required String title,
  required IconData icon,
  required String body,
}) {
  final theme = Theme.of(context);
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Responsive.wp(18)),
      ),
      title: Row(
        children: [
          Icon(icon, color: const Color(0xFF22B573), size: Responsive.sp(20)),
          SizedBox(width: Responsive.wp(10)),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.spaceGrotesk(
                fontSize: Responsive.sp(18),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
      content: Text(
        body,
        style: GoogleFonts.inter(
          fontSize: Responsive.sp(13),
          height: 1.45,
          color: theme.colorScheme.onSurface.withOpacity(0.78),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}

void _showAndroidUploadHelpDialog(BuildContext context) {
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Responsive.wp(20)),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(22),
        vertical: Responsive.pp(24),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius:
                  BorderRadius.all(Radius.circular(Responsive.wp(20))),
              child: const HexagonBackground(),
            ),
          ),
          SingleChildScrollView(
            padding: EdgeInsets.all(Responsive.pp(18)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: Responsive.wp(38),
                      height: Responsive.wp(38),
                      decoration: BoxDecoration(
                        color: const Color(0xFF22B573).withOpacity(0.14),
                        borderRadius: BorderRadius.circular(Responsive.wp(12)),
                      ),
                      child: Icon(Icons.cloud_upload_outlined,
                          color: const Color(0xFF22B573),
                          size: Responsive.sp(20)),
                    ),
                    SizedBox(width: Responsive.wp(10)),
                    Expanded(
                      child: Text(
                        'Upload from Android',
                        style: GoogleFonts.spaceGrotesk(
                          color: theme.colorScheme.onSurface,
                          fontSize: Responsive.sp(18),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                SizedBox(height: Responsive.wp(10)),
                Text(
                  'Use the upload menu for links, quick notes, files, and images that you want to keep searchable.',
                  style: GoogleFonts.inter(
                    color: theme.colorScheme.onSurface.withOpacity(0.72),
                    fontSize: Responsive.sp(12),
                    height: 1.45,
                  ),
                ),
                SizedBox(height: Responsive.wp(14)),
                _HelpImageCard(
                  assetPath: 'assets/help/android_upload_options.jpg',
                  aspectRatio: 9 / 16,
                  isDark: isDark,
                ),
                SizedBox(height: Responsive.wp(14)),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(Responsive.pp(12)),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(Responsive.wp(14)),
                    border: Border.all(color: Colors.amber.withOpacity(0.32)),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'Important: ',
                          style: GoogleFonts.inter(fontWeight: FontWeight.w900),
                        ),
                        const TextSpan(
                          text:
                              'for social media content, use the share button inside the social media app. Do not use Save URL from this upload page for social media links. Save URL is only for non-social-media webpages.',
                        ),
                      ],
                    ),
                    style: GoogleFonts.inter(
                      color: theme.colorScheme.onSurface,
                      fontSize: Responsive.sp(12),
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(height: Responsive.wp(14)),
                _HelpBullet(
                    icon: Icons.link_rounded,
                    title: 'Save URL',
                    body:
                        'Use this for regular webpages, articles, blogs, and other non-social-media links.'),
                _HelpBullet(
                    icon: Icons.edit_note_rounded,
                    title: 'Quick Note',
                    body:
                        'Save thoughts, reminders, ideas, or any text you want SnapBot to find later.'),
                _HelpBullet(
                    icon: Icons.file_upload_outlined,
                    title: 'Files and images',
                    body:
                        'Upload documents, screenshots, camera photos, or gallery images. Add a tag and description when useful.'),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

void _showSocialShareHelpDialog(BuildContext context) {
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Responsive.wp(20)),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(22),
        vertical: Responsive.pp(24),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(Responsive.pp(18)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: Responsive.wp(38),
                  height: Responsive.wp(38),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22B573).withOpacity(0.14),
                    borderRadius: BorderRadius.circular(Responsive.wp(12)),
                  ),
                  child: Icon(Icons.ios_share_rounded,
                      color: const Color(0xFF22B573), size: Responsive.sp(20)),
                ),
                SizedBox(width: Responsive.wp(10)),
                Expanded(
                  child: Text(
                    'Share from social media',
                    style: GoogleFonts.spaceGrotesk(
                      color: theme.colorScheme.onSurface,
                      fontSize: Responsive.sp(18),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            SizedBox(height: Responsive.wp(10)),
            Text(
              'Use the share button inside Instagram, YouTube, LinkedIn, Reddit, or other supported apps, then choose InfoSnap from the Android share sheet.',
              style: GoogleFonts.inter(
                color: theme.colorScheme.onSurface.withOpacity(0.72),
                fontSize: Responsive.sp(12),
                height: 1.45,
              ),
            ),
            SizedBox(height: Responsive.wp(14)),
            _HelpImageCard(
              assetPath: 'assets/help/share_infosnap_target.jpg',
              aspectRatio: 16 / 10,
              isDark: isDark,
            ),
            SizedBox(height: Responsive.wp(14)),
            _HelpBullet(
              icon: Icons.sell_outlined,
              title: 'Add a tag',
              body:
                  'Tags are like folders. Use one short tag to organize this saved social post with similar snaps.',
            ),
            _HelpBullet(
              icon: Icons.notes_rounded,
              title: 'Add a useful description',
              body:
                  'Social posts often have little searchable text. Describe what you want to remember so SnapBot can find it later.',
            ),
          ],
        ),
      ),
    ),
  );
}

class _HelpImageCard extends StatelessWidget {
  final String assetPath;
  final double aspectRatio;
  final bool isDark;

  const _HelpImageCard({
    required this.assetPath,
    required this.aspectRatio,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: Responsive.wp(290)),
        padding: EdgeInsets.all(Responsive.pp(6)),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(Responsive.wp(20)),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.14)
                : Colors.black.withOpacity(0.08),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.28 : 0.14),
              blurRadius: Responsive.wp(18),
              offset: Offset(0, Responsive.wp(8)),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Responsive.wp(15)),
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: Image.asset(assetPath, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}

class _HelpBullet extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _HelpBullet({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.wp(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF22B573), size: Responsive.sp(18)),
          SizedBox(width: Responsive.wp(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    color: theme.colorScheme.onSurface,
                    fontSize: Responsive.sp(13),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: Responsive.wp(3)),
                Text(
                  body,
                  style: GoogleFonts.inter(
                    color: theme.colorScheme.onSurface.withOpacity(0.74),
                    fontSize: Responsive.sp(12),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen modal overlay shown during upload processing.
/// Blocks all interaction until upload completes or user cancels.
class _UploadProgressOverlay extends StatefulWidget {
  final String itemName;
  final Future<void> Function() onCancel;

  const _UploadProgressOverlay({
    super.key,
    required this.itemName,
    required this.onCancel,
  });

  @override
  State<_UploadProgressOverlay> createState() => _UploadProgressOverlayState();
}

class _UploadProgressOverlayState extends State<_UploadProgressOverlay> {
  bool _cancelling = false;
  bool _cancelled = false;

  /// Called externally to transition the dialog to "Upload cancelled" confirmation.
  void markCancelled() {
    if (mounted) setState(() => _cancelled = true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF18181b) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtextColor =
        isDark ? const Color(0xFF9CA3AF) : const Color(0xFF374151);

    // Determine visual state
    Color accentColor;
    String title;
    String subtitle;
    Widget indicator;

    if (_cancelled) {
      accentColor = Colors.orange;
      title = 'Upload cancelled';
      subtitle = 'Your upload has been cancelled';
      indicator = Icon(
        Icons.check_circle_rounded,
        color: accentColor,
        size: Responsive.sp(44),
      );
    } else if (_cancelling) {
      accentColor = Colors.orange;
      title = 'Cancelling...';
      subtitle = 'Please wait while we cancel your upload';
      indicator = CircularProgressIndicator(
        strokeWidth: Responsive.wp(3.5),
        valueColor: AlwaysStoppedAnimation<Color>(accentColor),
        backgroundColor: accentColor.withOpacity(0.1),
      );
    } else {
      accentColor = const Color(0xFF22B573);
      title = 'Saving your snap';
      subtitle =
          'Processing your ${widget.itemName.toLowerCase()}...this may take a moment';
      indicator = CircularProgressIndicator(
        strokeWidth: Responsive.wp(3.5),
        valueColor: AlwaysStoppedAnimation<Color>(accentColor),
        backgroundColor: const Color(0x1A22B573),
      );
    }

    return PopScope(
      canPop: false,
      child: Material(
        color: Colors.transparent,
        child: Center(
          child: Container(
            width: Responsive.width * 0.82,
            constraints: BoxConstraints(maxWidth: Responsive.wp(320)),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(Responsive.wp(20)),
              border: Border.all(
                color:
                    isDark ? const Color(0xFF2A3A30) : const Color(0xFFE5E5E5),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF22B573).withOpacity(0.15),
                  blurRadius: Responsive.wp(40),
                  spreadRadius: Responsive.wp(2),
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: Responsive.wp(24),
                  offset: Offset(0, Responsive.wp(8)),
                ),
              ],
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.all(Radius.circular(Responsive.wp(20))),
                    child: const HexagonBackground(),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    Responsive.pp(28),
                    Responsive.pp(32),
                    Responsive.pp(28),
                    Responsive.pp(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Glow ring around spinner / icon
                      Container(
                        width: Responsive.wp(72),
                        height: Responsive.wp(72),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accentColor.withOpacity(isDark ? 0.08 : 0.06),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(Responsive.pp(10)),
                          child: Center(child: indicator),
                        ),
                      ),
                      SizedBox(height: Responsive.wp(24)),
                      Text(
                        title,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: Responsive.sp(18),
                          fontWeight: FontWeight.w600,
                          color: _cancelled || _cancelling
                              ? accentColor
                              : textColor,
                        ),
                      ),
                      SizedBox(height: Responsive.wp(8)),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                            fontSize: Responsive.sp(13),
                            color: subtextColor,
                            height: 1.5),
                      ),
                      SizedBox(height: Responsive.wp(24)),
                      if (!_cancelling && !_cancelled)
                        OutlinedButton(
                          onPressed: () async {
                            setState(() => _cancelling = true);
                            await widget.onCancel();
                            // Mark as cancelled once the server confirms
                            if (mounted)
                              setState(() {
                                _cancelling = false;
                                _cancelled = true;
                              });
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: isDark
                                ? Colors.white70
                                : const Color(0xFF374151),
                            side: BorderSide(
                              color: isDark
                                  ? Colors.white24
                                  : const Color(0xFFD1D5DB),
                              width: Responsive.wp(1.2),
                            ),
                            padding: EdgeInsets.symmetric(
                              horizontal: Responsive.pp(24),
                              vertical: Responsive.pp(10),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(10)),
                            ),
                          ),
                          child: Text(
                            'Cancel',
                            style: GoogleFonts.inter(
                                fontSize: Responsive.sp(13),
                                fontWeight: FontWeight.w500),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
