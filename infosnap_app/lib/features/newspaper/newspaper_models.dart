/// Data model for an edition of "The infoSnap Times".
///
/// The expected production flow:
///   1. Server-side job runs each morning, reads yesterday's notes for a user.
///   2. Calls an LLM with [kNewspaperGenerationPrompt] + a JSON-mode schema
///      mirroring the structures below.
///   3. Persists the resulting JSON to `daily_newspapers (user_id, date, payload)`.
///   4. Flutter fetches and decodes via `NewspaperEdition.fromJson`.
///
/// The client never invokes the LLM directly.

/// ─────────────────────────────────────────────────────────────────────────────
/// The prompt used to generate the v5.html mockup. Move this to the server-side
/// generation worker. Keep it here as the source of truth for layout schema.
/// ─────────────────────────────────────────────────────────────────────────────
const String kNewspaperGenerationPrompt = r'''
You are the editor-in-chief of "The infoSnap Times" — a personal daily
newspaper of everything the user saved yesterday.

INPUT: a JSON array of yesterday's notes. Each note has:
  title, description, content_markdown, file_type
  (instagram | youtube | webpage | uploaded_file | quick_note | image),
  metadata.social.{author, caption, source_url, thumbnail_url, post_type},
  metadata.highlights[], created_at.

OUTPUT: a single `NewspaperEdition` JSON object matching the schema in
newspaper_models.dart. Constraints:

1. Render the actual caption / content_markdown text as article body copy.
   Do NOT summarise into bullet points. Long-form prose, ~3 paragraphs per
   article, written in dry-witty newspaper voice.
2. Detect duplicate saves (same source_url or same title × same author saved
   2+ times). Collapse them into ONE article and add a `repeatStamp` listing
   every timestamp. Mention the re-save count in the editor's note.
3. Choose the lead story for actionability + timeliness (deadlines, alerts,
   travel warnings beat general interest beat entertainment). Avoid choosing
   an entertainment clip as the lead unless nothing else qualifies.
4. Group articles into desks: Travel Desk, Tech Desk, Careers Desk,
   Lifestyle & Local, Arts & Entertainment, Health, Money — only the desks
   actually needed for the day's content. Each section gets a one-line
   meta tag (e.g. "2 saves · both Vietnam · saved 90 min apart").
5. When two saves on the same topic appear, insert a `contradiction` block
   that points to the connection.
6. Pull at least one quote per significant article into a `pullQuote` block.
7. End with a colophon: one-paragraph "day in summary", by-the-numbers stats,
   authors cited with save counts.
8. Tone: New York Times Sunday + The Browser. Wry, observant, occasionally
   amused at the user's own re-saving behaviour. Never flatters.
9. Never fabricate facts not present in the source notes. If a transcript is
   missing, say so candidly.
''';

/// ─────────────────────────────────────────────────────────────────────────────

class NewspaperEdition {
  final DateTime editionDate;
  final String editionDateLabel; // "Saturday, May 15, 2026"
  final int issueNumber;
  final int totalSaves;
  final String editorsNote;
  final LeadStory lead;
  final List<NewspaperSection> sections;
  final String dayInOneParagraph;
  final List<Stat> stats;
  final List<AuthorCount> authorsCited;

  const NewspaperEdition({
    required this.editionDate,
    required this.editionDateLabel,
    required this.issueNumber,
    required this.totalSaves,
    required this.editorsNote,
    required this.lead,
    required this.sections,
    required this.dayInOneParagraph,
    required this.stats,
    required this.authorsCited,
  });
}

class LeadStory {
  final String kicker;
  final String headline;
  final String deck;
  final String byline;
  final List<String> paragraphs;
  final SidebarCard? sidebar;
  final String? heroImage;
  final String? imageCaption;

  /// Optional id of the underlying saved note. When set, the article shows a
  /// "View the snap" link that pushes the note detail screen (where the user
  /// can then tap "View original").
  final String? noteId;

  /// Optional direct source URL. Used as a fallback for the "View the snap"
  /// link when [noteId] is not available (e.g. baked sample editions).
  final String? sourceUrl;

  const LeadStory({
    required this.kicker,
    required this.headline,
    required this.deck,
    required this.byline,
    required this.paragraphs,
    this.sidebar,
    this.heroImage,
    this.imageCaption,
    this.noteId,
    this.sourceUrl,
  });
}

class SidebarCard {
  final String title;
  final List<String> items;
  const SidebarCard({required this.title, required this.items});
}

