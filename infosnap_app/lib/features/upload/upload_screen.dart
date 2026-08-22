import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/api_service.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';
import '../../core/widgets/tag_input_field.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen>
    with WidgetsBindingObserver {
  static const int _maxTagChars = 20;
  static const int _maxDescriptionChars = 50;

  bool _isUploading = false;
  double _uploadProgress = 0;
  String? _uploadStatus;
  String? _activeTraceId;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _pollTimer?.cancel();
      _pollTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      // Resume polling if an upload was in progress when we backgrounded.
      if (_isUploading && _activeTraceId != null && _pollTimer == null) {
        _pollStatus();
        _pollTimer =
            Timer.periodic(const Duration(seconds: 2), (_) => _pollStatus());
      }
    }
  }

  /// Map pipeline step names to user-friendly progress values
  double _stepToProgress(String step) {
    switch (step) {
      case 'init':
        return 0.05;
      case 'blob_upload':
        return 0.15;
      case 'tensorlake_parse':
      case 'tensorlake_poll':
        return 0.3;
      case 'html_cleanup':
        return 0.5;
      case 'title_gen':
        return 0.6;
      case 'chunking':
        return 0.7;
      case 'embedding':
        return 0.8;
      case 'db_insert':
        return 0.85;
      case 'vectorize_upsert':
        return 0.9;
      case 'finalize':
        return 0.95;
      case 'completed':
        return 1.0;
      default:
        return 0.1;
    }
  }

  String _stepToLabel(String step) {
    switch (step) {
      case 'init':
        return 'Starting...';
      case 'blob_upload':
        return 'Uploading file...';
      case 'tensorlake_parse':
      case 'tensorlake_poll':
        return 'Extracting text with AI...';
      case 'html_cleanup':
        return 'Cleaning up content...';
      case 'title_gen':
        return 'Generating title...';
      case 'chunking':
        return 'Splitting into chunks...';
      case 'embedding':
        return 'Creating search index...';
      case 'db_insert':
        return 'Saving to database...';
      case 'vectorize_upsert':
        return 'Indexing for search...';
      case 'finalize':
        return 'Finalizing...';
      case 'completed':
        return 'Done!';
      case 'failed':
        return 'Failed';
      default:
        return 'Processing...';
    }
  }

  void _startPolling(String traceId) {
    _activeTraceId = traceId;
    _pollTimer?.cancel();
    _pollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _pollStatus());
  }

  Future<void> _pollStatus() async {
    if (_activeTraceId == null) return;

    final status = await ApiService().getUploadStatus(_activeTraceId!);
    if (status == null || !mounted) return;

    final step = status['current_step'] as String? ?? 'init';
    final uploadStatus = status['status'] as String? ?? '';

    setState(() {
      _uploadProgress = _stepToProgress(step);
      _uploadStatus = _stepToLabel(step);
    });

    if (step == 'completed' || uploadStatus == 'completed') {
      _pollTimer?.cancel();
      setState(() {
        _uploadProgress = 1.0;
        _uploadStatus = 'Done!';
      });
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _uploadStatus = null;
        _activeTraceId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Webpage saved successfully!'),
          backgroundColor: const Color(0xFF22c55e),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Responsive.wp(10))),
        ),
      );
      context.pop();
    } else if (step == 'failed' || uploadStatus == 'failed') {
      _pollTimer?.cancel();
      final errorMsg =
          status['error_message'] as String? ?? 'Processing failed';
      setState(() {
        _isUploading = false;
        _uploadStatus = null;
        _activeTraceId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed: $errorMsg'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Responsive.wp(10))),
        ),
      );
    }
  }

  Future<void> _saveWebpage(String url, String tag,
      {String? description}) async {
    setState(() {
      _isUploading = true;
      _uploadStatus = 'Fetching webpage...';
      _uploadProgress = 0.05;
    });

    final result =
        await ApiService().saveWebpage(url, tag: tag, description: description);

    if (!mounted) return;

    if (result['success'] == true && result['trace_id'] != null) {
      setState(() {
        _uploadStatus = 'Processing...';
        _uploadProgress = 0.1;
      });
      _startPolling(result['trace_id'] as String);
    } else {
      setState(() {
        _isUploading = false;
        _uploadStatus = null;
      });
      if (result['code'] == 'MONTHLY_UPLOAD_LIMIT_REACHED') {
        _showUploadLimitDialog(
          result['error'] as String? ??
              'You have reached your monthly upload limit.',
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error'] as String? ?? 'Failed to save webpage'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Responsive.wp(10))),
        ),
      );
    }
  }

  Future<void> _pickAndUpload(String type) async {
    try {
      final picker = ImagePicker();
      XFile? photo;

      if (type == 'gallery') {
        // Directly open system gallery/media picker
        // On most Android phones this shows a system chooser with Camera, Gallery, Files, etc.
        photo = await picker.pickImage(
            source: ImageSource.gallery, imageQuality: 90);
      } else {
        // For document type, use the existing flow
        return;
      }

      if (photo == null) return; // User cancelled

      final fileBytes = await photo.readAsBytes();
      final fileName = photo.name;

      // Validate file type
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
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid file type: .$ext — Please select an image'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(10))),
          ),
        );
        return;
      }

      // Check file size (max 10MB)
      if (fileBytes.length > 10 * 1024 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Image too large. Max 10MB allowed.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(10))),
          ),
        );
        return;
      }

      // Show tag input dialog
      if (!mounted) return;
      final result = await _showImageUploadDialog(fileBytes, fileName);
      if (result == null || result['tag']?.isEmpty == true) return;

      final tag = result['tag']!;
      final description = result['description'];

      // Upload the image
      await _uploadImage(fileBytes, fileName, tag, description);
    } catch (e) {
      debugPrint('Image pick error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to access gallery'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Responsive.wp(10))),
        ),
      );
    }
  }

  Future<Map<String, String>?> _showImageUploadDialog(
      Uint8List fileBytes, String fileName) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tagController = TextEditingController(text: 'photo');
    final descriptionController = TextEditingController();

    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1F2937) : Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(16))),
        insetPadding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(20),
          vertical: Responsive.pp(24),
        ),
        title: Row(
          children: [
            Container(
              padding: EdgeInsets.all(Responsive.pp(8)),
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.1),
                borderRadius: BorderRadius.circular(Responsive.wp(8)),
              ),
              child: Icon(Icons.photo_library_rounded,
                  color: Colors.purple, size: Responsive.sp(20)),
            ),
            SizedBox(width: Responsive.wp(12)),
            Expanded(
              child: Text(
                'Upload Image',
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w600,
                  fontSize: Responsive.sp(18),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Image preview
              Container(
                padding: EdgeInsets.all(Responsive.pp(12)),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF374151)
                      : const Color(0xFFF1F5F9),
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
                            borderRadius:
                                BorderRadius.circular(Responsive.wp(8)),
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
                                fontSize: Responsive.sp(11),
                                color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: Responsive.wp(16)),
              // Tag field
              TagInputField(
                controller: tagController,
                labelText: 'Tag',
                hintText: 'e.g., photo, screenshot',
                prefixIcon: Icons.label_outline,
                maxLength: _maxTagChars,
                isDark: isDark,
                fillColor:
                    isDark ? const Color(0xFF374151) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(Responsive.wp(12)),
              ),
              SizedBox(height: Responsive.wp(12)),
              // Description field
              TextField(
                controller: descriptionController,
                maxLength: _maxDescriptionChars,
                decoration: InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: "What's in this image?",
                  prefixIcon: Icon(Icons.notes_rounded,
                      color: Colors.grey, size: Responsive.sp(20)),
                  filled: true,
                  fillColor: isDark
                      ? const Color(0xFF374151)
                      : const Color(0xFFF1F5F9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Responsive.wp(12)),
                    borderSide: BorderSide.none,
                  ),
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.grey, fontSize: Responsive.sp(14)),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final tag = tagController.text.trim();
              if (tag.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Please enter a tag'),
                    backgroundColor: Colors.orange,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Responsive.wp(10))),
                  ),
                );
                return;
              }
              Navigator.pop(ctx, {
                'tag': tag.substring(
                    0, tag.length > _maxTagChars ? _maxTagChars : tag.length),
                'description': descriptionController.text.trim().substring(
                      0,
                      descriptionController.text.trim().length >
                              _maxDescriptionChars
                          ? _maxDescriptionChars
                          : descriptionController.text.trim().length,
                    ),
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF22c55e),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Responsive.wp(8))),
            ),
            child:
                Text('Upload', style: TextStyle(fontSize: Responsive.sp(14))),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadImage(Uint8List fileBytes, String fileName, String tag,
      String? description) async {
    // Get auth token
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Not authenticated. Please sign in.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Responsive.wp(10))),
        ),
      );
      return;
    }

    setState(() {
      _isUploading = true;
      _uploadStatus = 'Uploading image...';
      _uploadProgress = 0.1;
    });

    try {
      const uploadBase =
          'https://notesapp-vector-search.monocle0712.workers.dev/api/v1';

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$uploadBase/upload/file'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['tag'] = tag.substring(
          0, tag.length > _maxTagChars ? _maxTagChars : tag.length);
      if (description != null && description.isNotEmpty) {
        request.fields['description'] = description.substring(
          0,
          description.length > _maxDescriptionChars
              ? _maxDescriptionChars
              : description.length,
        );
      }
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: fileName,
      ));

      final streamedResponse = await request.send();
      final responseBody = await streamedResponse.stream.bytesToString();

      if (!mounted) return;

      if (streamedResponse.statusCode == 200 ||
          streamedResponse.statusCode == 202) {
        final data = json.decode(responseBody);
        final traceId = data['trace_id'];
        if (traceId != null) {
          _startPolling(traceId);
        } else {
          setState(() {
            _isUploading = false;
            _uploadStatus = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Image uploaded successfully!'),
              backgroundColor: const Color(0xFF22c55e),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Responsive.wp(10))),
            ),
          );
          context.pop();
        }
      } else {
        debugPrint(
            'Upload error: ${streamedResponse.statusCode} $responseBody');
        setState(() {
          _isUploading = false;
          _uploadStatus = null;
        });
        final uploadLimitMessage = _uploadLimitMessage(responseBody);
        if (uploadLimitMessage != null) {
          _showUploadLimitDialog(uploadLimitMessage);
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: ${streamedResponse.statusCode}'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(10))),
          ),
        );
      }
    } catch (e) {
      debugPrint('Upload exception: $e');
      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _uploadStatus = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload error. Check your internet.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Responsive.wp(10))),
        ),
      );
    }
  }

  String? _uploadLimitMessage(String responseBody) {
    try {
      final data = json.decode(responseBody);
      if (data is! Map<String, dynamic>) return null;
      if (data['code'] != 'MONTHLY_UPLOAD_LIMIT_REACHED') return null;
      return data['error']?.toString() ??
          'You have reached your monthly upload limit.';
    } catch (_) {
      return null;
    }
  }

  void _showUploadLimitDialog(String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          backgroundColor: theme.colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(16)),
          ),
          title: Text(
            'Upload limit reached',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          content: Text(
            message,
            style: GoogleFonts.inter(
              color: theme.colorScheme.onSurface.withOpacity(0.75),
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Not now'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext);
                context.go('/settings');
              },
              icon: const Icon(Icons.person_outline_rounded),
              label: const Text('Open Profile'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: Icon(Icons.close_rounded, color: theme.colorScheme.onSurface),
        ),
        title: Text(
          'Add Note',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: HexagonBackground()),
          _isUploading ? _buildUploadingView() : _buildOptionsView(),
        ],
      ),
    );
  }

  Widget _buildOptionsView() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(Responsive.pp(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'What would you like to capture?',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: Responsive.sp(20),
                ),
          ).animate().fadeIn(),

          SizedBox(height: Responsive.wp(8)),

          Text(
            'Choose how to add your information',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              fontSize: Responsive.sp(15),
            ),
          ).animate(delay: 100.ms).fadeIn(),

          SizedBox(height: Responsive.wp(32)),

          // Image option - opens system picker directly
          _UploadOption(
            icon: Icons.add_photo_alternate_rounded,
            title: 'Upload Image',
            description: 'Select from gallery or camera',
            color: const Color(0xFF22c55e),
            onTap: () => _pickAndUpload('gallery'),
          ).animate(delay: 200.ms).fadeIn().slideX(begin: 0.05),

          SizedBox(height: Responsive.wp(16)),

          // Document option
          _UploadOption(
            icon: Icons.upload_file_rounded,
            title: 'Upload Document',
            description: 'PDF, DOC, TXT files',
            color: const Color(0xFF3b82f6),
            onTap: () => _pickAndUpload('document'),
          ).animate(delay: 300.ms).fadeIn().slideX(begin: 0.05),

          SizedBox(height: Responsive.wp(16)),

          // URL option
          _UploadOption(
            icon: Icons.link_rounded,
            title: 'Save from URL',
            description: 'Import from web link',
            color: const Color(0xFF22c55e),
            onTap: () => _showUrlDialog(),
          ).animate(delay: 500.ms).fadeIn().slideX(begin: 0.05),

          SizedBox(height: Responsive.wp(32)),

          // Tips
          Builder(
            builder: (context) {
              final theme = Theme.of(context);
              return Container(
                padding: EdgeInsets.all(Responsive.pp(16)),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(Responsive.wp(16)),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.lightbulb_outline_rounded,
                      color: const Color(0xFFf59e0b),
                      size: Responsive.sp(24),
                    ),
                    SizedBox(width: Responsive.wp(12)),
                    Expanded(
                      child: Text(
                        'Tip: infoSnap uses AI to extract text from images and make everything searchable!',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                          fontSize: Responsive.sp(13),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ).animate(delay: 600.ms).fadeIn(),
        ],
      ),
    );
  }

  Widget _buildUploadingView() {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(Responsive.pp(Responsive.isNarrow ? 20 : 40)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Progress circle
            SizedBox(
              width: Responsive.wp(Responsive.isNarrow ? 90 : 120),
              height: Responsive.wp(Responsive.isNarrow ? 90 : 120),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: _uploadProgress,
                    strokeWidth: Responsive.wp(8),
                    backgroundColor: Theme.of(context).colorScheme.surface,
                    valueColor: AlwaysStoppedAnimation(Color(0xFF22c55e)),
                  ),
                  Text(
                    '${(_uploadProgress * 100).toInt()}%',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF22c55e),
                        ),
                  ),
                ],
              ),
            ).animate().fadeIn().scale(begin: Offset(0.8, 0.8)),

            SizedBox(height: Responsive.wp(32)),

            Text(
              'Processing...',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ).animate(delay: 200.ms).fadeIn(),

            SizedBox(height: Responsive.wp(8)),

            Text(
              _uploadStatus ?? '',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                fontSize: Responsive.sp(15),
              ),
            ).animate(delay: 300.ms).fadeIn(),

            SizedBox(height: Responsive.wp(40)),

            // Processing steps
            _ProcessingStep(
              icon: Icons.file_copy_rounded,
              label: 'Reading file',
              isComplete: _uploadProgress >= 0.3,
              isActive: _uploadProgress < 0.3,
            ),
            _ProcessingStep(
              icon: Icons.auto_awesome_rounded,
              label: 'AI text extraction',
              isComplete: _uploadProgress >= 0.6,
              isActive: _uploadProgress >= 0.3 && _uploadProgress < 0.6,
            ),
            _ProcessingStep(
              icon: Icons.search_rounded,
              label: 'Indexing for search',
              isComplete: _uploadProgress >= 0.9,
              isActive: _uploadProgress >= 0.6 && _uploadProgress < 0.9,
            ),
            _ProcessingStep(
              icon: Icons.check_circle_rounded,
              label: 'Done!',
              isComplete: _uploadProgress >= 1.0,
              isActive: _uploadProgress >= 0.9 && _uploadProgress < 1.0,
            ),
          ],
        ),
      ),
    );
  }

  void _showUrlDialog() {
    final urlController = TextEditingController();
    final tagController = TextEditingController(text: 'Web Saves');
    final descriptionController = TextEditingController();

    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(16))),
        insetPadding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(20),
          vertical: Responsive.pp(24),
        ),
        title: Text(
          'Save Webpage',
          style: TextStyle(fontSize: Responsive.sp(18)),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: urlController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'https://...',
                  labelText: 'URL',
                  prefixIcon: Icon(Icons.link_rounded,
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                      size: Responsive.sp(20)),
                  filled: true,
                  fillColor: theme.scaffoldBackgroundColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Responsive.wp(12)),
                    borderSide: BorderSide.none,
                  ),
                ),
                keyboardType: TextInputType.url,
              ),
              SizedBox(height: Responsive.wp(12)),
              TagInputField(
                controller: tagController,
                hintText: 'e.g., work, research',
                labelText: 'Tag',
                prefixIcon: Icons.label_outline_rounded,
                maxLength: _maxTagChars,
                isDark: theme.brightness == Brightness.dark,
                fillColor: theme.scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(Responsive.wp(12)),
              ),
              Padding(
                padding: EdgeInsets.only(
                    left: Responsive.pp(4),
                    top: Responsive.pp(4),
                    bottom: Responsive.pp(8)),
                child: Text(
                  'Organize your saves by category',
                  style: TextStyle(
                    fontSize: Responsive.sp(11),
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              TextField(
                controller: descriptionController,
                maxLength: _maxDescriptionChars,
                decoration: InputDecoration(
                  hintText: "What's this about?",
                  labelText: 'Description (optional)',
                  prefixIcon: Icon(Icons.notes_rounded,
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                      size: Responsive.sp(20)),
                  filled: true,
                  fillColor: theme.scaffoldBackgroundColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Responsive.wp(12)),
                    borderSide: BorderSide.none,
                  ),
                  counterText: '',
                ),
              ),
              Padding(
                padding: EdgeInsets.only(
                    left: Responsive.pp(4),
                    top: Responsive.pp(4),
                    bottom: Responsive.pp(8)),
                child: Text(
                  'A short note to help you remember this page',
                  style: TextStyle(
                    fontSize: Responsive.sp(11),
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: Responsive.sp(14),
                      color: theme.colorScheme.onSurface.withOpacity(0.4)),
                  SizedBox(width: Responsive.wp(6)),
                  Expanded(
                    child: Text(
                      'Chrome extension does a better job for JS/graphics-heavy sites; for text-heavy pages, either option works.',
                      style: TextStyle(
                        fontSize: Responsive.sp(11),
                        color: theme.colorScheme.onSurface.withOpacity(0.4),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(0.4))),
          ),
          ElevatedButton(
            onPressed: () {
              final url = urlController.text.trim();
              if (url.isEmpty) return;
              if (!url.startsWith('http://') && !url.startsWith('https://')) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        'Please enter a valid URL starting with http:// or https://'),
                    backgroundColor: Colors.orange,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Responsive.wp(10))),
                  ),
                );
                return;
              }
              final description = descriptionController.text.trim();
              Navigator.pop(ctx);
              final trimmedTag = tagController.text.trim();
              final safeTag = trimmedTag.substring(
                  0,
                  trimmedTag.length > _maxTagChars
                      ? _maxTagChars
                      : trimmedTag.length);
              final safeDescription = description.substring(
                0,
                description.length > _maxDescriptionChars
                    ? _maxDescriptionChars
                    : description.length,
              );
              _saveWebpage(url, safeTag,
                  description:
                      safeDescription.isNotEmpty ? safeDescription : null);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF22c55e),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(8)),
              ),
            ),
            child: Text('Save', style: TextStyle(fontSize: Responsive.sp(14))),
          ),
        ],
      ),
    );
  }
}

