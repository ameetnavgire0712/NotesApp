// ============================================================================
// Social Enrichers
// ----------------------------------------------------------------------------
// Pulls human-readable + searchable content out of native social URLs that
// users share from their phones (Instagram, YouTube, LinkedIn, Twitter, â€¦).
//
// v1 scope: YouTube (videos + shorts) only.
//   - Primary path: InnerTube  â†’ title + author + transcript
//   - Fallback path: oEmbed     â†’ title + author + thumbnail (no transcript)
//
// All network calls use plain `fetch()` â€” no SDK packages needed (workers
// runtime constraint). Functions never throw; failures degrade to `null` /
// `success:false` so the caller can choose a fallback path.
// ============================================================================

export type SocialSource = 'youtube' | 'instagram' | 'facebook' | 'linkedin' | 'twitter' | 'reddit';

export interface SocialEnrichmentResult {
  /** Always set â€” what we'd store in notes.file_type */
  source: SocialSource;
  /** Best-effort title (post title, video title, tweet first line, â€¦) */
  title: string;
  /** Markdown body to persist as note content (includes transcript when available) */
  bodyMarkdown: string;
  /** Optional author / channel / handle */
  author?: string;
  /** Public thumbnail URL (will be cached to blob storage by caller) */
  thumbnailUrl?: string;
  /** 'video' | 'short' | 'post' | 'reel' | 'tweet' â€” for UI rendering */
  postType?: string;
  /** Did we get the rich content (transcript, full text)? */
  enrichedFully: boolean;
  /** Metadata blob persisted under notes.metadata.social */
  metadata: Record<string, unknown>;
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Source detection
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/** Returns the social source for a URL, or null for generic webpages. */
export function detectSocialSource(rawUrl: string): SocialSource | null {
  let host: string;
  try {
    host = new URL(rawUrl).hostname.toLowerCase().replace(/^www\./, '');
  } catch {
    return null;
  }
  if (
    host === 'youtube.com' ||
    host === 'm.youtube.com' ||
    host === 'youtu.be' ||
    host === 'music.youtube.com' ||
    host.endsWith('.youtube.com')
  ) {
    return 'youtube';
  }
  if (
    host === 'instagram.com' ||
    host === 'www.instagram.com' ||
    host === 'm.instagram.com' ||
    host === 'instagr.am' ||
    host.endsWith('.instagram.com')
  ) {
    return 'instagram';
  }
  if (
    host === 'facebook.com' ||
    host === 'm.facebook.com' ||
    host === 'web.facebook.com' ||
    host === 'fb.watch' ||
    host.endsWith('.facebook.com')
  ) {
    return 'facebook';
  }
  if (
    host === 'linkedin.com' ||
    host === 'www.linkedin.com' ||
    host === 'm.linkedin.com' ||
    host === 'lnkd.in' ||
    host.endsWith('.linkedin.com')
  ) {
    return 'linkedin';
  }
  if (
    host === 'twitter.com' ||
    host === 'x.com' ||
    host === 'mobile.twitter.com' ||
    host === 'mobile.x.com' ||
    host.endsWith('.twitter.com') ||
    host.endsWith('.x.com')
  ) {
    return 'twitter';
  }
  if (
    host === 'reddit.com' ||
    host === 'www.reddit.com' ||
    host === 'old.reddit.com' ||
    host === 'new.reddit.com' ||
    host === 'np.reddit.com' ||
    host === 'm.reddit.com' ||
    host === 'i.reddit.com' ||
    host === 'redd.it' ||
    host.endsWith('.reddit.com')
  ) {
    return 'reddit';
  }
  return null;
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// YouTube
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/** Extract canonical 11-char video id from any YouTube URL flavour. */
export function extractYouTubeVideoId(rawUrl: string): { id: string; isShort: boolean } | null {
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch {
    return null;
  }
  const host = u.hostname.toLowerCase().replace(/^www\./, '');
  const path = u.pathname;

  // youtu.be/<id>
  if (host === 'youtu.be') {
    const id = path.slice(1).split('/')[0];
    return isValidYtId(id) ? { id, isShort: false } : null;
  }

  // youtube.com/watch?v=<id>
  if (path === '/watch') {
    const id = u.searchParams.get('v') || '';
    return isValidYtId(id) ? { id, isShort: false } : null;
  }

  // youtube.com/shorts/<id>
  if (path.startsWith('/shorts/')) {
    const id = path.slice('/shorts/'.length).split('/')[0];
    return isValidYtId(id) ? { id, isShort: true } : null;
  }

  // youtube.com/embed/<id> or /v/<id>
  if (path.startsWith('/embed/') || path.startsWith('/v/')) {
    const id = path.split('/')[2] || '';
    return isValidYtId(id) ? { id, isShort: false } : null;
  }

  // youtube.com/live/<id>
  if (path.startsWith('/live/')) {
    const id = path.slice('/live/'.length).split('/')[0];
    return isValidYtId(id) ? { id, isShort: false } : null;
  }

  return null;
}

function isValidYtId(id: string): boolean {
  return /^[A-Za-z0-9_-]{11}$/.test(id);
}

/**
 * Pick a canonical, deterministic 16:9 thumbnail for a YouTube videoId.
 *
 * Problem: InnerTube/oEmbed return whichever thumbnail variants happen to
 * exist for a given video. `maxresdefault.jpg` is 1280Ã—720 (16:9) but only
 * exists for videos uploaded in HD. `sddefault.jpg`/`hqdefault.jpg` are 4:3
 * with black letterbox bars, so they render at a different aspect ratio than
 * 16:9 thumbs in note cards. Even uploading the SAME video twice can yield
 * different stored URLs depending on which client responded.
 *
 * Fix: probe a fixed priority list of *16:9-only* variants in descending
 * quality. All return 200 with a real image when available; missing variants
 * return 404 (for maxresdefault) or a tiny 120Ã—90 grey placeholder (for
 * mqdefault/hqdefault â€” those always exist). We HEAD-check size to detect
 * the grey placeholder.
 */
async function pickCanonicalYouTubeThumbnail(videoId: string): Promise<string | undefined> {
  // All entries are 16:9. hq720 is 1280Ã—720 (preferred when maxres is absent).
  // mqdefault is 320Ã—180 â€” always exists, last resort.
  const candidates = [
    `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg`,
    `https://i.ytimg.com/vi/${videoId}/hq720.jpg`,
    `https://i.ytimg.com/vi/${videoId}/mqdefault.jpg`,
  ];
  for (const url of candidates) {
    try {
      // HEAD is enough; ytimg returns Content-Length on 200.
      const resp = await fetch(url, { method: 'HEAD' });
      if (!resp.ok) continue;
      // Reject the 1-px grey placeholder (typically <1KB). Real thumbs are >5KB.
      const len = Number(resp.headers.get('content-length') || '0');
      if (len > 0 && len < 1500) continue;
      return url;
    } catch {
      continue;
    }
  }
  return undefined;
}

/** YouTube oEmbed â€” public, no auth. Returns title + author + thumbnail. */
async function fetchYouTubeOEmbed(canonicalUrl: string): Promise<{
  title?: string;
  author?: string;
  thumbnailUrl?: string;
} | null> {
  try {
    const resp = await fetch(
      `https://www.youtube.com/oembed?url=${encodeURIComponent(canonicalUrl)}&format=json`,
      { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; InfoSnap/1.0)' } },
    );
    if (!resp.ok) return null;
    const data = await resp.json() as {
      title?: string;
      author_name?: string;
      thumbnail_url?: string;
    };
    return {
      title: data.title,
      author: data.author_name,
      thumbnailUrl: data.thumbnail_url,
    };
  } catch (e) {
    console.warn('[social] YouTube oEmbed failed:', e);
    return null;
  }
}

/**
 * Fetch transcript via YouTube's internal InnerTube API.
 * This is the same endpoint used by yt-dlp / youtube-transcript-api. It works
 * without auth and without API keys for the player call.
 *
 * Returns null if no captions are available or the call fails. Caller MUST be
 * prepared for null and fall back to oEmbed-only mode.
 */
async function fetchYouTubeInnerTubeData(videoId: string): Promise<{
  title?: string;
  author?: string;
  thumbnailUrl?: string;
  description?: string;
  lengthSeconds?: number;
  transcript?: string;
} | null> {
  // YouTube increasingly blocks the WEB client when called from Cloudflare
  // datacenter IPs (empty videoDetails, stripped captionTracks, or "Sign in
  // to confirm you're not a bot"). The ANDROID client uses a different
  // fingerprint check and currently succeeds far more often. Try ANDROID
  // first; fall back to WEB if it returns nothing.
  const clients: Array<{
    name: string;
    body: any;
    headers: Record<string, string>;
  }> = [
    {
      name: 'ANDROID',
      body: {
        context: {
          client: {
            clientName: 'ANDROID',
            clientVersion: '19.09.37',
            androidSdkVersion: 30,
            hl: 'en',
            gl: 'US',
            userAgent:
              'com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip',
          },
        },
        videoId,
      },
      headers: {
        'User-Agent':
          'com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip',
        'X-Youtube-Client-Name': '3',
        'X-Youtube-Client-Version': '19.09.37',
      },
    },
    {
      name: 'WEB',
      body: {
        context: {
          client: {
            clientName: 'WEB',
            clientVersion: '2.20241201.00.00',
            hl: 'en',
            gl: 'US',
          },
        },
        videoId,
      },
      headers: {
        'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'X-Youtube-Client-Name': '1',
        'X-Youtube-Client-Version': '2.20241201.00.00',
      },
    },
  ];

  // First pass: get videoDetails + (any) captionTracks from any client.
  // Second pass: if we got details but no caption tracks (ANDROID strips
  // captions), retry other clients to harvest tracks.
  let result: {
    title?: string;
    author?: string;
    thumbnailUrl?: string;
    description?: string;
    lengthSeconds?: number;
    transcript?: string;
  } | null = null;
  let captionTracks:
    | Array<{
        baseUrl: string;
        languageCode?: string;
        kind?: string;
        name?: { simpleText?: string };
      }>
    | undefined;

  for (const client of clients) {
    try {
      const resp = await fetch('https://www.youtube.com/youtubei/v1/player', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...client.headers,
        },
        body: JSON.stringify(client.body),
      });
      if (!resp.ok) {
        console.warn(`[social] InnerTube ${client.name} non-OK:`, resp.status);
        continue;
      }

      const data = (await resp.json()) as any;
      const details = data?.videoDetails;
      const tracks = data?.captions?.playerCaptionsTracklistRenderer
        ?.captionTracks as typeof captionTracks;

      console.log(
        `[social] InnerTube ${client.name}: hasDetails=${!!details} tracks=${tracks?.length ?? 0}`,
      );

      if (details && !result) {
        const thumbs = details?.thumbnail?.thumbnails as
          | Array<{ url: string; width: number }>
          | undefined;
        const bestThumb = Array.isArray(thumbs) && thumbs.length > 0
          ? thumbs.reduce((a, b) => (a.width > b.width ? a : b))
          : null;
        result = {
          title: details.title,
          author: details.author,
          thumbnailUrl: bestThumb?.url,
          description: details.shortDescription,
          lengthSeconds: details.lengthSeconds ? Number(details.lengthSeconds) : undefined,
        };
      }

      if (Array.isArray(tracks) && tracks.length > 0 && !captionTracks) {
        captionTracks = tracks;
      }

      // Stop once we have both metadata and caption tracks.
      if (result && captionTracks) break;
    } catch (e) {
      console.warn(`[social] InnerTube ${client.name} fetch failed:`, e);
    }
  }

  // Fallback: enumerate caption tracks via the public timedtext list API.
  if (!captionTracks) {
    try {
      const listResp = await fetch(
        `https://www.youtube.com/api/timedtext?type=list&v=${encodeURIComponent(videoId)}`,
        { headers: { 'User-Agent': 'Mozilla/5.0' } },
      );
      if (listResp.ok) {
        const xml = await listResp.text();
        const re = /<track[^>]*lang_code="([^"]+)"[^>]*(?:name="([^"]*)")?[^>]*\/>/g;
        const found: Array<{ baseUrl: string; languageCode: string; kind?: string }> = [];
        let m: RegExpExecArray | null;
        while ((m = re.exec(xml)) !== null) {
          const lang = m[1];
          const name = m[2] || '';
          const params = new URLSearchParams({ v: videoId, lang });
          if (name) params.set('name', name);
          found.push({
            baseUrl: `https://www.youtube.com/api/timedtext?${params.toString()}`,
            languageCode: lang,
          });
        }
        if (found.length > 0) {
          captionTracks = found;
          console.log(`[social] timedtext list found ${found.length} tracks`);
        }
      }
    } catch (e) {
      console.warn('[social] timedtext list fetch failed:', e);
    }
  }

  // Final fallback: scrape ytInitialPlayerResponse from the watch page HTML.
  // This sometimes contains captionTracks even when both InnerTube clients
  // strip them, because the page is rendered as a normal HTML response.
  if (!captionTracks) {
    try {
      const pageResp = await fetch(
        `https://www.youtube.com/watch?v=${encodeURIComponent(videoId)}&hl=en`,
        {
          headers: {
            'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
            'Accept-Language': 'en-US,en;q=0.9',
          },
        },
      );
      if (pageResp.ok) {
        const html = await pageResp.text();
        const match = html.match(/ytInitialPlayerResponse\s*=\s*(\{.+?\})\s*;\s*(?:var|<\/script>)/);
        if (match) {
          try {
            const pr = JSON.parse(match[1]);
            const tracks = pr?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
            if (Array.isArray(tracks) && tracks.length > 0) {
              captionTracks = tracks;
              console.log(`[social] watch-page scrape found ${tracks.length} tracks`);
            } else {
              console.log('[social] watch-page scrape: no captionTracks');
            }
          } catch (e) {
            console.warn('[social] watch-page JSON parse failed:', e);
          }
        } else {
          console.log('[social] watch-page scrape: ytInitialPlayerResponse not found');
        }
      } else {
        console.warn('[social] watch-page fetch non-OK:', pageResp.status);
      }
    } catch (e) {
      console.warn('[social] watch-page scrape failed:', e);
    }
  }

  if (captionTracks && captionTracks.length > 0) {
    const pick =
      captionTracks.find(t => t.languageCode === 'en' && !t.kind) ||
      captionTracks.find(t => t.languageCode === 'en') ||
      captionTracks.find(t => t.languageCode && t.languageCode.startsWith('en')) ||
      captionTracks[0];
    if (pick?.baseUrl) {
      const transcript = await fetchTranscriptXml(pick.baseUrl);
      if (transcript && result) {
        result.transcript = transcript;
      }
      console.log(`[social] transcript chars=${transcript?.length ?? 0}`);
    }
  }

  return result;
}

/** Fetch and parse a YouTube transcript XML URL into plain text. */
async function fetchTranscriptXml(baseUrl: string): Promise<string | undefined> {
  // Try XML first (default). If empty, retry with fmt=json3 which some
  // Worker IPs receive when the plain XML form returns an empty body.
  const xmlText = await fetchTranscriptXmlOnce(baseUrl);
  if (xmlText) return xmlText;

  const jsonUrl = baseUrl.includes('fmt=')
    ? baseUrl.replace(/fmt=[^&]+/, 'fmt=json3')
    : `${baseUrl}${baseUrl.includes('?') ? '&' : '?'}fmt=json3`;
  return fetchTranscriptJson3(jsonUrl);
}

async function fetchTranscriptXmlOnce(baseUrl: string): Promise<string | undefined> {
  try {
    const resp = await fetch(baseUrl, {
      headers: { 'User-Agent': 'Mozilla/5.0' },
    });
    if (!resp.ok) return undefined;
    const xml = await resp.text();
    if (!xml || xml.length < 20) return undefined;

    const lines: string[] = [];
    const re = /<text[^>]*>([\s\S]*?)<\/text>/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(xml)) !== null) {
      const raw = m[1] || '';
      const decoded = decodeHtmlEntities(raw)
        .replace(/\n+/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
      if (decoded) lines.push(decoded);
    }
    if (lines.length === 0) return undefined;
    return lines.join(' ');
  } catch (e) {
    console.warn('[social] transcript XML fetch failed:', e);
    return undefined;
  }
}

