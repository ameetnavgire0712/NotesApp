// agent/understand.ts
// ===========================================================================
// !!! DEPRECATED — superseded by ../agent_v2/loop.ts on 2025-01 !!!
//
// This is the legacy regex-only intent classifier that fed the 5-lane
// dispatcher in handler.ts. The Groq function-calling planner in
// agent_v2/loop.ts replaces all of this — the planner picks a tool from
// the 6-tool catalogue based on the user query + recent conversation
// history, with no regex involved.
//
// Kept commented out (still imported by ./handler.ts which is itself
// deprecated) for reference + rollback. Safe to delete after agent_v2
// has been in production with no regressions for ~1 week.
//
// Phase 1: deterministic (regex-only) structured-query extractor for
// counting/aggregation queries. No LLM call — keeps Phase 1 cheap and
// dependency-free. Later phases can replace this with an 8B JSON extractor.
// ===========================================================================

import type { StructuredQuery, TimeWindow } from './types';

// Verbs/nouns that signal a counting/aggregation question.
const COUNT_RE =
  /\b(how\s+many|how\s+much|count(?:\s+of)?|number\s+of|total\s+(?:number|count))\b/i;

const GROUP_RE =
  /\b(which|what)\b[^?]*\b(most|fewest|top|popular|common)\b|\bbreakdown\b|\bdistribution\b|\bsplit\s+by\b|\bgroup(?:ed)?\s+by\b|\bby\s+(?:tag|platform|source|file\s*type|category|day|week|month)\b/i;

// Compare verbs/phrases.
const COMPARE_RE =
  /\b(compare|contrast|differ|differs|differ\s+from|differences?|vs\.?|versus|how\s+does\s+.+\s+compare|what\s+changed\s+between|change[ds]?\s+(?:from|over|between)|evolved?\s+(?:from|over)|then\s+(?:vs|and)\s+now|between\s+.+\s+and\s+.+\s+(?:in|about|for|on))\b/i;

// Summarize verbs/phrases (Phase 5).
const SUMMARIZE_RE =
  /\b(summari[sz]e|summary|recap|overview|tl;?dr|sum\s+up|sums?\s+up|tell\s+me\s+everything|what.?s\s+all|give\s+me\s+a\s+(?:rundown|recap|summary|overview)|run\s*down)\b/i;

// List/find verbs (Phase 5.5). Must be combined with a structured filter
// (time window, platform/file_type, tag) to claim the query — otherwise
// "find pan card" still goes to vector search.
const LIST_RE =
  /\b(find|show|list|give\s+me|pull\s+up|fetch|display|what)\s+(?:all\s+|me\s+|me\s+all\s+|all\s+of\s+)?(?:my\s+|the\s+)?/i;

// Notes-domain words. Required so we don't grab "how many planets are there".
const DOMAIN_RE =
  /\b(notes?|articles?|docs?|documents?|files?|pdfs?|videos?|images?|screenshots?|webpages?|tweets?|posts?|saved|saves?|save|tags?|platforms?|categor(?:y|ies)|sources?|uploads?|recaps?|highlights?|ig|insta(?:gram)?|youtube|yt|twitter|linkedin|reddit|facebook|fb)\b/i;

// Time-window keywords (deterministic only; LLM time extraction comes later).
const TIME_PATTERNS: Array<[RegExp, TimeWindow]> = [
  [/\btoday\b/i, 'today'],
  [/\byesterday\b/i, 'yesterday'],
  [/\bthis\s+week\b/i, 'this_week'],
  [/\blast\s+week\b/i, 'last_week'],
  [/\bthis\s+month\b/i, 'this_month'],
  [/\blast\s+month\b/i, 'last_month'],
  [/\bpast\s+(?:7|seven)\s*days?\b|\blast\s+(?:7|seven)\s*days?\b/i, 'last_7d'],
  [/\bpast\s+(?:30|thirty)\s*days?\b|\blast\s+(?:30|thirty)\s*days?\b/i, 'last_30d'],
  [/\bpast\s+(?:90|ninety)\s*days?\b|\blast\s+(?:90|ninety)\s*days?\b|\bpast\s+3\s*months?\b|\blast\s+3\s*months?\b/i, 'last_90d'],
  [/\bpast\s+(?:6|six)\s*months?\b|\blast\s+(?:6|six)\s*months?\b|\bpast\s+(?:180|hundred\s+eighty)\s*days?\b|\blast\s+(?:180|hundred\s+eighty)\s*days?\b|\bhalf\s+(?:a\s+)?year\b/i, 'last_180d'],
];