class NewspaperSection {
  final String title;
  final String meta;
  final List<Article> articles;
  const NewspaperSection({
    required this.title,
    required this.meta,
    required this.articles,
  });
}

class Article {
  final String headline;
  final String? deck;
  final String byline;
  final bool featured;
  final RepeatStamp? repeatStamp;
  final List<ArticleBlock> blocks;
  final String? heroImage;
  final String? imageCaption;

  /// Optional id of the underlying saved note. When set, the article shows a
  /// "View the snap" link that pushes the note detail screen.
  final String? noteId;

  /// Optional direct source URL. Fallback for the "View the snap" link.
  final String? sourceUrl;

  const Article({
    required this.headline,
    this.deck,
    required this.byline,
    this.featured = false,
    this.repeatStamp,
    required this.blocks,
    this.heroImage,
    this.imageCaption,
    this.noteId,
    this.sourceUrl,
  });
}

class RepeatStamp {
  final int count;
  final String note;
  final List<RepeatTime> timestamps;
  const RepeatStamp({
    required this.count,
    required this.note,
    required this.timestamps,
  });
}

class RepeatTime {
  final String time; // "09:34"
  final String label; // "Jeff Su · 99% of Beginners (youtu.be)"
  const RepeatTime(this.time, this.label);
}

enum BlockType { paragraph, pullQuote, contradiction, numberedList, portalList }

class ArticleBlock {
  final BlockType type;
  final String? text;
  final String? cite;
  final List<String>? items;
  final List<Portal>? portals;

  const ArticleBlock.paragraph(String text)
      : type = BlockType.paragraph,
        text = text,
        cite = null,
        items = null,
        portals = null;

  const ArticleBlock.pullQuote(String text, {String? cite})
      : type = BlockType.pullQuote,
        text = text,
        cite = cite,
        items = null,
        portals = null;

  const ArticleBlock.contradiction(String text, {String? cite})
      : type = BlockType.contradiction,
        text = text,
        cite = cite,
        items = null,
        portals = null;

  const ArticleBlock.numberedList(List<String> items)
      : type = BlockType.numberedList,
        text = null,
        cite = null,
        items = items,
        portals = null;

  const ArticleBlock.portalList(List<Portal> portals)
      : type = BlockType.portalList,
        text = null,
        cite = null,
        items = null,
        portals = portals;
}

class Portal {
  final String name;
  final String note;
  final String tag; // "DE", "NL · BE"
  const Portal(this.name, this.note, this.tag);
}

class Stat {
  final String label;
  final String value;
  const Stat(this.label, this.value);
}

class AuthorCount {
  final String label;
  final int count;
  const AuthorCount(this.label, this.count);
}

/// ─────────────────────────────────────────────────────────────────────────────
/// JSON parsing helpers — used to decode `/api/v1/newspaper` responses from
/// the Cloudflare Worker into the model classes above.
/// ─────────────────────────────────────────────────────────────────────────────

String? _asString(dynamic v) {
  if (v == null) return null;
  if (v is String) return v.isEmpty ? null : v;
  return v.toString();
}

String _asReqString(dynamic v, [String fallback = '']) =>
    _asString(v) ?? fallback;

int _asInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

