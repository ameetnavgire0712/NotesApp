import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  final List<OnboardingSlide> _slides = [
    OnboardingSlide(
      emoji: "⚡",
      title: "Capture Anything in Seconds",
      subtitle:
          "Save screenshots, files, and quick notes —\nall searchable with AI, instantly.",
    ),
    OnboardingSlide(
      emoji: "🗂️",
      title: "Organized Without Effort",
      subtitle:
          "No folders. No chaos. Find everything quickly with smart search & tags.",
    ),
    OnboardingSlide(
      emoji: "🤖",
      title: "Just Ask. Find Anything.",
      subtitle: "Meet SnapBot — your AI that remembers everything you saved.",
      punchline: "Search is dead. Conversation wins.",
      isSnapBot: true,
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextSlide() {
    if (_currentIndex < _slides.length - 1) {
      _pageController.animateToPage(
        _currentIndex + 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          const Positioned.fill(
            child: HexagonBackground(),
          ),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    onPageChanged: (index) {
                      setState(() {
                        _currentIndex = index;
                      });
                    },
                    itemCount: _slides.length,
                    itemBuilder: (context, index) {
                      final slide = _slides[index];
                      return SingleChildScrollView(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: Responsive.pp(32),
                              vertical: Responsive.pp(24)),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Emoji + Icon
                              if (slide.isSnapBot)
                                _buildSnapBotIcon()
                              else
                                Container(
                                  width: Responsive.wp(100),
                                  height: Responsive.wp(100),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(
                                        Responsive.wp(30)),
                                  ),
                                  child: Center(
                                    child: Text(
                                      slide.emoji,
                                      style: TextStyle(
                                          fontSize: Responsive.sp(48)),
                                    ),
                                  ),
                                )
                                    .animate(
                                        target: _currentIndex == index ? 1 : 0)
                                    .scale(
                                        duration: 400.ms,
                                        curve: Curves.easeOutBack),

                              SizedBox(height: Responsive.wp(48)),

                              // Title
                              Text(
                                slide.title,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.inter(
                                  fontSize: Responsive.sp(28),
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textDark,
                                ),
                              )
                                  .animate(
                                      target: _currentIndex == index ? 1 : 0)
                                  .fadeIn()
                                  .slideY(begin: 0.2),

                              SizedBox(height: Responsive.wp(20)),

                              // Subtitle
                              Text(
                                slide.subtitle,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.inter(
                                  fontSize: Responsive.sp(17),
                                  color: AppColors.textMuted,
                                  height: 1.6,
                                ),
                              )
                                  .animate(
                                      target: _currentIndex == index ? 1 : 0)
                                  .fadeIn(delay: 150.ms)
                                  .slideY(begin: 0.2),

                              SizedBox(height: Responsive.wp(24)),

                              // SnapBot example queries
                              if (slide.isSnapBot)
                                Column(
                                  children: [
                                    Text(
                                      "Ask like you talk:",
                                      style: GoogleFonts.inter(
                                        fontSize: Responsive.sp(15),
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                    SizedBox(height: Responsive.wp(16)),
                                    _buildQueryBubble(
                                        "“Show me that invoice from last month”"),
                                    SizedBox(height: Responsive.wp(12)),
                                    _buildQueryBubble(
                                        "“Find the screenshot about Azure pricing”"),
                                  ],
                                )
                                    .animate(
                                        target: _currentIndex == index ? 1 : 0)
                                    .fadeIn(delay: 300.ms)
                                    .slideX(begin: -0.1),

                              SizedBox(height: Responsive.wp(20)),

                              // Punchline
                              if (slide.punchline != null)
                                Container(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: Responsive.pp(20),
                                      vertical: Responsive.pp(12)),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(
                                        Responsive.wp(12)),
                                    border: Border.all(
                                      color: AppColors.primary.withOpacity(0.3),
                                      width: Responsive.wp(1),
                                    ),
                                  ),
                                  child: Text(
                                    slide.punchline!,
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: Responsive.sp(14),
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.primaryDark,
                                      height: 1.4,
                                    ),
                                  ),
                                )
                                    .animate(
                                        target: _currentIndex == index ? 1 : 0)
                                    .fadeIn(delay: 300.ms)
                                    .scale(begin: Offset(0.95, 0.95)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // Indicators & Controls
                Padding(
                  padding: EdgeInsets.all(Responsive.pp(32)),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          _slides.length,
                          (index) => Container(
                            margin: EdgeInsets.symmetric(
                                horizontal: Responsive.wp(4)),
                            width: _currentIndex == index
                                ? Responsive.wp(24)
                                : Responsive.wp(8),
                            height: Responsive.wp(8),
                            decoration: BoxDecoration(
                              color: _currentIndex == index
                                  ? AppColors.primary
                                  : AppColors.borderLight,
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(4)),
                            ),
                          )
                              .animate(target: _currentIndex == index ? 1 : 0)
                              .shimmer(),
                        ),
                      ),
                      SizedBox(height: Responsive.wp(40)),
                      if (_currentIndex == _slides.length - 1)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ElevatedButton(
                              onPressed: () => context.go('/home'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.symmetric(
                                    vertical: Responsive.pp(16)),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(Responsive.wp(12)),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SvgPicture.string(
                                    '''<svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg">
                                      <path d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844c-.209 1.125-.843 2.078-1.796 2.717v2.258h2.908c1.702-1.567 2.684-3.874 2.684-6.615z" fill="#4285F4"/>
                                      <path d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 009 18z" fill="#34A853"/>
                                      <path d="M3.964 10.71A5.41 5.41 0 013.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 000 9c0 1.452.348 2.827.957 4.042l3.007-2.332z" fill="#FBBC05"/>
                                      <path d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 00.957 4.958L3.964 7.29C4.672 5.163 6.656 3.58 9 3.58z" fill="#EA4335"/>
                                    </svg>''',
                                    width: Responsive.wp(18),
                                    height: Responsive.wp(18),
                                  ),
                                  SizedBox(width: Responsive.wp(8)),
                                  Text('Sign in with Google',
                                      style: TextStyle(
                                          fontSize: Responsive.sp(16),
                                          fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                            SizedBox(height: Responsive.wp(12)),
                            OutlinedButton(
                              onPressed: () => context.go('/home'),
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.symmetric(
                                    vertical: Responsive.pp(16)),
                                side: BorderSide(color: AppColors.borderLight),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(Responsive.wp(12)),
                                ),
                              ),
                              child: Text('Use API Key instead',
                                  style: TextStyle(
                                      fontSize: Responsive.sp(16),
                                      color: AppColors.textMuted,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        )
                      else
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextButton(
                              onPressed: () {
                                _pageController.animateToPage(
                                  _slides.length - 1,
                                  duration: const Duration(milliseconds: 400),
                                  curve: Curves.easeInOut,
                                );
                              },
                              child: Text('Skip',
                                  style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: Responsive.sp(16))),
                            ),
                            ElevatedButton(
                              onPressed: _nextSlide,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.symmetric(
                                    horizontal: Responsive.pp(32),
                                    vertical: Responsive.pp(16)),
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(Responsive.wp(30)),
                                ),
                              ),
                              child: Text('Next →',
                                  style: TextStyle(
                                      fontSize: Responsive.sp(16),
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapBotIcon() {
    return Container(
      width: Responsive.wp(100),
      height: Responsive.wp(100),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withOpacity(0.2),
            AppColors.primaryLight.withOpacity(0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(Responsive.wp(30)),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.3),
          width: Responsive.wp(2),
        ),
      ),
      child: Center(
        child: Text(
          "🤖",
          style: TextStyle(fontSize: Responsive.sp(48)),
        ),
      ),
    ).animate().scale(duration: 500.ms, curve: Curves.easeOutBack).shimmer(
        delay: 500.ms,
        duration: 1500.ms,
        color: AppColors.primary.withOpacity(0.3));
  }

  Widget _buildQueryBubble(String text) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(16), vertical: Responsive.pp(12)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Responsive.wp(20)),
        border: Border.all(
          color: AppColors.borderLight,
          width: Responsive.wp(1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: Responsive.wp(10),
            offset: Offset(0, Responsive.wp(4)),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_rounded,
              size: Responsive.sp(16), color: AppColors.primary),
          SizedBox(width: Responsive.wp(8)),
          Flexible(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(14),
                color: AppColors.textDark,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OnboardingSlide {
  final String emoji;
  final String title;
  final String subtitle;
  final String? punchline;
  final bool isSnapBot;

  OnboardingSlide({
    required this.emoji,
    required this.title,
    required this.subtitle,
    this.punchline,
    this.isSnapBot = false,
  });
}