class _UploadOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Color color;
  final VoidCallback onTap;

  const _UploadOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(Responsive.pp(20)),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(Responsive.wp(16)),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Row(
          children: [
            Container(
              width: Responsive.wp(56),
              height: Responsive.wp(56),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(Responsive.wp(14)),
              ),
              child: Icon(icon, color: color, size: Responsive.sp(28)),
            ),
            SizedBox(width: Responsive.wp(16)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: Responsive.sp(16),
                        ),
                  ),
                  SizedBox(height: Responsive.wp(4)),
                  Text(
                    description,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      fontSize: Responsive.sp(13),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              color: theme.colorScheme.onSurface.withOpacity(0.4),
              size: Responsive.sp(18),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessingStep extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isComplete;
  final bool isActive;

  const _ProcessingStep({
    required this.icon,
    required this.label,
    required this.isComplete,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isComplete
        ? const Color(0xFF22c55e)
        : isActive
            ? const Color(0xFF22c55e)
            : theme.colorScheme.onSurface.withOpacity(0.4);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: Responsive.pp(8)),
      child: Row(
        children: [
          Icon(
            isComplete ? Icons.check_circle_rounded : icon,
            color: color,
            size: Responsive.sp(20),
          ),
          SizedBox(width: Responsive.wp(12)),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: isActive || isComplete
                    ? FontWeight.w500
                    : FontWeight.normal,
                fontSize: Responsive.sp(14),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isActive) ...[
            SizedBox(width: Responsive.wp(8)),
            SizedBox(
              width: Responsive.wp(16),
              height: Responsive.wp(16),
              child: CircularProgressIndicator(
                strokeWidth: Responsive.wp(2),
                valueColor: AlwaysStoppedAnimation(Color(0xFF22c55e)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
