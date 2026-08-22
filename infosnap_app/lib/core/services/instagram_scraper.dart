// =============================================================================
// Instagram scraper (client-side, residential IP, persistent cookies)
// =============================================================================
// Loads an Instagram post/reel/IGTV URL in a headless `WebViewController` and
// scrapes the caption / author / thumbnail from the live DOM. Crucially this
// runs in the user's residential IP (and re-uses any IG login cookies they
// already have on-device), so it gets past the login-walls that the Cloudflare
// Worker hits from datacenter IPs.
//
// JS strategy (no waiting on `_sharedData`):
//   * Poll the DOM for `<meta property="og:description">` and
//     `<meta property="og:image">` (always present even on the lightest
//     anonymous SSR page).
//   * Look for any inline `<script>` containing `shortcode_media`/
//     `xdt_shortcode_media` and pull out the structured caption / username /
//     `display_url` directly (richer than og:description).
//   * Also try `<script type="application/ld+json">` (sometimes contains a
//     `caption`/`description` field).
//   * For reels, call IG's own internal `/api/v1/media/<media_id>/info/`
//     same-origin (with the user's cookies). This still returns the signed
//     `video_versions[].url` even when the public HTML has been stripped of
//     `shortcode_media`.
//   * As a last resort, auto-trigger muted playback on the `<video>` element
//     so IG starts requesting the real `.mp4` segments from cdninstagram.com,
//     which we then catch via the performance.getEntriesByType('resource')
//     sweep.
// =============================================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Result of a client-side Instagram scrape.
class InstagramScrapeResult {
  final String? caption;
  final String? author;
  final String? thumbnailUrl;
  final String? videoUrl;
  final List<Map<String, String>> mediaItems;
  final String? mediaType; // 'reel' | 'image' | 'video' | 'carousel'
  final int? carouselCount;

  /// Which layer produced the caption — useful for analytics + worker
  /// `metadata.social.caption_source`.
  final String
      captionSource; // 'shortcode_media' | 'ld_json' | 'og_tags' | 'none'

  const InstagramScrapeResult({
    this.caption,
    this.author,
    this.thumbnailUrl,
    this.videoUrl,
    this.mediaItems = const [],
    this.mediaType,
    this.carouselCount,
    this.captionSource = 'none',
  });

  bool get isEmpty =>
      (caption == null || caption!.isEmpty) &&
      (author == null || author!.isEmpty) &&
      (thumbnailUrl == null || thumbnailUrl!.isEmpty) &&
      (videoUrl == null || videoUrl!.isEmpty) &&
      mediaItems.isEmpty;

  Map<String, dynamic> toPrefetchedSocial() {
    return {
      if (caption != null && caption!.isNotEmpty) 'caption': caption,
      if (author != null && author!.isNotEmpty) 'author': author,
      if (thumbnailUrl != null && thumbnailUrl!.isNotEmpty)
        'thumbnail_url': thumbnailUrl,
      if (videoUrl != null && videoUrl!.isNotEmpty) 'video_url': videoUrl,
      if (mediaItems.isNotEmpty) 'media_items': mediaItems,
      if (mediaType != null && mediaType!.isNotEmpty) 'media_type': mediaType,
      if (carouselCount != null) 'carousel_media_count': carouselCount,
      'scraped_at': DateTime.now().toUtc().toIso8601String(),
    };
  }
}

