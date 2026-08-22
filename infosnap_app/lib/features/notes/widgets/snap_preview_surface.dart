// ignore_for_file: deprecated_member_use

import 'dart:ui';
import '../../../core/utils/responsive.dart';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/services/thumbnail_cache_manager.dart';
import 'text_card_thumbnail.dart';

enum SnapPreviewMode { grid, story }

class SnapPreviewSurface extends StatefulWidget {
  final String title;
  final String? description;
  final String? originalFilename;
  final String? contentType;
  final String? imageUrl;
  final String? noteId;
  final String? socialSource;
  final String? socialEmbedHtml;
  final String? sourceUrl;
  final SnapPreviewMode mode;
  final Color? accentColor;
  final BoxFit? imageFit;
  final bool interactive;

  const SnapPreviewSurface({
    super.key,
    required this.title,
    required this.description,
    required this.originalFilename,
    required this.contentType,
    required this.imageUrl,
    required this.mode,
    this.noteId,
    this.socialSource,
    this.socialEmbedHtml,
    this.sourceUrl,
    this.accentColor,
    this.imageFit,
    this.interactive = false,
  });

  @override
  State<SnapPreviewSurface> createState() => _SnapPreviewSurfaceState();
}

class _SnapPreviewSurfaceState extends State<SnapPreviewSurface> {
  late List<String> _candidates;
  int _fallbackIndex = 0;
  WebViewController? _socialEmbedController;
  bool _socialEmbedFailed = false;

  @override
  void initState() {
    super.initState();
    _candidates = _buildCandidates(widget.imageUrl);
    _configureSocialEmbed();
  }