// Keyword → group_by field
const GROUP_FIELD_PATTERNS: Array<[RegExp, NonNullable<StructuredQuery['group_by']>]> = [
  [/\bfile\s*type\b|\bkind\s+of\s+file\b/i, 'file_type'],
  [/\btags?\b/i, 'tag'],
  [/\bplatforms?\b|\bsources?\b|\bapps?\b|\bservices?\b|\bwhere.*from\b|\bfrom\s+where\b/i, 'platform'],
  [/\bday\b|\bdate\b|\bweek\b|\bmonth\b/i, 'date_day'],
];

// File-type / platform shortcuts in the query → filter to one group.
const PLATFORM_FILTER: Array<[RegExp, string]> = [
  [/\b(insta(?:gram)?|ig)\b/i, 'instagram'],
  [/\b(youtube|yt)\b/i, 'youtube'],
  [/\b(twitter|tweets?|x\.com)\b/i, 'twitter'],
  [/\blinkedin\b/i, 'linkedin'],
  [/\breddit\b/i, 'reddit'],
  [/\bfacebook|fb\b/i, 'facebook'],
  [/\bwebpages?\b|\barticles?\b/i, 'webpage'],
  [/\bpdfs?\b|\buploaded\s+files?\b|\bdocuments?\b/i, 'uploaded_file'],
  [/\bquick\s*notes?\b/i, 'quick_note'],
  [/\bimages?\b|\bphotos?\b|\bscreenshots?\b/i, 'image'],
];

/**
 * Inspect the raw query and decide whether the agent path should claim it.
 * Returns a StructuredQuery with `operation: 'unknown'` if the agent should
 * forward to classic search instead.
 */
export function understand(rawQuery: string): StructuredQuery {
  const q = rawQuery.trim();

  // Compare branch: try this first because compare queries may also contain
  // domain words that would otherwise be claimed by the count branch.
  const isCompare = COMPARE_RE.test(q);
  if (isCompare) {
    const cmp = extractCompareSpec(q);
    if (cmp) {
      return {
        operation: 'compare',
        topic: cmp.topic,
        filter: {},
        compare: cmp,
        ambiguity: 0.2,
        notes: `compare: a=${cmp.window_a} b=${cmp.window_b} topic="${cmp.topic}"`,
      };
    }
    // Compare verb but couldn't extract two windows or topic — bail to classic.
    return baseUnknown(q, 'compare_extraction_failed');
  }

  // Summarize branch (Phase 5): claim only if there's a real scope —
  // a topic, a time window, or a domain word. Otherwise "summarize this"
  // would grab unrelated chit-chat.
  if (SUMMARIZE_RE.test(q)) {
    const sm = extractSummarizeSpec(q);
    if (sm) {
      return {
        operation: 'summarize',
        topic: sm.topic || null,
        filter: { time: sm.window },
        summarize: sm,
        ambiguity: 0.2,
        notes: `summarize: window=${sm.window} topic="${sm.topic}"`,
      };
    }
    return baseUnknown(q, 'summarize_extraction_failed');
  }

  if (!DOMAIN_RE.test(q)) {
    return baseUnknown(q, 'no_domain_word');
  }

  const isGroup = GROUP_RE.test(q);
  const isCount = COUNT_RE.test(q);

  if (!isGroup && !isCount) {
    // List branch: claim "find/show/list/what" + a structured filter
    // (platform, file_type, time window). This routes around vector search
    // for queries like "find all linkedin posts this week" where semantic
    // search returns wrong results.
    if (LIST_RE.test(q)) {
      const ls = extractListSpec(q);
      if (ls) {
        return {
          operation: 'list',
          topic: ls.topic || null,
          filter: { time: ls.window, file_types: ls.file_types, tags: ls.tags },
          list: ls,
          ambiguity: 0.1,
          notes: `list: window=${ls.window ?? 'none'} ft=${(ls.file_types ?? []).join('|') || 'none'} topic="${ls.topic}"`,
        };
      }
    }
    return baseUnknown(q, 'no_count_or_group_verb');
  }

  // Time filter (optional)
  let time: TimeWindow | undefined;
  for (const [re, w] of TIME_PATTERNS) {
    if (re.test(q)) {
      time = w;
      break;
    }
  }

  // Platform/file-type filter (optional)
  const platforms: string[] = [];
  for (const [re, p] of PLATFORM_FILTER) {
    if (re.test(q)) platforms.push(p);
  }

  // Group-by field, if asking for breakdown/most-popular
  let group_by: StructuredQuery['group_by'] | undefined;
  if (isGroup) {
    for (const [re, field] of GROUP_FIELD_PATTERNS) {
      if (re.test(q)) {
        group_by = field;
        break;
      }
    }
    // Default: "which platform/source most" → platform; otherwise tag.
    if (!group_by) {
      group_by = /\bplatform|source|app|where.*from\b/i.test(q) ? 'platform' : 'tag';
    }
  }

  const operation: StructuredQuery['operation'] = isGroup ? 'group_count' : 'count';

  return {
    operation,
    topic: null,
    filter: {
      time,
      platforms: platforms.length > 0 ? platforms : undefined,
    },
    group_by,
    ambiguity: 0.1,
    notes: `regex match: count=${isCount}, group=${isGroup}, time=${time ?? 'none'}, platforms=${platforms.join(',') || 'none'}`,
  };
}