class InstagramScraper {
  /// Attempt to scrape [postUrl]. Returns an [InstagramScrapeResult]; fields
  /// may be null on failure. Never throws.
  static Future<InstagramScrapeResult> scrape(
    String postUrl, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final completer = Completer<InstagramScrapeResult>();

    void finish(InstagramScrapeResult value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    Timer? timeoutTimer;
    WebViewController? controller;

    try {
      controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        // Use a mobile UA — IG serves a lighter, less-walled page to mobile
        // Safari than to desktop Chrome.
        ..setUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
          'Mobile/15E148 Safari/604.1',
        )
        ..addJavaScriptChannel(
          'InstagramChannel',
          onMessageReceived: (msg) {
            try {
              final decoded = json.decode(msg.message) as Map<String, dynamic>;
              debugPrint(
                '[IGScraper] result captionSrc=${decoded['caption_source']} '
                'captionChars=${(decoded['caption'] as String?)?.length ?? 0} '
                'author=${decoded['author']} '
                'mediaType=${decoded['media_type']} '
                'carousel=${decoded['carousel_count']} '
                'thumbCandidates=${(decoded['thumbnail_candidates'] as List?)?.length ?? 0} '
                'videoUrl=${(decoded['video_url'] as String?)?.length ?? 0}ch '
                'apiStatus=${decoded['diag_api_status']} '
                'embedStatus=${decoded['diag_embed_status']} '
                'playKicked=${decoded['diag_play_kicked']} '
                'videoTags=${decoded['diag_video_tag_count']} '
                'url=${decoded['url']}',
              );
              debugPrint(
                  '[IGScraper] thumbCandidates=${json.encode(decoded['thumbnail_candidates'] ?? const [])}');
              debugPrint(
                  '[IGScraper] apiSnippet=${decoded['diag_api_snippet']}');
              debugPrint(
                  '[IGScraper] embedSnippet=${decoded['diag_embed_snippet']}');
              finish(InstagramScrapeResult(
                caption: (decoded['caption'] as String?)?.trim(),
                author: (decoded['author'] as String?)?.trim(),
                thumbnailUrl: (decoded['thumbnail_url'] as String?)?.trim(),
                videoUrl: (decoded['video_url'] as String?)?.trim(),
                mediaItems: (decoded['media_items'] as List?)
                        ?.whereType<Map>()
                        .map((item) => item.map(
                              (key, value) =>
                                  MapEntry(key.toString(), value.toString()),
                            ))
                        .where((item) =>
                            (item['url'] ?? '').isNotEmpty &&
                            (item['type'] ?? '').isNotEmpty)
                        .toList() ??
                    const [],
                mediaType: (decoded['media_type'] as String?)?.trim(),
                carouselCount: decoded['carousel_count'] is int
                    ? decoded['carousel_count'] as int
                    : null,
                captionSource: (decoded['caption_source'] as String?) ?? 'none',
              ));
            } catch (e) {
              debugPrint('[IGScraper] decode failed: $e raw=${msg.message}');
              finish(const InstagramScrapeResult());
            }
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) async {
              try {
                await controller!.runJavaScript(_scraperJs);
              } catch (e) {
                debugPrint('[IGScraper] injection failed: $e');
                finish(const InstagramScrapeResult());
              }
            },
            onWebResourceError: (err) {
              debugPrint(
                  '[IGScraper] resource error: ${err.description} mainFrame=${err.isForMainFrame}');
              if (err.isForMainFrame ?? false) {
                finish(const InstagramScrapeResult());
              }
            },
          ),
        );

      timeoutTimer = Timer(timeout, () {
        debugPrint('[IGScraper] timeout after ${timeout.inSeconds}s');
        finish(const InstagramScrapeResult());
      });

      debugPrint('[IGScraper] loading $postUrl');
      await controller.loadRequest(Uri.parse(postUrl));
    } catch (e) {
      debugPrint('[IGScraper] setup failed: $e');
      finish(const InstagramScrapeResult());
    }

    final result = await completer.future;
    timeoutTimer?.cancel();
    try {
      await controller?.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
    return result;
  }
}