async function fetchTranscriptJson3(url: string): Promise<string | undefined> {
  try {
    const resp = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
    if (!resp.ok) return undefined;
    const data = (await resp.json()) as any;
    const events = data?.events;
    if (!Array.isArray(events)) return undefined;
    const lines: string[] = [];
    for (const ev of events) {
      const segs = ev?.segs;
      if (!Array.isArray(segs)) continue;
      const txt = segs
        .map((s: any) => s?.utf8 || '')
        .join('')
        .replace(/\n+/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
      if (txt) lines.push(txt);
    }
    return lines.length > 0 ? lines.join(' ') : undefined;
  } catch (e) {
    console.warn('[social] transcript json3 fetch failed:', e);
    return undefined;
  }
}

function decodeHtmlEntities(s: string): string {
  return s
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(parseInt(dec, 10)));
}

/**
 * Public API â€” fetch enrichment for a YouTube URL.
 * Always returns a result (never throws). `enrichedFully:true` means we got
 * the transcript; `false` means we degraded to oEmbed-only.
 *
 * `options.prefetchedTranscript` lets a caller (typically the mobile client,
 * which scraped the transcript from a WebView using the user's residential
 * IP) inject the transcript directly, bypassing the in-Worker caption-fetch
 * chain that often fails from Cloudflare datacenter IPs.
 */
export async function fetchYouTubeEnrichment(
  rawUrl: string,
  options?: {
    prefetchedTranscript?: string | null;
    prefetchedDescription?: string | null;
    /** Direct audio-stream URL from the client's WebView scrape. Used as a
     *  last-resort Whisper input when no captions could be obtained from any
     *  source. May fail (IP-bound URLs); we degrade silently. */
    prefetchedAudioUrl?: string | null;
    /** Video length in seconds reported by the client. Lets us short-circuit
     *  Whisper for videos clearly above the 20 MB / ~25-minute cap. */
    prefetchedDurationSec?: number | null;
    /** Required for Whisper fallback. */
    groqApiKey?: string | null;
    /** Official Meta Instagram oEmbed access token. */
    instagramOEmbedAccessToken?: string | null;
  },
): Promise<SocialEnrichmentResult> {
  return fetchYouTubeLegalEnrichment(rawUrl);
  const parsed = extractYouTubeVideoId(rawUrl);
  const videoId = parsed?.id;
  const isShort = parsed?.isShort ?? false;
  const canonicalUrl = videoId
    ? `https://www.youtube.com/watch?v=${videoId}`
    : rawUrl;

  // Try InnerTube first (richest data)
  const innerTube = videoId ? await fetchYouTubeInnerTubeData(videoId) : null;

  // Always fetch oEmbed in parallel as a safety net for title/author/thumbnail
  // (InnerTube can succeed for player data but be missing some fields).
  const oembed = await fetchYouTubeOEmbed(canonicalUrl);

  const title = innerTube?.title || oembed?.title || 'YouTube video';
  const author = innerTube?.author || oembed?.author;
  let thumbnailUrl: string | undefined = videoId
    ? await pickCanonicalYouTubeThumbnail(videoId)
    : undefined;
  if (!thumbnailUrl) {
    thumbnailUrl = innerTube?.thumbnailUrl || oembed?.thumbnailUrl;
  }
  // Prefer client-scraped transcript when present (residential IP succeeds
  // where the Worker's datacenter IP gets blocked); fall back to whatever
  // the InnerTube path could fetch.
  const prefetched = (options?.prefetchedTranscript || '').trim();
  let transcript: string | undefined = prefetched.length > 0 ? prefetched : innerTube?.transcript;
  let transcriptSource: 'client_captions' | 'worker_captions' | 'whisper_audio' | 'none' =
    prefetched.length > 0 ? 'client_captions' : (innerTube?.transcript ? 'worker_captions' : 'none');
  if (prefetched.length > 0) {
    console.log(`[social] using client-prefetched transcript chars=${prefetched.length}`);
  }
  const prefetchedDesc = (options?.prefetchedDescription || '').trim();
  const description = prefetchedDesc.length > 0 ? prefetchedDesc : innerTube?.description;
  if (prefetchedDesc.length > 0) {
    console.log(`[social] using client-prefetched description chars=${prefetchedDesc.length}`);
  }
  const lengthSeconds = innerTube?.lengthSeconds || options?.prefetchedDurationSec || undefined;

  // â”€â”€â”€ Whisper fallback (last resort) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Only triggered when ALL caption paths above produced nothing.
  //   * Requires a client-supplied audio URL (worker can't reliably extract
  //     one â€” YouTube's signature cipher needs the JS player).
  //   * Requires a Groq API key.
  //   * Skipped when the video is clearly too long (>~25 min â‰ˆ 1500 s) so we
  //     don't waste 15 s on a fetch that will exceed the 20 MB cap.
  //   * URLs may be IP-bound to the client's residential IP; the worker fetch
  //     can fail. We degrade silently to the friendly "captions unavailable"
  //     message below.
  let whisperDurationSec: number | null = null;
  let whisperReason: 'success' | 'too_long' | 'fetch_failed' | 'size_cap' | 'no_audio_url' | 'no_groq_key' | 'not_attempted' = 'not_attempted';
  const TOO_LONG_SEC = 1500; // ~25 min, matches Whisper's practical limit at our 20 MB cap
  if (!transcript) {
    const audioUrl = (options?.prefetchedAudioUrl || '').trim();
    const groqKey = (options?.groqApiKey || '').trim();
    if (!audioUrl) {
      whisperReason = 'no_audio_url';
    } else if (!groqKey) {
      whisperReason = 'no_groq_key';
    } else if (lengthSeconds && lengthSeconds > TOO_LONG_SEC) {
      whisperReason = 'too_long';
      console.log(`[social] YouTube Whisper skipped: video too long (${lengthSeconds}s > ${TOO_LONG_SEC}s)`);
    } else {
      console.log(`[social] YouTube Whisper fallback: attempting transcription of audio stream`);
      const wh = await transcribeVideoWithWhisper(audioUrl, groqKey);
      if (wh && wh.text) {
        transcript = wh.text;
        whisperDurationSec = wh.durationSec;
        transcriptSource = 'whisper_audio';
        whisperReason = 'success';
        console.log(`[social] YouTube Whisper success: ${wh.text.length} chars`);
      } else {
        // transcribeVideoWithWhisper already logs the reason; we can't easily
        // distinguish fetch_failed vs size_cap here, so bucket as fetch_failed.
        whisperReason = 'fetch_failed';
      }
    }
  }

  const enrichedFully = !!transcript;
  const postType = isShort ? 'short' : 'video';

  // â”€â”€â”€ Build markdown body for the note â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const lines: string[] = [];
  lines.push(`# ${title}`);
  lines.push('');
  if (author) lines.push(`**Channel:** ${author}`);
  if (lengthSeconds && lengthSeconds > 0) {
    lines.push(`**Duration:** ${formatDuration(lengthSeconds)}`);
  }
  lines.push(`**Source:** ${canonicalUrl}`);
  lines.push('');

  if (description) {
    lines.push('## Description');
    lines.push('');
    lines.push(description.trim());
    lines.push('');
  }

  if (transcript) {
    const heading = transcriptSource === 'whisper_audio' ? '## Transcript (auto-generated from audio)' : '## Transcript';
    lines.push(heading);
    lines.push('');
    lines.push(transcript);
  } else {
    lines.push('## Transcript');
    lines.push('');
    // Friendly, situation-specific messaging.
    if (whisperReason === 'too_long') {
      lines.push('_Captions unavailable on YouTube. This video is too long for automatic transcription â€” open the original video to listen._');
    } else if (whisperReason === 'fetch_failed') {
      lines.push('_Captions unavailable on YouTube. Automatic transcription couldn\'t reach the audio stream â€” open the original video to listen._');
    } else if (description) {
      lines.push('_Captions unavailable on YouTube. The description above is what we could capture â€” open the original video to listen._');
    } else {
      lines.push('_Captions unavailable on YouTube. Open the original video to listen._');
    }
  }

  return {
    source: 'youtube',
    title,
    bodyMarkdown: lines.join('\n'),
    author,
    thumbnailUrl,
    postType,
    enrichedFully,
    metadata: {
      source_app: 'youtube',
      source_url: canonicalUrl,
      video_id: videoId || null,
      post_type: postType,
      author: author || null,
      length_seconds: lengthSeconds || null,
      thumbnail_url: thumbnailUrl || null,
      transcript_available: enrichedFully,
      transcript_source: transcriptSource,
      whisper_reason: whisperReason,
      whisper_duration_sec: whisperDurationSec,
      description: description || null,
    },
  };
}

async function fetchYouTubeDataApiLegal(videoId: string, apiKey?: string | null): Promise<{
  title?: string;
  author?: string;
  channelId?: string;
  thumbnailUrl?: string;
  description?: string;
  lengthSeconds?: number;
  publishedAt?: string;
  tags?: string[];
  categoryId?: string;
  defaultLanguage?: string;
  defaultAudioLanguage?: string;
  embeddable?: boolean;
  privacyStatus?: string;
  license?: string;
  publicStatsViewable?: boolean;
  madeForKids?: boolean;
  viewCount?: number;
  likeCount?: number;
  commentCount?: number;
  embedHtml?: string;
} | null> {
  const key = (apiKey || '').trim();
  if (!key) return null;
  try {
    const params = new URLSearchParams({
      part: 'snippet,contentDetails,status,statistics,player',
      id: videoId,
      key,
    });
    const resp = await fetch(`https://www.googleapis.com/youtube/v3/videos?${params.toString()}`);
    if (!resp.ok) {
      console.warn('[social] YouTube Data API non-OK:', resp.status);
      return null;
    }
    const data = (await resp.json()) as any;
    const item = Array.isArray(data?.items) ? data.items[0] : null;
    if (!item) return null;
    const snippet = item.snippet || {};
    const contentDetails = item.contentDetails || {};
    const status = item.status || {};
    const statistics = item.statistics || {};
    const thumbs = snippet.thumbnails || {};
    const thumbUrl = ['maxres', 'standard', 'high', 'medium', 'default']
      .map(name => thumbs[name]?.url)
      .find(Boolean);
    return {
      title: snippet.title,
      author: snippet.channelTitle,
      channelId: snippet.channelId,
      thumbnailUrl: thumbUrl,
      description: snippet.description,
      lengthSeconds: parseYouTubeIsoDuration(contentDetails.duration),
      publishedAt: snippet.publishedAt,
      tags: Array.isArray(snippet.tags) ? snippet.tags.slice(0, 50) : undefined,
      categoryId: snippet.categoryId,
      defaultLanguage: snippet.defaultLanguage,
      defaultAudioLanguage: snippet.defaultAudioLanguage,
      embeddable: typeof status.embeddable === 'boolean' ? status.embeddable : undefined,
      privacyStatus: status.privacyStatus,
      license: status.license,
      publicStatsViewable: typeof status.publicStatsViewable === 'boolean' ? status.publicStatsViewable : undefined,
      madeForKids: typeof status.madeForKids === 'boolean' ? status.madeForKids : undefined,
      viewCount: parseNumberLike(statistics.viewCount),
      likeCount: parseNumberLike(statistics.likeCount),
      commentCount: parseNumberLike(statistics.commentCount),
      embedHtml: item.player?.embedHtml,
    };
  } catch (e) {
    console.warn('[social] YouTube Data API failed:', e);
    return null;
  }
}

function parseNumberLike(value: unknown): number | undefined {
  if (typeof value !== 'string' && typeof value !== 'number') return undefined;
  const n = Number(value);
  return Number.isFinite(n) ? n : undefined;
}

function parseYouTubeIsoDuration(value: unknown): number | undefined {
  if (typeof value !== 'string') return undefined;
  const m = value.match(/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/);
  if (!m) return undefined;
  return Number(m[1] || 0) * 3600 + Number(m[2] || 0) * 60 + Number(m[3] || 0);
}

export async function fetchYouTubeLegalEnrichment(
  rawUrl: string,
  options?: { youtubeApiKey?: string | null },
): Promise<SocialEnrichmentResult> {
  const parsed = extractYouTubeVideoId(rawUrl);
  const videoId = parsed?.id;
  const isShort = parsed?.isShort ?? false;
  const canonicalUrl = videoId ? `https://www.youtube.com/watch?v=${videoId}` : rawUrl;
  const api = videoId ? await fetchYouTubeDataApiLegal(videoId, options?.youtubeApiKey || null) : null;
  const oembed = await fetchYouTubeOEmbed(canonicalUrl);
  const title = api?.title || oembed?.title || 'YouTube video';
  const author = api?.author || oembed?.author;
  const thumbnailUrl = api?.thumbnailUrl || oembed?.thumbnailUrl;
  const postType = isShort ? 'short' : 'video';

  const lines: string[] = [`# ${title}`, ''];
  if (author) lines.push(`**Channel:** ${author}`);
  if (api?.channelId) lines.push(`**Channel ID:** ${api.channelId}`);
  if (api?.publishedAt) lines.push(`**Published:** ${api.publishedAt}`);
  if (api?.lengthSeconds && api.lengthSeconds > 0) lines.push(`**Duration:** ${formatDuration(api.lengthSeconds)}`);
  if (typeof api?.viewCount === 'number') lines.push(`**Views:** ${api.viewCount}`);
  if (typeof api?.likeCount === 'number') lines.push(`**Likes:** ${api.likeCount}`);
  if (typeof api?.commentCount === 'number') lines.push(`**Comments:** ${api.commentCount}`);
  if (typeof api?.embeddable === 'boolean') lines.push(`**Embeddable:** ${api.embeddable ? 'Yes' : 'No'}`);
  lines.push(`**Source:** ${canonicalUrl}`, '');
  if (api?.description) lines.push('## Description', '', api.description.trim(), '');
  if (api?.tags && api.tags.length > 0) lines.push('## Tags', '', api.tags.join(', '), '');

  return {
    source: 'youtube',
    title,
    bodyMarkdown: lines.join('\n'),
    author,
    thumbnailUrl,
    postType,
    enrichedFully: !!api || !!oembed,
    metadata: {
      source_app: 'youtube',
      source_url: canonicalUrl,
      video_id: videoId || null,
      post_type: postType,
      author: author || null,
      channel_id: api?.channelId || null,
      published_at: api?.publishedAt || null,
      length_seconds: api?.lengthSeconds || null,
      thumbnail_url: thumbnailUrl || null,
      description: api?.description || null,
      tags: api?.tags || [],
      category_id: api?.categoryId || null,
      default_language: api?.defaultLanguage || null,
      default_audio_language: api?.defaultAudioLanguage || null,
      embeddable: api?.embeddable ?? null,
      privacy_status: api?.privacyStatus || null,
      license: api?.license || null,
      public_stats_viewable: api?.publicStatsViewable ?? null,
      made_for_kids: api?.madeForKids ?? null,
      view_count: api?.viewCount ?? null,
      like_count: api?.likeCount ?? null,
      comment_count: api?.commentCount ?? null,
      embed_html: api?.embedHtml || null,
      metadata_source: api ? 'youtube_data_api' : (oembed ? 'youtube_oembed' : 'none'),
      transcript_available: false,
      transcript_source: 'not_collected_policy',
      whisper_reason: 'not_collected_policy',
    },
  };
}

function formatDuration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}


// =============================================================================
// Generic prefetched-social envelope (Refinement #2)
// -----------------------------------------------------------------------------
// Clients (the mobile WebView scraper, primarily) hand us a small structured
// payload of fields they pulled in the user''s authenticated/residential
// browsing context. We trust these over server-side scraping because:
//   * residential IP avoids datacenter blocks/login walls;
//   * the user''s cookies often unlock more data (esp. Instagram).
// Adding a new platform = adding optional fields here, not adding new
// top-level body params per platform.
// =============================================================================
export interface PrefetchedSocialPayload {
  caption?: string | null;
  author?: string | null;
  thumbnail_url?: string | null;
  video_url?: string | null;
  media_items?: Array<{ type?: string | null; url?: string | null }> | null;
  media_type?: string | null;       // 'reel' | 'post' | 'igtv' | 'carousel' | ...
  carousel_media_count?: number | null;
  scraped_at?: string | null;       // ISO-8601 timestamp from client
}

