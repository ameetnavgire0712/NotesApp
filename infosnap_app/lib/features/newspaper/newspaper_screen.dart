// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import '../../core/utils/responsive.dart';

import '../../core/services/api_service.dart';
import 'newspaper_models.dart';
import 'newspaper_sample.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// The infoSnap Times — Flutter rendition of design-mockups/v5.html
///
/// Edition data flow:
///   1. [newspaperEditionProvider] fires `GET /api/v1/newspaper?days=N` against
///      the Cloudflare Worker (see api-endpoints.ts → handleNewspaperEdition).
///   2. The worker pulls the user's notes from the last N days, calls Groq,
///      and returns a structured NewspaperEdition JSON payload.
///   3. The screen renders the payload in NYT-Sunday newsprint styling.
///   4. While loading we show a paper-style placeholder; on error we fall
///      back to the baked sample edition so the screen is never empty.
/// ─────────────────────────────────────────────────────────────────────────────

/// Look-back window for the daily edition. 1 = "yesterday only".
final newspaperDaysProvider = StateProvider<int>((_) => 1);

final newspaperEditionProvider =
    FutureProvider.autoDispose<NewspaperEdition?>((ref) async {
  final days = ref.watch(newspaperDaysProvider);
  return ApiService().fetchNewspaperEdition(days: days);
});

class NewspaperScreen extends ConsumerStatefulWidget {
  const NewspaperScreen({super.key});

  @override
  ConsumerState<NewspaperScreen> createState() => _NewspaperScreenState();
}

class _NewspaperScreenState extends ConsumerState<NewspaperScreen> {
  // Paper-color palette (mirrors v5.html)
  static const Color _paper = Color(0xFFFAF8F3);
  static const Color _ink = Color(0xFF1A1A1A);
  static const Color _inkSoft = Color(0xFF3A3530);
  static const Color _inkMuted = Color(0xFF5A4A3A);
  static const Color _rule = Color(0xFFC9BFA8);
  static const Color _ruleDash = Color(0xFFD9CFB8);
  static const Color _amber = Color(0xFFB45309);
  static const Color _amberHi = Color(0xFFFBBF24);
  static const Color _amberBg = Color(0xFFFEF3C7);
  static const Color _bg = Color(0xFF2A2826);

  // GlobalKeys per section + lead, used for tap-to-scroll from the TOC.
  final GlobalKey _leadKey = GlobalKey();
  final Map<String, GlobalKey> _sectionKeys = {};

  GlobalKey _keyFor(String sectionTitle) =>
      _sectionKeys.putIfAbsent(sectionTitle, () => GlobalKey());

