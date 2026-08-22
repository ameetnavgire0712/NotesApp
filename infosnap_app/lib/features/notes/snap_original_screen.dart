import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io' show File, Platform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../../core/services/api_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';

/// Full-screen in-app reader for a note's original content.
/// Loads the signed view URL (from view-token API) in a WebView.
/// Stays in-app — no external browser launch.
class SnapOriginalScreen extends StatefulWidget {
  final String noteId;
  final Note? note; // optional, for title display

  const SnapOriginalScreen({super.key, required this.noteId, this.note});

  @override
  State<SnapOriginalScreen> createState() => _SnapOriginalScreenState();
}

class _SnapOriginalScreenState extends State<SnapOriginalScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _hasError = false;
  String? _originalUrl;
  bool _externalFallbackTried = false;
  bool _downloadFallbackTried = false;
  String? _pdfLocalPath;
  bool _pdfReady = false;
  String? _inlineTextContent;

  String get _fileExt {
    final filename = widget.note?.originalFilename?.toLowerCase() ?? '';
    if (!filename.contains('.')) return '';
    return filename.split('.').last;
  }

  bool get _isImageSnap {
    final note = widget.note;
    if (note == null) return false;
    final filename = note.originalFilename?.toLowerCase() ?? '';
    return note.contentType == 'image' ||
        note.contentType == 'screenshot' ||
        filename.endsWith('.jpg') ||
        filename.endsWith('.jpeg') ||
        filename.endsWith('.png') ||
        filename.endsWith('.gif') ||
        filename.endsWith('.webp') ||
        filename.endsWith('.heic') ||
        filename.endsWith('.heif') ||
        filename.endsWith('.bmp') ||
        filename.endsWith('.tif') ||
        filename.endsWith('.tiff') ||
        filename.endsWith('.svg');
  }

  bool get _isOfficeDoc {
    return _fileExt == 'doc' ||
        _fileExt == 'docx' ||
        _fileExt == 'xls' ||
        _fileExt == 'xlsx' ||
        _fileExt == 'ppt' ||
        _fileExt == 'pptx';
  }

  bool get _isPdfDoc => _fileExt == 'pdf';

  bool get _isWebpageSnap {
    final note = widget.note;
    if (note == null) return false;
    final contentType = (note.contentType ?? '').toLowerCase();
    final hasSourceUrl = (note.sourceUrl ?? '').trim().isNotEmpty;
    if (_isSocialSnap) return false;
    return contentType == 'webpage' ||
        contentType == 'article' ||
        contentType == 'url' ||
        contentType == 'link' ||
        contentType == 'website' ||
        contentType == 'web' ||
        hasSourceUrl;
  }

  static const Set<String> _kSocialContentTypes = {
    'youtube',
    'twitter',
    'tweet',
    'x',
    'instagram',
    'facebook',
    'linkedin',
    'pinterest',
    'tiktok',
    'reddit',
  };

  static const Map<String, String> _kSocialBadgeLabels = {
    'youtube': 'YouTube',
    'twitter': 'Twitter',
    'tweet': 'Twitter',
    'x': 'X',
    'instagram': 'Instagram',
    'facebook': 'Facebook',
    'linkedin': 'LinkedIn',
    'pinterest': 'Pinterest',
    'tiktok': 'TikTok',
    'reddit': 'Reddit',
  };

  bool get _isSocialSnap {
    final ct = (widget.note?.contentType ?? '').toLowerCase();
    return _kSocialContentTypes.contains(ct);
  }

  bool get _isQuickNote {
    final note = widget.note;
    if (note == null) return false;
    return (note.contentType ?? '').toLowerCase() == 'quick_note';
  }

  bool get _isGenericWebDoc {
    return !_isImageSnap && !_isPdfDoc && !_isOfficeDoc && !_isWebpageSnap;
  }

  String get _fileTypeBadge {
    final contentType = (widget.note?.contentType ?? '').toLowerCase();
    final socialLabel = _kSocialBadgeLabels[contentType];
    if (socialLabel != null) return socialLabel;
    if (_fileExt.isNotEmpty) return _fileExt.toUpperCase();
    if (contentType.isNotEmpty) {
      return contentType.toUpperCase();
    }
    return 'BIN';
  }

  String _buildViewerUrl(String rawUrl) {
    if (_isOfficeDoc) {
      final encoded = Uri.encodeComponent(rawUrl);
      return 'https://view.officeapps.live.com/op/embed.aspx?src=$encoded';
    }
    return rawUrl;
  }

  Future<bool> _preparePdf(String rawUrl) async {
    try {
      final response = await http.get(Uri.parse(rawUrl));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return false;
      }

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/snap_${widget.noteId}.pdf';
      final file = File(path);
      await file.writeAsBytes(response.bodyBytes, flush: true);

      if (!mounted) return false;
      setState(() {
        _pdfLocalPath = path;
        _pdfReady = true;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openExternally(
    String rawUrl, {
    bool closeAfterLaunch = false,
  }) async {
    final parsed = Uri.tryParse(rawUrl);
    if (parsed == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      return;
    }

    final launched =
        await launchUrl(parsed, mode: LaunchMode.externalApplication);
    if (!mounted) return;

    if (launched) {
      if (closeAfterLaunch && context.canPop()) {
        context.pop();
      }
      return;
    }

    setState(() {
      _isLoading = false;
      _hasError = true;
    });
  }

  Future<void> _downloadAndOpen(String rawUrl) async {
    if (_downloadFallbackTried) return;
    _downloadFallbackTried = true;

    try {
      final response = await http.get(Uri.parse(rawUrl));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        await _openExternally(rawUrl, closeAfterLaunch: true);
        return;
      }

      final dir = await getTemporaryDirectory();
      final originalName = widget.note?.originalFilename?.trim();
      final ext = _fileExt.isNotEmpty ? _fileExt : 'bin';
      final filename = (originalName != null && originalName.isNotEmpty)
          ? originalName
          : 'snap_${widget.noteId}.$ext';
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(response.bodyBytes, flush: true);

      final opened = await launchUrl(
        Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        await _openExternally(rawUrl, closeAfterLaunch: true);
      } else if (mounted && context.canPop()) {
        context.pop();
      }
    } catch (_) {
      await _openExternally(rawUrl, closeAfterLaunch: true);
    }
  }

  Future<bool> _prepareInlineText(String rawUrl) async {
    try {
      final response = await http.get(Uri.parse(rawUrl));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return false;
      }

      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (text.trim().isEmpty) return false;

      final sampleEnd = text.length < 4000 ? text.length : 4000;
      final sample = text.substring(0, sampleEnd);
      var printable = 0;
      for (final code in sample.runes) {
        if (code == 9 ||
            code == 10 ||
            code == 13 ||
            (code >= 32 && code < 127)) {
          printable++;
        }
      }
      final ratio = printable / sample.length;
      if (ratio < 0.70) return false;

      if (!mounted) return false;
      setState(() {
        _inlineTextContent = text;
        _isLoading = false;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  String _cleanPlainText(String input) {
    var text = input
        .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');

    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");

    return text.trim();
  }

  Future<void> _probeRenderAndFallbackIfBlank() async {
    if (!_isGenericWebDoc || _downloadFallbackTried || _originalUrl == null) {
      return;
    }

    try {
      final result = await _controller.runJavaScriptReturningResult(
        '''(function() {
          var text = (document.body && document.body.innerText ? document.body.innerText : '').trim();
          var hasStructure = !!document.querySelector('pre, code, table, p, article, main');
          return JSON.stringify({ len: text.length, hasStructure: hasStructure });
        })();''',
      );

      final cleaned =
          result.toString().replaceAll('"{', '{').replaceAll('}"', '}');
      final data = jsonDecode(cleaned) as Map<String, dynamic>;
      final len = (data['len'] as num?)?.toInt() ?? 0;
      final hasStructure = data['hasStructure'] == true;

      if (len == 0 && !hasStructure && _originalUrl != null) {
        await _downloadAndOpen(_originalUrl!);
      }
    } catch (_) {
      if (_originalUrl != null) {
        await _downloadAndOpen(_originalUrl!);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted && progress == 100) {
              setState(() => _isLoading = false);
            }
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
            // Force 100% zoom via JS viewport meta tag (works for HTML pages)
            _controller.runJavaScript(
              '''(function() {
                var m = document.querySelector('meta[name="viewport"]');
                if (!m) { m = document.createElement('meta'); m.name = "viewport"; document.head.appendChild(m); }
                m.content = "width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes";
              })();''',
            );
            // Also set Android WebView text zoom to 100% (works for images, PDFs, etc.)
            if (Platform.isAndroid &&
                _controller.platform is AndroidWebViewController) {
              (_controller.platform as AndroidWebViewController)
                  .setTextZoom(100);
            }

            // Generic fallback for blank attachment-style responses.
            unawaited(_probeRenderAndFallbackIfBlank());
          },
          onWebResourceError: (error) {
            if (!mounted) return;

            // If embedded viewers fail (common for attachment-style responses),
            // hand off to external app/browser so user can download/open the file.
            if ((_isPdfDoc || _isOfficeDoc) &&
                !_externalFallbackTried &&
                _originalUrl != null) {
              _externalFallbackTried = true;
              unawaited(_openExternally(_originalUrl!, closeAfterLaunch: true));
              return;
            }

            if (_isGenericWebDoc &&
                !_downloadFallbackTried &&
                _originalUrl != null) {
              unawaited(_downloadAndOpen(_originalUrl!));
              return;
            }

            setState(() {
              _isLoading = false;
              _hasError = true;
            });
          },
        ),
      );
    _loadContent();
  }

  Future<void> _loadContent() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    _externalFallbackTried = false;
    _downloadFallbackTried = false;
    _pdfLocalPath = null;
    _pdfReady = false;
    _inlineTextContent = null;
    final url = await ApiService().getViewUrl(widget.noteId);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      return;
    }

    if (_isPdfDoc) {
      setState(() {
        _originalUrl = url;
      });
      final ok = await _preparePdf(url);
      if (!ok) {
        await _openExternally(url, closeAfterLaunch: true);
      }
      return;
    }

    if (_isQuickNote) {
      final note = widget.note;
      final rawText = await ApiService().getQuickNoteContentForEditing(
        widget.noteId,
        fallback:
            note?.contentPreview ?? note?.description ?? note?.title ?? '',
      );
      final plainText = _cleanPlainText(
          rawText.isNotEmpty ? rawText : (note?.contentPreview ?? ''));

      setState(() {
        _originalUrl = url;
        _inlineTextContent =
            plainText.isNotEmpty ? plainText : 'No note content available.';
        _isLoading = false;
      });
      return;
    }

    if (_isSocialSnap) {
      // YouTube / Twitter / etc. behave badly inside an in-app WebView (the
      // YouTube feed becomes scrollable, players sometimes refuse to start).
      // Hand off to the native app or system browser instead.
      final sourceUrl = widget.note?.sourceUrl?.trim();
      final targetUrl =
          (sourceUrl != null && sourceUrl.isNotEmpty) ? sourceUrl : url;
      setState(() {
        _originalUrl = targetUrl;
      });
      await _openExternally(targetUrl, closeAfterLaunch: true);
      return;
    }

    if (_isWebpageSnap) {
      final sourceUrl = widget.note?.sourceUrl?.trim();
      final targetUrl =
          (sourceUrl != null && sourceUrl.isNotEmpty) ? sourceUrl : url;
      setState(() {
        _originalUrl = targetUrl;
      });
      await _controller.loadRequest(Uri.parse(targetUrl));
      return;
    }

    if (_isGenericWebDoc) {
      setState(() {
        _originalUrl = url;
      });
      final ok = await _prepareInlineText(url);
      if (!ok) {
        await _downloadAndOpen(url);
      }
      return;
    }

    final viewerUrl = _buildViewerUrl(url);
    setState(() {
      _originalUrl = url;
    });
    await _controller.loadRequest(Uri.parse(viewerUrl));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = widget.note?.title ?? 'Original';

    return Scaffold(
      backgroundColor:
          isDark ? AppColors.darkBackground : AppColors.lightBackground,
      appBar: AppBar(
        backgroundColor:
            isDark ? AppColors.darkSurface : AppColors.lightSurface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_rounded,
            color: isDark ? Colors.white : AppColors.textDark,
          ),
          onPressed: () => context.pop(),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(15),
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : AppColors.textDark,
                ),
              ),
            ),
            Container(
              margin: EdgeInsets.only(left: Responsive.pp(8)),
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(8), vertical: Responsive.pp(3)),
              decoration: BoxDecoration(
                color:
                    isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(Responsive.wp(999)),
              ),
              child: Text(
                _fileTypeBadge,
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(10),
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_originalUrl != null)
            IconButton(
              icon: Icon(
                Icons.open_in_new_rounded,
                color: isDark ? Colors.white70 : AppColors.textLight,
              ),
              tooltip: 'Open externally',
              onPressed: () => _openExternally(_originalUrl!),
            ),
          if (!_hasError)
            IconButton(
              icon: Icon(
                Icons.refresh_rounded,
                color: isDark ? Colors.white70 : AppColors.textLight,
              ),
              onPressed: _loadContent,
            ),
        ],
        bottom: _isLoading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                ),
              )
            : null,
      ),
      body: Column(
        children: [
          Expanded(
            child: _hasError
                ? _ErrorView(onRetry: _loadContent)
                : (_isPdfDoc && _pdfReady && _pdfLocalPath != null)
                    ? PDFView(
                        filePath: _pdfLocalPath!,
                        enableSwipe: true,
                        swipeHorizontal: false,
                        autoSpacing: true,
                        pageFling: true,
                        onError: (_) {
                          if (_originalUrl != null && !_externalFallbackTried) {
                            _externalFallbackTried = true;
                            unawaited(_openExternally(_originalUrl!,
                                closeAfterLaunch: true));
                          }
                        },
                      )
                    : (_inlineTextContent != null)
                        ? _InlineTextView(content: _inlineTextContent!)
                        : (_isImageSnap && _originalUrl != null)
                            ? _ImageOriginalView(imageUrl: _originalUrl!)
                            : WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}

class _InlineTextView extends StatelessWidget {
  final String content;

  const _InlineTextView({required this.content});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? AppColors.darkBackground : AppColors.lightBackground,
      padding: EdgeInsets.all(Responsive.pp(14)),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: SelectableText(
          content,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: Responsive.sp(13),
            height: 1.4,
            color: isDark ? Colors.white : AppColors.textDark,
          ),
        ),
      ),
    );
  }
}

class _ImageOriginalView extends StatelessWidget {
  final String imageUrl;

  const _ImageOriginalView({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: isDark ? AppColors.darkBackground : AppColors.lightBackground,
      child: Center(
        child: InteractiveViewer(
          minScale: 1.0,
          maxScale: 4.0,
          panEnabled: true,
          boundaryMargin: EdgeInsets.all(Responsive.pp(24)),
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            alignment: Alignment.topCenter,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Responsive.pp(32)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: Responsive.sp(56),
              color: isDark ? Colors.white24 : Colors.black26,
            ),
            SizedBox(height: Responsive.wp(20)),
            Text(
              'Could not load content',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(18),
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : AppColors.textDark,
              ),
            ),
            SizedBox(height: Responsive.wp(8)),
            Text(
              'This file cannot be previewed in-app. Try opening it externally.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(14),
                color: isDark ? Colors.white38 : AppColors.textLight,
              ),
            ),
            SizedBox(height: Responsive.wp(28)),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh_rounded),
              label: Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(
                    horizontal: Responsive.pp(28), vertical: Responsive.pp(14)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Responsive.wp(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