  @override
  void didUpdateWidget(covariant SnapPreviewSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.contentType != widget.contentType ||
        oldWidget.originalFilename != widget.originalFilename ||
        oldWidget.title != widget.title ||
        oldWidget.description != widget.description ||
        oldWidget.sourceUrl != widget.sourceUrl ||
        oldWidget.socialSource != widget.socialSource ||
        oldWidget.mode != widget.mode) {
      _candidates = _buildCandidates(widget.imageUrl);
      _fallbackIndex = 0;
      _socialEmbedFailed = false;
      _configureSocialEmbed();
    }
  }

  void _configureSocialEmbed() {
    final embedUrl = _socialEmbedUrl(widget.sourceUrl);
    final embedHtml = _firstNonEmpty([
      _officialEmbedHtml(widget.socialEmbedHtml),
      _socialEmbedHtml(widget.sourceUrl),
    ]);
    if (embedUrl == null && embedHtml == null) {
      _socialEmbedController = null;
      return;
    }
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent);
    _socialEmbedController = controller
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            await _afterSocialEmbedLoad(controller);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != true) return;
            if (!mounted) return;
            setState(() {
              _socialEmbedFailed = true;
            });
          },
        ),
      );
    if (embedHtml != null) {
      controller.loadHtmlString(embedHtml, baseUrl: 'https://infosnap.ai');
    } else {
      controller.loadRequest(Uri.parse(embedUrl!));
    }
  }

  String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  String? _officialEmbedHtml(String? rawHtml) {
    final html = rawHtml?.trim();
    if (html == null || html.isEmpty) return null;
    final source = (widget.socialSource ?? '').toLowerCase();
    if (source != 'facebook') return null;
    return '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <style>
    html, body {
      margin: 0;
      padding: 0;
      background: transparent;
      overflow: ${widget.mode == SnapPreviewMode.grid ? 'hidden' : 'auto'};
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    .fb-post, iframe {
      max-width: 100% !important;
      width: 100% !important;
    }
  </style>
</head>
<body>
  $html
</body>
</html>
''';
  }

  Future<void> _afterSocialEmbedLoad(WebViewController controller) async {
    final source = (widget.socialSource ?? '').toLowerCase();
    if (source == 'linkedin' && widget.mode == SnapPreviewMode.grid) {
      await controller.runJavaScript('''
        (function() {
          var css = document.createElement('style');
          css.innerHTML = `
            html, body {
              margin: 0 !important;
              padding: 0 !important;
              overflow: hidden !important;
              background: transparent !important;
            }
            .embed-footer, .share-via, .li-footer, footer {
              display: none !important;
            }
          `;
          document.head.appendChild(css);
        })();
      ''');
    }

    try {
      final result = await controller.runJavaScriptReturningResult('''
        (function() {
          return ((document.title || '') + '\\n' + (document.body ? document.body.innerText : '')).slice(0, 1200);
        })();
      ''');
      final text = result.toString().toLowerCase();
      final broken =
          text.contains('link to this photo or video may be broken') ||
              text.contains('post may have been removed') ||
              text.contains("page isn't available") ||
              text.contains("this page isn't available") ||
              text.contains('webpage not available') ||
              text.contains('err_') ||
              text.contains("can't be reached");
      if (broken && mounted) {
        setState(() {
          _socialEmbedFailed = true;
        });
      }
    } catch (_) {
      // Some official embeds block script inspection; keep the embed visible.
    }
  }

  String? _socialEmbedUrl(String? rawUrl) {
    switch ((widget.socialSource ?? '').toLowerCase()) {
      case 'instagram':
        return _instagramEmbedUrl(rawUrl);
      case 'facebook':
        return _facebookEmbedUrl(rawUrl);
      case 'linkedin':
        return _linkedInEmbedUrl(rawUrl);
      default:
        return null;
    }
  }

  String? _socialEmbedHtml(String? rawUrl) {
    switch ((widget.socialSource ?? '').toLowerCase()) {
      case 'youtube':
        return _youtubeEmbedHtml(rawUrl);
      case 'twitter':
        return _twitterEmbedHtml(rawUrl);
      case 'reddit':
        return _redditEmbedHtml(rawUrl);
      default:
        return null;
    }
  }

  String? _instagramEmbedUrl(String? rawUrl) {
    final clean = rawUrl?.trim();
    if (clean == null || clean.isEmpty) return null;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.toLowerCase();
      if (host != 'instagram.com' &&
          host != 'www.instagram.com' &&
          host != 'm.instagram.com' &&
          !host.endsWith('.instagram.com')) {
        return null;
      }
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      for (var i = 0; i < segments.length - 1; i++) {
        final marker = segments[i].toLowerCase();
        if (marker == 'reel' || marker == 'p' || marker == 'tv') {
          final code =
              segments[i + 1].replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
          if (code.isEmpty) return null;
          return 'https://www.instagram.com/$marker/$code/embed';
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  String? _facebookEmbedUrl(String? rawUrl) {
    final clean = rawUrl?.trim();
    if (clean == null || clean.isEmpty) return null;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host != 'facebook.com' &&
          host != 'm.facebook.com' &&
          host != 'web.facebook.com' &&
          host != 'fb.watch' &&
          !host.endsWith('.facebook.com')) {
        return null;
      }
      final canonicalUrl = _canonicalFacebookUrl(clean);
      final pluginPath = _facebookPluginPath(canonicalUrl);
      return Uri.https('www.facebook.com', pluginPath, {
        'href': canonicalUrl,
        'show_text': 'true',
        'width': widget.mode == SnapPreviewMode.grid ? '420' : '500',
      }).toString();
    } catch (_) {
      return null;
    }
  }

  String _canonicalFacebookUrl(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      if (uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '') ==
          'fb.watch') {
        return rawUrl;
      }
      final query = Map<String, String>.from(uri.queryParameters)
        ..removeWhere((key, _) => key.toLowerCase().startsWith('utm_'))
        ..remove('mibextid')
        ..remove('ref')
        ..remove('__cft__')
        ..remove('__tn__');
      return uri
          .replace(
            scheme: 'https',
            host: 'www.facebook.com',
            queryParameters: query.isEmpty ? null : query,
          )
          .toString();
    } catch (_) {
      return rawUrl;
    }
  }

  String _facebookPluginPath(String canonicalUrl) {
    final lower = canonicalUrl.toLowerCase();
    if (lower.contains('/videos/') ||
        lower.contains('/watch/') ||
        lower.contains('/reel/') ||
        lower.contains('/share/v/') ||
        lower.contains('fb.watch/')) {
      return '/plugins/video.php';
    }
    return '/plugins/post.php';
  }

  String? _linkedInEmbedUrl(String? rawUrl) {
    final clean = rawUrl?.trim();
    if (clean == null || clean.isEmpty) return null;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host != 'linkedin.com' &&
          host != 'm.linkedin.com' &&
          !host.endsWith('.linkedin.com')) {
        return null;
      }
      final path = uri.path;
      if (path.startsWith('/embed/feed/update/')) {
        return 'https://www.linkedin.com$path';
      }
      final feed = RegExp(r'/feed/update/(urn:li:[^/?#]+)').firstMatch(path);
      if (feed != null) {
        return 'https://www.linkedin.com/embed/feed/update/${feed.group(1)}';
      }
      final posts = RegExp(r'/posts/([^/?#]+)').firstMatch(path);
      if (posts != null) {
        final slug = posts.group(1)!;
        final id = RegExp(r'(\d{10,})').firstMatch(slug)?.group(1);
        if (id != null) {
          return 'https://www.linkedin.com/embed/feed/update/urn:li:activity:$id';
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  String? _twitterEmbedUrl(String? rawUrl) {
    final clean = rawUrl?.trim();
    if (clean == null || clean.isEmpty) return null;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host != 'twitter.com' &&
          host != 'x.com' &&
          host != 'mobile.twitter.com') {
        return null;
      }
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final statusIndex =
          segments.indexWhere((s) => s.toLowerCase() == 'status');
      if (statusIndex < 0 || statusIndex + 1 >= segments.length) return null;
      final tweetId =
          RegExp(r'\d{8,}').firstMatch(segments[statusIndex + 1])?.group(0);
      if (tweetId == null) return null;
      return 'https://platform.twitter.com/embed/Tweet.html?id=$tweetId&dnt=true&theme=light';
    } catch (_) {
      return null;
    }
  }

  String? _youtubeEmbedHtml(String? rawUrl) {
    final videoId = _youtubeVideoId(rawUrl);
    if (videoId == null) return null;
    final embedUrl =
        'https://www.youtube.com/embed/$videoId?autoplay=0&playsinline=1&rel=0&modestbranding=1';
    return '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: #000;
      overflow: hidden;
    }
    iframe {
      width: 100%;
      height: 100%;
      border: 0;
      background: #000;
    }
  </style>
</head>
<body>
  <iframe
    src="${_escapeHtml(embedUrl)}"
    loading="eager"
    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
    allowfullscreen>
  </iframe>
</body>
</html>
''';
  }

  String? _youtubeVideoId(String? rawUrl) {
    final clean = rawUrl?.trim();
    if (clean == null || clean.isEmpty) return null;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host == 'youtu.be') {
        final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
        return _cleanYouTubeId(id);
      }
      if (host == 'youtube.com' ||
          host == 'm.youtube.com' ||
          host.endsWith('.youtube.com')) {
        final v = uri.queryParameters['v'];
        if (v != null && v.isNotEmpty) return _cleanYouTubeId(v);
        final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (segments.length >= 2 &&
            ['shorts', 'embed', 'live']
                .contains(segments.first.toLowerCase())) {
          return _cleanYouTubeId(segments[1]);
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  String? _cleanYouTubeId(String? value) {
    final match = RegExp(r'^[A-Za-z0-9_-]{6,20}$').firstMatch(value ?? '');
    return match?.group(0);
  }

  String? _twitterEmbedHtml(String? rawUrl) {
    final embedUrl = _twitterEmbedUrl(rawUrl);
    final originalUrl = _canonicalTwitterUrl(rawUrl);
    if (embedUrl == null || originalUrl == null) return null;
    final scaleCss = _gridEmbedScaleCss();
    return '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <style>
    html, body {
      margin: 0;
      padding: 0;
      background: transparent;
      overflow: ${widget.mode == SnapPreviewMode.grid ? 'hidden' : 'auto'};
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    $scaleCss
    .twitter-tweet, .twitter-tweet-rendered {
      margin: 0 !important;
      max-width: 100% !important;
      min-width: 0 !important;
    }
  </style>
</head>
<body>
  <div class="embed-root twitter-root">
    <blockquote class="twitter-tweet" data-dnt="true" data-theme="light">
      <a href="${_escapeHtml(originalUrl)}"></a>
    </blockquote>
  </div>
  <script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>
</body>
</html>
''';
  }

  String? _canonicalTwitterUrl(String? rawUrl) {
    final clean = rawUrl?.trim();
    if (clean == null || clean.isEmpty) return null;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host != 'twitter.com' &&
          host != 'x.com' &&
          host != 'mobile.twitter.com') {
        return null;
      }
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final statusIndex =
          segments.indexWhere((s) => s.toLowerCase() == 'status');
      if (statusIndex <= 0 || statusIndex + 1 >= segments.length) return null;
      final screenName = segments[statusIndex - 1];
      final tweetId =
          RegExp(r'\d{8,}').firstMatch(segments[statusIndex + 1])?.group(0);
      if (tweetId == null) return null;
      return 'https://twitter.com/$screenName/status/$tweetId';
    } catch (_) {
      return null;
    }
  }

  String? _redditEmbedUrl(String? rawUrl) {
    final clean = rawUrl?.trim();
    if (clean == null || clean.isEmpty) return null;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host != 'reddit.com' &&
          host != 'new.reddit.com' &&
          host != 'np.reddit.com' &&
          host != 'm.reddit.com' &&
          host != 'redd.it' &&
          host != 'old.reddit.com') {
        return null;
      }
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      String? postId;
      final commentsIndex =
          segments.indexWhere((s) => s.toLowerCase() == 'comments');
      if (commentsIndex >= 0 && commentsIndex + 1 < segments.length) {
        postId = segments[commentsIndex + 1];
      } else if (host == 'redd.it' && segments.isNotEmpty) {
        postId = segments.first;
      }
      if (postId == null || postId.isEmpty) return null;
      return 'https://www.reddit.com/comments/$postId/?embed=true&ref_source=embed';
    } catch (_) {
      return null;
    }
  }

  String? _redditEmbedHtml(String? rawUrl) {
    final clean = rawUrl?.trim();
    if (clean == null || clean.isEmpty) return null;
    try {
      final uri = Uri.parse(clean);
      final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host != 'reddit.com' &&
          host != 'new.reddit.com' &&
          host != 'np.reddit.com' &&
          host != 'm.reddit.com' &&
          host != 'redd.it' &&
          host != 'old.reddit.com') {
        return null;
      }
      final canonicalUrl = _canonicalRedditUrl(uri);
      if (canonicalUrl == null) return null;
      final redditMediaUrl = _redditMediaEmbedUrl(canonicalUrl);
      if (redditMediaUrl == null) return null;
      final scaleCss = _gridEmbedScaleCss();
      return '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <style>
    html, body {
      margin: 0;
      padding: 0;
      background: transparent;
      overflow: ${widget.mode == SnapPreviewMode.grid ? 'hidden' : 'auto'};
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    $scaleCss
    .reddit-embed-bq, .reddit-embed {
      margin: 0 !important;
      max-width: 100% !important;
      min-width: 0 !important;
    }
    iframe {
      border: 0;
      width: 100%;
      height: ${widget.mode == SnapPreviewMode.grid ? '560px' : '780px'};
      background: transparent;
    }
  </style>
</head>
<body>
  <div class="embed-root reddit-root">
    <iframe
      src="${_escapeHtml(redditMediaUrl)}"
      loading="eager"
      referrerpolicy="no-referrer-when-downgrade"
      allow="clipboard-write; encrypted-media; fullscreen; picture-in-picture"
      allowfullscreen>
    </iframe>
  </div>
</body>
</html>
''';
    } catch (_) {
      return null;
    }
  }

  String? _canonicalRedditUrl(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (host == 'redd.it' && segments.isNotEmpty) {
      return 'https://www.reddit.com/comments/${segments.first}/';
    }
    final commentsIndex =
        segments.indexWhere((s) => s.toLowerCase() == 'comments');
    if (commentsIndex < 0 || commentsIndex + 1 >= segments.length) {
      return null;
    }
    return Uri(
      scheme: 'https',
      host: 'www.reddit.com',
      pathSegments: segments,
    ).toString();
  }

  String? _redditMediaEmbedUrl(String canonicalUrl) {
    try {
      final uri = Uri.parse(canonicalUrl);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return null;
      return Uri(
        scheme: 'https',
        host: 'embed.reddit.com',
        pathSegments: segments,
        queryParameters: const {
          'ref_source': 'embed',
          'ref': 'share',
          'embed': 'true',
          'theme': 'light',
        },
      ).toString();
    } catch (_) {
      return null;
    }
  }

  String _gridEmbedScaleCss() {
    if (widget.mode != SnapPreviewMode.grid) return '';
    const scale = 0.84;
    const width = 100 / scale;
    return '''
    .embed-root {
      transform: scale($scale);
      transform-origin: top left;
      width: $width%;
    }
    .reddit-root {
      min-height: 520px;
    }
    .twitter-root {
      min-height: 420px;
    }
    ''';
  }

  String _escapeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  List<String> _buildCandidates(String? url) {
    final out = <String>[];
    final primary = url?.trim();
    if (primary == null || primary.isEmpty) return out;

    out.add(primary);
    final proxied = _wsrvProxy(primary);
    if (proxied != null && proxied != primary) {
      out.add(proxied);
    }
    if (primary.contains('img.youtube.com') &&
        primary.contains('maxresdefault')) {
      out.add(primary.replaceFirst('maxresdefault', 'hqdefault'));
    }
    if (primary.contains('i.ytimg.com') && primary.contains('maxresdefault')) {
      out.add(primary.replaceFirst('maxresdefault', 'hqdefault'));
    }
    return out;
  }

  String? _wsrvProxy(String url) {
    if (url.startsWith('https://wsrv.nl/')) return null;
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      const unstable = [
        'fbcdn.net',
        'fbsbx.com',
        'twimg.com',
        'licdn.com',
        'redditmedia.com',
        'redd.it',
        'tiktokcdn.com',
        'tiktokcdn-us.com',
      ];
      final isUnstable =
          unstable.any((item) => host == item || host.endsWith('.$item'));
      if (!isUnstable) return null;
      final stripped =
          url.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
      return 'https://wsrv.nl/?url=ssl:${Uri.encodeComponent(stripped)}&w=1600&output=jpg&we=1&l=6';
    } catch (_) {
      return null;
    }
  }

  Gradient _contentGradient(String? contentType) {
    switch ((contentType ?? '').toLowerCase()) {
      case 'uploaded_file':
        return const LinearGradient(
          begin: Alignment(-0.35, -1.0),
          end: Alignment(0.35, 1.0),
          colors: [Color(0xFFF8D7DF), Color(0xFFF3E4CB)],
        );
      case 'webpage':
      case 'article':
        return const LinearGradient(
          begin: Alignment(-1.0, 0.0),
          end: Alignment(1.0, 0.0),
          colors: [Color(0xFFDDEAF6), Color(0xFFE9F5E8)],
        );
      case 'pdf':
        return const LinearGradient(
          begin: Alignment(-0.6, -1.0),
          end: Alignment(0.9, 1.0),
          colors: [Color(0xFFE3EFFE), Color(0xFFF9EFFC)],
        );
      case 'quick_note':
        return const RadialGradient(
          center: Alignment(0.10, 0.03),
          radius: 1.05,
          colors: [
            Color(0xFFE1F5FE),
            Color(0xFFF5F7FF),
            Color(0xFFF5F7FF),
          ],
          stops: [0.0, 0.423, 1.0],
        );
      case 'screenshot':
      case 'image':
        return const LinearGradient(
          begin: Alignment(-1.0, -1.0),
          end: Alignment(1.0, 1.0),
          colors: [Color(0xFFF9DDE4), Color(0xFFF4ECD9)],
        );
      default:
        return const LinearGradient(
          begin: Alignment(-0.35, -1.0),
          end: Alignment(0.35, 1.0),
          colors: [Color(0xFFE3F1FF), Color(0xFFEAF7F1)],
        );
    }
  }

  void _advanceFallback() {
    if (_fallbackIndex + 1 >= _candidates.length) return;
    setState(() {
      _fallbackIndex += 1;
    });
  }

  Widget _buildTextCard({required BorderRadius borderRadius}) {
    if ((widget.socialSource ?? '').toLowerCase() == 'instagram') {
      return _buildInstagramCard(borderRadius: borderRadius);
    }
    if ((widget.socialSource ?? '').toLowerCase() == 'facebook') {
      return _buildSocialFallbackCard(
        borderRadius: borderRadius,
        label: 'Facebook snap',
        fallbackTitle: 'Facebook post',
        actionText: 'Open original to view on Facebook',
        accent: const Color(0xFF1877F2),
        iconBuilder: (size) => Text(
          'f',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.66,
            fontWeight: FontWeight.w900,
            height: 0.95,
          ),
        ),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEAF3FF), Color(0xFFDCEBFF), Color(0xFFFFFFFF)],
        ),
      );
    }
    if ((widget.socialSource ?? '').toLowerCase() == 'linkedin') {
      return _buildLinkedInCard(borderRadius: borderRadius);
    }
    if ((widget.socialSource ?? '').toLowerCase() == 'twitter') {
      return _buildSocialFallbackCard(
        borderRadius: borderRadius,
        label: 'X / Twitter snap',
        fallbackTitle: 'Tweet',
        actionText: 'Open original to view on X',
        accent: const Color(0xFF111827),
        iconBuilder: (size) => Text(
          'X',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.54,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8FAFC), Color(0xFFE5E7EB), Color(0xFFFFFFFF)],
        ),
      );
    }
    if ((widget.socialSource ?? '').toLowerCase() == 'reddit') {
      return _buildSocialFallbackCard(
        borderRadius: borderRadius,
        label: 'Reddit snap',
        fallbackTitle: 'Reddit post',
        actionText: 'Open original to view on Reddit',
        accent: const Color(0xFFFF4500),
        iconBuilder: (size) => Text(
          'r/',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFF7ED), Color(0xFFFFEDD5), Color(0xFFFFFFFF)],
        ),
      );
    }
    return Center(
      child: FractionallySizedBox(
        widthFactor: widget.mode == SnapPreviewMode.story ? 0.92 : 0.88,
        heightFactor: widget.mode == SnapPreviewMode.story ? 0.92 : 0.88,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withOpacity(
                    widget.mode == SnapPreviewMode.story ? 0.18 : 0.08),
                blurRadius: widget.mode == SnapPreviewMode.story ? 16 : 10,
                offset: Offset(0, widget.mode == SnapPreviewMode.story ? 8 : 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: TextCardThumbnail(
              title: widget.title,
              description: widget.description,
              originalFilename: widget.originalFilename,
              contentType: widget.contentType,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSocialFallbackCard({
    required BorderRadius borderRadius,
    required String label,
    required String fallbackTitle,
    required String actionText,
    required Color accent,
    required Widget Function(double size) iconBuilder,
    required Gradient gradient,
  }) {
    final isGrid = widget.mode == SnapPreviewMode.grid;
    final description = (widget.description ?? '').trim();
    final title = description.isNotEmpty
        ? description
        : (widget.title.trim().isNotEmpty
            ? widget.title.trim()
            : fallbackTitle);
    final iconSize = Responsive.wp(isGrid ? 34 : 38);

    return Container(
      decoration: BoxDecoration(borderRadius: borderRadius, gradient: gradient),
      child: Center(
        child: FractionallySizedBox(
          widthFactor: isGrid ? 0.88 : 0.90,
          heightFactor: isGrid ? 0.88 : 0.86,
          child: Container(
            padding: EdgeInsets.all(Responsive.pp(isGrid ? 10 : 14)),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.90),
              borderRadius:
                  BorderRadius.circular(Responsive.wp(isGrid ? 14 : 18)),
              border: Border.all(color: accent.withOpacity(0.18)),
              boxShadow: [
                BoxShadow(
                  color: accent.withOpacity(0.14),
                  blurRadius: Responsive.wp(isGrid ? 12 : 18),
                  offset: Offset(0, Responsive.wp(isGrid ? 5 : 8)),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: iconSize,
                  height: iconSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Responsive.wp(10)),
                    color: accent,
                  ),
                  child: Center(child: iconBuilder(iconSize)),
                ),
                SizedBox(height: Responsive.wp(isGrid ? 8 : 12)),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: Responsive.sp(isGrid ? 10 : 12),
                    fontWeight: FontWeight.w800,
                    color: accent,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: Responsive.wp(isGrid ? 4 : 6)),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: Responsive.sp(isGrid ? 13 : 18),
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF111827),
                    height: isGrid ? 1.12 : 1.18,
                  ),
                  maxLines: isGrid ? 2 : 5,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!isGrid) ...[
                  SizedBox(height: Responsive.wp(10)),
                  Text(
                    actionText,
                    style: TextStyle(
                      fontSize: Responsive.sp(11),
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLinkedInCard({required BorderRadius borderRadius}) {
    final description = (widget.description ?? '').trim();
    final title = description.isNotEmpty
        ? description
        : (widget.title.trim().isNotEmpty ? widget.title.trim() : 'LinkedIn');

    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFEFF6FF),
            Color(0xFFE0F2FE),
            Color(0xFFF8FAFC),
          ],
        ),
      ),
      child: Center(
        child: FractionallySizedBox(
          widthFactor: widget.mode == SnapPreviewMode.story ? 0.90 : 0.84,
          heightFactor: widget.mode == SnapPreviewMode.story ? 0.86 : 0.80,
          child: Container(
            padding: EdgeInsets.all(Responsive.pp(14)),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.90),
              borderRadius: BorderRadius.circular(Responsive.wp(18)),
              border: Border.all(color: const Color(0xFFBFDBFE)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0A66C2).withOpacity(0.14),
                  blurRadius: Responsive.wp(18),
                  offset: Offset(0, Responsive.wp(8)),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: Responsive.wp(38),
                  height: Responsive.wp(38),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Responsive.wp(10)),
                    color: const Color(0xFF0A66C2),
                  ),
                  child: Center(
                    child: Text(
                      'in',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: Responsive.sp(20),
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: Responsive.wp(12)),
                Text(
                  'LinkedIn snap',
                  style: TextStyle(
                    fontSize: Responsive.sp(12),
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF075985),
                    letterSpacing: 0.2,
                  ),
                ),
                SizedBox(height: Responsive.wp(6)),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: Responsive.sp(
                        widget.mode == SnapPreviewMode.story ? 18 : 15),
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF111827),
                    height: 1.18,
                  ),
                  maxLines: widget.mode == SnapPreviewMode.story ? 5 : 4,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: Responsive.wp(10)),
                Text(
                  'Open original to view on LinkedIn',
                  style: TextStyle(
                    fontSize: Responsive.sp(11),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInstagramCard({required BorderRadius borderRadius}) {
    final description = (widget.description ?? '').trim();
    final title = description.isNotEmpty
        ? description
        : (widget.title.trim().isNotEmpty ? widget.title.trim() : 'Instagram');

    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFFFF7ED),
            Color(0xFFFFE4E6),
            Color(0xFFF5E8FF),
          ],
        ),
      ),
      child: Center(
        child: FractionallySizedBox(
          widthFactor: widget.mode == SnapPreviewMode.story ? 0.90 : 0.84,
          heightFactor: widget.mode == SnapPreviewMode.story ? 0.86 : 0.80,
          child: Container(
            padding: EdgeInsets.all(Responsive.pp(14)),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.88),
              borderRadius: BorderRadius.circular(Responsive.wp(18)),
              border: Border.all(color: Colors.white.withOpacity(0.80)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF9D174D).withOpacity(0.12),
                  blurRadius: Responsive.wp(18),
                  offset: Offset(0, Responsive.wp(8)),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: Responsive.wp(38),
                  height: Responsive.wp(38),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Responsive.wp(12)),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFFF58529),
                        Color(0xFFDD2A7B),
                        Color(0xFF8134AF),
                      ],
                    ),
                  ),
                  child: Icon(
                    Icons.camera_alt_rounded,
                    color: Colors.white,
                    size: Responsive.sp(20),
                  ),
                ),
                SizedBox(height: Responsive.wp(12)),
                Text(
                  'Instagram snap',
                  style: TextStyle(
                    fontSize: Responsive.sp(12),
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF9D174D),
                    letterSpacing: 0.2,
                  ),
                ),
                SizedBox(height: Responsive.wp(6)),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: Responsive.sp(
                        widget.mode == SnapPreviewMode.story ? 18 : 15),
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF111827),
                    height: 1.18,
                  ),
                  maxLines: widget.mode == SnapPreviewMode.story ? 5 : 4,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: Responsive.wp(10)),
                Text(
                  'Open original to view on Instagram',
                  style: TextStyle(
                    fontSize: Responsive.sp(11),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF6B7280),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage({required BorderRadius borderRadius}) {
    if (_candidates.isEmpty) {
      return _buildTextCard(borderRadius: borderRadius);
    }

    if (widget.mode == SnapPreviewMode.story) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Transform.scale(
                scale: 1.08,
                child: CachedNetworkImage(
                  imageUrl: _candidates[_fallbackIndex],
                  cacheManager: ThumbnailCacheManager.instance,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  color: Colors.white.withOpacity(0.24),
                  colorBlendMode: BlendMode.lighten,
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.02),
                    Colors.black.withOpacity(0.16),
                  ],
                ),
              ),
            ),
            CachedNetworkImage(
              imageUrl: _candidates[_fallbackIndex],
              cacheManager: ThumbnailCacheManager.instance,
              width: double.infinity,
              height: double.infinity,
              fit: widget.imageFit ?? BoxFit.contain,
              alignment: Alignment.center,
              placeholder: (_, __) =>
                  _buildTextCard(borderRadius: borderRadius),
              errorWidget: (context, error, stackTrace) {
                if (_fallbackIndex + 1 < _candidates.length) {
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => _advanceFallback());
                }
                return _buildTextCard(borderRadius: borderRadius);
              },
            ),
          ],
        ),
      );
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: CachedNetworkImage(
        imageUrl: _candidates[_fallbackIndex],
        cacheManager: ThumbnailCacheManager.instance,
        width: double.infinity,
        height: double.infinity,
        fit: widget.imageFit ??
            (widget.mode == SnapPreviewMode.story
                ? BoxFit.contain
                : BoxFit.cover),
        alignment: Alignment.center,
        placeholder: (_, __) => _buildTextCard(borderRadius: borderRadius),
        errorWidget: (context, error, stackTrace) {
          if (_fallbackIndex + 1 < _candidates.length) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _advanceFallback());
          }
          return _buildTextCard(borderRadius: borderRadius);
        },
      ),
    );
  }

  Widget _buildInnerSurface({required BorderRadius borderRadius}) {
    final hasImage = _candidates.isNotEmpty;
    final socialEmbedController = _socialEmbedController;
    final content = socialEmbedController != null && !_socialEmbedFailed
        ? ClipRRect(
            borderRadius: borderRadius,
            child: AbsorbPointer(
              absorbing: !widget.interactive,
              child: WebViewWidget(controller: socialEmbedController),
            ),
          )
        : hasImage
            ? _buildImage(borderRadius: borderRadius)
            : _buildTextCard(borderRadius: borderRadius);

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: _contentGradient(widget.contentType),
            borderRadius: borderRadius,
          ),
        ),
        content,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == SnapPreviewMode.story) {
      final accent = widget.accentColor ?? const Color(0xFF22C55E);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCC08101C),
          borderRadius: BorderRadius.circular(Responsive.wp(28)),
          border: Border.all(
              color: Colors.white.withOpacity(0.16), width: Responsive.wp(1.2)),
          boxShadow: [
            BoxShadow(
              color: accent.withOpacity(0.22),
              blurRadius: Responsive.wp(36),
              spreadRadius: Responsive.wp(2),
              offset: Offset(0, Responsive.wp(14)),
            ),
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: Responsive.wp(24),
              offset: Offset(0, Responsive.wp(14)),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Responsive.wp(28)),
          child: _buildInnerSurface(
              borderRadius: BorderRadius.circular(Responsive.wp(28))),
        ),
      );
    }

    return _buildInnerSurface(
        borderRadius: BorderRadius.only(
      topLeft: Radius.circular(Responsive.wp(18)),
      topRight: Radius.circular(Responsive.wp(18)),
    ));
  }
}