interface SocialMediaProcessingOptions {
  userId?: string | null;
  azureConnectionString?: string | null;
  azureContainer?: string | null;
  tensorlakeApiKey?: string | null;
}

interface InstagramAzureMediaEnv {
  azureConnectionString: string;
  azureContainer: string;
}

// =============================================================================
// Instagram
// =============================================================================

/** Extract canonical shortcode + post type from any Instagram URL flavour. */
export function extractInstagramShortcode(rawUrl: string): {
  shortcode: string;
  postType: 'reel' | 'post' | 'igtv';
  canonicalUrl: string;
} | null {
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch {
    return null;
  }
  const host = u.hostname.toLowerCase().replace(/^www\./, '');
  // Accept instagr.am short-domain too.
  if (host !== 'instagram.com' && host !== 'm.instagram.com' && host !== 'instagr.am' && !host.endsWith('.instagram.com')) {
    return null;
  }
  // Normalize path segments ï¿½ strip empty pieces and locale prefixes like /en/.
  const segments = u.pathname.split('/').filter(s => s.length > 0);
  if (segments.length === 0) return null;

  // Match /reel/{code} or /reels/{code} or /p/{code} or /tv/{code} possibly
  // preceded by a locale code (2-3 letter) or a username/share path. We do a
  // simple scan: find the first known marker and the next segment is the code.
  const markers: Record<string, 'reel' | 'post' | 'igtv'> = {
    reel: 'reel',
    reels: 'reel',
    p: 'post',
    tv: 'igtv',
  };
  let postType: 'reel' | 'post' | 'igtv' | null = null;
  let shortcode: string | null = null;
  for (let i = 0; i < segments.length - 1; i++) {
    const seg = segments[i].toLowerCase();
    if (markers[seg]) {
      postType = markers[seg];
      shortcode = segments[i + 1].replace(/[^A-Za-z0-9_-]/g, '');
      break;
    }
  }
  if (!postType || !shortcode || shortcode.length < 5 || shortcode.length > 30) {
    return null;
  }
  // Canonical URL ï¿½ drops query strings + utm/igsh tracking params, normalizes
  // host to www.instagram.com so dedup keys collapse cleanly.
  const canonicalPath = postType === 'igtv' ? `/tv/${shortcode}/` : `/${postType === 'reel' ? 'reel' : 'p'}/${shortcode}/`;
  const canonicalUrl = `https://www.instagram.com${canonicalPath}`;
  return { shortcode, postType, canonicalUrl };
}

function isLikelyCroppedInstagramThumbnail(url: string | null | undefined): boolean {
  const value = (url || '').trim();
  if (!value) return false;
  return (
    /[?&]stp=[^&]*c\d+(?:\.\d+){3}a_/i.test(value) ||
    /(?:s|p)(150|240|320|480|640|750|1080)x\1/i.test(value) ||
    /CAROUSEL_ITEM\.best_image_urlgen/i.test(value)
  );
}

// -------------------------------------------------------------------------
// Server-side HTML scrape fallbacks for Instagram
// -------------------------------------------------------------------------
// Strategy is layered. IG aggressively login-walls anonymous server-side
// requests, so we keep all paths best-effort and surface which one supplied
// the caption via metadata.social.caption_source (Refinement #5).

interface InstagramHtmlScrape {
  caption?: string;
  author?: string;
  thumbnailUrl?: string;
  videoUrl?: string;
  mediaItems?: Array<{ type: 'image' | 'video'; url: string }>;
  mediaType?: string;
  carouselCount?: number;
  captionSource: 'server_json' | 'og_tags' | 'none';
}

async function fetchInstagramHtml(canonicalUrl: string): Promise<string | null> {
  try {
    const resp = await fetch(canonicalUrl, {
      headers: {
        // Mobile UA tends to get the lighter, less-walled HTML.
        'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 ' +
          '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      },
      redirect: 'follow',
    });
    if (!resp.ok) return null;
    const html = await resp.text();
    if (html.length < 500) return null;
    return html;
  } catch (e) {
    console.warn('[social] IG HTML fetch failed:', e);
    return null;
  }
}

function addInstagramMediaItem(
  items: Array<{ type: 'image' | 'video'; url: string }>,
  type: 'image' | 'video',
  url: string | null | undefined,
): void {
  const clean = (url || '').trim();
  if (!clean || clean.startsWith('blob:')) return;
  if (!/^https?:\/\//i.test(clean)) return;
  if (items.some(item => item.url === clean)) return;
  if (items.length < 8) items.push({ type, url: clean });
}

function tryParseInstagramEmbeddedJson(html: string): Partial<InstagramHtmlScrape> {
  // IG ships a hydration JSON inside <script>window.__additionalDataLoaded(...)</script>
  // OR inside large GraphQL blobs. We look for `xdt_shortcode_media` /
  // `shortcode_media` references and try to pull the structured fields.
  const out: Partial<InstagramHtmlScrape> = {};
  const mediaItems: Array<{ type: 'image' | 'video'; url: string }> = [];
  try {
    // Caption text:  "edge_media_to_caption":{"edges":[{"node":{"text":"..."}}]}
    const capMatch = html.match(/"edge_media_to_caption"\s*:\s*\{\s*"edges"\s*:\s*\[\s*\{\s*"node"\s*:\s*\{\s*"text"\s*:\s*"((?:\\.|[^"\\])*)"/);
    if (capMatch && capMatch[1]) {
      out.caption = decodeJsonString(capMatch[1]);
    }
    // Owner username:  "owner":{"username":"...","..."}
    const authMatch = html.match(/"owner"\s*:\s*\{[^}]*?"username"\s*:\s*"([^"]+)"/);
    if (authMatch) out.author = authMatch[1];
    // Display URL (thumbnail):  "display_url":"..." (first occurrence is the main media)
    const thumbMatch = html.match(/"display_url"\s*:\s*"([^"]+)"/);
    if (thumbMatch) {
      out.thumbnailUrl = decodeJsonString(thumbMatch[1]);
      addInstagramMediaItem(mediaItems, 'image', out.thumbnailUrl);
    }
    const displayRe = /"display_url"\s*:\s*"((?:\\.|[^"\\])*)"/g;
    let displayMatch: RegExpExecArray | null;
    while ((displayMatch = displayRe.exec(html)) !== null && mediaItems.length < 8) {
      addInstagramMediaItem(mediaItems, 'image', decodeJsonString(displayMatch[1]));
    }
    const videoMatch =
      html.match(/"video_url"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
      html.match(/"playable_url"\s*:\s*"((?:\\.|[^"\\])*)"/) ||
      html.match(/"src"\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*"config_width"/);
    if (videoMatch) {
      out.videoUrl = decodeJsonString(videoMatch[1]);
      addInstagramMediaItem(mediaItems, 'video', out.videoUrl);
    }
    const videoRe = /"video_url"\s*:\s*"((?:\\.|[^"\\])*)"/g;
    let videoIterMatch: RegExpExecArray | null;
    while ((videoIterMatch = videoRe.exec(html)) !== null && mediaItems.length < 8) {
      addInstagramMediaItem(mediaItems, 'video', decodeJsonString(videoIterMatch[1]));
    }
    // Is video?  "is_video":true ? reel/video, false ? image post
    if (/"is_video"\s*:\s*true/.test(html)) {
      out.mediaType = 'video';
    } else if (/"is_video"\s*:\s*false/.test(html)) {
      out.mediaType = 'image';
    }
    if (out.videoUrl && !out.mediaType) out.mediaType = 'video';
    // Sidecar (carousel):  "__typename":"GraphSidecar"  AND  edge_sidecar_to_children.edges.length
    if (/"__typename"\s*:\s*"GraphSidecar"/.test(html) || /"product_type"\s*:\s*"carousel_container"/.test(html)) {
      out.mediaType = 'carousel';
      const carouselMatch = html.match(/"edge_sidecar_to_children"\s*:\s*\{\s*"edges"\s*:\s*\[((?:[^\[\]]|\[[^\]]*\])*)\]/);
      if (carouselMatch) {
        // crude count: number of top-level {"node": within the edges array
        const nodes = carouselMatch[1].match(/\{\s*"node"\s*:/g);
        out.carouselCount = nodes ? nodes.length : undefined;
      }
    }
  } catch (e) {
    console.warn('[social] IG embedded-json parse threw:', e);
  }
  if (mediaItems.length > 0) out.mediaItems = mediaItems;
  return out;
}

