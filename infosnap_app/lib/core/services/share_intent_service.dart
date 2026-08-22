import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Service to handle images/files/URLs shared from other apps.
class ShareIntentService {
  static final ShareIntentService _instance = ShareIntentService._internal();
  factory ShareIntentService() => _instance;
  ShareIntentService._internal();

  StreamSubscription<List<SharedMediaFile>>? _mediaStreamSubscription;

  /// Callback invoked when images are shared to the app.
  void Function(List<SharedImageData>)? onImagesShared;

  /// Callback invoked when non-image files are shared to the app.
  void Function(List<SharedFileData>)? onFilesShared;

  /// Callback invoked when shared text appears to contain a URL.
  void Function(SharedUrlData)? onUrlShared;

  /// Callback invoked when shared text is plain note content.
  void Function(SharedTextData)? onTextShared;

  /// Initialize the service - call this early in app lifecycle
  void initialize() {
    // Handle media shared while app is closed (cold start).
    ReceiveSharingIntent.instance
        .getInitialMedia()
        .then((List<SharedMediaFile> files) {
      if (files.isNotEmpty) {
        _processSharedMedia(files);
      }
    });

    // Handle media shared while app is running.
    _mediaStreamSubscription =
        ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> files) {
        if (files.isNotEmpty) {
          _processSharedMedia(files);
        }
      },
      onError: (err) {
        debugPrint('ShareIntentService error: $err');
      },
    );
  }

  /// Process shared media files and convert to usable format.
  Future<void> _processSharedMedia(List<SharedMediaFile> files) async {
    final imageFiles = <SharedImageData>[];
    final genericFiles = <SharedFileData>[];
    SharedUrlData? sharedUrl;
    SharedTextData? sharedText;

    for (final file in files) {
      debugPrint(
        '[ShareIntent] received type=${file.type} mime=${file.mimeType} '
        'path="${file.path}"',
      );
      if (file.type == SharedMediaType.url) {
        final raw = (file.path).trim();
        final url = _extractFirstUrl(raw);
        if (url != null && sharedUrl == null) {
          sharedUrl = SharedUrlData(url: url, rawText: raw);
        }
        continue;
      }

      try {
        final filePath = file.path;

        if (file.type == SharedMediaType.text) {
          final possibleUrl = _extractFirstUrl(filePath);
          final ioFile = File(filePath);
          if (possibleUrl != null && !await ioFile.exists()) {
            if (sharedUrl == null) {
              sharedUrl = SharedUrlData(url: possibleUrl, rawText: filePath);
            }
            continue;
          }

          if (await ioFile.exists()) {
            final bytes = await ioFile.readAsBytes();
            final text = _decodeSharedText(bytes).trim();
            if (text.isNotEmpty) {
              final contentUrl = _extractFirstUrl(text);
              if (contentUrl != null && sharedUrl == null) {
                sharedUrl = SharedUrlData(url: contentUrl, rawText: text);
              } else if (sharedText == null) {
                sharedText = SharedTextData(
                  content: text,
                  fileName: filePath.split('/').last.split('\\').last,
                );
              }
              continue;
            }
          } else if (filePath.trim().isNotEmpty && sharedText == null) {
            sharedText = SharedTextData(content: filePath.trim());
            continue;
          }
        }

        final ioFile = File(filePath);
        if (!await ioFile.exists()) continue;

        final bytes = await ioFile.readAsBytes();
        final fileName = filePath.split('/').last.split('\\').last;

        if (file.type == SharedMediaType.image) {
          imageFiles.add(SharedImageData(
            bytes: bytes,
            fileName: fileName,
            path: filePath,
          ));
        } else {
          genericFiles.add(SharedFileData(
            bytes: bytes,
            fileName: fileName,
            path: filePath,
            mimeType: file.mimeType,
          ));
        }
      } catch (e) {
        // URL/text shares can be passed directly in path and are not files.
        if (file.type == SharedMediaType.text) {
          final raw = (file.path).trim();
          final url = _extractFirstUrl(raw);
          if (url != null && sharedUrl == null) {
            sharedUrl = SharedUrlData(url: url, rawText: raw);
          } else if (raw.isNotEmpty && sharedText == null) {
            sharedText = SharedTextData(content: raw);
          }
        } else {
          debugPrint('Error reading shared file: $e');
        }
      }
    }

    if (imageFiles.isNotEmpty && onImagesShared != null) {
      onImagesShared!(imageFiles);
    }

    if (genericFiles.isNotEmpty && onFilesShared != null) {
      onFilesShared!(genericFiles);
    }

    final urlCallback = onUrlShared;
    final textCallback = onTextShared;

    if (sharedUrl != null && urlCallback != null) {
      urlCallback(sharedUrl);
    }

    if (sharedText != null && textCallback != null) {
      textCallback(sharedText);
    }

    // Clear media intent after processing.
    ReceiveSharingIntent.instance.reset();
  }

  String? _extractFirstUrl(String input) {
    final regex = RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false);
    final match = regex.firstMatch(input);
    return match?.group(1);
  }

  String _decodeSharedText(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  /// Dispose of subscriptions.
  void dispose() {
    _mediaStreamSubscription?.cancel();
    _mediaStreamSubscription = null;
  }
}

/// Data class for shared image information
class SharedImageData {
  final Uint8List bytes;
  final String fileName;
  final String path;

  SharedImageData({
    required this.bytes,
    required this.fileName,
    required this.path,
  });
}

/// Data class for shared non-image file information.
class SharedFileData {
  final Uint8List bytes;
  final String fileName;
  final String path;
  final String? mimeType;

  SharedFileData({
    required this.bytes,
    required this.fileName,
    required this.path,
    this.mimeType,
  });
}

/// Data class for shared URL/text payloads.
class SharedUrlData {
  final String url;
  final String rawText;

  SharedUrlData({
    required this.url,
    required this.rawText,
  });
}

/// Data class for shared plain text payloads.
class SharedTextData {
  final String content;
  final String? fileName;

  SharedTextData({
    required this.content,
    this.fileName,
  });
}
