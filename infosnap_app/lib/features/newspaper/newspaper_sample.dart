// ignore_for_file: lines_longer_than_80_chars
import 'newspaper_models.dart';

/// Baked-in sample edition for May 14, 2026 — mirrors design-mockups/v5.html.
/// Replace with a server-fetched [NewspaperEdition] once the daily job is live.
final NewspaperEdition sampleEdition = NewspaperEdition(
  editionDate: DateTime(2026, 5, 15),
  editionDateLabel: 'Saturday, May 15, 2026',
  issueNumber: 72,
  totalSaves: 13,
  editorsNote:
      "You saved Jeff Su's “99% of Beginners Don't Know the Basics of AI” four times yesterday — at 09:34, 09:41, 13:27 and 13:41 — and the Great Learning AI roadmap three times across the same day. We've collapsed them into one Tech Desk dispatch. Press is loud about AI; your tabs, evidently, are louder.",
  lead: const LeadStory(
    kicker: 'Travel Alert · Border Desk · Front Page',
    headline: 'Vietnam Will Now Deny Boarding Without a Pre-Arrival QR Code',
    deck:
        'A rule already in force at Ho Chi Minh City for a month is still catching Indian travellers off guard. The form is not the visa. The visa is not the form. Both, or stay home.',
    byline: 'By Sanjana & Tanmay · via Instagram Reel · saved 16:49',
    sourceUrl:
        'https://www.google.com/search?q=Vietnam+digital+pre-arrival+form+QR+code+April+2026',
    heroImage:
        'https://images.unsplash.com/photo-1528127269322-539801943592?w=1200&q=70',
    imageCaption:
        'Tan Son Nhat International Airport, Ho Chi Minh City — where the new digital pre-arrival form is now checked at the gate.',
    paragraphs: [
      'A brand-new rule has been quietly in effect since April 15, 2026, and most Indian passengers are still discovering it at the boarding gate. Vietnam has launched a mandatory Digital Pre-Arrival Form for every foreign traveller landing at Ho Chi Minh City\'s Tan Son Nhat airport. No form means no QR code, and no QR code means the airline can — and will — refuse to let you onto the aircraft.',
      'The trap is not in the rule itself but in the confusion around it. The Pre-Arrival Form and the e-Visa are two separate documents on two separate government portals, and travellers routinely complete one and assume they have completed both.',
      'There is also a 72-hour window: the portal will reject submissions filed earlier than three days before departure, sending applicants back to refresh their browser at exactly the wrong moment of pre-trip panic.',
      'The current enforcement is limited to Ho Chi Minh City. Versions for Hanoi and Da Nang are described as "coming soon" — which, given the rollout pattern so far, is the most ominous phrase in Southeast Asian travel right now.',
      'Save the QR code as a screenshot. Print a paper backup. Triple-check the passport number. Airport Wi-Fi, the post warns with feeling, "is not your friend."',
    ],
    sidebar: SidebarCard(
      title: 'The 6-Step Checklist',
      items: [
        'Apply e-Visa at evisa.gov.vn · \$25 single entry',
        'Fill Pre-Arrival Form at prearrival.immigration.gov.vn',
        'File only within 72 hours of your flight',
        'Save the QR code as a screenshot on your phone',
        'Carry a printed backup — don\'t trust airport Wi-Fi',
        'Verify your passport number twice. One typo = invalid QR',
      ],
    ),
  ),
  sections: const [
    NewspaperSection(
      title: 'Travel Desk',
      meta: '2 saves · both Vietnam · 90 min apart',
      articles: [
        Article(
          headline:
              'Vietnam Airlines Cuts 23 Domestic Flights a Week, Citing Middle-East Fuel Crunch',
          byline:
              'By Suhani Ritu Swaytank for Condé Nast Traveller India · saved 15:18',
          sourceUrl:
              'https://www.google.com/search?q=Vietnam+Airlines+domestic+route+cuts+2026+fuel',
          heroImage:
              'https://images.unsplash.com/photo-1583416750470-965b2707b355?w=1200&q=70',
          imageCaption:
              'A Vietnam Airlines A321 on the apron — the carrier has trimmed 23 weekly flights to conserve fuel.',
          featured: true,
          blocks: [
            ArticleBlock.paragraph(
                'As of April 1, 2026, the national carrier has suspended seven domestic routes, eliminating up to 23 flights per week. The Civil Aviation Authority of Vietnam said the airline is "prioritising routes important to national connectivity and domestic tourism" while attempting to conserve fuel.'),
            ArticleBlock.paragraph(
                'Other Vietnamese carriers are preparing fuel surcharges on international routes from early April. The Instagram reel that ran this news drew 1,799 likes and 39 comments.'),
            ArticleBlock.contradiction(
              'You saved this domestic-cuts story before the boarding-denial story today. Both concern Vietnam, both concern the same month in 2026. If you\'re flying domestically inside Vietnam, the pre-arrival form gets you in the country — the schedule cuts decide whether you make your connection.',
              cite: 'THE TIMES CONNECTS THE DOTS',
            ),
          ],
        ),
      ],
    ),
    NewspaperSection(
      title: 'Tech Desk · The Learning Loop',
      meta: '7 saves · 2 distinct videos · 0 watched',
      articles: [
        Article(
          headline:
              '"I Spent \$49 and Five Hours So You Don\'t Have To": Jeff Su\'s Field Report from Google\'s AI Essentials',
          deck:
              'The same ten-minute video saved four times in one day. The Times suspects intention; we do not adjudicate.',
          byline: 'By Jeff Su · via YouTube · 10m 12s · saved 4×',
          sourceUrl: 'https://www.youtube.com/watch?v=nVyD6THcvDQ',
          featured: true,
          heroImage: 'https://i.ytimg.com/vi/nVyD6THcvDQ/maxresdefault.jpg',
          imageCaption:
              'Jeff Su, address to the camera at the top of the video. The certificate, he says, took an afternoon.',
          repeatStamp: RepeatStamp(
            count: 7,
            note:
                'The Times has collapsed seven separate saves of the same two AI-for-beginners videos into one dispatch. Their re-saving suggests one of two things: a strong intention to watch them, or a strong intention to have already watched them.',
            timestamps: [
              RepeatTime('05:21', 'Great Learning · 6 Steps to AI (Shorts)'),
              RepeatTime('09:34', 'Jeff Su · 99% of Beginners (youtu.be)'),
              RepeatTime('09:39', 'Great Learning · 6 Steps to AI (Shorts)'),
              RepeatTime('09:41', 'Jeff Su · 99% of Beginners (youtu.be)'),
              RepeatTime('13:19', 'Great Learning · 6 Steps to AI (Shorts)'),
              RepeatTime('13:27', 'Jeff Su · 99% of Beginners (youtube.com)'),
              RepeatTime('13:41', 'Jeff Su · 99% of Beginners (youtube.com)'),
            ],
          ),
          blocks: [
            ArticleBlock.paragraph(
                'Jeff Su completed Google\'s AI Essentials certificate in a single afternoon and delivered the verdict in a tone that hovers between earnest tutorial and dry stand-up. His central frame: every AI tool you\'ll meet at work falls into one of three buckets.'),
            ArticleBlock.paragraph(
                'Standalone tools — ChatGPT, Gemini, Claude, Perplexity for the generalists; Speechify, Otter, Midjourney, Gamma for the specialists. Integrated AI features — Gemini inside Google Docs and Slides, where the AI lives within the software you already use. And custom AI solutions, where the case study is Johns Hopkins\'s sepsis detector: diagnostic accuracy lifted from 2–5% to an average of 40%.'),
            ArticleBlock.pullQuote(
              'Well-designed custom AI solutions should require little to no technical know-how.',
              cite:
                  'Jeff Su, paraphrasing the course\'s most counter-intuitive lesson',
            ),
            ArticleBlock.paragraph(
                'The remaining 70% of the video is prompt-engineering hygiene: surface implied context (the AI does not know your friend is vegetarian unless you say so); zero-shot vs. few-shot; chain-of-thought; and the three perennial AI limitations — biased training data, knowledge cut-offs, hallucinations.'),
            ArticleBlock.paragraph(
                'The lifehack tucked at the bottom: enrol in Google\'s Project Management Certification on Coursera and the AI Essentials course is unlocked for free, recouping all \$49.'),
          ],
        ),
        Article(
          headline: 'Great Learning\'s 59-Second AI Roadmap (Saved Thrice)',
          byline: 'A YouTube Short · 59s · saved 3×',
          sourceUrl: 'https://www.youtube.com/watch?v=-VFOy0Nw4PU',
          heroImage: 'https://i.ytimg.com/vi/-VFOy0Nw4PU/maxresdefault.jpg',
          imageCaption:
              'Title card from the 59-second short, which the user has now seen the title card of three times.',
          blocks: [
            ArticleBlock.paragraph(
                'Great Learning Academy\'s roadmap reduces "getting started with AI" to six steps in under a minute:'),
            ArticleBlock.numberedList([
              'Learn to code, especially in Python',
              'Understand neural networks & brain-inspired algorithms',
              'Explore NLP — including generative AI',
              'Dive into computer vision',
              'Practice by building projects (chatbots, image classifiers)',
              'Keep learning — the field evolves rapidly',
            ]),
            ArticleBlock.paragraph(
                'The Academy positions itself with the credentials: 1,000+ free courses, 10M+ learners across 170+ countries, partnerships with Stanford Executive Education, MIT Professional Education, Wharton, and IIT Madras.'),
            ArticleBlock.paragraph(
                '— The transcript, charmingly, was auto-rendered in Devanagari script. The Times has translated.'),
          ],
        ),
      ],
    ),
    NewspaperSection(
      title: 'Careers Desk',
      meta: '1 save · 17:01 · the day\'s last item',
      articles: [
        Article(
          headline:
              'Ten European Job Portals Most Non-EU Candidates Have Never Heard Of',
          byline:
              'By Samadhan Mule ("Swapnil In Germany") · via Instagram · 17:01',
          sourceUrl:
              'https://www.google.com/search?q=Swapnil+in+Germany+non-EU+job+portals+Arbeitsagentur',
          heroImage:
              'https://images.unsplash.com/photo-1467269204594-9661b134dd2b?w=1200&q=70',
          imageCaption:
              'Frankfurt skyline at dusk — most of the underused portals on Mr Mule’s list serve the DACH and Benelux markets.',
          featured: true,
          blocks: [
            ArticleBlock.paragraph(
                '"It\'s not about applying more — it\'s about applying right," writes Samadhan Mule in a post that is half career advice, half advertisement for his three-month Job Assistance Programme. The core argument: most candidates burn months on generalist job boards that do not sponsor non-EU workers, while smaller country-specific portals quietly do.'),
            ArticleBlock.pullQuote(
              'Smart candidates go where international hiring actually happens.',
              cite: 'Samadhan Mule',
            ),
            ArticleBlock.paragraph(
                'His three-month programme covers CV and LinkedIn optimisation, an application strategy, networking guidance, application support from his team, and interview prep. He notes — twice — that he works with "a limited number of serious candidates only." DM "VISA JOB" to begin.'),
            ArticleBlock.portalList([
              Portal('Arbeitsagentur.de', '· Germany\'s official job portal',
                  'DE'),
              Portal('Make it in Germany',
                  '· Government portal for skilled workers', 'DE'),
              Portal('Nationale Vacaturebank', '· Non-EU friendly', 'NL'),
              Portal(
                  'Jobbird.com', '· Less crowded than the giants', 'NL · BE'),
              Portal('Stepstone.de / .at', '· Corporate recruiters', 'DE · AT'),
              Portal('Karriere.at',
                  '· Austria\'s #1, underused internationally', 'AT'),
              Portal('VDAB.be', '· Belgium\'s official platform', 'BE'),
              Portal(
                  'EuroJobsites.com', '· Has a visa-sponsorship filter', 'EU'),
              Portal(
                  'Experteer.de', '· Mid- to senior-level DACH roles', 'DACH'),
              Portal(
                  'Welcome to the Jungle', '· Startup to corporate', 'NL · BE'),
            ]),
          ],
        ),
      ],
    ),
    NewspaperSection(
      title: 'Lifestyle & Local',
      meta: 'Pune Bureau · 16:34',
      articles: [
        Article(
          headline:
              'Fifteen Thousand Square Feet, Twelve Slides, One Ball-Pool the Size of a Small Pond',
          byline: 'By Dr Ruchi Parekh · via Instagram · saved 16:34',
          sourceUrl:
              'https://www.google.com/search?q=Kokonuts+Play+Club+NIBM+Road+Undri+Pune',
          heroImage:
              'https://images.unsplash.com/photo-1545558014-8692077e9b5c?w=1200&q=70',
          imageCaption:
              'A multicoloured ball pool of the kind from which, the saved post reports, no child returns voluntarily.',
          featured: true,
          blocks: [
            ArticleBlock.paragraph(
                'On the fifth floor of Golden Court on NIBM Road in Undri — above a Zudio and a Star Bazaar — sits a 15,000-square-foot indoor play complex called Kokonuts the Play Club. Twelve slides. A trampoline zone. A sand pit. A pretend-play zone. An obstacle course. And a ball pool that Dr Parekh\'s child reportedly refused to leave.'),
            ArticleBlock.paragraph(
                'The standard parental concession — that one is now also a chaperone — is partially solved here by dedicated caretakers on staff. A cafeteria with free Wi-Fi handles the parents. A banquet space with a pure-vegetarian menu and custom theming handles the inevitable birthday-party question.'),
            ArticleBlock.pullQuote(
              'Survey No. 12 & 13, NIBM Road, Undri, Pune 411060 · 9684022361',
              cite: 'for the next outing, and the next birthday after that',
            ),
          ],
        ),
        Article(
          headline:
              '"Never Seen a Show Hit This Hard": A 22,000-Like Verdict on Sapne Vs Everyone',
          byline: 'via @bingemoves on Instagram · saved 16:31',
          sourceUrl:
              'https://www.google.com/search?q=Sapne+Vs+Everyone+Ambrish+Verma+review',
          heroImage:
              'https://images.unsplash.com/photo-1489599588481-e9ce6a0db936?w=1200&q=70',
          imageCaption:
              'A near-empty theatre at the late show — where, by the reviewer’s account, Sapne Vs Everyone is meant to be watched.',
          blocks: [
            ArticleBlock.paragraph(
                'Three minutes before the Pune save, an Instagram reel by @bingemoves landed with 22,000 likes and 182 comments on a single proposition: Ambrish Verma\'s Sapne Vs Everyone is the rare web series that "understands ambition, rejection, insecurity and survival" without inflating any of them into cinematic fantasy.'),
            ArticleBlock.pullQuote(
              'Some shows entertain for a weekend. Sapne Vs Everyone stays in your head for a long time.',
              cite: '@bingemoves',
            ),
            ArticleBlock.paragraph(
                'The reviewer credits Verma not just as writer but as inhabitant of the world he wrote. "That honesty," they note, "is visible in every frame."'),
          ],
        ),
      ],
    ),
    NewspaperSection(
      title: 'Arts & Entertainment · The Late Edition',
      meta: '05:38 · earliest save of the day',
      articles: [
        Article(
          headline: 'How Nana Patekar Really Behaves During Shoots',
          byline: 'Digital Commentary Clips · YouTube · 05:38',
          sourceUrl: 'https://www.youtube.com/watch?v=33tDEvwquGw',
          heroImage: 'https://i.ytimg.com/vi/33tDEvwquGw/hqdefault.jpg',
          imageCaption:
              'Frame from the clip. The description, in full: "full video."',
          blocks: [
            ArticleBlock.paragraph(
                'The first save of the day, filed before dawn. The Times notes, with some regret, that no transcript was available for this video; we cannot, therefore, tell you what Nana Patekar really does on a film set.'),
            ArticleBlock.paragraph(
                'The description, in its entirety, reads: "full video."'),
            ArticleBlock.paragraph('We respect a man of few words.'),
          ],
        ),
      ],
    ),
  ],
  dayInOneParagraph:
      'You woke up curious about Nana Patekar, spent the morning hoarding AI courses you may or may not watch, drifted by lunch toward Vietnam\'s new border paperwork and a Pune kids\' play area, made a brief stop for a web-series review, and closed the day on European job portals that sponsor non-EU candidates. The mind, in summary, has been thinking about how to be qualified, where to go, and what to do with the kids while you figure both out.',
  stats: const [
    Stat('Total saves', '13'),
    Stat('Unique items', '8'),
    Stat('Most-resaved', '4×'),
    Stat('Span (hh:mm)', '11:23'),
    Stat('From Instagram', '5'),
    Stat('From YouTube', '7'),
    Stat('From the web', '1'),
  ],
  authorsCited: const [
    AuthorCount('Jeff Su', 4),
    AuthorCount('Great Learning', 3),
    AuthorCount('Sanjana & Tanmay', 1),
    AuthorCount('Dr Ruchi Parekh', 1),
    AuthorCount('BINGE MOVES', 1),
    AuthorCount('CN Traveller India', 1),
    AuthorCount('Swapnil / Mule', 1),
    AuthorCount('Digital Commentary', 1),
  ],
);