function tryParseInstagramOgTags(html: string): Partial<InstagramHtmlScrape> {
  const out: Partial<InstagramHtmlScrape> = {};
  const mediaItems: Array<{ type: 'image' | 'video'; url: string }> = [];
  try {
    const ogDesc = html.match(/<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["']/i);
    if (ogDesc) {
      // og:description on IG is typically  "<N> likes, <M> comments - <author> on <date>: \"<caption>\""
      // IG serves ASCII quotes; accept curly quotes too for safety.
      const raw = decodeHtmlEntities(ogDesc[1]);
      let capMatch = raw.match(/:\s*["\u201C\u201D]([\s\S]+?)["\u201C\u201D]\s*$/);
      if (!capMatch) {
        // Fallback: strip the "<likes>, <comments> - <author> on <date>:" preamble.
        capMatch = raw.match(/^[\d,]+\s+likes?,\s*[\d,]+\s+comments?\s*-\s*[^:]+:\s*["\u201C]?([\s\S]+?)["\u201D]?\s*$/i);
      }
      if (capMatch) {
        out.caption = capMatch[1].trim();
      } else {
        out.caption = raw.trim();
      }
    }
    const ogImg = html.match(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i);
    if (ogImg) {
      out.thumbnailUrl = decodeHtmlEntities(ogImg[1]);
      addInstagramMediaItem(mediaItems, 'image', out.thumbnailUrl);
    }
    const ogVideo = html.match(/<meta[^>]+property=["']og:video(?::secure_url)?["'][^>]+content=["']([^"']+)["']/i);
    if (ogVideo) {
      out.videoUrl = decodeHtmlEntities(ogVideo[1]);
      out.mediaType = 'video';
      addInstagramMediaItem(mediaItems, 'video', out.videoUrl);
    }
    const ogTitle = html.match(/<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i);
    if (ogTitle) {
      // og:title is usually "<author> on Instagram: ..."
      const tm = decodeHtmlEntities(ogTitle[1]).match(/^([^()]+?)\s+on Instagram/i);
      if (tm) out.author = tm[1].trim().replace(/^@/, '');
    }
  } catch (e) {
    console.warn('[social] IG og-tag parse threw:', e);
  }
  if (mediaItems.length > 0) out.mediaItems = mediaItems;
  return out;
}

function decodeJsonString(s: string): string {
  // The match captures the *escaped* JSON content. Use JSON.parse to unescape.
  try {
    return JSON.parse('"' + s + '"') as string;
  } catch {
    return s.replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
  }
}

function parseAzureConnectionString(connStr: string): { accountName: string; accountKey: string } {
  let accountName = '';
  let accountKey = '';
  for (const part of connStr.split(';')) {
    if (part.startsWith('AccountName=')) accountName = part.substring('AccountName='.length);
    if (part.startsWith('AccountKey=')) accountKey = part.substring('AccountKey='.length);
  }
  return { accountName, accountKey };
}

async function createAzureSharedKeyAuth(
  accountName: string,
  accountKey: string,
  method: string,
  url: string,
  headers: Record<string, string>,
  contentLength: number,
): Promise<string> {
  const xmsHeaders = Object.entries(headers)
    .filter(([k]) => k.toLowerCase().startsWith('x-ms-'))
    .sort(([a], [b]) => a.toLowerCase().localeCompare(b.toLowerCase()))
    .map(([k, v]) => `${k.toLowerCase()}:${v}`)
    .join('\n');
  const urlObj = new URL(url);
  const canonicalResource = `/${accountName}${urlObj.pathname}`;
  const stringToSign = [
    method, '', '', contentLength > 0 ? contentLength.toString() : '', '',
    headers['Content-Type'] || '', '', '', '', '', '', '',
    xmsHeaders,
    canonicalResource,
  ].join('\n');
  const keyBytes = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
  return `SharedKey ${accountName}:${btoa(String.fromCharCode(...new Uint8Array(signature)))}`;
}

function imageExtFromContentType(contentType: string): string {
  const clean = contentType.toLowerCase().split(';')[0].trim();
  if (clean === 'image/png') return 'png';
  if (clean === 'image/webp') return 'webp';
  if (clean === 'image/gif') return 'gif';
  if (clean === 'image/bmp') return 'bmp';
  return 'jpg';
}

async function uploadInstagramMediaToAzure(
  data: ArrayBuffer,
  contentType: string,
  userId: string,
  env: InstagramAzureMediaEnv,
): Promise<{ blobUrl: string; blobName: string }> {
  const { accountName, accountKey } = parseAzureConnectionString(env.azureConnectionString);
  const ext = imageExtFromContentType(contentType);
  const blobName = `${userId}/instagram-media/${Date.now()}_${crypto.randomUUID()}.${ext}`;
  const url = `https://${accountName}.blob.core.windows.net/${env.azureContainer}/${blobName}`;
  const headers: Record<string, string> = {
    'Content-Type': contentType || 'image/jpeg',
    'x-ms-blob-type': 'BlockBlob',
    'x-ms-date': new Date().toUTCString(),
    'x-ms-version': '2020-10-02',
  };
  const authHeader = await createAzureSharedKeyAuth(accountName, accountKey, 'PUT', url, headers, data.byteLength);
  const resp = await fetch(url, {
    method: 'PUT',
    headers: {
      ...headers,
      'Authorization': authHeader,
      'Content-Length': data.byteLength.toString(),
    },
    body: data,
  });
  if (!resp.ok) {
    const text = await resp.text().catch(() => '');
    throw new Error(`Azure upload failed: ${resp.status} ${text.slice(0, 160)}`);
  }
  return { blobUrl: url, blobName };
}

async function generateInstagramMediaSasUrl(
  blobUrl: string,
  env: Pick<InstagramAzureMediaEnv, 'azureConnectionString'>,
  expiryMinutes = 30,
): Promise<string> {
  const { accountName, accountKey } = parseAzureConnectionString(env.azureConnectionString);
  const urlObj = new URL(blobUrl);
  const pathParts = urlObj.pathname.split('/').filter(Boolean);
  const container = pathParts[0];
  const blobName = pathParts.slice(1).join('/');
  const version = '2020-10-02';
  const now = new Date();
  const st = new Date(now.getTime() - 5 * 60 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const se = new Date(now.getTime() + expiryMinutes * 60 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const sp = 'r';
  const sr = 'b';
  const spr = 'https';
  const stringToSign = [
    sp, st, se, `/blob/${accountName}/${container}/${blobName}`, '', '', spr,
    version, sr, '', '', '', '', '', '',
  ].join('\n');
  const keyBytes = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
  const sig = btoa(String.fromCharCode(...new Uint8Array(signature)));
  const params = new URLSearchParams({ sv: version, st, se, sr, sp, spr, sig });
  return `${blobUrl}?${params.toString()}`;
}

async function convertInstagramImageWithTensorLake(
  fileUrl: string,
  apiKey: string,
): Promise<string | null> {
  const parseResp = await fetch('https://api.tensorlake.ai/documents/v2/read', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ file_url: fileUrl }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!parseResp.ok) {
    console.warn('[social] IG TensorLake parse start failed:', parseResp.status);
    return null;
  }
  const parseData = await parseResp.json() as any;
  const parseId = parseData.parse_id || parseData.task_id;
  if (!parseId) return null;

  for (let attempt = 0; attempt < 40; attempt++) {
    const delay = attempt < 3 ? 150 : attempt < 10 ? 500 : 1500;
    await new Promise(resolve => setTimeout(resolve, delay));
    const pollResp = await fetch(`https://api.tensorlake.ai/documents/v2/parse/${parseId}`, {
      headers: { 'Authorization': `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(10_000),
    });
    if (!pollResp.ok) return null;
    const pollData = await pollResp.json() as any;
    const status = (pollData.status || '').toLowerCase();
    if (status === 'processing' || status === 'pending' || status === 'queued') continue;
    if (status === 'failed' || pollData.error) return null;
    const docMarkdown = pollData?.document_markdown || pollData?.result?.document_markdown;
    if (docMarkdown && docMarkdown.trim()) return docMarkdown.trim();
    const chunks = pollData?.chunks || pollData?.result?.chunks || [];
    if (Array.isArray(chunks) && chunks.length > 0) {
      const text = chunks.map((c: any) => c.content || c.text || '').join('\n\n').trim();
      if (text) return text;
    }
    const pages = pollData?.pages || pollData?.result?.pages || [];
    if (Array.isArray(pages) && pages.length > 0) {
      const text = pages.map((p: any) => p.content || p.text || '').join('\n\n').trim();
      if (text) return text;
    }
    const md = pollData?.markdown || pollData?.result?.markdown;
    return md?.trim() || null;
  }
  return null;
}

async function processInstagramImageItems(
  mediaItems: Array<{ type: 'image' | 'video'; url: string }>,
  options: SocialMediaProcessingOptions | undefined,
): Promise<{
  sections: string[];
  processedCount: number;
  failedCount: number;
  blobUrls: string[];
}> {
  const userId = (options?.userId || '').trim();
  const azureConnectionString = (options?.azureConnectionString || '').trim();
  const azureContainer = (options?.azureContainer || '').trim();
  const tensorlakeApiKey = (options?.tensorlakeApiKey || '').trim();
  if (!userId || !azureConnectionString || !azureContainer || !tensorlakeApiKey) {
    return { sections: [], processedCount: 0, failedCount: 0, blobUrls: [] };
  }

  const sections: string[] = [];
  const blobUrls: string[] = [];
  let processedCount = 0;
  let failedCount = 0;
  const images = mediaItems.filter(item => item.type === 'image').slice(0, 5);
  for (let i = 0; i < images.length; i++) {
    const item = images[i];
    try {
      const resp = await fetch(item.url, {
        headers: {
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        },
        signal: AbortSignal.timeout(12_000),
      });
      if (!resp.ok) throw new Error(`image fetch HTTP ${resp.status}`);
      const contentType = (resp.headers.get('content-type') || 'image/jpeg').split(';')[0];
      if (!contentType.startsWith('image/')) throw new Error(`unexpected content-type ${contentType}`);
      const buf = await resp.arrayBuffer();
      if (buf.byteLength < 512) throw new Error('image response too small');
      if (buf.byteLength > 12 * 1024 * 1024) throw new Error('image too large');
      const uploaded = await uploadInstagramMediaToAzure(buf, contentType, userId, {
        azureConnectionString,
        azureContainer,
      });
      blobUrls.push(uploaded.blobUrl);
      const sasUrl = await generateInstagramMediaSasUrl(uploaded.blobUrl, { azureConnectionString });
      const text = await convertInstagramImageWithTensorLake(sasUrl, tensorlakeApiKey);
      if (text) {
        processedCount++;
        sections.push(`### Image ${i + 1}\n\n${text}`);
      } else {
        failedCount++;
      }
    } catch (e) {
      failedCount++;
      console.warn('[social] IG image TensorLake processing failed:', e);
    }
  }
  return { sections, processedCount, failedCount, blobUrls };
}

async function fetchInstagramHtmlScrape(canonicalUrl: string): Promise<InstagramHtmlScrape> {
  const html = await fetchInstagramHtml(canonicalUrl);
  if (!html) return { captionSource: 'none' };

  // 1) Try embedded JSON (richer, structured).
  const json = tryParseInstagramEmbeddedJson(html);
  // 2) Always also parse og: tags; we merge so OG fills gaps json missed.
  const og = tryParseInstagramOgTags(html);

  const merged: InstagramHtmlScrape = {
    caption: json.caption || og.caption,
    author: json.author || og.author,
    thumbnailUrl: json.thumbnailUrl || og.thumbnailUrl,
    videoUrl: json.videoUrl || og.videoUrl,
    mediaItems: [...(json.mediaItems || []), ...(og.mediaItems || [])].filter(
      (item, idx, arr) => arr.findIndex(other => other.url === item.url) === idx,
    ).slice(0, 8),
    mediaType: json.mediaType || og.mediaType,
    carouselCount: json.carouselCount,
    captionSource: json.caption ? 'server_json' : (og.caption ? 'og_tags' : 'none'),
  };
  return merged;
}

// -------------------------------------------------------------------------
// Public API ï¿½ Instagram enrichment
// -------------------------------------------------------------------------

/** First non-empty meaningful line of a caption; trimmed to maxChars. */
function firstCaptionLine(caption: string | null | undefined, maxChars = 100): string | null {
  if (!caption) return null;
  const lines = caption.split(/\r?\n/).map(l => l.trim()).filter(l => l.length > 0);
  if (lines.length === 0) return null;
  const first = lines[0];
  if (first.length <= maxChars) return first;
  return first.slice(0, maxChars).replace(/\s+\S*$/, '') + 'ï¿½';
}

// ---------------------------------------------------------------------------
// (Removed) Apify IG fallback resolver â€” the entire Apify integration
// (interfaces, resolver, queue, every-minute drainer cron) was retired in
// favor of the official Meta oEmbed flow exposed by
// fetchInstagramLegalEnrichment.
// ---------------------------------------------------------------------------

export async function fetchInstagramEnrichment(
  rawUrl: string,
  options?: {
    prefetched?: PrefetchedSocialPayload | null;
    instagramOEmbedAccessToken?: string | null;
    groqApiKey?: string | null;
  } & SocialMediaProcessingOptions,
): Promise<SocialEnrichmentResult> {
  return fetchInstagramLegalEnrichment(rawUrl, {
    accessToken: options?.instagramOEmbedAccessToken || null,
  });
}

export async function fetchInstagramLegalEnrichment(
  rawUrl: string,
  options?: { accessToken?: string | null },
): Promise<SocialEnrichmentResult> {
  const parsed = extractInstagramShortcode(rawUrl);
  const shortcode = parsed?.shortcode;
  const postType = parsed?.postType || 'post';
  const canonicalUrl = parsed?.canonicalUrl || rawUrl;
  const oembed = await fetchInstagramOEmbed(canonicalUrl, options?.accessToken || null);
  const provider = oembed?.provider_name || 'Instagram';
  const author = (oembed?.author_name || '').trim() || null;
  const thumbnailUrl = (oembed?.thumbnail_url || '').trim() || null;
  const title = author
    ? `Instagram ${postType === 'reel' ? 'Reel' : postType === 'igtv' ? 'Video' : 'Post'} by @${author.replace(/^@/, '')}`
    : `Instagram ${postType === 'reel' ? 'Reel' : postType === 'igtv' ? 'Video' : 'Post'}`;

  const lines: string[] = [
    `# ${title}`,
    '',
    `**Source app:** Instagram`,
    `**Type:** ${postType}`,
    `**Source:** ${canonicalUrl}`,
  ];
  if (author) lines.splice(2, 0, `**Author:** @${author.replace(/^@/, '')}`);
  if (provider) lines.push(`**Provider:** ${provider}`);
  lines.push('', '_Instagram preview is rendered from official oEmbed. Add your own description to make this snap searchable._');

  return {
    source: 'instagram',
    title,
    bodyMarkdown: lines.join('\n'),
    author: author || undefined,
    thumbnailUrl: thumbnailUrl || undefined,
    postType,
    enrichedFully: !!oembed,
    metadata: {
      source_app: 'instagram',
      source_url: canonicalUrl,
      shortcode: shortcode || null,
      post_type: postType,
      author: author || null,
      provider_name: provider,
      thumbnail_url: thumbnailUrl || null,
      thumbnail_source_url: thumbnailUrl || null,
      metadata_source: oembed ? 'instagram_oembed' : 'instagram_oembed_unavailable',
      embed_html: oembed?.html || null,
      oembed_version: oembed?.version || null,
      oembed_type: oembed?.type || null,
      transcript_available: false,
      transcript_source: 'not_collected_policy',
      image_content_available: false,
      apify_used: false,
    },
  };
}

interface InstagramOEmbedResponse {
  version?: string;
  type?: string;
  provider_name?: string;
  provider_url?: string;
  author_name?: string;
  author_url?: string;
  title?: string;
  html?: string;
  thumbnail_url?: string;
  thumbnail_width?: number;
  thumbnail_height?: number;
}

interface FacebookOEmbedResponse {
  version?: string;
  type?: string;
  provider_name?: string;
  provider_url?: string;
  author_name?: string;
  author_url?: string;
  title?: string;
  html?: string;
  width?: number;
  height?: number;
}

function canonicalizeFacebookUrl(rawUrl: string): string {
  try {
    const uri = new URL(rawUrl);
    const host = uri.hostname.toLowerCase().replace(/^www\./, '');
    const wrapped = extractFacebookWrappedUrl(uri);
    if (wrapped && wrapped !== rawUrl) {
      return canonicalizeFacebookUrl(wrapped);
    }
    if (host === 'fb.watch') return rawUrl;
    uri.protocol = 'https:';
    uri.hostname = 'www.facebook.com';
    for (const key of Array.from(uri.searchParams.keys())) {
      const lower = key.toLowerCase();
      if (
        lower.startsWith('utm_') ||
        lower === 'mibextid' ||
        lower === 'ref' ||
        lower === '__cft__' ||
        lower === '__tn__'
      ) {
        uri.searchParams.delete(key);
      }
    }
    return uri.toString();
  } catch {
    return rawUrl;
  }
}

function extractFacebookWrappedUrl(uri: URL): string | null {
  const host = uri.hostname.toLowerCase().replace(/^www\./, '');
  const path = uri.pathname.toLowerCase();

  const decodeParam = (key: string): string | null => {
    const value = uri.searchParams.get(key)?.trim();
    if (!value) return null;
    try {
      return decodeURIComponent(value);
    } catch {
      return value;
    }
  };

  if (host === 'l.facebook.com' && path === '/l.php') {
    return decodeParam('u');
  }

  if (path === '/share.php' || path === '/sharer.php') {
    return decodeParam('u');
  }

  if (path.startsWith('/login/') || path.startsWith('/checkpoint/')) {
    return decodeParam('next');
  }

  return null;
}

function isFacebookShareWrapperUrl(rawUrl: string): boolean {
  try {
    const uri = new URL(rawUrl);
    const host = uri.hostname.toLowerCase().replace(/^www\./, '');
    const path = uri.pathname.toLowerCase();
    if (host === 'fb.watch') return false;
    return path.startsWith('/share/') ||
        path === '/share.php' ||
        path === '/sharer.php' ||
        (host === 'l.facebook.com' && path === '/l.php');
  } catch {
    return false;
  }
}

async function resolveFacebookCanonicalUrl(rawUrl: string): Promise<string> {
  let current = canonicalizeFacebookUrl(rawUrl);

  for (let i = 0; i < 3; i++) {
    if (!isFacebookShareWrapperUrl(current)) break;
    try {
      const resp = await fetch(current, {
        method: 'HEAD',
        redirect: 'manual',
        headers: { 'User-Agent': 'Mozilla/5.0 (compatible; InfoSnap/1.0)' },
        signal: AbortSignal.timeout(10_000),
      });
      const location = resp.headers.get('location');
      if (!location) break;
      const next = new URL(location, current).toString();
      const unwrapped = canonicalizeFacebookUrl(next);
      if (unwrapped === current) break;
      current = unwrapped;
    } catch {
      break;
    }
  }

  return current;
}

function facebookOEmbedEndpoint(canonicalUrl: string): string {
  const lower = canonicalUrl.toLowerCase();
  return lower.includes('/videos/') ||
    lower.includes('/watch/') ||
    lower.includes('/reel/') ||
    lower.includes('/share/v/') ||
    lower.includes('fb.watch/')
    ? 'oembed_video'
    : 'oembed_post';
}

async function fetchFacebookOEmbed(
  canonicalUrl: string,
  accessToken?: string | null,
): Promise<FacebookOEmbedResponse | null> {
  const token = (accessToken || '').trim();
  if (!token) {
    console.warn('[social] Facebook oEmbed skipped: access token missing');
    return null;
  }
  try {
    const endpoint = new URL(`https://graph.facebook.com/v19.0/${facebookOEmbedEndpoint(canonicalUrl)}`);
    endpoint.searchParams.set('url', canonicalUrl);
    endpoint.searchParams.set('access_token', token);
    endpoint.searchParams.set('omit_script', 'true');
    const resp = await fetch(endpoint.toString(), {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(10_000),
    });
    if (!resp.ok) {
      console.warn('[social] Facebook oEmbed failed:', resp.status, (await resp.text()).slice(0, 200));
      return null;
    }
    return await resp.json() as FacebookOEmbedResponse;
  } catch (e) {
    console.warn('[social] Facebook oEmbed threw:', e);
    return null;
  }
}

export async function fetchFacebookLegalEnrichment(
  rawUrl: string,
  options?: { accessToken?: string | null },
): Promise<SocialEnrichmentResult> {
  const canonicalUrl = await resolveFacebookCanonicalUrl(rawUrl);
  const oembed = await fetchFacebookOEmbed(canonicalUrl, options?.accessToken || null);
  const provider = oembed?.provider_name || 'Facebook';
  const author = (oembed?.author_name || '').trim() || null;
  const title = author ? `Facebook post by ${author}` : 'Facebook post';

  const lines: string[] = [
    `# ${title}`,
    '',
    `**Source app:** Facebook`,
    `**Type:** post`,
    `**Source:** ${canonicalUrl}`,
  ];
  if (author) lines.splice(2, 0, `**Author:** ${author}`);
  if (provider) lines.push(`**Provider:** ${provider}`);
  lines.push('', '_Facebook preview is rendered from Meta official embed. Add your own description to make this snap searchable._');

  return {
    source: 'facebook',
    title,
    bodyMarkdown: lines.join('\n'),
    author: author || undefined,
    postType: 'post',
    enrichedFully: !!oembed,
    metadata: {
      source_app: 'facebook',
      source_url: canonicalUrl,
      post_type: 'post',
      author: author || null,
      author_url: oembed?.author_url || null,
      provider_name: provider,
      provider_url: oembed?.provider_url || null,
      metadata_source: oembed ? 'facebook_oembed' : 'facebook_oembed_unavailable',
      embed_html: oembed?.html || null,
      oembed_version: oembed?.version || null,
      oembed_type: oembed?.type || null,
      transcript_available: false,
      transcript_source: 'not_collected_policy',
      image_content_available: false,
      thumbnail_url: null,
    },
  };
}

async function fetchInstagramOEmbed(
  canonicalUrl: string,
  accessToken?: string | null,
): Promise<InstagramOEmbedResponse | null> {
  const token = (accessToken || '').trim();
  if (!token) {
    console.warn('[social] Instagram oEmbed skipped: INSTAGRAM_OEMBED_ACCESS_TOKEN missing');
    return null;
  }
  try {
    const endpoint = new URL('https://graph.facebook.com/v19.0/instagram_oembed');
    endpoint.searchParams.set('url', canonicalUrl);
    endpoint.searchParams.set('access_token', token);
    endpoint.searchParams.set('omit_script', 'true');
    const resp = await fetch(endpoint.toString(), {
      headers: { 'Accept': 'application/json' },
      signal: AbortSignal.timeout(10_000),
    });
    if (!resp.ok) {
      console.warn('[social] Instagram oEmbed failed:', resp.status, (await resp.text()).slice(0, 200));
      return null;
    }
    return await resp.json() as InstagramOEmbedResponse;
  } catch (e) {
    console.warn('[social] Instagram oEmbed threw:', e);
    return null;
  }
}


// =============================================================================
// LinkedIn
// -----------------------------------------------------------------------------
// LinkedIn doesn't expose an oEmbed or public post API, so we scrape og:* meta
// tags from the post URL (same pattern as Instagram). Members-only / restricted
// posts return a login wall â€” we detect that and degrade to a placeholder
// instead of saving the generic LinkedIn shell image.
// =============================================================================

interface LinkedInScrape {
  caption?: string;
  author?: string;
  thumbnailUrl?: string;
  transcript?: string;
  isLoginWall: boolean;
}

/** Extract a usable identifier + canonical URL from a LinkedIn share URL. */
export function extractLinkedInPostInfo(rawUrl: string): {
  postId: string | null;
  postType: 'post' | 'article' | 'video';
  canonicalUrl: string;
} | null {
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch {
    return null;
  }
  const host = u.hostname.toLowerCase().replace(/^www\./, '');
  if (
    host !== 'linkedin.com' &&
    host !== 'm.linkedin.com' &&
    host !== 'lnkd.in' &&
    !host.endsWith('.linkedin.com')
  ) {
    return null;
  }

  // /posts/{slug}-{id}/
  const mPosts = u.pathname.match(/\/posts\/([^/?#]+)/);
  if (mPosts) {
    const slug = mPosts[1];
    const idMatch = slug.match(/(\d{10,})/);
    return {
      postId: idMatch ? idMatch[1] : slug,
      postType: 'post',
      canonicalUrl: `https://www.linkedin.com/posts/${slug}`,
    };
  }

  // /feed/update/urn:li:activity:{id}
  const mFeed = u.pathname.match(/\/feed\/update\/urn:li:activity:(\d+)/);
  if (mFeed) {
    return {
      postId: mFeed[1],
      postType: 'post',
      canonicalUrl: `https://www.linkedin.com/feed/update/urn:li:activity:${mFeed[1]}/`,
    };
  }

  // /pulse/{slug} â€” long-form article
  const mPulse = u.pathname.match(/\/pulse\/([^/?#]+)/);
  if (mPulse) {
    return {
      postId: mPulse[1],
      postType: 'article',
      canonicalUrl: `https://www.linkedin.com/pulse/${mPulse[1]}`,
    };
  }

  // lnkd.in/{shortcode} â€” keep as-is, let fetch follow redirects
  if (host === 'lnkd.in') {
    const m = u.pathname.match(/^\/([A-Za-z0-9_-]+)/);
    if (m) {
      return { postId: m[1], postType: 'post', canonicalUrl: rawUrl };
    }
  }

  return null;
}

async function fetchLinkedInHtml(canonicalUrl: string): Promise<string | null> {
  try {
    const resp = await fetch(canonicalUrl, {
      headers: {
        // Desktop UA â€” LinkedIn serves richer og tags to desktop crawlers than
        // mobile. Identifying as a known bot also helps (Twitterbot-style).
        'User-Agent':
          'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      },
      redirect: 'follow',
    });
    if (!resp.ok) return null;
    const html = await resp.text();
    if (html.length < 500) return null;
    return html;
  } catch (e) {
    console.warn('[social] LinkedIn HTML fetch failed:', e);
    return null;
  }
}

function parseLinkedInOgTags(html: string): LinkedInScrape {
  const out: LinkedInScrape = { isLoginWall: false };

  // Order-agnostic meta extractor: LinkedIn ships meta tags in both
  // `property=...content=...` and `content=...property=...` orderings, often
  // mixed within the same page. We try both.
  const readMeta = (prop: string): string | null => {
    const p = prop.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re1 = new RegExp(
      `<meta[^>]+(?:property|name)=["']${p}["'][^>]+content=["']([^"']*)["']`,
      'i',
    );
    const re2 = new RegExp(
      `<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']${p}["']`,
      'i',
    );
    const m = html.match(re1) || html.match(re2);
    return m ? decodeHtmlEntities(m[1]) : null;
  };

  const htmlToPlainText = (value: string): string => decodeHtmlEntities(value)
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|h\d|li)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\r/g, '')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/[ \t]{2,}/g, ' ')
    .trim();

  const readLinkedInTranscript = (): string | null => {
    const candidates: string[] = [];
    const transcriptBlockRe =
      /<div[^>]+class=["'][^"']*show-more-less-html__markup[^"']*["'][^>]*>\s*<h5>\s*<strong>\s*Transcript\s*<\/strong>\s*<\/h5>([\s\S]*?)<\/div>/gi;
    let match: RegExpExecArray | null;
    while ((match = transcriptBlockRe.exec(html)) !== null) {
      candidates.push(match[1]);
    }

    const looseTranscriptRe =
      /<h5>\s*<strong>\s*Transcript\s*<\/strong>\s*<\/h5>([\s\S]{40,5000}?)(?:<\/div>|<\/section>|<section\b|<button\b)/gi;
    while ((match = looseTranscriptRe.exec(html)) !== null) {
      candidates.push(match[1]);
    }

    for (const candidate of candidates) {
      const text = htmlToPlainText(candidate)
        .replace(/^Transcript\s*/i, '')
        .trim();
      if (text.length >= 40) return text;
    }
    return null;
  };

  try {
    const ogImg = readMeta('og:image') || readMeta('og:image:secure_url') || readMeta('twitter:image');
    if (ogImg) out.thumbnailUrl = ogImg;

    let caption = readMeta('og:description') || readMeta('twitter:description') || readMeta('description');
    if (caption) caption = caption.trim();

    // JSON-LD often contains the FULL post body (LinkedIn embeds an
    // `articleBody` or `description` field for Articles, and `headline`+
    // `description` for posts). Prefer it over og:description when longer.
    try {
      const ldMatches = html.match(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi);
      if (ldMatches) {
        for (const block of ldMatches) {
          const jsonText = block.replace(/^<script[^>]*>/i, '').replace(/<\/script>$/i, '').trim();
          try {
            const data = JSON.parse(jsonText);
            const candidates = Array.isArray(data) ? data : [data];
            for (const node of candidates) {
              if (!node || typeof node !== 'object') continue;
              const body = (node.articleBody || node.description || node.text || '').toString().trim();
              if (body && (!caption || body.length > caption.length)) {
                caption = body;
              }
              if (!out.author) {
                const a = node.author && (node.author.name || node.author);
                if (typeof a === 'string' && a.trim()) out.author = a.trim();
                else if (a && typeof a === 'object' && typeof a.name === 'string') out.author = a.name.trim();
              }
            }
          } catch {
            // ignore malformed JSON-LD blob
          }
        }
      }
    } catch (e) {
      console.warn('[social] LinkedIn JSON-LD parse threw:', e);
    }

    if (caption && caption.length > 0) out.caption = caption;

    const transcript = readLinkedInTranscript();
    if (transcript) {
      out.transcript = transcript;
    }

    const ogTitle = readMeta('og:title') || readMeta('twitter:title');
    if (ogTitle) {
      // og:title patterns:
      //   "First Last on LinkedIn: <first line of post>"   â† personal post
      //   "First Last | LinkedIn"                          â† profile/login wall
      //   "<Company> on LinkedIn: <text>"                  â† company post
      const onLinkedIn = ogTitle.match(/^(.+?)\s+on\s+LinkedIn(?:\s*[::]\s*([\s\S]*))?$/i);
      if (onLinkedIn) {
        if (!out.author) out.author = onLinkedIn[1].trim();
        // Title-tail is usually a truncated preview; only use it if we have
        // nothing else.
        const tail = (onLinkedIn[2] || '').trim();
        if (tail && (!out.caption || tail.length > out.caption.length)) {
          out.caption = tail;
        }
      } else if (!out.author) {
        const bar = ogTitle.split('|')[0].trim();
        if (bar.length > 0) out.author = bar;
      }
    }

    // Login-wall heuristic: LinkedIn returns the generic shell page with a
    // boilerplate og:description for members-only / signed-in-required posts.
    // We treat anything with these tell-tale phrases as "unavailable" so we
    // don't store a misleading thumbnail + sign-in caption.
    const desc = (out.caption || '').toLowerCase();
    if (
      desc.includes('sign in to see') ||
      desc.includes('sign in to view') ||
      desc.includes('join linkedin') ||
      desc.includes('join now to see') ||
      /^linkedin$/i.test(out.caption || '')
    ) {
      out.isLoginWall = true;
    }
  } catch (e) {
    console.warn('[social] LinkedIn og-tag parse threw:', e);
  }
  return out;
}

export async function fetchLinkedInEnrichment(
  rawUrl: string,
  options?: { prefetched?: PrefetchedSocialPayload | null },
): Promise<SocialEnrichmentResult> {
  void options;
  const parsed = extractLinkedInPostInfo(rawUrl);
  const postId = parsed?.postId || null;
  const postType = parsed?.postType || 'post';
  const canonicalUrl = parsed?.canonicalUrl || rawUrl;
  const title = `LinkedIn ${postType === 'article' ? 'Article' : 'Post'}`;
  const lines = [
    `# ${title}`,
    '',
    `**Type:** ${postType[0].toUpperCase() + postType.slice(1)}`,
    `**Source:** ${canonicalUrl}`,
    '',
    '## Preview',
    '',
    '_LinkedIn preview is rendered from the official LinkedIn embed where available. Add your own description to make this snap searchable._',
  ];

  return {
    source: 'linkedin',
    title,
    bodyMarkdown: lines.join('\n'),
    postType,
    enrichedFully: false,
    metadata: {
      source_app: 'linkedin',
      source_url: canonicalUrl,
      post_id: postId,
      post_type: postType,
      metadata_source: 'linkedin_official_embed',
      display_strategy: 'official_embed',
      thumbnail_url: null,
      caption: null,
      caption_chars: 0,
      caption_source: 'none',
      media_type: null,
      transcript_available: false,
      transcript_chars: 0,
      transcript_source: 'none',
      is_login_wall: false,
    },
  };
}

async function fetchLinkedInEnrichmentLegacy(
  rawUrl: string,
  options?: { prefetched?: PrefetchedSocialPayload | null },
): Promise<SocialEnrichmentResult> {
  const parsed = extractLinkedInPostInfo(rawUrl);
  const postId = parsed?.postId || null;
  const postType = parsed?.postType || 'post';
  const canonicalUrl = parsed?.canonicalUrl || rawUrl;

  // Layered fallback: client-prefetched â†’ server scrape â†’ placeholder.
  const pre = options?.prefetched || null;
  let caption: string | null = (pre?.caption || '').trim() || null;
  let author: string | null = (pre?.author || '').trim() || null;
  let thumbnailUrl: string | null = (pre?.thumbnail_url || '').trim() || null;
  let mediaType: string | null = (pre?.media_type || '').trim() || null;
  let transcript: string | null = null;
  let transcriptSource: 'linkedin_public_html' | 'none' = 'none';
  let captionSource: 'client_scrape' | 'server_json' | 'og_tags' | 'none' = caption
    ? 'client_scrape'
    : 'none';
  let isLoginWall = false;

  const needsServerFill = !caption || !author || !thumbnailUrl || !transcript;
  if (needsServerFill) {
    try {
      const html = await fetchLinkedInHtml(canonicalUrl);
      if (html) {
        const scrape = parseLinkedInOgTags(html);
        isLoginWall = scrape.isLoginWall;
        if (!isLoginWall) {
          if (!caption && scrape.caption) {
            caption = scrape.caption;
            captionSource = 'og_tags';
          }
          if (!author && scrape.author) author = scrape.author;
          if (!thumbnailUrl && scrape.thumbnailUrl) thumbnailUrl = scrape.thumbnailUrl;
          if (!transcript && scrape.transcript) {
            transcript = scrape.transcript;
            transcriptSource = 'linkedin_public_html';
            mediaType = mediaType || 'video';
          }
        } else {
          // Login wall: discard the generic LinkedIn shell image / description.
          // We keep the URL so the snap is still openable, but render as a
          // text tile in the app.
          console.log('[social] LinkedIn: login-wall detected, dropping og fields');
          thumbnailUrl = null;
        }
      }
    } catch (e) {
      console.warn('[social] LinkedIn server fallback threw:', e);
    }
  } else {
    console.log('[social] LinkedIn: using client-prefetched payload only (no server fill needed)');
  }

  // Title heuristic: caption first line > author fallback > generic.
  const titleLine = firstCaptionLine(caption);
  const fallbackTitle = isLoginWall
    ? 'LinkedIn Post (sign-in required)'
    : author
      ? `LinkedIn ${postType === 'article' ? 'Article' : 'Post'} by ${author}`
      : `LinkedIn ${postType === 'article' ? 'Article' : 'Post'}`;
  const title = titleLine || fallbackTitle;

  const enrichedFully = (!!caption || !!transcript) && !isLoginWall;

  const lines: string[] = [];
  lines.push(`# ${title}`);
  lines.push('');
  if (author) lines.push(`**Author:** ${author}`);
  lines.push(`**Type:** ${postType[0].toUpperCase() + postType.slice(1)}`);
  lines.push(`**Source:** ${canonicalUrl}`);
  lines.push('');

  if (caption && !isLoginWall) {
    lines.push('## Post');
    lines.push('');
    lines.push(caption);
  } else if (isLoginWall) {
    lines.push('## Post');
    lines.push('');
    lines.push('_This LinkedIn post requires you to sign in to LinkedIn to view. Open the original link to read the full post._');
  } else {
    lines.push('## Post');
    lines.push('');
    lines.push('_Post content not available (may be private, deleted, or LinkedIn-restricted)._');
  }

  if (transcript && !isLoginWall) {
    lines.push('');
    lines.push('## Video Transcript');
    lines.push('');
    lines.push(transcript);
  }

  return {
    source: 'linkedin',
    title,
    bodyMarkdown: lines.join('\n'),
    author: author || undefined,
    thumbnailUrl: thumbnailUrl || undefined,
    postType,
    enrichedFully,
    metadata: {
      source_app: 'linkedin',
      source_url: canonicalUrl,
      post_id: postId,
      post_type: postType,
      author: author || null,
      thumbnail_url: thumbnailUrl || null,
      caption: caption || null,
      caption_chars: caption ? caption.length : 0,
      caption_source: captionSource,
      media_type: mediaType || null,
      transcript_available: !!transcript,
      transcript_chars: transcript ? transcript.length : 0,
      transcript_source: transcriptSource,
      is_login_wall: isLoginWall,
    },
  };
}

// =============================================================================
// Twitter / X
// -----------------------------------------------------------------------------
// Primary: cdn.syndication.twimg.com/tweet-result â€” the same read-only public
//   endpoint that Twitter's own embedded-tweet widget uses. No auth required;
//   the "token" is derived deterministically from the tweet id. Returns rich
//   JSON (full text, author, media, quoted tweet, â€¦).
// Fallback: publish.twitter.com oEmbed â€” author + small HTML excerpt.
// Last-ditch: scrape x.com OG tags (usually sparse since pages are JS-shell).
// =============================================================================

/** Parse a Twitter/X URL into its tweet id + screen name + canonical URL. */
export function extractTweetInfo(rawUrl: string): {
  tweetId: string;
  screenName: string | null;
  canonicalUrl: string;
} | null {
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch {
    return null;
  }
  const host = u.hostname.toLowerCase().replace(/^www\./, '').replace(/^mobile\./, '');
  if (host !== 'twitter.com' && host !== 'x.com' && !host.endsWith('.twitter.com') && !host.endsWith('.x.com')) {
    return null;
  }
  // Common path shapes:
  //   /<screen_name>/status/<id>
  //   /<screen_name>/status/<id>/photo/1
  //   /i/status/<id>
  //   /i/web/status/<id>
  const parts = u.pathname.split('/').filter(Boolean);
  let tweetId: string | null = null;
  let screenName: string | null = null;
  const statusIdx = parts.indexOf('status');
  if (statusIdx >= 0 && parts[statusIdx + 1]) {
    tweetId = parts[statusIdx + 1];
    if (statusIdx > 0 && parts[statusIdx - 1] !== 'i' && parts[statusIdx - 1] !== 'web') {
      screenName = parts[statusIdx - 1];
    } else if (parts[0] === 'i' && parts[1] === 'web' && parts[2] === 'status' && parts[3]) {
      tweetId = parts[3];
    }
  }
  if (!tweetId || !/^\d{5,25}$/.test(tweetId)) return null;
  const canonicalUrl = screenName
    ? `https://twitter.com/${screenName}/status/${tweetId}`
    : `https://twitter.com/i/status/${tweetId}`;
  return { tweetId, screenName, canonicalUrl };
}

/**
 * Compute the syndication-API token from a tweet id. This formula is the same
 * one the official Twitter embed widget uses (and react-tweet, etc.). Without
 * a valid token the endpoint returns 404.
 */
function getTwitterSyndicationToken(tweetId: string): string {
  // Cast to Number is safe for the high-order arithmetic â€” the formula does
  // not need bit-exact precision; the API only checks that it round-trips.
  return ((Number(tweetId) / 1e15) * Math.PI)
    .toString(36)
    .replace(/(0+|\.)/g, '');
}

interface TwitterSyndicationResponse {
  __typename?: string;
  id_str?: string;
  text?: string;
  created_at?: string;
  lang?: string;
  favorite_count?: number;
  conversation_count?: number;
  display_text_range?: [number, number];
  user?: {
    name?: string;
    screen_name?: string;
    profile_image_url_https?: string;
    verified?: boolean;
    is_blue_verified?: boolean;
  };
  entities?: {
    urls?: Array<{ url?: string; expanded_url?: string; display_url?: string }>;
  };
  mediaDetails?: Array<{
    type?: 'photo' | 'video' | 'animated_gif';
    media_url_https?: string;
    video_info?: { variants?: Array<{ bitrate?: number; url?: string; content_type?: string }> };
  }>;
  photos?: Array<{ url?: string }>;
  in_reply_to_screen_name?: string;
  in_reply_to_status_id_str?: string;
  quoted_tweet?: TwitterSyndicationResponse;
  tombstone?: { text?: { text?: string } };
}

/** Fetch + parse a tweet via the public syndication endpoint. Returns null on any failure. */
export async function fetchTwitterSyndication(tweetId: string): Promise<TwitterSyndicationResponse | null> {
  const token = getTwitterSyndicationToken(tweetId);
  const url = `https://cdn.syndication.twimg.com/tweet-result?id=${encodeURIComponent(tweetId)}&token=${encodeURIComponent(token)}&lang=en`;
  try {
    const resp = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9',
      },
      signal: AbortSignal.timeout(8_000),
    });
    if (!resp.ok) {
      console.warn(`[social] Twitter syndication ${tweetId} â†’ ${resp.status}`);
      return null;
    }
    const json = (await resp.json()) as TwitterSyndicationResponse;
    return json || null;
  } catch (e) {
    console.warn('[social] Twitter syndication fetch threw:', e);
    return null;
  }
}

/** Expand t.co shortlinks in tweet text using the entities table; also drop the */
/** trailing t.co that represents an attached media item.                         */
function expandTweetText(syn: TwitterSyndicationResponse): string {
  let text = syn.text || '';
  const urls = syn.entities?.urls || [];
  for (const e of urls) {
    if (e.url && e.expanded_url) {
      text = text.split(e.url).join(e.expanded_url);
    }
  }
  // Trailing media t.co (not in entities.urls) â€” only strip when media is attached.
  if (syn.mediaDetails && syn.mediaDetails.length > 0) {
    text = text.replace(/\s*https?:\/\/t\.co\/\S+\s*$/i, '').trimEnd();
  }
  return text.trim();
}

/** Pick the lowest-bitrate MP4 variant so Whisper gets the smallest usable file. */
function lowestBitrateMp4Variant(mediaDetail: NonNullable<TwitterSyndicationResponse['mediaDetails']>[number]): {
  url: string;
  bitrate: number | null;
} | null {
  const variants = mediaDetail.video_info?.variants || [];
  let best: { bitrate: number; url: string } | null = null;
  for (const v of variants) {
    if (v.content_type === 'video/mp4' && v.url) {
      const b = typeof v.bitrate === 'number' && v.bitrate > 0 ? v.bitrate : Number.MAX_SAFE_INTEGER;
      if (!best || b < best.bitrate) best = { bitrate: b, url: v.url };
    }
  }
  if (!best) return null;
  return {
    url: best.url,
    bitrate: best.bitrate === Number.MAX_SAFE_INTEGER ? null : best.bitrate,
  };
}

async function fetchTwitterOembed(canonicalUrl: string): Promise<{ author: string | null; html: string | null } | null> {
  const url = `https://publish.twitter.com/oembed?url=${encodeURIComponent(canonicalUrl)}&omit_script=1&dnt=true`;
  try {
    const resp = await fetch(url, {
      headers: { 'User-Agent': 'Mozilla/5.0 NotesApp/1.0', 'Accept': 'application/json' },
      signal: AbortSignal.timeout(6_000),
    });
    if (!resp.ok) return null;
    const j = (await resp.json()) as { author_name?: string; html?: string };
    return { author: (j.author_name || '').trim() || null, html: j.html || null };
  } catch {
    return null;
  }
}

/**
 * Download a video file and transcribe it via Groq Whisper Large v3 Turbo.
 * Returns null on any failure (network, size cap, Whisper error, â€¦).
 *   - Hard cap 20 MB (Groq Whisper limit is 25 MB; we leave headroom for the
 *     multipart envelope).
 *   - Hard cap 15 s on fetch and 20 s on Whisper.
 */
function isUsefulWhisperTranscript(text: string): boolean {
  const clean = text.trim();
  if (!clean) return false;
  // Whisper can emit timestamp-like noise such as "00 00 00" for silent clips.
  return /\p{L}/u.test(clean);
}

export async function transcribeVideoWithWhisper(
  mp4Url: string,
  groqApiKey: string,
): Promise<{ text: string; durationSec: number | null } | null> {
  const MAX_BYTES = 20 * 1024 * 1024;
  try {
    const videoResp = await fetch(mp4Url, { signal: AbortSignal.timeout(15_000) });
    if (!videoResp.ok) {
      console.warn(`[social] video fetch failed: HTTP ${videoResp.status}`);
      return null;
    }
    // Cheap early-exit on Content-Length when present.
    const cl = videoResp.headers.get('content-length');
    if (cl && Number(cl) > MAX_BYTES) {
      console.warn(`[social] video too large (${cl} bytes), skipping transcription`);
      return null;
    }
    const buf = await videoResp.arrayBuffer();
    if (buf.byteLength > MAX_BYTES) {
      console.warn(`[social] video too large (${buf.byteLength} bytes), skipping transcription`);
      return null;
    }
    if (buf.byteLength < 1024) {
      // Suspiciously small â€” likely an error page.
      return null;
    }

    const fd = new FormData();
    fd.append('file', new Blob([buf], { type: 'video/mp4' }), 'video.mp4');
    fd.append('model', 'whisper-large-v3-turbo');
    fd.append('response_format', 'verbose_json');
    fd.append('temperature', '0');

    const whisperResp = await fetch('https://api.groq.com/openai/v1/audio/transcriptions', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${groqApiKey}` },
      body: fd,
      signal: AbortSignal.timeout(20_000),
    });
    if (!whisperResp.ok) {
      const errText = await whisperResp.text().catch(() => '');
      console.warn(`[social] Whisper transcribe failed: HTTP ${whisperResp.status} ${errText.slice(0, 200)}`);
      return null;
    }
    const j = (await whisperResp.json()) as { text?: string; duration?: number };
    const text = (j.text || '').trim();
    if (!isUsefulWhisperTranscript(text)) return null;
    return {
      text,
      durationSec: typeof j.duration === 'number' ? j.duration : null,
    };
  } catch (e) {
    console.warn('[social] Whisper transcription threw:', e);
    return null;
  }
}

/**
 * High-level Twitter/X enricher. Layered fallback:
 *   1. Client-prefetched payload (rare for tweets but supported for parity)
 *   2. cdn.syndication.twimg.com â€” full content + media (primary)
 *   3. publish.twitter.com/oembed â€” author + html excerpt (fallback)
 *
 * If the tweet has a video AND `options.groqApiKey` is provided, we'll also
 * fetch the MP4 and run it through Groq Whisper for a transcript.
 */
export async function fetchTwitterEnrichment(
  rawUrl: string,
  _options?: { prefetched?: PrefetchedSocialPayload | null },
): Promise<SocialEnrichmentResult> {
  const parsed = extractTweetInfo(rawUrl);
  const tweetId = parsed?.tweetId || null;
  const canonicalUrl = parsed?.canonicalUrl || rawUrl;

  return {
    source: 'twitter',
    title: 'Tweet',
    bodyMarkdown: [
      '# Tweet',
      '',
      '**Source app:** X / Twitter',
      `**Source:** ${canonicalUrl}`,
      '',
      '## Searchable context',
      '',
      'This snap stores the original tweet link. Add a tag and your own description so Snapbot can find it later.',
    ].join('\n'),
    postType: 'tweet',
    enrichedFully: false,
    metadata: {
      source_app: 'twitter',
      source_url: canonicalUrl,
      tweet_id: tweetId,
      metadata_source: 'url_only_no_paid_api',
      display_strategy: 'official_embed',
      screen_name: parsed?.screenName || null,
      thumbnail_url: null,
      caption: null,
    },
  };
}

async function fetchTwitterEnrichmentLegacy(
  rawUrl: string,
  options?: { prefetched?: PrefetchedSocialPayload | null; groqApiKey?: string | null },
): Promise<SocialEnrichmentResult> {
  const parsed = extractTweetInfo(rawUrl);
  const tweetId = parsed?.tweetId || null;
  const canonicalUrl = parsed?.canonicalUrl || rawUrl;
  const screenNameFromUrl = parsed?.screenName || null;

  const pre = options?.prefetched || null;
  let caption: string | null = (pre?.caption || '').trim() || null;
  let author: string | null = (pre?.author || '').trim() || null;
  let screenName: string | null = screenNameFromUrl;
  let thumbnailUrl: string | null = (pre?.thumbnail_url || '').trim() || null;
  let captionSource: 'client_scrape' | 'syndication' | 'oembed' | 'none' = caption ? 'client_scrape' : 'none';

  let syn: TwitterSyndicationResponse | null = null;
  let mediaPhotos: string[] = [];
  let mediaVideos: string[] = [];
  let mediaVideoVariants: Array<{ url: string; bitrate: number | null; media_type: string }> = [];
  let animatedGifCount = 0;
  let createdAt: string | null = null;
  let likeCount: number | null = null;
  let replyCount: number | null = null;
  let inReplyTo: string | null = null;
  let quoted: { author: string; text: string } | null = null;
  let isTombstone = false;
  let lang: string | null = null;

  if (tweetId) {
    syn = await fetchTwitterSyndication(tweetId);
    if (syn) {
      if (syn.__typename === 'TweetTombstone' || syn.tombstone) {
        isTombstone = true;
      } else {
        const text = expandTweetText(syn);
        if (text && !caption) {
          caption = text;
          captionSource = 'syndication';
        }
        if (syn.user?.name && !author) author = syn.user.name;
        if (syn.user?.screen_name) screenName = syn.user.screen_name;
        if (syn.user?.profile_image_url_https && !thumbnailUrl) {
          // Use a media image when available; else the profile pic.
          thumbnailUrl = syn.user.profile_image_url_https;
        }
        for (const m of syn.mediaDetails || []) {
          if (m.type === 'photo' && m.media_url_https) {
            mediaPhotos.push(m.media_url_https);
          } else if ((m.type === 'video' || m.type === 'animated_gif') && m.media_url_https) {
            // Use the poster image as the thumbnail too.
            mediaPhotos.push(m.media_url_https);
            if (m.type === 'animated_gif') {
              animatedGifCount++;
            } else {
              const v = lowestBitrateMp4Variant(m);
              if (v) {
                mediaVideos.push(v.url);
                mediaVideoVariants.push({
                  url: v.url,
                  bitrate: v.bitrate,
                  media_type: m.type || 'video',
                });
              }
            }
          }
        }
        // Prefer the first media image as thumbnail over the profile pic.
        if (mediaPhotos[0]) thumbnailUrl = mediaPhotos[0];
        createdAt = syn.created_at || null;
        likeCount = typeof syn.favorite_count === 'number' ? syn.favorite_count : null;
        replyCount = typeof syn.conversation_count === 'number' ? syn.conversation_count : null;
        inReplyTo = (syn.in_reply_to_screen_name || '').trim() || null;
        lang = (syn.lang || '').trim() || null;
        if (syn.quoted_tweet && syn.quoted_tweet.user) {
          const qText = expandTweetText(syn.quoted_tweet);
          const qAuthor = syn.quoted_tweet.user.name || syn.quoted_tweet.user.screen_name || '';
          if (qText && qAuthor) {
            quoted = { author: qAuthor, text: qText };
          }
        }
      }
    }
  }

  // Fallback: oEmbed for at least the author name.
  if ((!caption || !author) && !isTombstone) {
    const oe = await fetchTwitterOembed(canonicalUrl);
    if (oe) {
      if (!author && oe.author) author = oe.author;
      if (!caption && oe.html) {
        // The oEmbed html contains a <p>â€¦</p> with the tweet body. Strip tags.
        const m = oe.html.match(/<p[^>]*>([\s\S]*?)<\/p>/i);
        if (m && m[1]) {
          const stripped = m[1]
            .replace(/<br\s*\/?>/gi, '\n')
            .replace(/<a [^>]*href="([^"]+)"[^>]*>[^<]*<\/a>/gi, '$1')
            .replace(/<[^>]+>/g, '')
            .replace(/&amp;/g, '&')
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>')
            .replace(/&quot;/g, '"')
            .replace(/&#39;/g, "'")
            .trim();
          if (stripped) {
            caption = stripped;
            captionSource = 'oembed';
          }
        }
      }
    }
  }

  // â”€â”€ Video transcription via Groq Whisper â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Only runs if (a) there's at least one video, (b) groqApiKey was supplied,
  // and (c) the video isn't tombstoned. Cheap (~$0.0001 per minute) and falls
  // back silently to "no transcript" on any error.
  let transcript: string | null = null;
  let transcriptDurationSec: number | null = null;
  let transcriptSource: 'whisper_low_bitrate_mp4' | 'none' = 'none';
  let transcriptReason: 'success' | 'no_video' | 'no_groq_key' | 'fetch_failed' | 'animated_gif_only' | 'tombstone' | 'not_attempted' = 'not_attempted';
  if (isTombstone) {
    transcriptReason = 'tombstone';
  } else if (mediaVideos.length === 0) {
    transcriptReason = animatedGifCount > 0 ? 'animated_gif_only' : 'no_video';
  } else if (!options?.groqApiKey) {
    transcriptReason = 'no_groq_key';
  } else {
    const transcriptParts: string[] = [];
    let durationTotal = 0;
    for (let i = 0; i < Math.min(mediaVideos.length, 3); i++) {
      console.log(`[social] Twitter Whisper: transcribing low-bitrate MP4 ${i + 1}/${mediaVideos.length} bitrate=${mediaVideoVariants[i]?.bitrate ?? 'unknown'}`);
      const wh = await transcribeVideoWithWhisper(mediaVideos[i], options.groqApiKey);
      if (wh && wh.text) {
        transcriptParts.push(mediaVideos.length > 1 ? `--- Clip ${i + 1} ---\n${wh.text}` : wh.text);
        durationTotal += wh.durationSec || 0;
      }
    }
    if (transcriptParts.length > 0) {
      transcript = transcriptParts.join('\n\n');
      transcriptDurationSec = durationTotal > 0 ? durationTotal : null;
      transcriptSource = 'whisper_low_bitrate_mp4';
      transcriptReason = 'success';
    } else {
      transcriptReason = 'fetch_failed';
    }
  }

  // Title heuristic
  const titleLine = firstCaptionLine(caption);
  const handle = screenName ? `@${screenName}` : null;
  const fallbackTitle = isTombstone
    ? 'Tweet (unavailable)'
    : author
      ? `Tweet by ${author}${handle ? ` (${handle})` : ''}`
      : 'Tweet';
  const title = titleLine || fallbackTitle;

  const enrichedFully = !!caption && !isTombstone;

  const lines: string[] = [];
  lines.push(`# ${title}`);
  lines.push('');
  if (author || handle) {
    const authorLine = author && handle ? `${author} (${handle})` : (author || handle || '');
    lines.push(`**Author:** ${authorLine}`);
  }
  if (createdAt) lines.push(`**Posted:** ${createdAt}`);
  lines.push(`**Source:** ${canonicalUrl}`);
  if (inReplyTo) lines.push(`**In reply to:** @${inReplyTo}`);
  lines.push('');

  lines.push('## Tweet');
  lines.push('');
  if (caption && !isTombstone) {
    lines.push(caption);
  } else if (isTombstone) {
    lines.push('_This tweet is no longer available (it may have been deleted, withheld, or the author\'s account is protected/suspended)._');
  } else {
    lines.push('_Tweet content not available._');
  }
  lines.push('');

  if (mediaPhotos.length > 0 || mediaVideos.length > 0) {
    lines.push('## Media');
    lines.push('');
    for (const p of mediaPhotos) lines.push(`- ![image](${p})`);
    for (const v of mediaVideos) lines.push(`- ðŸŽ¬ Video: ${v}`);
    lines.push('');
  }

  if (transcript) {
    lines.push('## Transcript');
    lines.push('');
    lines.push(transcript);
    lines.push('');
  }

  if (quoted) {
    lines.push('## Quoted tweet');
    lines.push('');
    lines.push(`> ${quoted.text.split('\n').join('\n> ')}`);
    lines.push('');
    lines.push(`â€” ${quoted.author}`);
    lines.push('');
  }

  if (likeCount !== null || replyCount !== null) {
    const stats: string[] = [];
    if (likeCount !== null) stats.push(`${likeCount} likes`);
    if (replyCount !== null) stats.push(`${replyCount} replies`);
    lines.push(`**Stats:** ${stats.join(' Â· ')}`);
  }

  const postType = 'tweet';

  return {
    source: 'twitter',
    title,
    bodyMarkdown: lines.join('\n'),
    author: author || undefined,
    thumbnailUrl: thumbnailUrl || undefined,
    postType,
    enrichedFully,
    metadata: {
      source_app: 'twitter',
      source_url: canonicalUrl,
      tweet_id: tweetId,
      screen_name: screenName,
      author_name: author || null,
      thumbnail_url: thumbnailUrl || null,
      caption: caption || null,
      caption_chars: caption ? caption.length : 0,
      caption_source: captionSource,
      created_at: createdAt,
      lang: lang,
      like_count: likeCount,
      reply_count: replyCount,
      in_reply_to_screen_name: inReplyTo,
      media_photo_urls: mediaPhotos,
      media_video_urls: mediaVideos,
      media_video_variants: mediaVideoVariants,
      animated_gif_count: animatedGifCount,
      has_quoted_tweet: !!quoted,
      is_tombstone: isTombstone,
      transcript: transcript,
      transcript_available: !!transcript,
      transcript_chars: transcript ? transcript.length : 0,
      transcript_source: transcriptSource,
      transcript_reason: transcriptReason,
      transcript_duration_sec: transcriptDurationSec,
    },
  };
}

// =============================================================================
// Reddit
// -----------------------------------------------------------------------------
// Reddit exposes a *clean* public JSON endpoint that returns the full post
// plus a forest of comments: `https://www.reddit.com/comments/<id>.json`. No
// auth needed, no scraping, no fragile HTML parsing. We just need a polite
// User-Agent string. We pull the post + top N comments and render them into a
// markdown thread that's both human-readable and great fodder for the
// embedding pipeline.
// =============================================================================

interface RedditPostInfo {
  /** 6-7 char base36 post id, no `t3_` prefix */
  postId: string;
  subreddit: string | null;
  /** Canonical https://www.reddit.com/comments/<id> URL */
  canonicalUrl: string;
}

/** Pull the post id + subreddit (if present) from any reddit URL flavour. */
export function extractRedditInfo(rawUrl: string): RedditPostInfo | null {
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch {
    return null;
  }
  const host = u.hostname.toLowerCase().replace(/^www\./, '');
  const segs = u.pathname.split('/').filter(Boolean);

  // redd.it/<id>
  if (host === 'redd.it' && segs[0]) {
    const id = segs[0];
    if (/^[a-z0-9]{4,10}$/i.test(id)) {
      return { postId: id, subreddit: null, canonicalUrl: `https://www.reddit.com/comments/${id}` };
    }
    return null;
  }

  // /r/<sub>/comments/<id>/<slug>?
  // /comments/<id>/<slug>?
  const cIdx = segs.indexOf('comments');
  if (cIdx >= 0 && segs[cIdx + 1]) {
    const id = segs[cIdx + 1];
    if (/^[a-z0-9]{4,10}$/i.test(id)) {
      const sub = segs[0] === 'r' && segs[1] ? segs[1] : null;
      return {
        postId: id,
        subreddit: sub,
        canonicalUrl: `https://www.reddit.com/comments/${id}`,
      };
    }
  }
  return null;
}

/** Resolve a Reddit short share link (e.g. /r/<sub>/s/<code> or /u/<user>/s/<code>)
 *  by following its redirect to the canonical /comments/<id> URL. Returns null
 *  if the URL isn't a share link or the redirect can't be followed. */
async function resolveRedditShareLink(rawUrl: string): Promise<string | null> {
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch {
    return null;
  }
  const host = u.hostname.toLowerCase().replace(/^www\./, '');
  if (!host.endsWith('reddit.com')) return null;
  const segs = u.pathname.split('/').filter(Boolean);
  const sIdx = segs.indexOf('s');
  // Must look like /r/<sub>/s/<code> or /u/<user>/s/<code>
  if (sIdx < 2 || !segs[sIdx + 1]) return null;

  const controller = new AbortController();
  const to = setTimeout(() => controller.abort(), 6000);
  try {
    // Reddit returns a 301/302 to the canonical /r/<sub>/comments/<id>/...
    // URL. Use manual redirect so we can read the Location header.
    const res = await fetch(rawUrl, {
      method: 'GET',
      redirect: 'manual',
      headers: {
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        accept: 'text/html,application/xhtml+xml',
        'accept-language': 'en-US,en;q=0.9',
      },
      signal: controller.signal,
    });
    const loc = res.headers.get('location');
    if (loc) {
      // Location may be absolute or path-relative.
      try {
        return new URL(loc, rawUrl).toString();
      } catch {
        return null;
      }
    }
    return null;
  } catch {
    return null;
  } finally {
    clearTimeout(to);
  }
}

interface RedditPostData {
  title: string;
  selftext: string;
  author: string;
  subreddit: string;
  subreddit_name_prefixed?: string;
  score: number;
  num_comments: number;
  created_utc: number;
  url: string;           // outbound URL (for link posts)
  permalink: string;     // /r/sub/comments/...
  post_hint?: string;    // 'image' | 'link' | 'hosted:video' | 'rich:video' | 'self'
  is_video: boolean;
  is_self: boolean;
  over_18: boolean;
  thumbnail: string;
  link_flair_text?: string | null;
  domain?: string;
  preview?: {
    images?: Array<{ source?: { url: string; width: number; height: number } }>;
  };
  secure_media?: {
    reddit_video?: RedditVideoData;
  };
  media?: {
    reddit_video?: RedditVideoData;
  };
  gallery_data?: { items: Array<{ media_id: string }> };
  media_metadata?: Record<string, { s?: { u?: string; gif?: string } }>;
  removed_by_category?: string | null;
}

interface RedditVideoData {
  fallback_url?: string;
  dash_url?: string;
  hls_url?: string;
  scrubber_media_url?: string;
  duration?: number;
  height?: number;
  width?: number;
  bitrate_kbps?: number;
  is_gif?: boolean;
  transcoding_status?: string;
}

interface RedditCommentData {
  author: string;
  body: string;
  score: number;
  created_utc: number;
  is_submitter: boolean;
  stickied: boolean;
  distinguished?: string | null;
  replies?: { data?: { children?: Array<{ kind: string; data: RedditCommentData }> } } | string;
}

/** Fetch the post + comments listing. Returns null on any failure. */
async function fetchRedditPostJson(postId: string): Promise<{
  post: RedditPostData;
  comments: RedditCommentData[];
} | null> {
  // raw_json=1 keeps URLs un-HTML-encoded (no `&amp;`). limit=20 caps comments.
  const url = `https://www.reddit.com/comments/${encodeURIComponent(postId)}.json?raw_json=1&limit=20`;
  const controller = new AbortController();
  const to = setTimeout(() => controller.abort(), 8000);
  try {
    const res = await fetch(url, {
      headers: {
        // Reddit blocks Cloudflare Worker egress IPs when the UA looks like a
        // bot/script. A normal desktop Chrome UA gets us clean 200s.
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        accept: 'application/json,text/plain,*/*',
        'accept-language': 'en-US,en;q=0.9',
      },
      signal: controller.signal,
    });
    if (!res.ok) {
      console.warn('[reddit] fetchRedditPostJson non-OK', { postId, status: res.status, url });
      return null;
    }
    const body = (await res.json()) as Array<{ data?: { children?: Array<{ kind: string; data: unknown }> } }>;
    if (!Array.isArray(body) || body.length < 1) {
      console.warn('[reddit] fetchRedditPostJson bad body shape', { postId, isArr: Array.isArray(body), len: Array.isArray(body) ? body.length : 0 });
      return null;
    }
    const postNode = body[0]?.data?.children?.[0];
    if (!postNode || postNode.kind !== 't3') {
      console.warn('[reddit] fetchRedditPostJson missing t3', { postId, kind: postNode?.kind });
      return null;
    }
    const post = postNode.data as RedditPostData;
    const comments: RedditCommentData[] = [];
    const commentNodes = body[1]?.data?.children || [];
    for (const node of commentNodes) {
      if (node.kind === 't1') comments.push(node.data as RedditCommentData);
    }
    return { post, comments };
  } catch (e) {
    console.warn('[reddit] fetchRedditPostJson threw', { postId, err: (e as Error)?.message });
    return null;
  } finally {
    clearTimeout(to);
  }
}

/** Pick the best preview image url from a Reddit post (for thumbnail). */
function bestRedditImage(post: RedditPostData): string | null {
  // Direct image post.
  if (post.post_hint === 'image' && /^https?:/.test(post.url)) return post.url;
  // i.redd.it preview
  const previewSrc = post.preview?.images?.[0]?.source?.url;
  if (previewSrc) return previewSrc;
  // Gallery
  if (post.media_metadata) {
    for (const mid of Object.keys(post.media_metadata)) {
      const u = post.media_metadata[mid]?.s?.u || post.media_metadata[mid]?.s?.gif;
      if (u) return u;
    }
  }
  // Fall back to the post's `thumbnail` only if it looks like a real URL
  // ('self', 'default', 'nsfw', 'spoiler' are placeholder strings).
  if (/^https?:/.test(post.thumbnail)) return post.thumbnail;
  return null;
}

interface RedditVideoMedia {
  videoUrl: string | null;
  dashUrl: string | null;
  hlsUrl: string | null;
  audioCandidates: Array<{ url: string; source: string; bitrate: number | null }>;
  durationSec: number | null;
  isGif: boolean;
  transcodingStatus: string | null;
}

function redditVideoData(post: RedditPostData): RedditVideoData | null {
  return post.secure_media?.reddit_video || post.media?.reddit_video || null;
}

function addRedditAudioCandidate(
  candidates: Array<{ url: string; source: string; bitrate: number | null }>,
  url: string | null | undefined,
  source: string,
  bitrate: number | null,
): void {
  const clean = (url || '').trim();
  if (!/^https?:\/\//i.test(clean)) return;
  if (candidates.some(c => c.url === clean)) return;
  candidates.push({ url: clean, source, bitrate });
}

function deriveRedditAudioCandidatesFromUrl(
  mediaUrl: string | null,
  source: string,
): Array<{ url: string; source: string; bitrate: number | null }> {
  const out: Array<{ url: string; source: string; bitrate: number | null }> = [];
  if (!mediaUrl) return out;
  try {
    const u = new URL(mediaUrl);
    const names: Array<[string, number]> = [
      ['DASH_AUDIO_64.mp4', 64],
      ['DASH_AUDIO_128.mp4', 128],
      ['DASH_AUDIO.mp4', 128],
    ];
    for (const [name, bitrate] of names) {
      const candidate = new URL(name, u);
      candidate.search = '';
      addRedditAudioCandidate(out, candidate.toString(), source, bitrate);
    }
  } catch {
    // Ignore malformed media URLs; caller still has the original fallback URL.
  }
  return out;
}

async function fetchRedditDashAudioCandidates(
  dashUrl: string | null,
): Promise<Array<{ url: string; source: string; bitrate: number | null }>> {
  if (!dashUrl) return [];
  const controller = new AbortController();
  const to = setTimeout(() => controller.abort(), 6000);
  try {
    const resp = await fetch(dashUrl, {
      headers: {
        'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        accept: 'application/dash+xml,application/xml,text/xml,*/*',
      },
      signal: controller.signal,
    });
    if (!resp.ok) {
      console.warn('[reddit] DASH manifest fetch non-OK', { status: resp.status, dashUrl });
      return [];
    }
    const mpd = await resp.text();
    const out: Array<{ url: string; source: string; bitrate: number | null }> = [];
    const adaptationRe = /<AdaptationSet\b[^>]*>[\s\S]*?<\/AdaptationSet>/gi;
    const representationRe = /<Representation\b([^>]*)>([\s\S]*?)<\/Representation>/gi;
    for (const adaptationMatch of mpd.matchAll(adaptationRe)) {
      const adaptation = adaptationMatch[0];
      if (!/mimeType=["']audio\/mp4["']|contentType=["']audio["']/i.test(adaptation)) continue;
      for (const repMatch of adaptation.matchAll(representationRe)) {
        const attrs = repMatch[1] || '';
        const body = repMatch[2] || '';
        const baseMatch = body.match(/<BaseURL>([\s\S]*?)<\/BaseURL>/i);
        if (!baseMatch) continue;
        const rawBase = decodeHtmlEntities(baseMatch[1].trim());
        const bitrateMatch = attrs.match(/\bbandwidth=["'](\d+)["']/i);
        const bitrate = bitrateMatch ? Math.round(Number(bitrateMatch[1]) / 1000) : null;
        try {
          const absolute = new URL(rawBase, dashUrl).toString();
          addRedditAudioCandidate(out, absolute, 'dash_manifest_audio', bitrate);
        } catch {
          // Skip invalid BaseURL entries.
        }
      }
    }
    return out.sort((a, b) => (a.bitrate ?? Number.MAX_SAFE_INTEGER) - (b.bitrate ?? Number.MAX_SAFE_INTEGER));
  } catch (e) {
    console.warn('[reddit] DASH manifest fetch threw', { dashUrl, err: (e as Error)?.message });
    return [];
  } finally {
    clearTimeout(to);
  }
}

async function redditVideoMedia(post: RedditPostData): Promise<RedditVideoMedia> {
  const rv = redditVideoData(post);
  const videoUrl = (rv?.fallback_url || '').trim() || null;
  const dashUrl = (rv?.dash_url || '').trim() || null;
  const hlsUrl = (rv?.hls_url || '').trim() || null;
  const audioCandidates: Array<{ url: string; source: string; bitrate: number | null }> = [];

  for (const c of deriveRedditAudioCandidatesFromUrl(dashUrl, 'dash_url_derived_audio')) {
    addRedditAudioCandidate(audioCandidates, c.url, c.source, c.bitrate);
  }
  for (const c of deriveRedditAudioCandidatesFromUrl(videoUrl, 'fallback_url_derived_audio')) {
    addRedditAudioCandidate(audioCandidates, c.url, c.source, c.bitrate);
  }
  for (const c of await fetchRedditDashAudioCandidates(dashUrl)) {
    addRedditAudioCandidate(audioCandidates, c.url, c.source, c.bitrate);
  }
  audioCandidates.sort((a, b) => (a.bitrate ?? Number.MAX_SAFE_INTEGER) - (b.bitrate ?? Number.MAX_SAFE_INTEGER));

  return {
    videoUrl,
    dashUrl,
    hlsUrl,
    audioCandidates,
    durationSec: typeof rv?.duration === 'number' ? rv.duration : null,
    isGif: !!rv?.is_gif,
    transcodingStatus: (rv?.transcoding_status || '').trim() || null,
  };
}

/** Flatten a comment forest depth-first. Returns up to `limit` top-level
 *  comments rendered as `> body â€” u/author (Nx)` blocks. */
function renderTopComments(comments: RedditCommentData[], limit = 8): string[] {
  // Filter out "[deleted]" / "[removed]" stub comments and stickied automod.
  const usable = comments.filter(c => {
    if (!c || !c.body) return false;
    const b = c.body.trim();
    if (b === '[deleted]' || b === '[removed]') return false;
    if (c.stickied && c.author?.toLowerCase() === 'automoderator') return false;
    return true;
  });
  // Already sorted by Reddit (default = "confidence/best"). Take top N.
  const top = usable.slice(0, limit);
  const out: string[] = [];
  for (const c of top) {
    const body = c.body.trim().split('\n').map(l => `> ${l}`).join('\n');
    const opTag = c.is_submitter ? ' **(OP)**' : '';
    const modTag = c.distinguished === 'moderator' ? ' **(mod)**' : '';
    const score = typeof c.score === 'number' ? ` Â· ${c.score} pts` : '';
    out.push(`${body}\n>\n> â€” u/${c.author}${opTag}${modTag}${score}`);
  }
  return out;
}

async function fetchRedditOAuthToken(clientId: string, clientSecret: string): Promise<string | null> {
  try {
    const body = new URLSearchParams({ grant_type: 'client_credentials' });
    const resp = await fetch('https://www.reddit.com/api/v1/access_token', {
      method: 'POST',
      headers: {
        'Authorization': `Basic ${btoa(`${clientId}:${clientSecret}`)}`,
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'InfoSnap/1.0 by InfoSnap',
      },
      body,
      signal: AbortSignal.timeout(8_000),
    });
    if (!resp.ok) {
      console.warn('[social] Reddit OAuth token failed', { status: resp.status });
      return null;
    }
    const json = await resp.json() as { access_token?: string };
    return (json.access_token || '').trim() || null;
  } catch (e) {
    console.warn('[social] Reddit OAuth token threw:', e);
    return null;
  }
}

export async function fetchRedditEnrichment(
  rawUrl: string,
  _options?: {
    prefetched?: PrefetchedSocialPayload | null;
    youtubeApiKey?: string | null;
  },
): Promise<SocialEnrichmentResult> {
  let parsed = extractRedditInfo(rawUrl);
  if (!parsed?.postId) {
    const resolved = await resolveRedditShareLink(rawUrl);
    if (resolved) parsed = extractRedditInfo(resolved);
  }

  const postId = parsed?.postId || null;
  const canonicalUrl = parsed?.canonicalUrl || rawUrl;
  const subreddit = parsed?.subreddit || null;
  const title = subreddit ? `Reddit post in r/${subreddit}` : 'Reddit post';

  return {
    source: 'reddit',
    title,
    bodyMarkdown: [
      `# ${title}`,
      '',
      '**Source app:** Reddit',
      subreddit ? `**Subreddit:** r/${subreddit}` : null,
      `**Source:** ${canonicalUrl}`,
      '',
      '## Searchable context',
      '',
      'This snap stores the original Reddit link. Add a tag and your own description so Snapbot can find it later.',
    ].filter(Boolean).join('\n'),
    postType: 'post',
    enrichedFully: false,
    metadata: {
      source_app: 'reddit',
      source_url: canonicalUrl,
      post_id: postId,
      metadata_source: 'url_only_no_commercial_api',
      display_strategy: 'official_embed',
      subreddit,
      thumbnail_url: null,
      caption: null,
    },
  };
}

async function fetchRedditEnrichmentLegacy(
  rawUrl: string,
  options?: { prefetched?: PrefetchedSocialPayload | null; groqApiKey?: string | null; youtubeApiKey?: string | null },
): Promise<SocialEnrichmentResult> {
  const parsed = extractRedditInfo(rawUrl);
  let postId = parsed?.postId || null;
  let canonicalUrl = parsed?.canonicalUrl || rawUrl;
  let subFromUrl = parsed?.subreddit || null;

  // If this is a /s/<code> share link, follow the redirect and re-parse.
  if (!postId) {
    const resolved = await resolveRedditShareLink(rawUrl);
    if (resolved) {
      const reparsed = extractRedditInfo(resolved);
      if (reparsed?.postId) {
        postId = reparsed.postId;
        canonicalUrl = reparsed.canonicalUrl;
        subFromUrl = reparsed.subreddit;
      }
    }
  }

  const pre = options?.prefetched || null;
  let title: string | null = (pre?.caption || '').trim() || null;
  let author: string | null = (pre?.author || '').trim() || null;
  let thumbnailUrl: string | null = (pre?.thumbnail_url || '').trim() || null;

  let post: RedditPostData | null = null;
  let comments: RedditCommentData[] = [];
  let captionSource: 'client_scrape' | 'reddit_json' | 'none' = title ? 'client_scrape' : 'none';

  if (postId) {
    const fetched = await fetchRedditPostJson(postId);
    if (fetched) {
      post = fetched.post;
      comments = fetched.comments;
      if (!title && post.title) {
        title = post.title;
        captionSource = 'reddit_json';
      }
      if (!author && post.author) author = post.author;
      if (!thumbnailUrl) thumbnailUrl = bestRedditImage(post);
    }
  }

  const subreddit = post?.subreddit || subFromUrl || null;
  const isRemoved = !!post?.removed_by_category;
  const videoMedia = post ? await redditVideoMedia(post) : null;
  const videoUrl = videoMedia?.videoUrl || null;
  const isVideo = !!post?.is_video || !!videoUrl || !!videoMedia?.dashUrl || !!videoMedia?.hlsUrl;
  const isImagePost = post?.post_hint === 'image';
  const isLinkPost = post?.post_hint === 'link' || (post && !post.is_self && !post.is_video && post.post_hint !== 'image');
  const outboundUrl = post && !post.is_self ? post.url : null;
  const flair = (post?.link_flair_text || '').trim() || null;
  const score = typeof post?.score === 'number' ? post!.score : null;
  const numComments = typeof post?.num_comments === 'number' ? post!.num_comments : null;
  const createdAtIso = post?.created_utc ? new Date(post.created_utc * 1000).toISOString() : null;

  // Determine post type for UI hints.
  let postType = 'post';
  if (isVideo) postType = 'video';
  else if (isImagePost) postType = 'image';
  else if (isLinkPost) postType = 'link';
  else if (post?.is_self) postType = 'text';

  // Title fallback
  const fallbackTitle = isRemoved
    ? 'Reddit post (removed)'
    : subreddit
      ? `Post in r/${subreddit}`
      : 'Reddit post';
  const finalTitle = title || fallbackTitle;

  const enrichedFully = !!post && !isRemoved && !!title;

  // â”€â”€ Reddit-hosted video transcription via Groq Whisper â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Only when post has a reddit_video fallback URL and groqApiKey supplied.
  // The `?source=fallback` MP4 is a muxed audio+video stream (legacy fallback
  // for clients that can't play DASH/HLS) so Whisper can read the audio.
  let redditTranscript: string | null = null;
  let redditTranscriptDurationSec: number | null = null;
  let redditTranscriptSource: string | null = null;
  let redditTranscriptReason: 'success' | 'removed' | 'gif' | 'no_video' | 'no_groq_key' | 'fetch_failed' | 'not_attempted' = 'not_attempted';
  let redditAudioUrl: string | null = null;
  if (isRemoved) {
    redditTranscriptReason = 'removed';
  } else if (!isVideo) {
    redditTranscriptReason = 'no_video';
  } else if (videoMedia?.isGif) {
    redditTranscriptReason = 'gif';
  } else if (!options?.groqApiKey) {
    redditTranscriptReason = 'no_groq_key';
  } else {
    const candidates = [
      ...(videoMedia?.audioCandidates || []),
      ...(videoUrl ? [{ url: videoUrl, source: 'fallback_video_mp4', bitrate: null }] : []),
    ];
    for (const candidate of candidates.slice(0, 4)) {
      console.log(`[reddit] Whisper: trying ${candidate.source} bitrate=${candidate.bitrate ?? 'unknown'}`);
      const wh = await transcribeVideoWithWhisper(candidate.url, options.groqApiKey);
      if (wh && wh.text) {
        redditTranscript = wh.text;
        redditTranscriptDurationSec = wh.durationSec;
        redditTranscriptSource = candidate.source;
        redditAudioUrl = candidate.url;
        redditTranscriptReason = 'success';
        break;
      }
    }
    if (!redditTranscript) redditTranscriptReason = 'fetch_failed';
  }

  // â”€â”€ Outbound YouTube chain â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // When a Reddit post links out to a YouTube video, run that URL through the
  // YouTube enricher so we capture the title, description, and (if available)
  // transcript. Cheap â€” InnerTube call only when needed.
  let youtubeChain: SocialEnrichmentResult | null = null;
  if (!isRemoved && outboundUrl) {
    const outDomain = (post?.domain || '').toLowerCase();
    const isYt =
      outDomain.includes('youtube.com') ||
      outDomain === 'youtu.be' ||
      /(^|\.)(youtube\.com|youtu\.be)/.test(outDomain);
    if (isYt) {
      try {
        youtubeChain = await fetchYouTubeLegalEnrichment(outboundUrl, { youtubeApiKey: options?.youtubeApiKey || null });
      } catch (e) {
        console.warn('[reddit] youtube chain failed:', (e as Error)?.message);
      }
    }
  }

  // Render markdown body.
  const lines: string[] = [];
  lines.push(`# ${finalTitle}`);
  lines.push('');
  if (subreddit) lines.push(`**Subreddit:** r/${subreddit}`);
  if (author) lines.push(`**Author:** u/${author}`);
  if (flair) lines.push(`**Flair:** ${flair}`);
  if (createdAtIso) lines.push(`**Posted:** ${createdAtIso}`);
  lines.push(`**Source:** ${canonicalUrl}`);
  if (outboundUrl && outboundUrl !== canonicalUrl) {
    lines.push(`**Link:** ${outboundUrl}`);
  }
  lines.push('');

  // Body / selftext
  if (post?.selftext && post.selftext.trim()) {
    lines.push('## Post');
    lines.push('');
    lines.push(post.selftext.trim());
    lines.push('');
  } else if (isRemoved) {
    lines.push('## Post');
    lines.push('');
    lines.push(`_This post was removed (${post?.removed_by_category})._`);
    lines.push('');
  }

  // Media
  if (thumbnailUrl || videoUrl) {
    lines.push('## Media');
    lines.push('');
    if (thumbnailUrl) lines.push(`- ![image](${thumbnailUrl})`);
    if (videoUrl) lines.push(`- ðŸŽ¬ Video: ${videoUrl}`);
    lines.push('');
  }

  // Reddit video transcript (Whisper)
  if (redditTranscript) {
    lines.push('## Video transcript');
    lines.push('');
    lines.push(redditTranscript);
    lines.push('');
  }

  // Linked YouTube content
  if (youtubeChain) {
    lines.push('## Linked YouTube content');
    lines.push('');
    // Strip the leading "# Title" heading from the chained body to avoid
    // a duplicate H1 in the merged note.
    const chainBody = (youtubeChain.bodyMarkdown || '').replace(/^#\s+[^\n]*\n+/, '').trim();
    if (chainBody) {
      lines.push(chainBody);
      lines.push('');
    }
  }

  // Top comments
  const rendered = renderTopComments(comments, 8);
  if (rendered.length > 0) {
    lines.push(`## Top comments`);
    lines.push('');
    for (const block of rendered) {
      lines.push(block);
      lines.push('');
    }
  }

  // Stats footer
  if (score !== null || numComments !== null) {
    const stats: string[] = [];
    if (score !== null) stats.push(`${score} upvotes`);
    if (numComments !== null) stats.push(`${numComments} comments`);
    lines.push(`**Stats:** ${stats.join(' Â· ')}`);
  }

  return {
    source: 'reddit',
    title: finalTitle,
    bodyMarkdown: lines.join('\n'),
    author: author || undefined,
    thumbnailUrl: thumbnailUrl || undefined,
    postType,
    enrichedFully,
    metadata: {
      source_app: 'reddit',
      source_url: canonicalUrl,
      post_id: postId,
      subreddit: subreddit,
      author_name: author || null,
      thumbnail_url: thumbnailUrl || null,
      title: post?.title || title || null,
      selftext: post?.selftext || null,
      selftext_chars: post?.selftext ? post.selftext.length : 0,
      caption_source: captionSource,
      created_at: createdAtIso,
      score: score,
      num_comments: numComments,
      flair: flair,
      post_hint: post?.post_hint || null,
      post_type: postType,
      is_self: post?.is_self ?? null,
      is_video: isVideo,
      over_18: post?.over_18 ?? null,
      outbound_url: outboundUrl,
      outbound_domain: post?.domain || null,
      media_video_url: videoUrl,
      media_dash_url: videoMedia?.dashUrl || null,
      media_hls_url: videoMedia?.hlsUrl || null,
      reddit_audio_url: redditAudioUrl,
      reddit_audio_candidates: videoMedia?.audioCandidates || [],
      reddit_video_duration_sec: videoMedia?.durationSec || null,
      reddit_video_transcoding_status: videoMedia?.transcodingStatus || null,
      top_comments_rendered: rendered.length,
      is_removed: isRemoved,
      reddit_transcript_available: !!redditTranscript,
      reddit_transcript_chars: redditTranscript ? redditTranscript.length : 0,
      reddit_transcript_duration_sec: redditTranscriptDurationSec,
      reddit_transcript_source: redditTranscriptSource,
      reddit_transcript_reason: redditTranscriptReason,
      linked_youtube_url: youtubeChain ? outboundUrl : null,
      linked_youtube_title: youtubeChain?.title || null,
      linked_youtube_transcript_chars: youtubeChain
        ? ((youtubeChain.metadata as Record<string, unknown> | undefined)?.transcript_chars as number | undefined) || 0
        : 0,
    },
  };
}

// =============================================================================
// Unified dispatcher (Refinement #10)
// -----------------------------------------------------------------------------
// Single entry-point so upload-routes doesn''t need to know each platform''s
// option shape. Adding a new platform = adding one case here + an enricher.
// =============================================================================
export async function fetchSocialEnrichment(
  source: SocialSource,
  rawUrl: string,
  prefetched?: PrefetchedSocialPayload | null,
  /** Platform-specific extras that don''t fit the generic envelope (YT''s
   * giant transcript string is too big to belong in metadata). */
  extras?: {
    youtubeTranscript?: string | null;
    youtubeDescription?: string | null;
    /** Audio-stream URL from the client's WebView scrape â€” Whisper fallback. */
    youtubeAudioUrl?: string | null;
    /** Video length in seconds reported by the client. */
    youtubeDurationSec?: number | null;
    /** Official YouTube Data API key for policy-compliant metadata. */
    youtubeApiKey?: string | null;
    /** Official Meta token for Instagram oEmbed previews. */
    instagramOEmbedAccessToken?: string | null;
    /** Official Meta token for Facebook oEmbed previews. */
    facebookOEmbedAccessToken?: string | null;
    /** Used by Twitter/Reddit/YouTube for in-Worker video transcription. */
    groqApiKey?: string | null;
    /** Used by Instagram image/carousel OCR through Azure Blob + TensorLake. */
    userId?: string | null;
    azureConnectionString?: string | null;
    azureContainer?: string | null;
    tensorlakeApiKey?: string | null;
  },
): Promise<SocialEnrichmentResult> {
  if (source === 'youtube') {
    return fetchYouTubeLegalEnrichment(rawUrl, {
      youtubeApiKey: extras?.youtubeApiKey || null,
    });
  }
  if (source === 'instagram') {
    return fetchInstagramEnrichment(rawUrl, {
      prefetched: prefetched || null,
      instagramOEmbedAccessToken: extras?.instagramOEmbedAccessToken || null,
      groqApiKey: extras?.groqApiKey || null,
      userId: extras?.userId || null,
      azureConnectionString: extras?.azureConnectionString || null,
      azureContainer: extras?.azureContainer || null,
      tensorlakeApiKey: extras?.tensorlakeApiKey || null,
    });
  }
  if (source === 'linkedin') {
    return fetchLinkedInEnrichment(rawUrl, { prefetched: prefetched || null });
  }
  if (source === 'twitter') {
    return fetchTwitterEnrichment(rawUrl, {
      prefetched: prefetched || null,
    });
  }
  if (source === 'facebook') {
    return fetchFacebookLegalEnrichment(rawUrl, {
      accessToken: extras?.facebookOEmbedAccessToken ||
        extras?.instagramOEmbedAccessToken ||
        null,
    });
  }
  if (source === 'reddit') {
    return fetchRedditEnrichment(rawUrl, {
      prefetched: prefetched || null,
      youtubeApiKey: extras?.youtubeApiKey || null,
    });
  }
  // Exhaustiveness check.
  const _exhaustive: never = source;
  throw new Error(`Unsupported social source: ${_exhaustive}`);
}