List<String> _asStringList(dynamic v) {
  if (v is List) {
    return v
        .map((e) => e == null ? '' : e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  return const [];
}

extension NewspaperEditionJson on NewspaperEdition {
  static NewspaperEdition fromJson(Map<String, dynamic> json) {
    final dateStr = _asString(json['editionDate']);
    DateTime parsedDate;
    try {
      parsedDate = dateStr != null ? DateTime.parse(dateStr) : DateTime.now();
    } catch (_) {
      parsedDate = DateTime.now();
    }

    final sectionsRaw = json['sections'];
    final sections = (sectionsRaw is List)
        ? sectionsRaw
            .whereType<Map>()
            .map((m) =>
                NewspaperSectionJson.fromJson(Map<String, dynamic>.from(m)))
            .toList()
        : <NewspaperSection>[];

    final statsRaw = json['stats'];
    final stats = (statsRaw is List)
        ? statsRaw
            .whereType<Map>()
            .map((m) => Stat(
                  _asReqString(m['label']),
                  _asReqString(m['value']),
                ))
            .toList()
        : <Stat>[];

    final authorsRaw = json['authorsCited'];
    final authors = (authorsRaw is List)
        ? authorsRaw
            .whereType<Map>()
            .map((m) => AuthorCount(
                  _asReqString(m['label']),
                  _asInt(m['count']),
                ))
            .toList()
        : <AuthorCount>[];

    final leadRaw = json['lead'];
    final lead = (leadRaw is Map)
        ? LeadStoryJson.fromJson(Map<String, dynamic>.from(leadRaw))
        : const LeadStory(
            kicker: '',
            headline: 'Untitled edition',
            deck: '',
            byline: '',
            paragraphs: [],
          );

    return NewspaperEdition(
      editionDate: parsedDate,
      editionDateLabel: _asReqString(json['editionDateLabel']),
      issueNumber: _asInt(json['issueNumber'], 1),
      totalSaves: _asInt(json['totalSaves']),
      editorsNote: _asReqString(json['editorsNote']),
      lead: lead,
      sections: sections,
      dayInOneParagraph: _asReqString(json['dayInOneParagraph']),
      stats: stats,
      authorsCited: authors,
    );
  }
}

extension LeadStoryJson on LeadStory {
  static LeadStory fromJson(Map<String, dynamic> json) {
    final sidebarRaw = json['sidebar'];
    SidebarCard? sidebar;
    if (sidebarRaw is Map) {
      final items = _asStringList(sidebarRaw['items']);
      final title = _asString(sidebarRaw['title']);
      if (items.isNotEmpty || title != null) {
        sidebar = SidebarCard(title: title ?? '', items: items);
      }
    }
    return LeadStory(
      kicker: _asReqString(json['kicker']),
      headline: _asReqString(json['headline']),
      deck: _asReqString(json['deck']),
      byline: _asReqString(json['byline']),
      paragraphs: _asStringList(json['paragraphs']),
      sidebar: sidebar,
      heroImage: _asString(json['heroImage']),
      imageCaption: _asString(json['imageCaption']),
      noteId: _asString(json['noteId']),
      sourceUrl: _asString(json['sourceUrl']),
    );
  }
}

extension NewspaperSectionJson on NewspaperSection {
  static NewspaperSection fromJson(Map<String, dynamic> json) {
    final articlesRaw = json['articles'];
    final articles = (articlesRaw is List)
        ? articlesRaw
            .whereType<Map>()
            .map((m) => ArticleJson.fromJson(Map<String, dynamic>.from(m)))
            .toList()
        : <Article>[];
    return NewspaperSection(
      title: _asReqString(json['title']),
      meta: _asReqString(json['meta']),
      articles: articles,
    );
  }
}

extension ArticleJson on Article {
  static Article fromJson(Map<String, dynamic> json) {
    final blocksRaw = json['blocks'];
    final blocks = (blocksRaw is List)
        ? blocksRaw
            .whereType<Map>()
            .map((m) => ArticleBlockJson.fromJson(Map<String, dynamic>.from(m)))
            .whereType<ArticleBlock>()
            .toList()
        : <ArticleBlock>[];

    final repeatRaw = json['repeatStamp'];
    RepeatStamp? repeat;
    if (repeatRaw is Map) {
      final tsRaw = repeatRaw['timestamps'];
      final ts = (tsRaw is List)
          ? tsRaw
              .whereType<Map>()
              .map((m) => RepeatTime(
                    _asReqString(m['time']),
                    _asReqString(m['label']),
                  ))
              .toList()
          : <RepeatTime>[];
      repeat = RepeatStamp(
        count: _asInt(repeatRaw['count']),
        note: _asReqString(repeatRaw['note']),
        timestamps: ts,
      );
    }

    return Article(
      headline: _asReqString(json['headline']),
      deck: _asString(json['deck']),
      byline: _asReqString(json['byline']),
      featured: json['featured'] == true,
      repeatStamp: repeat,
      blocks: blocks,
      heroImage: _asString(json['heroImage']),
      imageCaption: _asString(json['imageCaption']),
      noteId: _asString(json['noteId']),
      sourceUrl: _asString(json['sourceUrl']),
    );
  }
}

extension ArticleBlockJson on ArticleBlock {
  static ArticleBlock? fromJson(Map<String, dynamic> json) {
    final type = _asString(json['type']);
    switch (type) {
      case 'paragraph':
        return ArticleBlock.paragraph(_asReqString(json['text']));
      case 'pullQuote':
        return ArticleBlock.pullQuote(
          _asReqString(json['text']),
          cite: _asString(json['cite']),
        );
      case 'contradiction':
        return ArticleBlock.contradiction(
          _asReqString(json['text']),
          cite: _asString(json['cite']),
        );
      case 'numberedList':
        return ArticleBlock.numberedList(_asStringList(json['items']));
      default:
        // Unknown / unsupported block type — skip gracefully.
        return null;
    }
  }
}