  Future<void> _scrollTo(GlobalKey key) async {
    final ctx = key.currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      alignment: 0.02,
    );
  }

  @override
  Widget build(BuildContext context) {
    final editionAsync = ref.watch(newspaperEditionProvider);

    return editionAsync.when(
      // While we wait for the LLM-generated edition, show a paper-styled
      // skeleton so the screen never appears blank.
      loading: () => _scaffoldWrap(_loadingState(context)),
      error: (err, _) {
        debugPrint(
            'NewspaperScreen: load failed → falling back to sample. $err');
        return _renderEdition(sampleEdition, isFallback: true);
      },
      // null result = unauthenticated or backend error. Render sample.
      data: (edition) =>
          _renderEdition(edition ?? sampleEdition, isFallback: edition == null),
    );
  }

  Widget _scaffoldWrap(Widget child) => Scaffold(
        backgroundColor: _bg,
        body: SafeArea(child: child),
      );

  Widget _loadingState(BuildContext context) {
    return Column(
      children: [
        // Minimal top bar with a back button so the user can escape if the
        // edition takes a while to generate.
        Padding(
          padding: EdgeInsets.fromLTRB(Responsive.pp(8), Responsive.pp(6),
              Responsive.pp(12), Responsive.pp(6)),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back, color: Color(0xFFFAF8F3)),
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/home');
                  }
                },
              ),
              Spacer(),
              Text(
                'Setting type…',
                style: GoogleFonts.fraunces(
                  color: const Color(0xFFFAF8F3),
                  fontSize: Responsive.sp(13),
                  fontStyle: FontStyle.italic,
                ),
              ),
              SizedBox(width: Responsive.wp(12)),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: Responsive.wp(28),
                  width: Responsive.wp(28),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation(Color(0xFFFEF3C7)),
                  ),
                ),
                SizedBox(height: Responsive.wp(18)),
                Text(
                  "The infoSnap Times",
                  style: TextStyle(
                    color: Color(0xFFFAF8F3),
                    fontSize: Responsive.sp(18),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                  ),
                ),
                SizedBox(height: Responsive.wp(6)),
                Text(
                  'Editors are filing today\'s edition…',
                  style: TextStyle(
                    color: Color(0xFFC9BFA8),
                    fontSize: Responsive.sp(12),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _renderEdition(NewspaperEdition edition, {bool isFallback = false}) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(context, edition),
            if (isFallback) _fallbackBanner(),
            Expanded(
              child: RefreshIndicator(
                color: _amber,
                backgroundColor: _paper,
                onRefresh: () async {
                  ref.invalidate(newspaperEditionProvider);
                  // Allow the new request to kick off; the FutureProvider's
                  // own loading state will then drive the UI.
                  await Future<void>.delayed(const Duration(milliseconds: 250));
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(Responsive.pp(14),
                      Responsive.pp(8), Responsive.pp(14), Responsive.pp(24)),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _paper,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.45),
                          blurRadius: Responsive.wp(30),
                          offset: Offset(0, Responsive.wp(12)),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _masthead(edition),
                        _editorsNote(edition.editorsNote),
                        _tableOfContents(edition),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                              Responsive.pp(20),
                              Responsive.pp(8),
                              Responsive.pp(20),
                              Responsive.pp(24)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _leadStory(edition.lead),
                              if (edition.lead.sidebar != null) ...[
                                SizedBox(height: Responsive.wp(16)),
                                _sidebarCard(edition.lead.sidebar!),
                              ],
                              for (final section in edition.sections) ...[
                                _sectionHead(section),
                                for (final article in section.articles)
                                  _articleBlock(article),
                              ],
                              SizedBox(height: Responsive.wp(24)),
                              _colophon(edition),
                              SizedBox(height: Responsive.wp(16)),
                              _footerNote(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Small banner shown when we couldn't load a fresh edition and are showing
  // the baked sample instead. Tapping it retries.
  Widget _fallbackBanner() {
    return Material(
      color: _amberBg,
      child: InkWell(
        onTap: () => ref.invalidate(newspaperEditionProvider),
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(14), vertical: Responsive.pp(8)),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 14, color: _amber),
              SizedBox(width: Responsive.wp(8)),
              Expanded(
                child: Text(
                  "Showing yesterday's sample — couldn't reach the newsroom. Tap to retry.",
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(11),
                    color: _amber,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              Icon(Icons.refresh, size: 14, color: _amber),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Top bar (out of paper) ────────────────────────────────────────────────
  Widget _topBar(BuildContext context, NewspaperEdition edition) {
    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.pp(8), Responsive.pp(6),
          Responsive.pp(12), Responsive.pp(6)),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: Color(0xFFF5F1E8)),
            onPressed: () => context.pop(),
          ),
          Expanded(
            child: Text(
              'The infoSnap Times · ${edition.editionDateLabel}',
              style: GoogleFonts.fraunces(
                fontSize: Responsive.sp(12),
                letterSpacing: 2.5,
                color: const Color(0xFFF5F1E8).withOpacity(0.6),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: Icon(Icons.ios_share, color: Color(0xFFF5F1E8), size: 20),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Share — coming soon')),
              );
            },
          ),
        ],
      ),
    );
  }

  // ─── Masthead ──────────────────────────────────────────────────────────────
  Widget _masthead(NewspaperEdition e) {
    return Container(
      padding: EdgeInsets.fromLTRB(Responsive.pp(20), Responsive.pp(16),
          Responsive.pp(20), Responsive.pp(14)),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: _ink, width: Responsive.wp(3)),
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Vol. I · No. ${e.issueNumber}', style: _mastTopStyle()),
              Text('Saturday Edition', style: _mastTopStyle()),
            ],
          ),
          SizedBox(height: Responsive.wp(6)),
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              children: [
                TextSpan(
                  text: 'The ',
                  style: GoogleFonts.fraunces(
                    fontSize: Responsive.sp(22),
                    fontStyle: FontStyle.italic,
                    color: _ink,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                TextSpan(
                  text: 'infoSnap Times',
                  style: GoogleFonts.fraunces(
                    fontSize: Responsive.sp(34),
                    fontWeight: FontWeight.w900,
                    color: _ink,
                    height: 0.95,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Responsive.wp(4)),
          Text(
            '"Everything you saved yesterday, set in type before the day forgets it."',
            textAlign: TextAlign.center,
            style: GoogleFonts.fraunces(
              fontSize: Responsive.sp(11),
              fontStyle: FontStyle.italic,
              color: _inkMuted,
            ),
          ),
          SizedBox(height: Responsive.wp(10)),
          Container(
            padding: EdgeInsets.only(top: Responsive.pp(8)),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: _ink)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(e.editionDateLabel,
                      style: _mastMetaStyle(), overflow: TextOverflow.ellipsis),
                ),
                Flexible(
                  child: Text(
                    '${e.totalSaves} stories filed',
                    style: _mastMetaStyle(),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _mastTopStyle() => GoogleFonts.fraunces(
        fontSize: Responsive.sp(9),
        letterSpacing: 1.8,
        color: _inkMuted,
        fontWeight: FontWeight.w600,
      );

  TextStyle _mastMetaStyle() => GoogleFonts.fraunces(
        fontSize: Responsive.sp(10),
        letterSpacing: 1.2,
        color: _ink,
      );

  // ─── Editor's note (black strip) ───────────────────────────────────────────
  Widget _editorsNote(String note) {
    return Container(
      color: _ink,
      padding: EdgeInsets.fromLTRB(Responsive.pp(20), Responsive.pp(12),
          Responsive.pp(20), Responsive.pp(14)),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: _amber, width: Responsive.wp(3)),
          ),
        ),
        padding: EdgeInsets.only(bottom: Responsive.pp(10)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(8), vertical: Responsive.pp(3)),
              color: _amber,
              child: Text(
                "EDITOR'S NOTE",
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(9),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.8,
                  color: _paper,
                ),
              ),
            ),
            SizedBox(height: Responsive.wp(8)),
            Text(
              note,
              style: GoogleFonts.fraunces(
                fontSize: Responsive.sp(13),
                fontStyle: FontStyle.italic,
                height: 1.5,
                color: _paper,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Lead story ────────────────────────────────────────────────────────────
  Widget _leadStory(LeadStory lead) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: Responsive.wp(18)),
        _kicker(lead.kicker),
        SizedBox(height: Responsive.wp(6)),
        Text(
          lead.headline,
          style: GoogleFonts.fraunces(
            fontSize: Responsive.sp(32),
            fontWeight: FontWeight.w900,
            height: 1.02,
            color: _ink,
            letterSpacing: -0.5,
          ),
        ),
        SizedBox(height: Responsive.wp(10)),
        Text(
          lead.deck,
          style: GoogleFonts.fraunces(
            fontSize: Responsive.sp(15),
            fontStyle: FontStyle.italic,
            height: 1.4,
            color: _inkSoft,
          ),
        ),
        SizedBox(height: Responsive.wp(12)),
        _byline(lead.byline),
        if (lead.heroImage != null) ...[
          SizedBox(height: Responsive.wp(14)),
          _heroImage(lead.heroImage!, lead.imageCaption),
        ],
        SizedBox(height: Responsive.wp(14)),
        for (int i = 0; i < lead.paragraphs.length; i++)
          _bodyParagraph(lead.paragraphs[i], dropCap: i == 0),
      ],
    );
  }

  Widget _kicker(String text) {
    return Text(
      text.toUpperCase(),
      style: GoogleFonts.inter(
        fontSize: Responsive.sp(10),
        fontWeight: FontWeight.w700,
        letterSpacing: 2.5,
        color: _amber,
      ),
    );
  }

  Widget _byline(String byline) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: _rule),
          bottom: BorderSide(color: _rule),
        ),
      ),
      child: Text(
        byline,
        style: GoogleFonts.inter(
          fontSize: Responsive.sp(11),
          color: _inkMuted,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _bodyParagraph(String text, {bool dropCap = false}) {
    if (!dropCap) {
      return Padding(
        padding: EdgeInsets.only(bottom: Responsive.pp(10)),
        child: Text(
          text,
          style: GoogleFonts.fraunces(
            fontSize: Responsive.sp(14.5),
            height: 1.55,
            color: _ink,
          ),
        ),
      );
    }
    final firstLetter = text.isNotEmpty ? text.substring(0, 1) : '';
    final rest = text.length > 1 ? text.substring(1) : '';
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.pp(10)),
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: Padding(
                padding: const EdgeInsets.only(right: 6, top: 4),
                child: Text(
                  firstLetter,
                  style: GoogleFonts.fraunces(
                    fontSize: Responsive.sp(52),
                    fontWeight: FontWeight.w900,
                    height: 0.85,
                    color: _amber,
                  ),
                ),
              ),
            ),
            TextSpan(
              text: rest,
              style: GoogleFonts.fraunces(
                fontSize: Responsive.sp(14.5),
                height: 1.55,
                color: _ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Sidebar (checklist card) ──────────────────────────────────────────────
  Widget _sidebarCard(SidebarCard card) {
    return Container(
      padding: EdgeInsets.all(Responsive.pp(16)),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _ruleDash),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.only(bottom: Responsive.pp(8)),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: _ink, width: Responsive.wp(2))),
            ),
            child: Text(
              card.title,
              style: GoogleFonts.fraunces(
                fontSize: Responsive.sp(19),
                fontWeight: FontWeight.w900,
                color: _ink,
                height: 1.1,
              ),
            ),
          ),
          for (int i = 0; i < card.items.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: i == card.items.length - 1
                      ? BorderSide.none
                      : BorderSide(color: _ruleDash, style: BorderStyle.solid),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: Responsive.wp(18),
                    height: Responsive.wp(18),
                    margin: const EdgeInsets.only(right: 10, top: 2),
                    decoration: BoxDecoration(
                      color: _ink,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${i + 1}',
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(10),
                        fontWeight: FontWeight.w700,
                        color: _paper,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      card.items[i],
                      style: GoogleFonts.fraunces(
                        fontSize: Responsive.sp(13.5),
                        height: 1.5,
                        color: _ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ─── Section header bar ────────────────────────────────────────────────────
  Widget _sectionHead(NewspaperSection section) {
    // Stacked layout: long titles like "Tech Desk · The Learning Loop" or
    // "Arts & Entertainment · The Late Edition" now have room to breathe;
    // the meta line ("2 saves · both Vietnam · 90 min apart") sits below.
    return Container(
      key: _keyFor(section.title),
      margin: const EdgeInsets.only(top: 24, bottom: 12),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: _ink, width: Responsive.wp(2)),
          bottom: BorderSide(color: _ink),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.title.toUpperCase(),
            style: GoogleFonts.fraunces(
              fontSize: Responsive.sp(15),
              fontWeight: FontWeight.w900,
              letterSpacing: 2.2,
              height: 1.2,
              color: _ink,
            ),
          ),
          SizedBox(height: Responsive.wp(4)),
          Text(
            section.meta,
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(10),
              color: _inkMuted,
              letterSpacing: 0.8,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Article ───────────────────────────────────────────────────────────────
  Widget _articleBlock(Article a) {
    return Container(
      margin: EdgeInsets.only(bottom: Responsive.pp(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (a.repeatStamp != null) _repeatCard(a.repeatStamp!),
          if (a.heroImage != null) ...[
            _heroImage(a.heroImage!, a.imageCaption),
            SizedBox(height: Responsive.wp(12)),
          ],
          Text(
            a.headline,
            style: GoogleFonts.fraunces(
              fontSize: a.featured ? 24 : 20,
              fontWeight: FontWeight.w900,
              height: 1.05,
              color: _ink,
            ),
          ),
          if (a.deck != null) ...[
            SizedBox(height: Responsive.wp(6)),
            Text(
              a.deck!,
              style: GoogleFonts.fraunces(
                fontSize: Responsive.sp(14),
                fontStyle: FontStyle.italic,
                height: 1.4,
                color: _inkSoft,
              ),
            ),
          ],
          SizedBox(height: Responsive.wp(8)),
          Container(
            padding: EdgeInsets.only(bottom: Responsive.pp(6)),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: _rule)),
            ),
            child: Text(
              a.byline.toUpperCase(),
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(9.5),
                letterSpacing: 1,
                color: _inkMuted,
              ),
            ),
          ),
          SizedBox(height: Responsive.wp(10)),
          for (final block in a.blocks) _renderBlock(block),
          _viewSnapLink(noteId: a.noteId, sourceUrl: a.sourceUrl),
        ],
      ),
    );
  }

  Widget _heroImage(String url, String? caption) {
    // Newspaper-style image: black frame, slight desaturation, italic caption.
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.pp(4)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _ink, width: Responsive.wp(1.5)),
              color: const Color(0xFFEAE4D2),
            ),
            child: ColorFiltered(
              // Halftone-ish: desaturate slightly so it sits on newsprint.
              colorFilter: const ColorFilter.matrix([
                0.45,
                0.45,
                0.10,
                0,
                8,
                0.40,
                0.45,
                0.10,
                0,
                8,
                0.35,
                0.40,
                0.10,
                0,
                8,
                0,
                0,
                0,
                1,
                0,
              ]),
              child: AspectRatio(
                aspectRatio: 16 / 10,
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return _imagePlaceholder('Developing in the darkroom…');
                  },
                  errorBuilder: (_, __, ___) => _imagePlaceholder(
                      '[ photograph filed, plate unavailable ]'),
                ),
              ),
            ),
          ),
          if (caption != null) ...[
            SizedBox(height: Responsive.wp(4)),
            Text(
              caption,
              style: GoogleFonts.fraunces(
                fontSize: Responsive.sp(11),
                fontStyle: FontStyle.italic,
                color: _inkMuted,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _imagePlaceholder(String label) {
    return Container(
      color: const Color(0xFFEAE4D2),
      alignment: Alignment.center,
      child: Padding(
        padding: EdgeInsets.all(Responsive.pp(12)),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: GoogleFonts.fraunces(
            fontSize: Responsive.sp(11),
            fontStyle: FontStyle.italic,
            color: _inkMuted,
          ),
        ),
      ),
    );
  }

  Widget _repeatCard(RepeatStamp stamp) {
    return Container(
      margin: EdgeInsets.only(bottom: Responsive.pp(12)),
      padding: EdgeInsets.all(Responsive.pp(14)),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _ink, width: Responsive.wp(2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Transform.rotate(
            angle: -0.035,
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(8), vertical: Responsive.pp(3)),
              color: _amber,
              child: Text(
                'FILED ${stamp.count}×',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(9),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          SizedBox(height: Responsive.wp(8)),
          Text(
            stamp.note,
            style: GoogleFonts.fraunces(
              fontSize: Responsive.sp(13.5),
              height: 1.5,
              color: _ink,
            ),
          ),
          SizedBox(height: Responsive.wp(8)),
          for (final ts in stamp.timestamps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: RichText(
                text: TextSpan(
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: Responsive.sp(10.5),
                    color: _inkMuted,
                  ),
                  children: [
                    TextSpan(
                      text: ts.time,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: Responsive.sp(10.5),
                        color: _ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(text: '  ·  ${ts.label}'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _renderBlock(ArticleBlock b) {
    switch (b.type) {
      case BlockType.paragraph:
        return Padding(
          padding: EdgeInsets.only(bottom: Responsive.pp(10)),
          child: Text(
            b.text!,
            style: GoogleFonts.fraunces(
              fontSize: Responsive.sp(14),
              height: 1.55,
              color: _ink,
            ),
          ),
        );
      case BlockType.pullQuote:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: EdgeInsets.fromLTRB(Responsive.pp(14), Responsive.pp(4),
              Responsive.pp(0), Responsive.pp(4)),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: _amber, width: Responsive.wp(3)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                b.text!,
                style: GoogleFonts.fraunces(
                  fontSize: Responsive.sp(16),
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                  color: _ink,
                ),
              ),
              if (b.cite != null) ...[
                SizedBox(height: Responsive.wp(6)),
                Text(
                  b.cite!.toUpperCase(),
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(9.5),
                    letterSpacing: 1,
                    color: _inkMuted,
                  ),
                ),
              ],
            ],
          ),
        );
      case BlockType.contradiction:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: EdgeInsets.all(Responsive.pp(12)),
          decoration: BoxDecoration(
            color: _amberBg,
            border: Border(
              left: BorderSide(color: _amber, width: Responsive.wp(4)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                b.cite ?? 'THE TIMES CONNECTS THE DOTS',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(9.5),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                  color: _amber,
                ),
              ),
              SizedBox(height: Responsive.wp(4)),
              Text(
                b.text!,
                style: GoogleFonts.fraunces(
                  fontSize: Responsive.sp(13),
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                  color: const Color(0xFF5A3A0A),
                ),
              ),
            ],
          ),
        );
      case BlockType.numberedList:
        return Padding(
          padding: EdgeInsets.only(bottom: Responsive.pp(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int i = 0; i < (b.items ?? const []).length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: Responsive.wp(22),
                        child: Text(
                          '${i + 1}.',
                          style: GoogleFonts.fraunces(
                            fontSize: Responsive.sp(13.5),
                            color: _amber,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          b.items![i],
                          style: GoogleFonts.fraunces(
                            fontSize: Responsive.sp(13.5),
                            height: 1.5,
                            color: _ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      case BlockType.portalList:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: _rule)),
          ),
          child: Column(
            children: [
              for (int i = 0; i < (b.portals ?? const []).length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: i == b.portals!.length - 1
                          ? BorderSide.none
                          : BorderSide(color: _ruleDash),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: Responsive.wp(26),
                        child: Text(
                          (i + 1).toString().padLeft(2, '0'),
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(10.5),
                            color: _amber,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: '${b.portals![i].name}  ',
                                style: GoogleFonts.fraunces(
                                  fontSize: Responsive.sp(13),
                                  fontWeight: FontWeight.w700,
                                  color: _ink,
                                ),
                              ),
                              TextSpan(
                                text: b.portals![i].note,
                                style: GoogleFonts.fraunces(
                                  fontSize: Responsive.sp(12.5),
                                  color: _ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(width: Responsive.wp(6)),
                      Text(
                        b.portals![i].tag,
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(9),
                          color: _inkMuted,
                          letterSpacing: 0.8,
                          fontWeight: FontWeight.w600,
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

  // ─── Colophon ──────────────────────────────────────────────────────────────
  Widget _colophon(NewspaperEdition e) {
    return Container(
      padding: EdgeInsets.only(top: Responsive.pp(18)),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _ink, width: Responsive.wp(3))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _colophonHead('The Day in One Paragraph'),
          SizedBox(height: Responsive.wp(6)),
          Text(
            e.dayInOneParagraph,
            style: GoogleFonts.fraunces(
              fontSize: Responsive.sp(13),
              height: 1.55,
              color: _inkSoft,
            ),
          ),
          SizedBox(height: Responsive.wp(16)),
          _colophonHead('By the Numbers'),
          SizedBox(height: Responsive.wp(4)),
          for (final stat in e.stats) _statRow(stat.label, stat.value),
          SizedBox(height: Responsive.wp(16)),
          _colophonHead('Authors Cited'),
          SizedBox(height: Responsive.wp(4)),
          for (final author in e.authorsCited)
            _statRow(author.label, '${author.count}×'),
        ],
      ),
    );
  }

  Widget _colophonHead(String t) {
    return Container(
      padding: EdgeInsets.only(bottom: Responsive.pp(4)),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _rule)),
      ),
      child: Text(
        t.toUpperCase(),
        style: GoogleFonts.fraunces(
          fontSize: Responsive.sp(11),
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
          color: _ink,
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _ruleDash)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: GoogleFonts.fraunces(
                    fontSize: Responsive.sp(12), color: _inkSoft)),
          ),
          Text(value,
              style: GoogleFonts.jetBrainsMono(
                fontSize: Responsive.sp(11.5),
                color: _ink,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }

  Widget _footerNote() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(
          'The infoSnap Times · A digest of one person\'s saved curiosities, '
          'set in print so they have somewhere to land. '
          'Tomorrow\'s edition arrives at sunrise.',
          textAlign: TextAlign.center,
          style: GoogleFonts.fraunces(
            fontSize: Responsive.sp(11),
            fontStyle: FontStyle.italic,
            color: _inkMuted,
            letterSpacing: 0.3,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  // ─── Table of contents (jump to section) ───────────────────────────────────
  Widget _tableOfContents(NewspaperEdition e) {
    final entries = <_TocEntry>[
      _TocEntry(
          label: 'Front Page · Lead Story',
          meta: e.lead.kicker,
          onTap: () => _scrollTo(_leadKey)),
      for (final s in e.sections)
        _TocEntry(
          label: s.title,
          meta: s.meta,
          onTap: () => _scrollTo(_keyFor(s.title)),
        ),
    ];
    return Container(
      margin: EdgeInsets.fromLTRB(Responsive.pp(20), Responsive.pp(16),
          Responsive.pp(20), Responsive.pp(4)),
      padding: EdgeInsets.fromLTRB(Responsive.pp(14), Responsive.pp(12),
          Responsive.pp(14), Responsive.pp(6)),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _ink, width: Responsive.wp(1.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.only(bottom: Responsive.pp(6)),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: _ink)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "INSIDE TODAY'S EDITION",
                  style: GoogleFonts.fraunces(
                    fontSize: Responsive.sp(11),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    color: _ink,
                  ),
                ),
                Text(
                  '${entries.length} sections',
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(9.5),
                    color: _inkMuted,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          for (int i = 0; i < entries.length; i++)
            InkWell(
              onTap: entries[i].onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: i == entries.length - 1
                        ? BorderSide.none
                        : BorderSide(color: _ruleDash),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: Responsive.wp(26),
                      child: Text(
                        (i + 1).toString().padLeft(2, '0'),
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(10.5),
                          color: _amber,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entries[i].label,
                            style: GoogleFonts.fraunces(
                              fontSize: Responsive.sp(13.5),
                              fontWeight: FontWeight.w700,
                              color: _ink,
                              height: 1.25,
                            ),
                          ),
                          if (entries[i].meta.isNotEmpty)
                            Padding(
                              padding: EdgeInsets.only(top: Responsive.pp(2)),
                              child: Text(
                                entries[i].meta,
                                style: GoogleFonts.inter(
                                  fontSize: Responsive.sp(10),
                                  color: _inkMuted,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(width: Responsive.wp(8)),
                    Text(
                      'Jump →',
                      style: GoogleFonts.fraunces(
                        fontSize: Responsive.sp(11),
                        fontStyle: FontStyle.italic,
                        color: _amber,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── "View the snap" link ──────────────────────────────────────────────────
  /// Renders a small tappable link at the bottom of an article that takes the
  /// user to the underlying saved note's detail page, where the existing
  /// "View original" button can be used to open the source. For the baked
  /// sample edition (which has no real note ids on file), we send the user to
  /// the My Snaps list and pre-fill the search query so they can find it.
  Widget _viewSnapLink({String? noteId, String? sourceUrl}) {
    final hasNote = noteId != null && noteId.isNotEmpty;
    // Only show the link when we have a real note id to deep-link to.
    // For the baked sample edition (no note ids), hide it entirely rather
    // than dumping the user on the My Snaps list.
    if (!hasNote) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: InkWell(
        onTap: () {
          context.push('/notes/$noteId');
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: _ruleDash)),
          ),
          child: Row(
            children: [
              Icon(Icons.bookmark_outline, size: 14, color: _amber),
              SizedBox(width: Responsive.wp(6)),
              Text(
                'View the snap',
                style: GoogleFonts.fraunces(
                  fontSize: Responsive.sp(12),
                  fontStyle: FontStyle.italic,
                  color: _amber,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: _amber,
                ),
              ),
              SizedBox(width: Responsive.wp(4)),
              Text(
                '→',
                style: GoogleFonts.fraunces(
                  fontSize: Responsive.sp(12),
                  color: _amber,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TocEntry {
  final String label;
  final String meta;
  final VoidCallback onTap;
  _TocEntry({required this.label, required this.meta, required this.onTap});
}