function baseUnknown(_q: string, reason: string): StructuredQuery {
  // ambiguity=0 for "agent doesn't claim this query". The Phase 3 controller
  // uses ambiguity to decide whether to ask the user back; that signal is
  // only meaningful once we have an LLM extractor that can detect genuine
  // topic ambiguity, so the regex path leaves it at zero.
  return {
    operation: 'unknown',
    topic: null,
    filter: {},
    ambiguity: 0,
    notes: `unsupported_by_agent: ${reason}`,
  };
}

// ---------------------------------------------------------------------------
// Compare query extractor (Phase 4)
// ---------------------------------------------------------------------------

/**
 * Find the first match index for any of the configured TIME_PATTERNS in the
 * query and return [TimeWindow, matchIndex, matchLength] tuples in order.
 * "now" / "currently" / "today" all map to recent windows.
 */
function findTimeWindowsInOrder(q: string): Array<{ window: TimeWindow; start: number; end: number }> {
  // Extra patterns for compare-specific phrasing.
  const allPatterns: Array<[RegExp, TimeWindow]> = [
    ...TIME_PATTERNS,
    [/\b(?:right\s+)?now\b/i, 'last_30d'],
    [/\bcurrently\b/i, 'last_30d'],
    [/\brecent(?:ly)?\b/i, 'last_30d'],
  ];

  const found: Array<{ window: TimeWindow; start: number; end: number }> = [];
  for (const [re, w] of allPatterns) {
    const re2 = new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g');
    let m: RegExpExecArray | null;
    while ((m = re2.exec(q)) !== null) {
      found.push({ window: w, start: m.index, end: m.index + m[0].length });
      if (m.index === re2.lastIndex) re2.lastIndex++;
    }
  }
  // Sort by appearance order.
  found.sort((a, b) => a.start - b.start);
  // Deduplicate overlapping matches: keep the earlier one.
  const out: typeof found = [];
  for (const f of found) {
    if (out.length === 0 || f.start >= out[out.length - 1].end) {
      out.push(f);
    }
  }
  return out;
}

/**
 * Pull the topic from the query by stripping compare/time/connective words.
 * Returns '' to mean "no specific topic — compare everything in the window".
 */