// -----------------------------------------------------------------------------
// JS payload — runs in instagram.com origin with the user's cookies.
//
// Polls the DOM (up to ~12s) for any of:
//   * a <script> containing "shortcode_media" / "xdt_shortcode_media"
//   * <meta property="og:description"> + <meta property="og:image">
//   * <script type="application/ld+json">
//
// Returns JSON via InstagramChannel:
//   { caption, author, thumbnail_url, video_url, media_items, media_type, carousel_count,
//     caption_source, url }
// -----------------------------------------------------------------------------
const String _scraperJs = r'''
(async function () {
  function send(payload) {
    try { window.InstagramChannel.postMessage(JSON.stringify(payload)); } catch (e) {}
  }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  var result = {
    caption: '',
    author: '',
    thumbnail_url: '',
    video_url: '',
    media_items: [],
    thumbnail_candidates: [],
    media_type: '',
    carousel_count: null,
    caption_source: 'none',
    url: location.href,
  };

  function addMediaItem(type, url) {
    if (!type || !url || /^blob:/i.test(url)) return;
    for (var i = 0; i < result.media_items.length; i++) {
      if (result.media_items[i].url === url) return;
    }
    if (result.media_items.length < 8) {
      result.media_items.push({ type: type, url: url });
    }
  }

  function decodeEscapedUrl(raw) {
    var out = String(raw || '');
    try { out = JSON.parse('"' + out + '"'); } catch (e) {
      out = out.replace(/\\u0026/g, '&').replace(/\\\//g, '/').replace(/\\"/g, '"');
    }
    return out.replace(/\\u0026/g, '&').replace(/\\\//g, '/');
  }

  function imageCropPenalty(url) {
    var u = String(url || '');
    var penalty = 0;
    if (/[?&]stp=[^&]*c\d+(?:\.\d+){3}a_/i.test(u)) penalty += 80;
    if (/\/c\d+(?:\.\d+){3}\//i.test(u)) penalty += 80;
    if (/(?:s|p)(150|240|320|480|640|750|1080)x\1/i.test(u)) penalty += 25;
    if (/s(?:150|240|320|480|640|750|1080)x(?:150|240|320|480|640|750|1080)/i.test(u)) penalty += 15;
    if (/CAROUSEL_ITEM\.best_image_urlgen/i.test(u)) penalty += 10;
    return penalty;
  }

  function addThumbnailCandidate(url, source, width, height, firstImage) {
    if (!url || /^blob:/i.test(url) || !/^https?:\/\//i.test(url)) return;
    for (var i = 0; i < result.thumbnail_candidates.length; i++) {
      if (result.thumbnail_candidates[i].url === url) return;
    }
    var w = Number(width || 0);
    var h = Number(height || 0);
    var area = w > 0 && h > 0 ? w * h : 0;
    var isSquare = w > 0 && h > 0 && Math.abs(w - h) <= 4;
    var cropPenalty = imageCropPenalty(url);
    var score = area / 1000;
    if (firstImage) score += 10000;
    if (cropPenalty) score -= cropPenalty * 100;
    if (isSquare && cropPenalty) score -= 1500;
    result.thumbnail_candidates.push({
      url: url,
      source: source || 'unknown',
      width: w || null,
      height: h || null,
      first_image: !!firstImage,
      crop_penalty: cropPenalty,
      score: Math.round(score),
    });
  }

  function chooseBestThumbnail() {
    if (!result.thumbnail_candidates.length) return;
    var best = result.thumbnail_candidates[0];
    for (var i = 1; i < result.thumbnail_candidates.length; i++) {
      var c = result.thumbnail_candidates[i];
      if ((c.score || 0) > (best.score || 0)) best = c;
    }
    if (best && best.url) result.thumbnail_url = best.url;
  }

  function pickShortcodeMediaFromScripts() {
    var scripts = document.querySelectorAll('script');
    for (var i = 0; i < scripts.length; i++) {
      var txt = scripts[i].textContent || '';
      if (txt.indexOf('shortcode_media') === -1 &&
          txt.indexOf('xdt_shortcode_media') === -1) continue;

      // edge_media_to_caption  ->  edges[0].node.text
      var capMatch = txt.match(/"edge_media_to_caption"\s*:\s*\{\s*"edges"\s*:\s*\[\s*\{\s*"node"\s*:\s*\{\s*"text"\s*:\s*"((?:\\.|[^"\\])*)"/);
      if (capMatch && capMatch[1]) {
        try { result.caption = JSON.parse('"' + capMatch[1] + '"'); }
        catch (e) { result.caption = capMatch[1].replace(/\\n/g, '\n').replace(/\\"/g, '"'); }
        result.caption_source = 'shortcode_media';
      }
      var authMatch = txt.match(/"owner"\s*:\s*\{[^}]*?"username"\s*:\s*"([^"]+)"/);
      if (authMatch) result.author = authMatch[1];
      var thumbMatch = txt.match(/"display_url"\s*:\s*"([^"]+)"/);
      if (thumbMatch) {
        try { result.thumbnail_url = JSON.parse('"' + thumbMatch[1] + '"'); }
        catch (e) { result.thumbnail_url = thumbMatch[1].replace(/\\u0026/g, '&'); }
        addThumbnailCandidate(result.thumbnail_url, 'shortcode_display_url_first', null, null, true);
        addMediaItem('image', result.thumbnail_url);
      }
      var videoMatch =
        // Modern v1 API shape (most common as of 2024+):
        //   "video_versions":[{"type":101,"width":540,"height":960,"url":"..."}]
        // Pull the first object's "url" out without needing to fully parse.
        txt.match(/"video_versions"\s*:\s*\[\s*\{[^}]*?"url"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
        // Polaris GraphQL shapes (Reels / IGTV).
        txt.match(/"playable_url_quality_hd"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
        txt.match(/"playable_url"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
        // Legacy shortcode_media field name (older HTML responses).
        txt.match(/"video_url"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
        // Last-ditch: a <video><source ... config_width=...> style payload.
        txt.match(/"src"\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*"config_width"/);
      if (videoMatch && videoMatch[1] && !result.video_url) {
        try { result.video_url = JSON.parse('"' + videoMatch[1] + '"'); }
        catch (e) { result.video_url = videoMatch[1].replace(/\\u0026/g, '&'); }
        addMediaItem('video', result.video_url);
      }
      var displayRe = /"display_url"\s*:\s*"((?:\\.|[^"\\])*)"/g;
      var displayMatch;
      while ((displayMatch = displayRe.exec(txt)) !== null && result.media_items.length < 8) {
        var displayUrl = '';
        try { displayUrl = JSON.parse('"' + displayMatch[1] + '"'); }
        catch (e) { displayUrl = displayMatch[1].replace(/\\u0026/g, '&'); }
        addThumbnailCandidate(displayUrl, 'shortcode_display_url', null, null, false);
        addMediaItem('image', displayUrl);
      }
      var videoRe = /"video_url"\s*:\s*"((?:\\.|[^"\\])*)"/g;
      var videoIterMatch;
      while ((videoIterMatch = videoRe.exec(txt)) !== null && result.media_items.length < 8) {
        try { addMediaItem('video', JSON.parse('"' + videoIterMatch[1] + '"')); }
        catch (e) { addMediaItem('video', videoIterMatch[1].replace(/\\u0026/g, '&')); }
      }
      // Modern carousel video shape: each carousel item carries a
      // "video_versions":[{... "url":"..." ...}] block.
      var vvRe = /"video_versions"\s*:\s*\[\s*\{[^}]*?"url"\s*:\s*"((?:\\.|[^"\\])*)"/g;
      var vvIterMatch;
      while ((vvIterMatch = vvRe.exec(txt)) !== null && result.media_items.length < 8) {
        try { addMediaItem('video', JSON.parse('"' + vvIterMatch[1] + '"')); }
        catch (e) { addMediaItem('video', vvIterMatch[1].replace(/\\u0026/g, '&')); }
      }
      if (/"is_video"\s*:\s*true/.test(txt)) result.media_type = 'video';
      else if (/"is_video"\s*:\s*false/.test(txt)) result.media_type = 'image';
      // Modern reels: media_type=2, or product_type:"clips" (Reels) / "igtv".
      if (!result.media_type && /"product_type"\s*:\s*"(?:clips|igtv|feed_video)"/.test(txt)) {
        result.media_type = 'video';
      }
      if (!result.media_type && /"media_type"\s*:\s*2\b/.test(txt)) {
        result.media_type = 'video';
      }
      if (/"__typename"\s*:\s*"GraphSidecar"/.test(txt) ||
          /"product_type"\s*:\s*"carousel_container"/.test(txt)) {
        result.media_type = 'carousel';
        var carMatch = txt.match(/"edge_sidecar_to_children"\s*:\s*\{\s*"edges"\s*:\s*\[((?:[^\[\]]|\[[^\]]*\])*)\]/);
        if (carMatch) {
          var nodes = carMatch[1].match(/\{\s*"node"\s*:/g);
          if (nodes) result.carousel_count = nodes.length;
        }
      }
      if (result.video_url && !result.media_type) result.media_type = 'video';
      if (result.caption) return true;
    }
    return false;
  }

  function pickFromLdJson() {
    var blocks = document.querySelectorAll('script[type="application/ld+json"]');
    for (var i = 0; i < blocks.length; i++) {
      try {
        var data = JSON.parse(blocks[i].textContent || '{}');
        var arr = Array.isArray(data) ? data : [data];
        for (var j = 0; j < arr.length; j++) {
          var d = arr[j] || {};
          var cap = d.caption || d.description || d.articleBody;
          if (cap && typeof cap === 'string' && !result.caption) {
            result.caption = cap.trim();
            result.caption_source = 'ld_json';
          }
          if (!result.author && d.author && d.author.identifier) {
            result.author = String(d.author.identifier).replace(/^@/, '');
          } else if (!result.author && d.author && d.author.name) {
            result.author = String(d.author.name).replace(/^@/, '');
          }
          if (!result.thumbnail_url && d.thumbnailUrl) {
            result.thumbnail_url = Array.isArray(d.thumbnailUrl) ? d.thumbnailUrl[0] : d.thumbnailUrl;
            addThumbnailCandidate(result.thumbnail_url, 'ld_json_thumbnail', null, null, true);
          }
        }
      } catch (e) {}
    }
    return !!result.caption;
  }

  function pickFromOgTags() {
    var ogDesc = document.querySelector('meta[property="og:description"]');
    var ogImg = document.querySelector('meta[property="og:image"]');
    var ogVideo = document.querySelector('meta[property="og:video"]') ||
      document.querySelector('meta[property="og:video:secure_url"]');
    var ogTitle = document.querySelector('meta[property="og:title"]');
    if (ogImg && !result.thumbnail_url) result.thumbnail_url = ogImg.getAttribute('content') || '';
    if (result.thumbnail_url) {
      addThumbnailCandidate(result.thumbnail_url, 'og_image', null, null, true);
      addMediaItem('image', result.thumbnail_url);
    }
    if (ogVideo && !result.video_url) {
      result.video_url = ogVideo.getAttribute('content') || '';
      if (result.video_url && !result.media_type) result.media_type = 'video';
      addMediaItem('video', result.video_url);
    }
    if (ogTitle && !result.author) {
      var t = ogTitle.getAttribute('content') || '';
      var m = t.match(/^(.+?)\s+on Instagram/i);
      if (m) result.author = m[1].trim().replace(/^@/, '');
    }
    if (ogDesc && !result.caption) {
      var raw = ogDesc.getAttribute('content') || '';
      // og:description shape: "N likes, M comments - <author> on <date>: \"<caption>\""
      // IG serves ASCII quotes; accept curly quotes too for safety.
      var m2 = raw.match(/:\s*["\u201C\u201D]([\s\S]+?)["\u201C\u201D]\s*$/);
      if (!m2) {
        // Fallback: strip the "<likes>, <comments> - <author> on <date>:" preamble.
        m2 = raw.match(/^[\d,]+\s+likes?,\s*[\d,]+\s+comments?\s*-\s*[^:]+:\s*["\u201C]?([\s\S]+?)["\u201D]?\s*$/i);
      }
      result.caption = (m2 ? m2[1] : raw).trim();
      if (result.caption) result.caption_source = 'og_tags';
    }
    return !!result.caption;
  }

  function pickFromDomVideo() {
    var videos = document.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      var src = v.currentSrc || v.src || '';
      if (!src) {
        var source = v.querySelector('source[src]');
        src = source ? (source.getAttribute('src') || '') : '';
      }
      if (src && !/^blob:/i.test(src)) {
        result.video_url = src;
        addMediaItem('video', src);
        if (!result.media_type) result.media_type = 'video';
        return true;
      }
    }
    return false;
  }

  function pickFromPerformanceVideo() {
    try {
      var entries = performance.getEntriesByType ? performance.getEntriesByType('resource') : [];
      for (var i = 0; i < entries.length; i++) {
        var name = entries[i] && entries[i].name ? String(entries[i].name) : '';
        if (!name || /^blob:/i.test(name)) continue;
        if (/\.mp4(?:\?|$)/i.test(name) || /\/video\//i.test(name) || /bytestart=/i.test(name)) {
          result.video_url = name;
          addMediaItem('video', name);
          if (!result.media_type) result.media_type = 'video';
          return true;
        }
      }
    } catch (e) {}
    return false;
  }

  // -- Auto-play any <video> so IG actually starts requesting .mp4 segments.
  // Without this, performance entries never contain a real CDN URL for reels.
  // We mute first (autoplay policies) and only kick playback once per element.
  var playKicked = false;
  function triggerVideoPlayback() {
    if (playKicked) return;
    var videos = document.querySelectorAll('video');
    if (!videos.length) return;
    playKicked = true;
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      try {
        v.muted = true;
        v.playsInline = true;
        v.setAttribute('muted', '');
        v.setAttribute('playsinline', '');
        var p = v.play();
        if (p && typeof p.then === 'function') {
          p.catch(function (e) {
            try { console.warn('[IGScraper] play() rejected:', e && e.message); } catch (_) {}
          });
        }
      } catch (e) {}
    }
  }

  // -- Shortcode -> numeric media_id (IG's base64 -> int10 scheme).
  // Lets us hit IG's own internal media-info API which still returns the
  // signed video_versions[] even when the public HTML omits shortcode_media.
  function shortcodeToMediaId(sc) {
    if (!sc) return null;
    var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    try {
      var id = 0n;
      for (var i = 0; i < sc.length; i++) {
        var idx = alphabet.indexOf(sc.charAt(i));
        if (idx < 0) return null;
        id = id * 64n + BigInt(idx);
      }
      return id.toString();
    } catch (e) { return null; }
  }

  function extractShortcode() {
    var m = (location.pathname || '').match(/\/(?:reel|reels|p|tv)\/([A-Za-z0-9_-]+)/);
    return m ? m[1] : '';
  }

  // -- Same-origin call to IG's mobile-API media-info endpoint. Uses the
  // user's IG cookies + residential IP, so it succeeds even when the public
  // HTML is login-walled. Returns video_versions[0].url for reels.
  var apiTried = false;
  var apiStatus = 0; // surfaced into result for debugging
  var apiSnippet = '';
  async function pickFromInternalApi() {
    if (apiTried) return result.video_url ? true : false;
    var sc = extractShortcode();
    var mid = shortcodeToMediaId(sc);
    if (!mid) { apiTried = true; return false; }
    apiTried = true;
    try {
      var r = await fetch('/api/v1/media/' + mid + '/info/', {
        method: 'GET',
        credentials: 'include',
        headers: {
          'X-IG-App-ID': '936619743392459',
          'Accept': '*/*',
        },
      });
      apiStatus = r.status;
      var rawTxt = await r.text();
      try { apiSnippet = String(rawTxt || '').slice(0, 400); } catch (_) {}
      if (!r.ok) {
        try { console.warn('[IGScraper] internal api status', r.status); } catch (_) {}
        return false;
      }
      var data;
      try { data = JSON.parse(rawTxt); } catch (e) { return false; }
      var item = data && data.items && data.items[0];
      if (!item) return false;
      // video_versions: [{ url, type, width, height }, ...]; prefer highest type.
      var vv = item.video_versions || [];
      if (vv.length && !result.video_url) {
        var best = vv[0];
        for (var i = 1; i < vv.length; i++) {
          if ((vv[i].width || 0) > (best.width || 0)) best = vv[i];
        }
        if (best && best.url) {
          result.video_url = best.url;
          addMediaItem('video', best.url);
          if (!result.media_type) result.media_type = 'video';
          result.caption_source = result.caption ? result.caption_source : 'internal_api';
        }
      }
      // Image fallback for non-video posts in the same call. For carousel
      // shares, always inspect the first carousel item only; InfoSnap uses the
      // first image as the card thumbnail, regardless of img_index in the URL.
      var firstImageItem = item;
      if (item.carousel_media && item.carousel_media.length) {
        firstImageItem = item.carousel_media[0] || item;
      }
      var ic = firstImageItem.image_versions2 && firstImageItem.image_versions2.candidates;
      if (ic && ic.length) {
        for (var ci = 0; ci < ic.length; ci++) {
          addThumbnailCandidate(
            ic[ci].url || '',
            'internal_api_first_image',
            ic[ci].width || null,
            ic[ci].height || null,
            true
          );
        }
        chooseBestThumbnail();
        if (result.thumbnail_url) addMediaItem('image', result.thumbnail_url);
      }
      if (!result.author && item.user && item.user.username) {
        result.author = String(item.user.username).replace(/^@/, '');
      }
      if (!result.caption && item.caption && item.caption.text) {
        result.caption = String(item.caption.text);
        result.caption_source = 'internal_api';
      }
      if (item.media_type === 2 && !result.media_type) result.media_type = 'video';
      if (item.carousel_media && item.carousel_media.length) {
        result.media_type = 'carousel';
        result.carousel_count = item.carousel_media.length;
      }
      return !!result.video_url;
    } catch (e) {
      try { console.warn('[IGScraper] internal api error', e && e.message); } catch (_) {}
      return false;
    }
  }

  // -- Public embed-page fallback. IG serves an unauthenticated, embed-
  // friendly variant of every public post at /<type>/<sc>/embed/captioned/
  // that's designed to be iframed by 3rd-party sites — so it doesn't gate on
  // login cookies and typically inlines the video URL (in shortcode_media
  // and/or as a <video src="..."> tag).
  var embedTried = false;
  var embedStatus = 0;
  var embedSnippet = '';
  async function pickFromEmbedPage() {
    if (embedTried) return !!result.video_url;
    var sc = extractShortcode();
    if (!sc) { embedTried = true; return false; }
    embedTried = true;
    var pathType = /\/(reel|reels)\//i.test(location.pathname || '') ? 'reel'
      : /\/tv\//i.test(location.pathname || '') ? 'tv' : 'p';
    try {
      var r = await fetch('/' + pathType + '/' + sc + '/embed/captioned/', {
        method: 'GET',
        credentials: 'include',
        headers: { 'Accept': 'text/html,*/*' },
      });
      embedStatus = r.status;
      if (!r.ok) return false;
      var html = await r.text();
      try { embedSnippet = String(html || '').slice(0, 400); } catch (_) {}
      var sidecarIdx = html.indexOf('edge_sidecar_to_children');
      if (sidecarIdx >= 0) {
        var sidecar = html.slice(sidecarIdx, sidecarIdx + 12000);
        var firstNodeEnd = sidecar.indexOf('},{\\\"node\\\":');
        var firstNode = firstNodeEnd > 0 ? sidecar.slice(0, firstNodeEnd) : sidecar;
        var resRe = /\\\"config_width\\\":(\d+),\\\"config_height\\\":(\d+),\\\"src\\\":\\\"((?:\\\\.|[^\\\"\\\\])*)\\\"/g;
        var resMatch;
        while ((resMatch = resRe.exec(firstNode)) !== null) {
          addThumbnailCandidate(
            decodeEscapedUrl(resMatch[3]),
            'embed_first_image_display_resource',
            Number(resMatch[1] || 0),
            Number(resMatch[2] || 0),
            true
          );
        }
        chooseBestThumbnail();
        if (result.thumbnail_url) addMediaItem('image', result.thumbnail_url);
      } else {
        var singleRe = /\\\"display_resources\\\":\[((?:.|\n|\r)*?)\]/;
        var singleMatch = html.match(singleRe);
        if (singleMatch && singleMatch[1]) {
          var resRe2 = /\\\"config_width\\\":(\d+),\\\"config_height\\\":(\d+),\\\"src\\\":\\\"((?:\\\\.|[^\\\"\\\\])*)\\\"/g;
          var resMatch2;
          while ((resMatch2 = resRe2.exec(singleMatch[1])) !== null) {
            addThumbnailCandidate(
              decodeEscapedUrl(resMatch2[3]),
              'embed_display_resource',
              Number(resMatch2[1] || 0),
              Number(resMatch2[2] || 0),
              true
            );
          }
          chooseBestThumbnail();
          if (result.thumbnail_url) addMediaItem('image', result.thumbnail_url);
        }
      }
      // Try modern v1 shape first.
      var m =
        html.match(/"video_versions"\s*:\s*\[\s*\{[^}]*?"url"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
        html.match(/"playable_url_quality_hd"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
        html.match(/"playable_url"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
        html.match(/"video_url"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
        html.match(/<video[^>]+src=["']((?:https?:|\/\/)[^"']+)["']/i);
      if (m && m[1] && !result.video_url) {
        var raw = m[1];
        try { result.video_url = JSON.parse('"' + raw + '"'); }
        catch (e) { result.video_url = raw.replace(/\\u0026/g, '&'); }
        addMediaItem('video', result.video_url);
        if (!result.media_type) result.media_type = 'video';
        result.caption_source = result.caption ? result.caption_source : 'embed_page';
      }
      return !!result.video_url;
    } catch (e) {
      try { console.warn('[IGScraper] embed fetch error', e && e.message); } catch (_) {}
      return false;
    }
  }

  // Poll for up to ~12s. Try richest source first each iteration; bail as
  // soon as we have enough content. Reels often expose caption/poster before
  // the video element gets a real CDN URL, so keep polling a few extra seconds
  // for video_url instead of returning immediately on caption.
  var maxIters = 24;
  for (var iter = 0; iter < maxIters; iter++) {
    var got = pickShortcodeMediaFromScripts();
    if (!got) got = pickFromLdJson();
    if (!got) got = pickFromOgTags();
    pickFromDomVideo();
    pickFromPerformanceVideo();
    // Always sweep og tags last to fill thumbnail/author gaps.
    pickFromOgTags();
    // Also try IG's same-origin media-info API for posts/carousels. This is
    // still no-Apify and runs from the user's WebView/cookies; it exposes
    // image_versions2.candidates so we can avoid square crop thumbnails.
    if (!apiTried) await pickFromInternalApi();
    // Normal IG posts often expose only a cropped square og:image in the live
    // page, while the public embed page includes display_resources for the
    // first image with its real aspect ratio. Try it for posts too, not just
    // reels/videos, before deciding the thumbnail is good enough.
    if (!embedTried) await pickFromEmbedPage();
    var urlLooksVideo = /\/(?:reel|reels|tv)\//i.test(location.pathname || '');
    var shouldWaitForVideo = urlLooksVideo || result.media_type === 'video';
    // If we still need a video URL, try IG's internal API (one shot) and
    // kick off muted playback so the .mp4 segments start loading for the
    // performance-entry fallback.
    if (shouldWaitForVideo && !result.video_url) {
      if (!apiTried) await pickFromInternalApi();
      if (!result.video_url && !embedTried) await pickFromEmbedPage();
      triggerVideoPlayback();
    }
    if (result.caption && (!shouldWaitForVideo || result.video_url || iter >= 10)) break;
    await sleep(500);
  }

  // Surface diagnostics so the dart side can debugPrint them to logcat.
  result.diag_api_status = apiStatus;
  result.diag_embed_status = embedStatus;
  result.diag_play_kicked = playKicked;
  result.diag_video_tag_count = (document.querySelectorAll('video') || []).length;
  result.diag_api_snippet = apiSnippet;
  result.diag_embed_snippet = embedSnippet;
  chooseBestThumbnail();

  send(result);
})();
''';
