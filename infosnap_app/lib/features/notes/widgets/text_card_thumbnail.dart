/// Side-stripe text-card thumbnail used when a note has no image thumbnail.
///
/// Renders a 200×200 SVG card with:
///   - Left coloured stripe + rotated file-extension label
///   - File-type icon
///   - Auto-fit title (largest font that fits without truncation)
///   - Auto-fit description below the title (if present)
///
/// Design ported verbatim from `temp/thumbnail-style4-refined.html`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../core/utils/responsive.dart';

class TextCardThumbnail extends StatelessWidget {
  final String title;
  final String? description;
  final String? originalFilename;
  final String? contentType;
  final BorderRadius? borderRadius;

  const TextCardThumbnail({
    super.key,
    required this.title,
    this.description,
    this.originalFilename,
    this.contentType,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final ext = _extOf(originalFilename, contentType);
    // Use the card's actual aspect ratio so the stripe stays a consistent
    // percentage of the visible width on tall, square, and wide cards alike.
    // Without this, BoxFit.cover crops the 200x200 SVG and the stripe (plus
    // the rotated ext label) gets clipped to a thin sliver on tall 4:5 cards.
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fall back to square when constraints are unbounded.
        final w = constraints.hasBoundedWidth ? constraints.maxWidth : 200.0;
        final h = constraints.hasBoundedHeight ? constraints.maxHeight : 200.0;
        final vbW = w <= 0 ? 200 : w.round().clamp(60, 800);
        final vbH = h <= 0 ? 200 : h.round().clamp(60, 800);
        final svg = _renderTileSvg(
          title: title.trim().isEmpty ? 'Untitled' : title.trim(),
          description: description ?? '',
          ext: ext,
          width: vbW,
          height: vbH,
        );
        final svgPicture = SvgPicture.string(
          svg,
          fit: BoxFit.fill,
          alignment: Alignment.center,
        );
        if (borderRadius != null) {
          return ClipRRect(borderRadius: borderRadius!, child: svgPicture);
        }
        return svgPicture;
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Extension detection (mirrors ext_of in fetch_thumbnail_samples_v2.py)
// ──────────────────────────────────────────────────────────────────────────

String _extOf(String? originalFilename, String? contentType) {
  final ct = (contentType ?? '').toLowerCase();
  if (ct == 'quick_note') return 'NOTE';
  if (ct == 'webpage' || ct == 'article' || ct == 'html') return 'WEB';
  if (ct == 'youtube') return 'YOUTUBE';

  final name = (originalFilename ?? '').toLowerCase();
  if (name.isEmpty) {
    if (ct == 'pdf') return 'PDF';
    return 'FILE';
  }
  if (name.endsWith('.pdf')) return 'PDF';
  if (name.endsWith('.docx') || name.endsWith('.doc')) return 'DOCX';
  if (name.endsWith('.csv')) return 'CSV';
  if (name.endsWith('.xlsx') || name.endsWith('.xls')) return 'XLSX';
  if (name.endsWith('.pptx') || name.endsWith('.ppt')) return 'PPTX';
  if (name.endsWith('.txt')) return 'TXT';
  if (name.endsWith('.md') || name.endsWith('.markdown')) return 'MD';
  if (name.endsWith('.html') || name.endsWith('.htm')) return 'WEB';
  return 'FILE';
}

// ──────────────────────────────────────────────────────────────────────────
// Colour map
// ──────────────────────────────────────────────────────────────────────────

const Map<String, String> _kColors = {
  'PDF': '#dc2626',
  'DOCX': '#2563eb',
  'XLSX': '#16a34a',
  'CSV': '#15803d',
  'PPTX': '#ea580c',
  'TXT': '#64748b',
  'MD': '#0ea5e9',
  'WEB': '#7c3aed',
  // YouTube: darker red than the PDF stripe (#dc2626) so the two are
  // visually distinct. Acts as the base/bottom of the stripe gradient.
  'YOUTUBE': '#a30000',
  'NOTE': '#f59e0b',
  'FILE': '#475569',
};

// ──────────────────────────────────────────────────────────────────────────
// Text fitting helpers
// ──────────────────────────────────────────────────────────────────────────

class _Fit {
  final List<String> lines;
  final int fontSize;
  final int lineHeight;
  const _Fit(this.lines, this.fontSize, this.lineHeight);
}

List<String> _wrapText(String text, int maxChars) {
  final t = text.trim();
  if (t.isEmpty) return const [];
  final words = t.split(RegExp(r'\s+'));
  final lines = <String>[];
  String cur = '';
  for (final w in words) {
    if (w.length > maxChars) {
      if (cur.isNotEmpty) {
        lines.add(cur);
        cur = '';
      }
      var rest = w;
      while (rest.length > maxChars) {
        lines.add('${rest.substring(0, maxChars - 1)}-');
        rest = rest.substring(maxChars - 1);
      }
      cur = rest;
      continue;
    }
    final candidate = cur.isEmpty ? w : '$cur $w';
    if (candidate.length <= maxChars) {
      cur = candidate;
    } else {
      lines.add(cur);
      cur = w;
    }
  }
  if (cur.isNotEmpty) lines.add(cur);
  return lines;
}

_Fit? _fitText(String text, double maxWidth, double maxHeight,
    List<int> fontSizes, double charWidthRatio) {
  final t = text.trim();
  if (t.isEmpty) return null;
  for (final fs in fontSizes) {
    final charPx = fs * charWidthRatio;
    final maxChars = (maxWidth / charPx).floor().clamp(4, 999);
    final lineHeight = (fs * 1.22).round();
    final lines = _wrapText(t, maxChars);
    final totalH = lines.length * lineHeight;
    if (totalH <= maxHeight) {
      return _Fit(lines, fs, lineHeight);
    }
  }
  // Fall back to smallest size even if it slightly overflows.
  final fs = fontSizes.last;
  final charPx = fs * charWidthRatio;
  final maxChars = (maxWidth / charPx).floor().clamp(4, 999);
  final lineHeight = (fs * 1.22).round();
  return _Fit(_wrapText(t, maxChars), fs, lineHeight);
}

String _escapeXml(String s) {
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

String _tspans(List<String> lines, int x, int startY, int lineHeight) {
  final buf = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final y = startY + i * lineHeight;
    buf.write('<tspan x="$x" y="$y">${_escapeXml(lines[i])}</tspan>');
  }
  return buf.toString();
}

// ──────────────────────────────────────────────────────────────────────────
// Per-type 24×24 icons
// ──────────────────────────────────────────────────────────────────────────

String _iconPath(String ext) {
  final color = _kColors[ext] ?? _kColors['FILE']!;
  switch (ext) {
    case 'PDF':
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <path d="M3 2 L15 2 L19 6 L19 21 L3 21 Z" fill="#fee2e2"/>
          <path d="M15 2 L15 6 L19 6"/>
        </g>
        <text x="11" y="17" fill="$color" font-family="Segoe UI,system-ui,Arial" font-weight="900" font-size="6.5" text-anchor="middle" letter-spacing="0.3">PDF</text>''';
    case 'DOCX':
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <path d="M3 2 L15 2 L19 6 L19 21 L3 21 Z" fill="#dbeafe"/>
          <path d="M15 2 L15 6 L19 6"/>
          <line x1="6" y1="11" x2="16" y2="11" stroke-width="1.4"/>
          <line x1="6" y1="14" x2="16" y2="14" stroke-width="1.4"/>
          <line x1="6" y1="17" x2="12" y2="17" stroke-width="1.4"/>
        </g>''';
    case 'XLSX':
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <path d="M3 2 L15 2 L19 6 L19 21 L3 21 Z" fill="#dcfce7"/>
          <path d="M15 2 L15 6 L19 6"/>
          <line x1="3" y1="11" x2="19" y2="11" stroke-width="1.2"/>
          <line x1="3" y1="15" x2="19" y2="15" stroke-width="1.2"/>
          <line x1="3" y1="19" x2="19" y2="19" stroke-width="1.2"/>
          <line x1="8" y1="9" x2="8" y2="21" stroke-width="1.2"/>
          <line x1="13" y1="9" x2="13" y2="21" stroke-width="1.2"/>
        </g>''';
    case 'PPTX':
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <rect x="2" y="3" width="20" height="14" rx="1.5" fill="#ffedd5"/>
          <line x1="5" y1="8" x2="14" y2="8"/>
          <line x1="5" y1="11" x2="12" y2="11"/>
          <line x1="5" y1="14" x2="10" y2="14"/>
          <line x1="12" y1="17" x2="12" y2="21"/>
          <line x1="8" y1="21" x2="16" y2="21"/>
        </g>''';
    case 'TXT':
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <path d="M3 2 L15 2 L19 6 L19 21 L3 21 Z" fill="#f1f5f9"/>
          <path d="M15 2 L15 6 L19 6"/>
          <line x1="6" y1="10" x2="16" y2="10" stroke-width="1.2"/>
          <line x1="6" y1="13" x2="16" y2="13" stroke-width="1.2"/>
          <line x1="6" y1="16" x2="16" y2="16" stroke-width="1.2"/>
          <line x1="6" y1="19" x2="13" y2="19" stroke-width="1.2"/>
        </g>''';
    case 'MD':
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <rect x="2" y="4" width="20" height="16" rx="1.5" fill="#e0f2fe"/>
          <path d="M5 16 L5 9 L8 12 L11 9 L11 16" stroke-width="1.6"/>
          <path d="M15 9 L15 16 M13 14 L15 16 L17 14" stroke-width="1.6"/>
        </g>''';
    case 'WEB':
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <circle cx="12" cy="12" r="9" fill="#ede9fe"/>
          <ellipse cx="12" cy="12" rx="9" ry="4"/>
          <line x1="12" y1="3" x2="12" y2="21"/>
          <line x1="3" y1="12" x2="21" y2="12"/>
        </g>''';
    case 'YOUTUBE':
      // Official YouTube play-button mark: red rounded rectangle with white
      // triangle. Drawn full-bleed at 24×24 so it reads at small sizes.
      return '''
        <rect x="1" y="5" width="22" height="14" rx="3.5" ry="3.5" fill="#FF0000"/>
        <polygon points="10,9 10,15 15.5,12" fill="#ffffff"/>''';
    case 'NOTE':
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <path d="M4 3 L20 3 L20 19 L14 21 L4 21 Z" fill="#fef3c7"/>
          <line x1="7" y1="8" x2="17" y2="8" stroke-width="1.4"/>
          <line x1="7" y1="11" x2="17" y2="11" stroke-width="1.4"/>
          <line x1="7" y1="14" x2="13" y2="14" stroke-width="1.4"/>
          <path d="M14 21 L14 17 L20 17" stroke-width="1.4"/>
        </g>''';
    default:
      return '''
        <g stroke="$color" stroke-width="1.6" fill="none" stroke-linejoin="round">
          <path d="M3 2 L15 2 L19 6 L19 21 L3 21 Z" fill="#e2e8f0"/>
          <path d="M15 2 L15 6 L19 6"/>
        </g>''';
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Tile renderer
// ──────────────────────────────────────────────────────────────────────────

bool _isJunkDescription(String d) {
  return RegExp(r'^(n\/?a|none|null|tbd|\-)+$', caseSensitive: false)
      .hasMatch(d);
}

String _renderTileSvg({
  required String title,
  required String description,
  required String ext,
  int width = 200,
  int height = 200,
}) {
  final stripeColor = _kColors[ext] ?? _kColors['FILE']!;
  final iconColor = stripeColor;

  // Stripe stays at 18% of card width regardless of aspect ratio so it looks
  // visually identical on tall, square, and wide cards. Text body, icon, and
  // padding scale relative to width/height too.
  final stripeW = (width * 0.18).round(); // ~36 on a 200-wide card
  final iconBoxSize = (width * 0.16).round(); // ~32 on a 200-wide card
  final iconBoxX = stripeW + (width * 0.05).round();
  final iconBoxY = (height * 0.09).round();
  final iconBoxRadius = (iconBoxSize * 0.30).round();
  final iconScale = iconBoxSize / 24.0; // SVG icons are authored at 24x24
  final iconInsetX = iconBoxX + ((iconBoxSize - 24 * iconScale) / 2).round();
  final iconInsetY = iconBoxY + ((iconBoxSize - 24 * iconScale) / 2).round();

  // Text body lives to the right of the stripe + icon block, with a bit of
  // breathing room on all four sides.
  final textX = stripeW + (width * 0.05).round();
  final textWidth = width - textX - (width * 0.04).round();
  final bodyTop = iconBoxY + iconBoxSize + (height * 0.06).round();
  final bodyBottom = height - (height * 0.06).round();
  final totalH = bodyBottom - bodyTop;

  final descTrim = description.trim();
  final cleanDesc =
      (descTrim.isEmpty || _isJunkDescription(descTrim)) ? '' : descTrim;
  final isUploadedDoc = const {
    'PDF',
    'DOCX',
    'XLSX',
    'CSV',
    'PPTX',
    'TXT',
    'MD',
    'FILE'
  }.contains(ext);

  // Font-size pools — keep these similar to the original SVG so existing
  // cards don't look wildly different.
  final titleSizes = isUploadedDoc
      ? const [18, 17, 16, 15, 14, 13, 12]
      : const [14, 13, 12, 11, 10];
  final descSizes =
      isUploadedDoc ? const [12, 11, 10, 9] : const [11, 10, 9, 8];
  final gap = isUploadedDoc ? 8 : 10;

  _Fit? titleFit;
  _Fit? descFit;

  if (cleanDesc.isNotEmpty) {
    final splits = isUploadedDoc
        ? const [0.74, 0.68, 0.62, 0.56, 0.50, 0.44]
        : const [0.65, 0.55, 0.45, 0.4, 0.35, 0.3];
    _Fit? bestT;
    _Fit? bestD;
    int bestScore = -1;
    for (final split in splits) {
      final titleH = ((totalH - gap) * split).floor();
      final descH = totalH - gap - titleH;
      final tf = _fitText(
          title, textWidth.toDouble(), titleH.toDouble(), titleSizes, 0.58);
      final df = _fitText(
          cleanDesc, textWidth.toDouble(), descH.toDouble(), descSizes, 0.55);
      if (tf == null || df == null) continue;
      final score = tf.fontSize * 100 + df.fontSize;
      if (score > bestScore) {
        bestScore = score;
        bestT = tf;
        bestD = df;
      }
    }
    if (bestT != null) {
      titleFit = bestT;
      descFit = bestD;
    } else {
      titleFit = _fitText(
          title, textWidth.toDouble(), totalH.toDouble(), titleSizes, 0.58);
    }
  } else {
    titleFit = _fitText(
        title, textWidth.toDouble(), totalH.toDouble(), titleSizes, 0.58);
  }

  titleFit ??= const _Fit(['Untitled'], 15, 18);

  final titleLinesH = titleFit.lines.length * titleFit.lineHeight;
  final titleStartY = bodyTop + titleFit.fontSize;

  String descBlock = '';
  if (descFit != null) {
    final descStartY = bodyTop + titleLinesH + gap + descFit.fontSize;
    descBlock = '''
  <text fill="#64748b" font-family="Segoe UI,system-ui,Arial" font-weight="400" font-size="${descFit.fontSize}">
    ${_tspans(descFit.lines, textX, descStartY, descFit.lineHeight)}
  </text>''';
  }

  final titleSpans =
      _tspans(titleFit.lines, textX, titleStartY, titleFit.lineHeight);
  final icon = _iconPath(ext);
  final extLabel = _escapeXml(ext);

  // Rotated ext-label sits in the centre of the stripe.
  final stripeLabelX = (stripeW / 2).round();
  final stripeLabelY = (height / 2).round();
  // Letter-spacing for the rotated label is tuned by stripe height (i.e.
  // card height). Smaller cards get less spacing so the label still fits.
  final stripeLabelFont = (height * 0.085).clamp(10, 22).round();

  return '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $height" width="$width" height="$height">
  <defs>
    <linearGradient id="thumbBg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="100%" stop-color="${_lightenHex(iconColor, 0.90)}"/>
    </linearGradient>
    <linearGradient id="stripeGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="${_lightenHex(stripeColor, 0.20)}"/>
      <stop offset="100%" stop-color="$stripeColor"/>
    </linearGradient>
  </defs>
  <rect width="$width" height="$height" fill="url(#thumbBg)"/>
  <rect x="0" y="0" width="$stripeW" height="$height" fill="url(#stripeGrad)"/>
  <text transform="translate($stripeLabelX $stripeLabelY) rotate(-90)" text-anchor="middle"
        fill="#ffffff" font-family="Segoe UI,system-ui,Arial" font-weight="900" font-size="$stripeLabelFont" letter-spacing="2.0">$extLabel</text>
  <rect x="$iconBoxX" y="$iconBoxY" width="$iconBoxSize" height="$iconBoxSize" rx="$iconBoxRadius" fill="#ffffff" fill-opacity="0.82"/>
  <g transform="translate($iconInsetX $iconInsetY) scale(${iconScale.toStringAsFixed(3)})">
    $icon
  </g>
  <text fill="#0f172a" font-family="Segoe UI,system-ui,Arial" font-weight="700" font-size="${titleFit.fontSize}">
    $titleSpans
  </text>
  $descBlock
</svg>''';
}

String _lightenHex(String hex, double amount) {
  final value = hex.replaceAll('#', '');
  if (value.length != 6) return '#f8fafc';
  final r = int.parse(value.substring(0, 2), radix: 16);
  final g = int.parse(value.substring(2, 4), radix: 16);
  final b = int.parse(value.substring(4, 6), radix: 16);

  int blend(int c) => (c + ((255 - c) * amount)).round().clamp(0, 255);
  final rr = blend(r).toRadixString(16).padLeft(2, '0');
  final gg = blend(g).toRadixString(16).padLeft(2, '0');
  final bb = blend(b).toRadixString(16).padLeft(2, '0');
  return '#$rr$gg$bb';
}