function extractTopic(q: string, windowMatches: Array<{ start: number; end: number }>): string {
  // Try "about|on|regarding|of <topic>" first.
  const introRe = /\b(?:about|on|regarding|on\s+the\s+topic\s+of|with\s+respect\s+to|w\.r\.t\.?)\s+([a-z0-9 \-_'/]{2,80})/i;
  const intro = q.match(introRe);
  if (intro && intro[1]) {
    const topic = postCleanTopic(intro[1]);
    if (topic.length >= 2) return topic;
  }

  // Fallback: remove window phrases + compare verbs + stopwords + question words.
  let stripped = q;
  const sorted = [...windowMatches].sort((a, b) => b.start - a.start);
  for (const m of sorted) {
    stripped = stripped.slice(0, m.start) + ' ' + stripped.slice(m.end);
  }
  stripped = stripped
    .replace(COMPARE_RE, ' ')
    .replace(
      /\b(my|the|a|an|of|in|to|with|for|about|on|by|at|from|how|what|where|when|why|who|which|does|do|did|is|are|was|were|i|i\u2019d|ive|i've|me|notes?|saved|saves?|save|thinking|thoughts?|view|views?|stance|take|takes?|differ|differs|differed|change[ds]?|evolved?|differences?|between|versus|vs|and|or|but)\b/gi,
      ' ',
    )
    .replace(/[?.!,;:]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  return postCleanTopic(stripped);
}

/**
 * Post-clean a candidate topic string: strip leading/trailing prepositions,
 * compare verbs, time fragments, and stray punctuation.
 */
function postCleanTopic(s: string): string {
  let t = s.trim();
  // Strip "over the last/past N units" / "in the last N units" preambles anywhere.
  t = t.replace(/\b(?:over|in|during|across|from|for|within)\s+the\s+(?:last|past|previous)\s+(?:\d+|\w+)\s+(?:days?|weeks?|months?|years?)\b.*$/i, '');
  // Strip trailing numeric time fragments (e.g. "last 6 months", "past 3 weeks").
  t = t.replace(/\b(?:last|this|next|past|previous)\s+(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|few|several|couple\s+of)\s+(?:days?|weeks?|months?|years?)\b.*$/i, '');
  // Strip trailing word time fragments first (e.g. "last month and this month").
  t = t.replace(/\b(?:last|this|next|past|previous)\s+(?:week|month|year|7\s*days|30\s*days|90\s*days)\b.*$/i, '');
  t = t.replace(/\b(?:now|today|yesterday|currently|recently)\b.*$/i, '');
  // Strip compare verbs anywhere.
  t = t.replace(/\b(compare|contrast|differ|differs|differed|change[ds]?|evolved?|versus|vs)\b/gi, '');
  // Strip trailing domain words ("ai notes" → "ai", "foundry stuff" → "foundry").
  for (let i = 0; i < 3; i++) {
    t = t.replace(/\s+(?:notes?|saves?|saved|stuff|things?|content|posts?|articles?|items?)\s*$/i, '');
  }
  // Strip dangling prepositions / connectives at edges, repeatedly.
  for (let i = 0; i < 4; i++) {
    t = t.replace(/^\s*(?:of|in|to|from|with|for|about|on|by|at|and|or|my|the)\s+/i, '');
    t = t.replace(/\s+(?:of|in|to|from|with|for|about|on|by|at|and|or|my|the)\s*$/i, '');
  }
  return t.replace(/[^a-z0-9]+$/i, '').replace(/^[^a-z0-9]+/i, '').replace(/\s+/g, ' ').trim();
}

/**
 * Reject obviously-degenerate topics like "this", "that", "it".
 */
function isDegenerateTopic(t: string): boolean {
  if (!t) return true;
  const norm = t.trim().toLowerCase();
  if (norm.length < 2) return true;
  return /^(this|that|it|them|those|these|stuff|things?|something|anything|everything|all|something\s+all)$/i.test(norm);
}

interface CompareSpec {
  window_a: TimeWindow;
  window_b: TimeWindow;
  topic: string;
}

function extractCompareSpec(q: string): CompareSpec | null {
  const windows = findTimeWindowsInOrder(q);
  if (windows.length < 2) return null;

  const window_a = windows[0].window;
  const window_b = windows[1].window;
  if (window_a === window_b) return null; // "compare last week vs last week" — degenerate

  // Empty topic is allowed → "compare all notes between window A and window B".
  const topic = extractTopic(q, windows);

  return { window_a, window_b, topic };
}

// ---------------------------------------------------------------------------
// Summarize query extractor (Phase 5)
// ---------------------------------------------------------------------------

interface SummarizeSpec {
  topic: string;
  window: TimeWindow;
}

/**
 * Extract a {topic, window} spec for a summarize-style query.
 *
 * Requires at least one of: explicit topic ("about X"), explicit time window,
 * or a domain word ("notes", platform name, etc.). Otherwise returns null so
 * the agent forwards "summarize this" / "tldr" to classic search.
 */
function extractSummarizeSpec(q: string): SummarizeSpec | null {
  const windows = findTimeWindowsInOrder(q);
  const window: TimeWindow = windows.length > 0 ? windows[0].window : 'all_time';

  // Topic: prefer "about X" / "on X" / "regarding X", same as compare.
  const introRe = /\b(?:about|on|regarding|of\s+my|of\s+the|on\s+the\s+topic\s+of|with\s+respect\s+to|w\.r\.t\.?)\s+([a-z0-9 \-_'/]{2,80})/i;
  const intro = q.match(introRe);
  let topic = '';
  if (intro && intro[1]) {
    topic = postCleanTopic(intro[1]);
  }

  // Fallback topic: strip summarize verbs + windows + common stopwords.
  if (!topic || topic.length < 2) {
    let stripped = q;
    const sorted = [...windows].sort((a, b) => b.start - a.start);
    for (const m of sorted) {
      stripped = stripped.slice(0, m.start) + ' ' + stripped.slice(m.end);
    }
    stripped = stripped
      .replace(SUMMARIZE_RE, ' ')
      .replace(
        /\b(my|the|a|an|of|in|to|with|for|about|on|by|at|from|how|what|where|when|why|who|which|does|do|did|is|are|was|were|i|i\u2019d|ive|i've|me|notes?|saved|saves?|save|everything|all|stuff|things?|content|and|or|but|please|just)\b/gi,
        ' ',
      )
      .replace(/[?.!,;:]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
    topic = postCleanTopic(stripped);
  }

  const hasDomain = DOMAIN_RE.test(q);
  const cleanTopic = isDegenerateTopic(topic) ? '' : topic;
  const hasScope = cleanTopic.length >= 2 || windows.length > 0 || hasDomain;
  if (!hasScope) return null;

  return { topic: cleanTopic, window };
}

// ---------------------------------------------------------------------------
// List query extractor (Phase 5.5)
// ---------------------------------------------------------------------------

interface ListSpec {
  topic: string;
  window?: TimeWindow;
  file_types?: string[];
  tags?: string[];
}

/**
 * Extract a deterministic list spec. Requires AT LEAST ONE structured filter
 * (time window, file_type / platform, or tag) — otherwise we'd grab too many
 * generic queries. Topic is optional and only used to narrow keyword match.
 */
function extractListSpec(q: string): ListSpec | null {
  const windows = findTimeWindowsInOrder(q);
  const window: TimeWindow | undefined = windows.length > 0 ? windows[0].window : undefined;

  // Map detected platforms / file_types via the existing PLATFORM_FILTER.
  const fileTypes: string[] = [];
  for (const [re, p] of PLATFORM_FILTER) {
    if (re.test(q)) fileTypes.push(p);
  }

  // "tagged X" / "with tag X" support.
  const tags: string[] = [];
  const tagMatch = q.match(/\b(?:tagged|with\s+tag|under\s+tag)\s+([a-z0-9_-]{1,40})\b/i);
  if (tagMatch) tags.push(tagMatch[1].toLowerCase());

  // Need at least one structured filter to claim the query.
  if (!window && fileTypes.length === 0 && tags.length === 0) return null;

  // Topic: prefer "about X" / "on X". For list queries this is usually empty.
  const introRe = /\b(?:about|on|regarding|mentioning|related\s+to|containing|with\s+the\s+word)\s+([a-z0-9 \-_'/]{2,80})/i;
  const intro = q.match(introRe);
  let topic = '';
  if (intro && intro[1]) topic = postCleanTopic(intro[1]);
  if (isDegenerateTopic(topic)) topic = '';

  return {
    topic,
    window,
    file_types: fileTypes.length > 0 ? fileTypes : undefined,
    tags: tags.length > 0 ? tags : undefined,
  };
}
