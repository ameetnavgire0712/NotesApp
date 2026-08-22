import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/utils/responsive.dart';

/// Feature Showcase - Premium visual design with animations
class FeatureShowcaseScreen extends StatefulWidget {
  final VoidCallback? onComplete;
  final bool showSkip;

  const FeatureShowcaseScreen({
    super.key,
    this.onComplete,
    this.showSkip = true,
  });

  @override
  State<FeatureShowcaseScreen> createState() => _FeatureShowcaseScreenState();
}

class _FeatureShowcaseScreenState extends State<FeatureShowcaseScreen>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentIndex = 0;
  late AnimationController _bgController;
  late AnimationController _floatController;
  late AnimationController _orbitController;

  final List<_Feature> _features = [
    _Feature(
      icon: Icons.cloud_download_rounded,
      title: 'Upload / Save Anything',
      subtitle: 'From social media to searchable memory',
      description:
          'Share reels, shorts, posts, pages, screenshots, files, and notes. InfoSnap captures the content, extracts meaning, and prepares it for SnapBot.',
      gradient: [const Color(0xFF10B981), const Color(0xFF2563EB)],
      points: ['Share from apps', 'AI extracts context', 'Ask later'],
      isSocialSaveHero: true,
    ),
    _Feature(
      icon: Icons.chat_bubble_rounded,
      title: 'Ask SnapBot',
      subtitle: 'Answers from your own knowledge',
      description: 'Ask naturally and get concise, source-backed answers.',
      gradient: [const Color(0xFF4facfe), const Color(0xFF00f2fe)],
      points: ['Ask anything', 'Cross-note reasoning', 'Cited answers'],
      isSnapBotHero: true,
    ),
    _Feature(
      icon: Icons.auto_awesome_rounded,
      title: 'AI Understands',
      subtitle: 'Organized without manual work',
      description:
          'InfoSnap auto-tags, connects ideas, and keeps everything structured.',
      gradient: [const Color(0xFF11998e), const Color(0xFF38ef7d)],
      points: ['Smart tagging', 'Meaning links', 'Clean library'],
      isAiUnderstandsHero: true,
    ),
    _Feature(
      icon: Icons.psychology_rounded,
      title: 'Smart Recall',
      subtitle: 'Find what matters fast',
      description: 'Use natural language to pull the right note in seconds.',
      gradient: [const Color(0xFFf093fb), const Color(0xFFf5576c)],
      points: ['Natural search', 'Fast retrieval', 'Right context'],
      isSmartRecallHero: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      duration: const Duration(seconds: 20),
      vsync: this,
    )..repeat();
    _floatController = AnimationController(
      duration: const Duration(seconds: 4),
      vsync: this,
    )..repeat(reverse: true);
    _orbitController = AnimationController(
      duration: const Duration(seconds: 7),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _bgController.dispose();
    _floatController.dispose();
    _orbitController.dispose();
    super.dispose();
  }

  void _nextSlide() {
    if (_currentIndex < _features.length - 1) {
      _pageController.animateToPage(
        _currentIndex + 1,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onComplete() {
    if (widget.onComplete != null) {
      widget.onComplete!();
    } else if (Navigator.of(context).canPop()) {
      context.pop();
    } else {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0a0f1a) : Colors.white,
      body: Stack(
        children: [
          // Animated gradient background
          AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) {
              return CustomPaint(
                painter: _GradientBackgroundPainter(
                  progress: _bgController.value,
                  colors: _features[_currentIndex].gradient,
                  isDark: isDark,
                ),
                size: size,
              );
            },
          ),

          // Floating orbs
          ..._buildFloatingOrbs(size, isDark),

          // Main content
          SafeArea(
            child: Column(
              children: [
                _buildHeader(isDark, colorScheme),
                _buildProgressBar(isDark),
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    onPageChanged: (i) => setState(() => _currentIndex = i),
                    itemCount: _features.length,
                    itemBuilder: (context, i) => _buildFeaturePage(
                        _features[i], i == _currentIndex, isDark),
                  ),
                ),
                _buildBottomSection(isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFloatingOrbs(Size size, bool isDark) {
    return [
      AnimatedBuilder(
        animation: _floatController,
        builder: (context, child) {
          final offset = _floatController.value * 20 - 10;
          return Positioned(
            top: size.height * 0.15 + offset,
            right: size.width * 0.1,
            child: _Orb(
              size: 120,
              color: _features[_currentIndex].gradient[0].withOpacity(0.15),
            ),
          );
        },
      ),
      AnimatedBuilder(
        animation: _floatController,
        builder: (context, child) {
          final offset = (1 - _floatController.value) * 15 - 7;
          return Positioned(
            bottom: size.height * 0.25 + offset,
            left: size.width * 0.05,
            child: _Orb(
              size: 80,
              color: _features[_currentIndex].gradient[1].withOpacity(0.12),
            ),
          );
        },
      ),
      AnimatedBuilder(
        animation: _floatController,
        builder: (context, child) {
          final offset = _floatController.value * 12 - 6;
          return Positioned(
            top: size.height * 0.5 + offset,
            right: size.width * 0.15,
            child: _Orb(
              size: 50,
              color: _features[_currentIndex].gradient[0].withOpacity(0.1),
            ),
          );
        },
      ),
    ];
  }

  Widget _buildHeader(bool isDark, ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(20),
        vertical: Responsive.pp(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_rounded,
                  size: Responsive.sp(20),
                  color: colorScheme.onSurface.withOpacity(0.7),
                ),
                onPressed: () => context.pop(),
              ),
              Text(
                'Discover',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: Responsive.sp(20),
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
          if (widget.showSkip && _currentIndex < _features.length - 1)
            TextButton(
              onPressed: _onComplete,
              child: Text(
                'Skip',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(14),
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(bool isDark) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(24)),
      child: Row(
        children: List.generate(_features.length, (i) {
          final isActive = i == _currentIndex;
          final isPast = i < _currentIndex;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: Responsive.wp(4),
              margin: EdgeInsets.symmetric(horizontal: Responsive.wp(3)),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Responsive.wp(2)),
                gradient: isActive || isPast
                    ? LinearGradient(colors: _features[_currentIndex].gradient)
                    : null,
                color: isActive || isPast
                    ? null
                    : (isDark ? Colors.white12 : Colors.black12),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildFeaturePage(_Feature feature, bool isActive, bool isDark) {
    if (feature.isSocialSaveHero) {
      return _buildSocialSaveFeaturePage(feature, isActive, isDark);
    }
    if (feature.isAiUnderstandsHero) {
      return _buildAiUnderstandsFeaturePage(feature, isActive, isDark);
    }
    if (feature.isSnapBotHero) {
      return _buildSnapBotFeaturePage(feature, isActive, isDark);
    }
    if (feature.isSmartRecallHero) {
      return _buildSmartRecallFeaturePage(feature, isActive, isDark);
    }

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(24)),
      child: Column(
        children: [
          SizedBox(height: Responsive.wp(40)),

          // Hero icon with glow
          _buildHeroIcon(feature, isActive, isDark),

          SizedBox(height: Responsive.wp(32)),

          // Title
          Text(
            feature.title,
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: Responsive.sp(32),
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black87,
              height: 1.1,
            ),
          )
              .animate(target: isActive ? 1 : 0)
              .fadeIn(delay: 100.ms, duration: 400.ms)
              .slideY(begin: 0.2),

          SizedBox(height: Responsive.wp(8)),

          // Subtitle with gradient
          ShaderMask(
            shaderCallback: (bounds) =>
                LinearGradient(colors: feature.gradient).createShader(bounds),
            child: Text(
              feature.subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(16),
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          )
              .animate(target: isActive ? 1 : 0)
              .fadeIn(delay: 150.ms, duration: 400.ms),

          SizedBox(height: Responsive.wp(28)),

          // Description card
          _buildDescriptionCard(feature, isActive, isDark),

          SizedBox(height: Responsive.wp(24)),

          // Infographic flow row
          _buildInfographicFlow(feature, isActive, isDark),

          SizedBox(height: Responsive.wp(40)),
        ],
      ),
    );
  }

  Widget _buildAiUnderstandsFeaturePage(
      _Feature feature, bool isActive, bool isDark) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(16)),
      child: Column(
        children: [
          SizedBox(height: Responsive.wp(16)),
          _AiUnderstandsFramedHero(
            controller: _orbitController,
            isActive: isActive,
            isDark: isDark,
          ),
          SizedBox(height: Responsive.wp(24)),
        ],
      ),
    );
  }

  Widget _buildSnapBotFeaturePage(
      _Feature feature, bool isActive, bool isDark) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(16)),
      child: Column(
        children: [
          SizedBox(height: Responsive.wp(16)),
          _SnapBotFramedHero(
            controller: _orbitController,
            isActive: isActive,
          ),
          SizedBox(height: Responsive.wp(24)),
        ],
      ),
    );
  }

  Widget _buildSmartRecallFeaturePage(
      _Feature feature, bool isActive, bool isDark) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(16)),
      child: Column(
        children: [
          SizedBox(height: Responsive.wp(16)),
          _SmartRecallFramedHero(
            controller: _orbitController,
            isActive: isActive,
          ),
          SizedBox(height: Responsive.wp(24)),
        ],
      ),
    );
  }

  Widget _buildSocialSaveFeaturePage(
      _Feature feature, bool isActive, bool isDark) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(16)),
      child: Column(
        children: [
          SizedBox(height: Responsive.wp(16)),
          _LightSocialSaveHero(
            feature: feature,
            isActive: isActive,
            floatController: _floatController,
            orbitController: _orbitController,
          ),
          SizedBox(height: Responsive.wp(24)),
        ],
      ),
    );
  }

  Widget _buildHeroIcon(_Feature feature, bool isActive, bool isDark) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer glow ring
        Container(
          width: Responsive.wp(140),
          height: Responsive.wp(140),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                feature.gradient[0].withOpacity(0.2),
                feature.gradient[1].withOpacity(0.05),
                Colors.transparent,
              ],
            ),
          ),
        ).animate(target: isActive ? 1 : 0).scale(
            begin: Offset(0.8, 0.8),
            duration: 500.ms,
            curve: Curves.easeOutBack),

        // Inner glow
        Container(
          width: Responsive.wp(110),
          height: Responsive.wp(110),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                feature.gradient[0].withOpacity(0.3),
                feature.gradient[1].withOpacity(0.1),
              ],
            ),
          ),
        ),

        // Icon container
        Container(
          width: Responsive.wp(88),
          height: Responsive.wp(88),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: feature.gradient,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: feature.gradient[0].withOpacity(0.4),
                blurRadius: Responsive.wp(30),
                spreadRadius: Responsive.wp(5),
              ),
            ],
          ),
          child: Icon(
            feature.icon,
            size: Responsive.sp(40),
            color: Colors.white,
          ),
        ).animate(target: isActive ? 1 : 0).scale(
            begin: Offset(0.7, 0.7),
            duration: 600.ms,
            curve: Curves.elasticOut),
      ],
    );
  }

  Widget _buildDescriptionCard(_Feature feature, bool isActive, bool isDark) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Responsive.pp(24)),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.05)
            : Colors.black.withOpacity(0.03),
        borderRadius: BorderRadius.circular(Responsive.wp(20)),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.1)
              : Colors.black.withOpacity(0.05),
        ),
        boxShadow: [
          BoxShadow(
            color: feature.gradient[0].withOpacity(0.05),
            blurRadius: Responsive.wp(40),
            offset: Offset(0, Responsive.wp(10)),
          ),
        ],
      ),
      child: Text(
        feature.description,
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: Responsive.sp(16),
          height: 1.7,
          color: isDark ? Colors.white70 : Colors.black54,
        ),
      ),
    )
        .animate(target: isActive ? 1 : 0)
        .fadeIn(delay: 200.ms, duration: 400.ms)
        .slideY(begin: 0.1);
  }

  Widget _buildInfographicFlow(_Feature feature, bool isActive, bool isDark) {
    final cards = feature.points.take(3).toList();
    return Row(
      children: [
        Expanded(
          child: _buildFlowCard(
              cards.isNotEmpty ? cards[0] : '', feature, isDark, isActive, 0),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: Responsive.wp(6)),
          child: Icon(
            Icons.arrow_forward_rounded,
            size: Responsive.sp(16),
            color: isDark ? Colors.white54 : Colors.black45,
          ),
        ),
        Expanded(
          child: _buildFlowCard(
              cards.length > 1 ? cards[1] : '', feature, isDark, isActive, 1),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: Responsive.wp(6)),
          child: Icon(
            Icons.arrow_forward_rounded,
            size: Responsive.sp(16),
            color: isDark ? Colors.white54 : Colors.black45,
          ),
        ),
        Expanded(
          child: _buildFlowCard(
              cards.length > 2 ? cards[2] : '', feature, isDark, isActive, 2),
        ),
      ],
    );
  }

  Widget _buildFlowCard(
    String text,
    _Feature feature,
    bool isDark,
    bool isActive,
    int index,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(8),
        vertical: Responsive.pp(12),
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            feature.gradient[0].withOpacity(isDark ? 0.25 : 0.12),
            feature.gradient[1].withOpacity(isDark ? 0.15 : 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(Responsive.wp(12)),
        border: Border.all(
          color: feature.gradient[0].withOpacity(0.35),
        ),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: Responsive.sp(12),
          fontWeight: FontWeight.w700,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
    )
        .animate(target: isActive ? 1 : 0)
        .fadeIn(delay: Duration(milliseconds: 280 + index * 120))
        .scale(begin: Offset(0.9, 0.9));
  }

  Widget _buildBottomSection(bool isDark) {
    final isLast = _currentIndex == _features.length - 1;
    final feature = _features[_currentIndex];

    return Padding(
      padding: EdgeInsets.all(Responsive.pp(24)),
      child: Row(
        children: [
          // Page indicator
          Row(
            children: List.generate(_features.length, (i) {
              final isActive = i == _currentIndex;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                margin: EdgeInsets.only(right: Responsive.wp(8)),
                width: isActive ? Responsive.wp(24) : Responsive.wp(8),
                height: Responsive.wp(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Responsive.wp(4)),
                  gradient: isActive
                      ? LinearGradient(colors: feature.gradient)
                      : null,
                  color: isActive
                      ? null
                      : (isDark ? Colors.white24 : Colors.black12),
                ),
              );
            }),
          ),

          Spacer(),

          // Action button
          GestureDetector(
            onTap: isLast ? _onComplete : _nextSlide,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: Responsive.pp(isLast ? 32 : 24),
                vertical: Responsive.pp(16),
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: feature.gradient),
                borderRadius: BorderRadius.circular(Responsive.wp(16)),
                boxShadow: [
                  BoxShadow(
                    color: feature.gradient[0].withOpacity(0.4),
                    blurRadius: Responsive.wp(20),
                    offset: Offset(0, Responsive.wp(8)),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isLast ? 'Get Started' : 'Next',
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(16),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: Responsive.wp(8)),
                  Icon(
                    isLast
                        ? Icons.rocket_launch_rounded
                        : Icons.arrow_forward_rounded,
                    color: Colors.white,
                    size: Responsive.sp(20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Floating orb widget
class _Orb extends StatelessWidget {
  final double size;
  final Color color;

  const _Orb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withOpacity(0)],
        ),
      ),
    );
  }
}

class _LightSocialSaveHero extends StatelessWidget {
  final _Feature feature;
  final bool isActive;
  final AnimationController floatController;
  final AnimationController orbitController;

  const _LightSocialSaveHero({
    required this.feature,
    required this.isActive,
    required this.floatController,
    required this.orbitController,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(300.0, 760.0);
        final isCompact = width < 390;
        final heroHeight = isCompact ? 690.0 : 760.0;
        final phoneWidth =
            isCompact ? width * 0.7 : width.clamp(330, 390) * 0.78;
        final frameWidth = Responsive.wp(isCompact ? 5 : 8);
        final frameRadius = Responsive.wp(34);

        return Container(
          width: width,
          constraints: BoxConstraints(minHeight: heroHeight),
          margin: EdgeInsets.symmetric(
            horizontal: Responsive.wp(8),
            vertical: Responsive.wp(8),
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(frameRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.16),
                blurRadius: Responsive.wp(34),
                spreadRadius: -Responsive.wp(4),
                offset: Offset(0, Responsive.wp(16)),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(frameWidth),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(frameRadius - frameWidth),
              child: Container(
                color: const Color(0xFFFFFAF2),
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: _SoftGridBackdrop(
                        colors: [
                          Color(0xFFFFE8C7),
                          Color(0xFFFFFAF2),
                          Color(0xFFFCE7F3),
                          Color(0xFFE1F8EB),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        Responsive.pp(18),
                        Responsive.pp(24),
                        Responsive.pp(18),
                        0,
                      ),
                      child: Column(
                        children: [
                          const _OfficialBrandPill(),
                          SizedBox(height: Responsive.wp(16)),
                          Text.rich(
                            TextSpan(
                              children: [
                                const TextSpan(text: 'Save anything. '),
                                TextSpan(
                                  text: 'We get ',
                                  style: TextStyle(
                                    color: const Color(0xFF4F46E5),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                                TextSpan(
                                  text: 'it.',
                                  style: TextStyle(
                                    color: const Color(0xFFA43D5D),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                            textAlign: TextAlign.center,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: Responsive.sp(isCompact ? 40 : 48),
                              fontWeight: FontWeight.w600,
                              height: 0.94,
                              color: const Color(0xFF171717),
                            ),
                          )
                              .animate(target: isActive ? 1 : 0)
                              .fadeIn(duration: 480.ms)
                              .slideY(begin: 0.08),
                          SizedBox(height: Responsive.wp(14)),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: Text(
                              'Save social posts, videos, files and images. InfoSnap AI understands the context and makes every snap instantly searchable.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize:
                                    Responsive.sp(isCompact ? 13.2 : 14.5),
                                height: 1.48,
                                color: const Color(0xFF596174),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                              .animate(target: isActive ? 1 : 0)
                              .fadeIn(delay: 120.ms, duration: 480.ms),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: Responsive.wp(20),
                      height: isCompact ? 420 : 470,
                      child: _SaturnPhoneScene(
                        orbitController: orbitController,
                        phoneController: floatController,
                        sceneWidth: width,
                        phoneWidth: phoneWidth.clamp(250, 320),
                        compact: isCompact,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate(target: isActive ? 1 : 0)
            .fadeIn(duration: 520.ms)
            .scale(begin: const Offset(0.98, 0.98));
      },
    );
  }
}

class _SoftGridBackdrop extends StatelessWidget {
  final List<Color> colors;

  const _SoftGridBackdrop({
    this.colors = const [
      Color(0xFFFFE4BD),
      Color(0xFFFFFAF2),
      Color(0xFFFCE7F3),
      Color(0xFFE1F8EB),
    ],
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _SoftGridPainter(colors: colors));
  }
}

class _SoftGridPainter extends CustomPainter {
  final List<Color> colors;

  const _SoftGridPainter({required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(rect);
    canvas.drawRect(rect, bg);

    final gridPaint = Paint()
      ..color = Colors.black.withOpacity(0.045)
      ..strokeWidth = 1;
    const step = 28.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SoftGridPainter oldDelegate) =>
      oldDelegate.colors != colors;
}

class _SnapBotFramedHero extends StatelessWidget {
  final AnimationController controller;
  final bool isActive;

  const _SnapBotFramedHero({
    required this.controller,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(300.0, 760.0);
        final compact = width < 390;
        final heroHeight = compact ? 850.0 : 870.0;
        final frameWidth = Responsive.wp(compact ? 5 : 8);
        final frameRadius = Responsive.wp(34);

        return Container(
          width: width,
          constraints: BoxConstraints(minHeight: heroHeight),
          margin: EdgeInsets.symmetric(
            horizontal: Responsive.wp(8),
            vertical: Responsive.wp(8),
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(frameRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.16),
                blurRadius: Responsive.wp(34),
                spreadRadius: -Responsive.wp(4),
                offset: Offset(0, Responsive.wp(16)),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(frameWidth),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(frameRadius - frameWidth),
              child: Container(
                color: const Color(0xFFFFFAF2),
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: _SoftGridBackdrop(
                        colors: [
                          Color(0xFFE0F7FF),
                          Color(0xFFFFFCF7),
                          Color(0xFFE7F3FF),
                          Color(0xFFE4FAEF),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        Responsive.pp(18),
                        Responsive.pp(24),
                        Responsive.pp(18),
                        Responsive.pp(18),
                      ),
                      child: Column(
                        children: [
                          const _OfficialBrandPill(),
                          SizedBox(height: Responsive.wp(16)),
                          Text.rich(
                            TextSpan(
                              children: [
                                const TextSpan(text: 'Ask naturally. '),
                                TextSpan(
                                  text: 'SnapBot finds it.',
                                  style: TextStyle(
                                    color: const Color(0xFF16A34A),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                            textAlign: TextAlign.center,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: Responsive.sp(compact ? 36 : 45),
                              fontWeight: FontWeight.w600,
                              height: 0.96,
                              color: const Color(0xFF171717),
                            ),
                          )
                              .animate(target: isActive ? 1 : 0)
                              .fadeIn(duration: 480.ms)
                              .slideY(begin: 0.08),
                          SizedBox(height: Responsive.wp(14)),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 590),
                            child: Text(
                              'Ask in plain English. SnapBot searches your saved reels, pages, notes, files, and images to bring back the right sources.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: Responsive.sp(compact ? 13.2 : 14.5),
                                height: 1.5,
                                color: const Color(0xFF596174),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                              .animate(target: isActive ? 1 : 0)
                              .fadeIn(delay: 120.ms, duration: 480.ms),
                          SizedBox(height: Responsive.wp(compact ? 18 : 22)),
                          AnimatedBuilder(
                            animation: controller,
                            builder: (context, child) {
                              return _CleanSnapBotAnimatedSearchPhone(
                                width: (compact ? width * 0.78 : 285.0)
                                    .clamp(230.0, 305.0),
                                progress: controller.value,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate(target: isActive ? 1 : 0)
            .fadeIn(duration: 520.ms)
            .scale(begin: const Offset(0.98, 0.98));
      },
    );
  }
}

class _SnapBotAnimatedSearchPhone extends StatelessWidget {
  final double width;
  final double progress;

  const _SnapBotAnimatedSearchPhone({
    required this.width,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * 2.2;
    const query = 'places to eat';
    final typeProgress = (progress / 0.34).clamp(0.0, 1.0);
    final typedLength = (query.length * typeProgress).floor();
    final typedQuery = query.substring(0, typedLength);
    final resultsProgress = ((progress - 0.36) / 0.42).clamp(0.0, 1.0);
    final deeperPulse = math.sin(progress * math.pi * 2).abs();

    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(Responsive.wp(8)),
      decoration: BoxDecoration(
        color: const Color(0xFF09090B),
        borderRadius: BorderRadius.circular(Responsive.wp(36)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.24),
            blurRadius: Responsive.wp(34),
            offset: Offset(0, Responsive.wp(18)),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Responsive.wp(28)),
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.asset(
                'assets/help/snapbot_search_showcase.jpg',
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withOpacity(0.03),
                      Colors.transparent,
                      Colors.white.withOpacity(0.08),
                    ],
                    stops: const [0, 0.55, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              left: width * 0.12,
              right: width * 0.10,
              top: height * 0.145,
              child: Container(
                height: height * 0.055,
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.symmetric(horizontal: Responsive.wp(12)),
                decoration: BoxDecoration(
                  color: const Color(0xFF27B875),
                  borderRadius: BorderRadius.circular(Responsive.wp(16)),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF10B981).withOpacity(0.32),
                      blurRadius: Responsive.wp(18),
                      offset: Offset(0, Responsive.wp(8)),
                    ),
                  ],
                ),
                child: Text(
                  '$typedQuery${typeProgress < 1 ? "|" : ""}',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: Responsive.sp(14),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            Positioned(
              left: width * 0.13,
              right: width * 0.12,
              top: height * 0.30,
              child: _SnapBotResponseGlow(
                opacity: resultsProgress,
                delay: 0.0,
              ),
            ),
            Positioned(
              left: width * 0.17,
              right: width * 0.17,
              top: height * 0.38,
              child: _SnapBotResponseGlow(
                opacity: resultsProgress,
                delay: 0.18,
              ),
            ),
            Positioned(
              left: width * 0.17,
              right: width * 0.17,
              top: height * 0.47,
              child: _SnapBotResponseGlow(
                opacity: resultsProgress,
                delay: 0.36,
              ),
            ),
            Positioned(
              left: width * 0.17,
              right: width * 0.17,
              top: height * 0.56,
              child: _SnapBotResponseGlow(
                opacity: resultsProgress,
                delay: 0.54,
              ),
            ),
            Positioned(
              left: width * 0.18,
              top: height * 0.74,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: resultsProgress > 0.86 ? 1 : 0,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: Responsive.wp(12),
                    vertical: Responsive.wp(7),
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8FFF5).withOpacity(0.96),
                    borderRadius: BorderRadius.circular(Responsive.wp(12)),
                    border: Border.all(
                      color: const Color(0xFF10B981)
                          .withOpacity(0.44 + deeperPulse * 0.30),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF10B981)
                            .withOpacity(0.12 + deeperPulse * 0.14),
                        blurRadius: Responsive.wp(16),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome_mosaic_rounded,
                        color: const Color(0xFF10B981),
                        size: Responsive.sp(13),
                      ),
                      SizedBox(width: Responsive.wp(6)),
                      Text(
                        'Search deeper',
                        style: GoogleFonts.inter(
                          color: const Color(0xFF047857),
                          fontSize: Responsive.sp(11.5),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CleanSnapBotAnimatedSearchPhone extends StatelessWidget {
  final double width;
  final double progress;

  const _CleanSnapBotAnimatedSearchPhone({
    required this.width,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * 2.2;
    const query = 'places to eat';
    final typeProgress = (progress / 0.34).clamp(0.0, 1.0);
    final typedLength = (query.length * typeProgress).floor();
    final typedQuery = query.substring(0, typedLength);
    final responseProgress = ((progress - 0.36) / 0.44).clamp(0.0, 1.0);
    final pulse = math.sin(progress * math.pi * 2).abs();

    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(Responsive.wp(8)),
      decoration: BoxDecoration(
        color: const Color(0xFF09090B),
        borderRadius: BorderRadius.circular(Responsive.wp(36)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.24),
            blurRadius: Responsive.wp(34),
            offset: Offset(0, Responsive.wp(18)),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Responsive.wp(28)),
        child: Container(
          color: const Color(0xFFFFFEFA),
          child: Stack(
            children: [
              const Positioned.fill(
                child: _SoftGridBackdrop(
                  colors: [
                    Color(0xFFF8FEFF),
                    Color(0xFFFFFEFA),
                    Color(0xFFEAF7FF),
                    Color(0xFFE8FAF0),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  Responsive.wp(14),
                  Responsive.wp(24),
                  Responsive.wp(14),
                  Responsive.wp(12),
                ),
                child: Column(
                  children: [
                    _SnapBotPhoneHeader(width: width),
                    SizedBox(height: Responsive.wp(18)),
                    _SnapBotUserBubble(
                        query: typedQuery, typing: typeProgress < 1),
                    SizedBox(height: Responsive.wp(12)),
                    Expanded(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: responseProgress > 0.04 ? 1 : 0,
                        child: _SnapBotAnswerCard(progress: responseProgress),
                      ),
                    ),
                    SizedBox(height: Responsive.wp(10)),
                    _SnapBotTagFilter(progress: responseProgress),
                    SizedBox(height: Responsive.wp(9)),
                    _SnapBotInputBar(pulse: pulse),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SnapBotPhoneHeader extends StatelessWidget {
  final double width;

  const _SnapBotPhoneHeader({required this.width});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.arrow_back_rounded,
            color: const Color(0xFF172033), size: Responsive.sp(18)),
        SizedBox(width: Responsive.wp(12)),
        Container(
          width: Responsive.wp(30),
          height: Responsive.wp(30),
          decoration: BoxDecoration(
            color: const Color(0xFF24B981),
            borderRadius: BorderRadius.circular(Responsive.wp(10)),
          ),
          child: Icon(Icons.auto_awesome_rounded,
              color: Colors.white, size: Responsive.sp(16)),
        ),
        SizedBox(width: Responsive.wp(8)),
        Expanded(
          child: Text(
            'SnapBot',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.spaceGrotesk(
              color: const Color(0xFF172033),
              fontSize: Responsive.sp(20),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Icon(Icons.delete_outline_rounded,
            color: const Color(0xFF172033), size: Responsive.sp(19)),
      ],
    );
  }
}

class _SnapBotUserBubble extends StatelessWidget {
  final String query;
  final bool typing;

  const _SnapBotUserBubble({required this.query, required this.typing});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.only(left: Responsive.wp(26)),
        padding: EdgeInsets.symmetric(
          horizontal: Responsive.wp(15),
          vertical: Responsive.wp(13),
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF28B978),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(Responsive.wp(18)),
            topRight: Radius.circular(Responsive.wp(18)),
            bottomLeft: Radius.circular(Responsive.wp(18)),
            bottomRight: Radius.circular(Responsive.wp(4)),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF10B981).withOpacity(0.22),
              blurRadius: Responsive.wp(16),
              offset: Offset(0, Responsive.wp(8)),
            ),
          ],
        ),
        child: Text(
          query.isEmpty ? (typing ? '|' : '') : '$query${typing ? "|" : ""}',
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: Responsive.sp(14),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _SnapBotAnswerCard extends StatelessWidget {
  final double progress;

  const _SnapBotAnswerCard({required this.progress});

  @override
  Widget build(BuildContext context) {
    final items = [
      'Loco Otro, Aundh, Pune.',
      'Tiny Mangalorean gem in Bavdhan',
      'Pan-Asian ramen + bao spot',
      'Japanese ramen place in Pune',
      'Nostalgic viral cafe in Puje',
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Responsive.wp(13)),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(Responsive.wp(20)),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: Responsive.wp(18),
            offset: Offset(0, Responsive.wp(10)),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'I found 5 relevant documents for your query:',
            style: GoogleFonts.inter(
              color: const Color(0xFF172033),
              fontSize: Responsive.sp(13.2),
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: Responsive.wp(10)),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Responsive.wp(10)),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(Responsive.wp(14)),
              border: Border.all(color: Colors.black.withOpacity(0.06)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.description_outlined,
                        color: const Color(0xFF8A94A6),
                        size: Responsive.sp(13)),
                    SizedBox(width: Responsive.wp(6)),
                    Text(
                      '5 sources found',
                      style: GoogleFonts.inter(
                        color: const Color(0xFF7C8799),
                        fontSize: Responsive.sp(11.5),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Responsive.wp(8)),
                ...List.generate(items.length, (index) {
                  final visible =
                      ((progress - index * 0.14) / 0.22).clamp(0.0, 1.0);
                  return AnimatedOpacity(
                    opacity: visible,
                    duration: const Duration(milliseconds: 180),
                    child: Transform.translate(
                      offset: Offset(0, (1 - visible) * 10),
                      child: _SnapBotSourceRow(text: items[index]),
                    ),
                  );
                }),
              ],
            ),
          ),
          SizedBox(height: Responsive.wp(10)),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: progress > 0.8 ? 1 : 0,
            child: Text(
              'Not quite what you are looking for? Try searching deeper.',
              style: GoogleFonts.inter(
                color: const Color(0xFF8A8F9D),
                fontSize: Responsive.sp(10.8),
                fontStyle: FontStyle.italic,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapBotSourceRow extends StatelessWidget {
  final String text;

  const _SnapBotSourceRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: Responsive.wp(7)),
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.wp(9),
        vertical: Responsive.wp(8),
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(Responsive.wp(10)),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Icon(Icons.notes_rounded,
              color: const Color(0xFF22C190), size: Responsive.sp(12)),
          SizedBox(width: Responsive.wp(7)),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                color: const Color(0xFF172033),
                fontSize: Responsive.sp(11.2),
                height: 1.22,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapBotTagFilter extends StatelessWidget {
  final double progress;

  const _SnapBotTagFilter({required this.progress});

  @override
  Widget build(BuildContext context) {
    final tags = ['All', 'food', 'Pune'];
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: progress > 0.75 ? 1 : 0.35,
      child: Row(
        children: [
          Text(
            'Filter by Tag:',
            style: GoogleFonts.inter(
              color: const Color(0xFF7C8799),
              fontSize: Responsive.sp(10.5),
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(width: Responsive.wp(6)),
          ...tags.map((tag) {
            final selected = tag == 'All';
            return Container(
              margin: EdgeInsets.only(right: Responsive.wp(5)),
              padding: EdgeInsets.symmetric(
                horizontal: Responsive.wp(9),
                vertical: Responsive.wp(5),
              ),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF28B978) : Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.black.withOpacity(0.08)),
              ),
              child: Text(
                tag,
                style: GoogleFonts.inter(
                  color: selected ? Colors.white : const Color(0xFF596174),
                  fontSize: Responsive.sp(9.5),
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _SnapBotInputBar extends StatelessWidget {
  final double pulse;

  const _SnapBotInputBar({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: Responsive.wp(42),
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.symmetric(horizontal: Responsive.wp(12)),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(Responsive.wp(14)),
              border: Border.all(color: Colors.black.withOpacity(0.08)),
            ),
            child: Text(
              'What are you looking for?',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                color: const Color(0xFFADB3BF),
                fontSize: Responsive.sp(11.8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        SizedBox(width: Responsive.wp(8)),
        Container(
          width: Responsive.wp(42),
          height: Responsive.wp(42),
          decoration: BoxDecoration(
            color: const Color(0xFF28B978),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF10B981).withOpacity(0.18 + pulse * 0.18),
                blurRadius: Responsive.wp(16),
              ),
            ],
          ),
          child: Icon(Icons.send_rounded,
              color: Colors.white, size: Responsive.sp(18)),
        ),
      ],
    );
  }
}

class _SmartRecallFramedHero extends StatelessWidget {
  final AnimationController controller;
  final bool isActive;

  const _SmartRecallFramedHero({
    required this.controller,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(300.0, 760.0);
        final compact = width < 390;
        final heroHeight = compact ? 780.0 : 820.0;
        final frameWidth = Responsive.wp(compact ? 5 : 8);
        final frameRadius = Responsive.wp(34);

        return Container(
          width: width,
          constraints: BoxConstraints(minHeight: heroHeight),
          margin: EdgeInsets.symmetric(
            horizontal: Responsive.wp(8),
            vertical: Responsive.wp(8),
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(frameRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.16),
                blurRadius: Responsive.wp(34),
                spreadRadius: -Responsive.wp(4),
                offset: Offset(0, Responsive.wp(16)),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(frameWidth),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(frameRadius - frameWidth),
              child: Container(
                color: const Color(0xFFFFFAF2),
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: _SoftGridBackdrop(
                        colors: [
                          Color(0xFFF2E8FF),
                          Color(0xFFFFFBF5),
                          Color(0xFFFFE8F0),
                          Color(0xFFE7F6FF),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        Responsive.pp(18),
                        Responsive.pp(24),
                        Responsive.pp(18),
                        Responsive.pp(18),
                      ),
                      child: Column(
                        children: [
                          const _OfficialBrandPill(),
                          SizedBox(height: Responsive.wp(16)),
                          Text.rich(
                            TextSpan(
                              children: [
                                const TextSpan(text: 'Recall it '),
                                TextSpan(
                                  text: 'before you search.',
                                  style: TextStyle(
                                    color: const Color(0xFFB63B6C),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                            textAlign: TextAlign.center,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: Responsive.sp(compact ? 36 : 45),
                              fontWeight: FontWeight.w600,
                              height: 0.96,
                              color: const Color(0xFF171717),
                            ),
                          )
                              .animate(target: isActive ? 1 : 0)
                              .fadeIn(duration: 480.ms)
                              .slideY(begin: 0.08),
                          SizedBox(height: Responsive.wp(14)),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 590),
                            child: Text(
                              'When you search the web, InfoSnap can remind you about related things you already saved.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: Responsive.sp(compact ? 13.2 : 14.5),
                                height: 1.5,
                                color: const Color(0xFF596174),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                              .animate(target: isActive ? 1 : 0)
                              .fadeIn(delay: 120.ms, duration: 480.ms),
                          SizedBox(height: Responsive.wp(compact ? 20 : 26)),
                          AnimatedBuilder(
                            animation: controller,
                            builder: (context, child) {
                              return _SmartRecallBrowserPhone(
                                width: (compact ? width * 0.80 : 300.0)
                                    .clamp(235.0, 320.0),
                                progress: controller.value,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate(target: isActive ? 1 : 0)
            .fadeIn(duration: 520.ms)
            .scale(begin: const Offset(0.98, 0.98));
      },
    );
  }
}

class _SmartRecallBrowserPhone extends StatelessWidget {
  final double width;
  final double progress;

  const _SmartRecallBrowserPhone({
    required this.width,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * 1.82;
    const query = 'best romantic movies';
    final typeProgress = (progress / 0.36).clamp(0.0, 1.0);
    final typedLength = (query.length * typeProgress).floor();
    final typedQuery = query.substring(0, typedLength);
    final notificationProgress = ((progress - 0.42) / 0.28).clamp(0.0, 1.0);
    final pulse = math.sin(progress * math.pi * 2).abs();

    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(Responsive.wp(8)),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(Responsive.wp(36)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: Responsive.wp(34),
            offset: Offset(0, Responsive.wp(18)),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Responsive.wp(28)),
        child: Container(
          color: const Color(0xFFF8FAFC),
          child: Stack(
            children: [
              const Positioned.fill(
                child: _SoftGridBackdrop(
                  colors: [
                    Color(0xFFFFF7ED),
                    Color(0xFFFFFCF7),
                    Color(0xFFFCE7F3),
                    Color(0xFFEFF6FF),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.all(Responsive.wp(14)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BrowserTopBar(),
                    SizedBox(height: Responsive.wp(22)),
                    Center(
                      child: Text(
                        'Google',
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(31),
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF2C3442),
                        ),
                      ),
                    ),
                    SizedBox(height: Responsive.wp(18)),
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(
                        horizontal: Responsive.wp(12),
                        vertical: Responsive.wp(12),
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border:
                            Border.all(color: Colors.black.withOpacity(0.08)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: Responsive.wp(14),
                            offset: Offset(0, Responsive.wp(8)),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search_rounded,
                              color: const Color(0xFF8A94A6),
                              size: Responsive.sp(15)),
                          SizedBox(width: Responsive.wp(7)),
                          Expanded(
                            child: Text(
                              '$typedQuery${typeProgress < 1 ? "|" : ""}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                color: const Color(0xFF202938),
                                fontSize: Responsive.sp(12.8),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: Responsive.wp(22)),
                    _GoogleResultStub(
                        title: '25 best romantic movies to watch'),
                    _GoogleResultStub(title: 'Romantic movies streaming now'),
                    _GoogleResultStub(title: 'Classic romance film list'),
                  ],
                ),
              ),
              Positioned(
                top: Responsive.wp(92),
                right: Responsive.wp(10),
                child: Transform.translate(
                  offset: Offset((1 - notificationProgress) * 36, 0),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: notificationProgress,
                    child: _InfoSnapRecallPopup(pulse: pulse),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrowserTopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.arrow_back_ios_new_rounded,
            color: const Color(0xFF596174), size: Responsive.sp(12)),
        SizedBox(width: Responsive.wp(8)),
        Expanded(
          child: Container(
            height: Responsive.wp(28),
            padding: EdgeInsets.symmetric(horizontal: Responsive.wp(10)),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.black.withOpacity(0.06)),
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              'google.com',
              style: GoogleFonts.inter(
                color: const Color(0xFF8A94A6),
                fontSize: Responsive.sp(10),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        SizedBox(width: Responsive.wp(8)),
        Icon(Icons.more_vert_rounded,
            color: const Color(0xFF596174), size: Responsive.sp(15)),
      ],
    );
  }
}

class _GoogleResultStub extends StatelessWidget {
  final String title;

  const _GoogleResultStub({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: Responsive.wp(10)),
      padding: EdgeInsets.all(Responsive.wp(10)),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.72),
        borderRadius: BorderRadius.circular(Responsive.wp(12)),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: Responsive.wp(54),
            height: Responsive.wp(5),
            decoration: BoxDecoration(
              color: const Color(0xFF9CA3AF).withOpacity(0.45),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          SizedBox(height: Responsive.wp(7)),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              color: const Color(0xFF2563EB),
              fontSize: Responsive.sp(10.5),
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: Responsive.wp(5)),
          Container(
            width: double.infinity,
            height: Responsive.wp(5),
            decoration: BoxDecoration(
              color: const Color(0xFFCBD5E1).withOpacity(0.65),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoSnapRecallPopup extends StatelessWidget {
  final double pulse;

  const _InfoSnapRecallPopup({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Responsive.wp(158),
      padding: EdgeInsets.all(Responsive.wp(10)),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.98),
        borderRadius: BorderRadius.circular(Responsive.wp(16)),
        border: Border.all(
          color: const Color(0xFFB63B6C).withOpacity(0.22 + pulse * 0.18),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFB63B6C).withOpacity(0.16 + pulse * 0.12),
            blurRadius: Responsive.wp(22),
            offset: Offset(0, Responsive.wp(10)),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _OverlappingSquaresLogo(size: Responsive.wp(22)),
              SizedBox(width: Responsive.wp(7)),
              Expanded(
                child: RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: Responsive.sp(11),
                      fontWeight: FontWeight.w800,
                    ),
                    children: const [
                      TextSpan(
                          text: 'info',
                          style: TextStyle(color: Color(0xFF111827))),
                      TextSpan(
                          text: 'Snap',
                          style: TextStyle(color: Color(0xFF10B981))),
                      TextSpan(
                          text: '.ai',
                          style: TextStyle(color: Color(0xFF6B7280))),
                    ],
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: Responsive.wp(8)),
          Text(
            'You saved 3 related snaps',
            style: GoogleFonts.inter(
              color: const Color(0xFF172033),
              fontSize: Responsive.sp(10.4),
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: Responsive.wp(5)),
          Text(
            'Romantic watchlist, date-night picks, and movie quotes.',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              color: const Color(0xFF596174),
              fontSize: Responsive.sp(9.2),
              height: 1.28,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapBotResponseGlow extends StatelessWidget {
  final double opacity;
  final double delay;

  const _SnapBotResponseGlow({
    required this.opacity,
    required this.delay,
  });

  @override
  Widget build(BuildContext context) {
    final visible = ((opacity - delay) / 0.30).clamp(0.0, 1.0);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: visible,
      child: Container(
        height: Responsive.wp(34),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Responsive.wp(10)),
          border: Border.all(
            color: const Color(0xFF10B981).withOpacity(0.18 + visible * 0.28),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF10B981).withOpacity(0.10 + visible * 0.12),
              blurRadius: Responsive.wp(16),
              spreadRadius: Responsive.wp(1),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiUnderstandsHero extends StatelessWidget {
  final AnimationController controller;
  final bool isActive;
  final bool isDark;

  const _AiUnderstandsHero({
    required this.controller,
    required this.isActive,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(300.0, 680.0);
        final compact = width < 430;
        final phoneWidth = compact ? width * 0.72 : 250.0;
        final phoneHeight = phoneWidth * 1.78;

        return AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final progress = controller.value;
            return Container(
              width: width,
              padding: EdgeInsets.all(Responsive.pp(compact ? 8 : 12)),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(Responsive.wp(26)),
              ),
              child: compact
                  ? Column(
                      children: [
                        _AnimatedPhoneScanner(
                          width: phoneWidth.clamp(220, 280),
                          progress: progress,
                        ),
                        SizedBox(height: Responsive.wp(18)),
                        _ExtractionPanel(progress: progress, isDark: isDark),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: phoneWidth + 92,
                          height: phoneHeight + 30,
                          child: Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: [
                              _AnimatedPhoneScanner(
                                width: phoneWidth,
                                progress: progress,
                              ),
                              _FloatingExtractionChip(
                                text: 'Caption detected',
                                progress: progress,
                                threshold: 0.14,
                                alignment: const Alignment(-1.05, -0.58),
                                color: const Color(0xFF10B981),
                              ),
                              _FloatingExtractionChip(
                                text: 'Transcript generated',
                                progress: progress,
                                threshold: 0.30,
                                alignment: const Alignment(1.08, -0.28),
                                color: const Color(0xFF06B6D4),
                              ),
                              _FloatingExtractionChip(
                                text: 'Tags extracted',
                                progress: progress,
                                threshold: 0.47,
                                alignment: const Alignment(-1.05, 0.14),
                                color: const Color(0xFF8B5CF6),
                              ),
                              _FloatingExtractionChip(
                                text: 'Summary created',
                                progress: progress,
                                threshold: 0.68,
                                alignment: const Alignment(1.02, 0.50),
                                color: const Color(0xFFF59E0B),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: Responsive.wp(18)),
                        Expanded(
                          child: _ExtractionPanel(
                            progress: progress,
                            isDark: isDark,
                          ),
                        ),
                      ],
                    ),
            );
          },
        )
            .animate(target: isActive ? 1 : 0)
            .fadeIn(duration: 480.ms)
            .slideY(begin: 0.08);
      },
    );
  }
}

class _AiUnderstandsFramedHero extends StatelessWidget {
  final AnimationController controller;
  final bool isActive;
  final bool isDark;

  const _AiUnderstandsFramedHero({
    required this.controller,
    required this.isActive,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(300.0, 760.0);
        final compact = width < 390;
        final heroHeight = compact ? 830.0 : 850.0;
        final frameWidth = Responsive.wp(compact ? 5 : 8);
        final frameRadius = Responsive.wp(34);

        return Container(
          width: width,
          constraints: BoxConstraints(minHeight: heroHeight),
          margin: EdgeInsets.symmetric(
            horizontal: Responsive.wp(8),
            vertical: Responsive.wp(8),
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(frameRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.16),
                blurRadius: Responsive.wp(34),
                spreadRadius: -Responsive.wp(4),
                offset: Offset(0, Responsive.wp(16)),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(frameWidth),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(frameRadius - frameWidth),
              child: Container(
                color: const Color(0xFFFFFAF2),
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: _SoftGridBackdrop(
                        colors: [
                          Color(0xFFFFF1C9),
                          Color(0xFFFFFAF2),
                          Color(0xFFEAFBF0),
                          Color(0xFFE8F4FF),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        Responsive.pp(18),
                        Responsive.pp(24),
                        Responsive.pp(18),
                        0,
                      ),
                      child: Column(
                        children: [
                          const _OfficialBrandPill(),
                          SizedBox(height: Responsive.wp(16)),
                          Text.rich(
                            TextSpan(
                              children: [
                                const TextSpan(text: 'AI understands '),
                                TextSpan(
                                  text: 'what you save.',
                                  style: TextStyle(
                                    color: const Color(0xFF16A34A),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                            textAlign: TextAlign.center,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: Responsive.sp(compact ? 37 : 46),
                              fontWeight: FontWeight.w600,
                              height: 0.96,
                              color: const Color(0xFF171717),
                            ),
                          )
                              .animate(target: isActive ? 1 : 0)
                              .fadeIn(duration: 480.ms)
                              .slideY(begin: 0.08),
                          SizedBox(height: Responsive.wp(14)),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 590),
                            child: Text(
                              'InfoSnap reads captions, transcripts, tags, descriptions and your own notes, then turns every save into searchable knowledge.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: Responsive.sp(compact ? 13.2 : 14.5),
                                height: 1.5,
                                color: const Color(0xFF596174),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                              .animate(target: isActive ? 1 : 0)
                              .fadeIn(delay: 120.ms, duration: 480.ms),
                          SizedBox(height: Responsive.wp(compact ? 18 : 22)),
                          _AiUnderstandsHero(
                            controller: controller,
                            isActive: isActive,
                            isDark: false,
                          ),
                          SizedBox(height: Responsive.wp(18)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate(target: isActive ? 1 : 0)
            .fadeIn(duration: 520.ms)
            .scale(begin: const Offset(0.98, 0.98));
      },
    );
  }
}

class _AnimatedPhoneScanner extends StatelessWidget {
  final double width;
  final double progress;

  const _AnimatedPhoneScanner({
    required this.width,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * 1.78;
    final scanTravel = height - 96;
    final scanY = 48 + (progress * scanTravel);

    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(Responsive.wp(9)),
      decoration: BoxDecoration(
        color: const Color(0xFF09090B),
        borderRadius: BorderRadius.circular(Responsive.wp(36)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: Responsive.wp(34),
            offset: Offset(0, Responsive.wp(18)),
          ),
        ],
      ),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Responsive.wp(28)),
            child: Container(
              color: const Color(0xFF0B0F14),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Image.asset(
                      'assets/help/ai_understands_reel.jpg',
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      errorBuilder: (context, error, stackTrace) =>
                          const _FakeReelFrame(),
                    ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.04),
                            Colors.transparent,
                            Colors.black.withOpacity(0.30),
                          ],
                          stops: const [0, 0.52, 1],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: scanY,
                    left: Responsive.wp(12),
                    right: Responsive.wp(12),
                    child: Container(
                      height: Responsive.wp(42),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Responsive.wp(16)),
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            const Color(0xFF67E8F9).withOpacity(0.72),
                            const Color(0xFF34D399).withOpacity(0.34),
                            Colors.transparent,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF22D3EE).withOpacity(0.42),
                            blurRadius: Responsive.wp(26),
                            spreadRadius: Responsive.wp(2),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    top: scanY + Responsive.wp(18),
                    left: Responsive.wp(18),
                    right: Responsive.wp(18),
                    child: Container(
                      height: 2.2,
                      color: const Color(0xFF67E8F9).withOpacity(1),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: Responsive.wp(8),
            left: width * 0.34,
            right: width * 0.34,
            child: Container(
              height: Responsive.wp(16),
              decoration: BoxDecoration(
                color: const Color(0xFF09090B),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FakeReelFrame extends StatelessWidget {
  const _FakeReelFrame();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _ReelBackdropPainter()),
        ),
        Positioned(
          left: Responsive.wp(14),
          top: Responsive.wp(38),
          child: Row(
            children: [
              CircleAvatar(
                radius: Responsive.wp(13),
                backgroundColor: Colors.white.withOpacity(0.22),
                child: Icon(Icons.restaurant_rounded,
                    color: Colors.white, size: Responsive.sp(13)),
              ),
              SizedBox(width: Responsive.wp(8)),
              Text(
                'foodiesfood_court',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: Responsive.sp(10.5),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: Responsive.wp(14),
          top: Responsive.wp(138),
          child: Column(
            children: [
              _ReelAction(icon: Icons.favorite_border_rounded, label: '114K'),
              SizedBox(height: Responsive.wp(16)),
              _ReelAction(
                  icon: Icons.chat_bubble_outline_rounded, label: '250'),
              SizedBox(height: Responsive.wp(16)),
              _ReelAction(icon: Icons.send_rounded, label: 'Share'),
            ],
          ),
        ),
        Positioned(
          left: Responsive.wp(14),
          right: Responsive.wp(60),
          bottom: Responsive.wp(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Viral cheesy masala pasta recipe',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: Responsive.sp(13),
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: Responsive.wp(6)),
              Text(
                'Onion, garlic, tomato, cheese...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  color: Colors.white70,
                  fontSize: Responsive.sp(10.5),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReelAction extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ReelAction({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Colors.white, size: Responsive.sp(22)),
        SizedBox(height: Responsive.wp(3)),
        Text(
          label,
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: Responsive.sp(8),
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _ReelBackdropPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    paint.color = const Color(0xFFFAE8A4).withOpacity(0.65);
    canvas.drawCircle(Offset(size.width * 0.42, size.height * 0.48),
        size.width * 0.33, paint);
    paint.color = const Color(0xFFEF4444).withOpacity(0.9);
    for (final offset in [
      Offset(size.width * 0.32, size.height * 0.42),
      Offset(size.width * 0.55, size.height * 0.42),
      Offset(size.width * 0.44, size.height * 0.58),
    ]) {
      canvas.drawCircle(offset, size.width * 0.08, paint);
    }
    paint.color = const Color(0xFFE879F9).withOpacity(0.62);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.48, size.height * 0.50),
        width: size.width * 0.24,
        height: size.width * 0.12,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FloatingExtractionChip extends StatelessWidget {
  final String text;
  final double progress;
  final double threshold;
  final Alignment alignment;
  final Color color;

  const _FloatingExtractionChip({
    required this.text,
    required this.progress,
    required this.threshold,
    required this.alignment,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final active = progress >= threshold;
    final local =
        active ? ((progress - threshold) / 0.16).clamp(0.0, 1.0) : 0.0;
    final opacity = active ? local : 0.0;
    final lift = (1 - local) * 14;

    return Align(
      alignment: alignment,
      child: Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(0, lift),
          child: Container(
            constraints: BoxConstraints(maxWidth: Responsive.wp(150)),
            padding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(10),
              vertical: Responsive.pp(8),
            ),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.94),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withOpacity(0.22)),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.16),
                  blurRadius: Responsive.wp(18),
                  offset: Offset(0, Responsive.wp(8)),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome_rounded,
                    color: color, size: Responsive.sp(14)),
                SizedBox(width: Responsive.wp(6)),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(10.8),
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF172033),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExtractionPanel extends StatelessWidget {
  final double progress;
  final bool isDark;

  const _ExtractionPanel({
    required this.progress,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final rows = [
      _ExtractionItem('Caption', 'Recipe title and reel caption detected',
          Icons.closed_caption_rounded, 0.14),
      _ExtractionItem('Transcript', 'Spoken cooking steps generated',
          Icons.record_voice_over_rounded, 0.30),
      _ExtractionItem(
          'Tags', 'recipe, pasta, dinner, social', Icons.sell_rounded, 0.47),
      _ExtractionItem(
          'Description', 'User context understood', Icons.notes_rounded, 0.62),
      _ExtractionItem(
          'Summary', 'Ready for SnapBot search', Icons.search_rounded, 0.78),
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Responsive.pp(16)),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.06)
            : const Color(0xFFF8FAFC).withOpacity(0.92),
        borderRadius: BorderRadius.circular(Responsive.wp(22)),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.1)
              : Colors.black.withOpacity(0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: Responsive.wp(34),
                height: Responsive.wp(34),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF10B981), Color(0xFF06B6D4)],
                  ),
                  borderRadius: BorderRadius.circular(Responsive.wp(11)),
                ),
                child: Icon(Icons.document_scanner_rounded,
                    color: Colors.white, size: Responsive.sp(18)),
              ),
              SizedBox(width: Responsive.wp(10)),
              Expanded(
                child: Text(
                  'AI extracted',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: Responsive.sp(18),
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : const Color(0xFF101827),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: Responsive.wp(14)),
          ...rows.map((row) => _ExtractionPanelRow(
                item: row,
                active: progress >= row.threshold,
                isDark: isDark,
              )),
        ],
      ),
    );
  }
}

class _ExtractionPanelRow extends StatelessWidget {
  final _ExtractionItem item;
  final bool active;
  final bool isDark;

  const _ExtractionPanelRow({
    required this.item,
    required this.active,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF10B981) : const Color(0xFF94A3B8);
    return AnimatedOpacity(
      opacity: active ? 1 : 0.42,
      duration: const Duration(milliseconds: 220),
      child: Padding(
        padding: EdgeInsets.only(bottom: Responsive.wp(10)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: Responsive.wp(28),
              height: Responsive.wp(28),
              decoration: BoxDecoration(
                color: color.withOpacity(active ? 0.14 : 0.08),
                borderRadius: BorderRadius.circular(Responsive.wp(9)),
              ),
              child: Icon(item.icon, color: color, size: Responsive.sp(15)),
            ),
            SizedBox(width: Responsive.wp(10)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(12.4),
                      fontWeight: FontWeight.w900,
                      color: isDark ? Colors.white : const Color(0xFF172033),
                    ),
                  ),
                  SizedBox(height: Responsive.wp(2)),
                  Text(
                    item.detail,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(11),
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: Responsive.wp(6)),
            Icon(
              active
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              color: color,
              size: Responsive.sp(16),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExtractionItem {
  final String title;
  final String detail;
  final IconData icon;
  final double threshold;

  const _ExtractionItem(this.title, this.detail, this.icon, this.threshold);
}

class _OfficialBrandPill extends StatelessWidget {
  const _OfficialBrandPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(14),
        vertical: Responsive.pp(8),
      ),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.76),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withOpacity(0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: Responsive.wp(18),
            offset: Offset(0, Responsive.wp(8)),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _OverlappingSquaresLogo(size: 34),
          SizedBox(width: Responsive.wp(10)),
          RichText(
            text: TextSpan(
              style: GoogleFonts.spaceGrotesk(
                fontSize: Responsive.sp(22),
                fontWeight: FontWeight.w800,
                color: const Color(0xFF18181B),
              ),
              children: [
                const TextSpan(text: 'info'),
                const TextSpan(
                  text: 'Snap',
                  style: TextStyle(color: Color(0xFF16A34A)),
                ),
                TextSpan(
                  text: '.ai',
                  style: TextStyle(
                    color: const Color(0xFF71717A),
                    fontWeight: FontWeight.w500,
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

class _OfficialAppIcon extends StatelessWidget {
  final double size;

  const _OfficialAppIcon({required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.24),
            child: Image.asset('assets/icon_background.png', fit: BoxFit.cover),
          ),
          Padding(
            padding: EdgeInsets.all(size * 0.1),
            child:
                Image.asset('assets/icon_foreground.png', fit: BoxFit.contain),
          ),
        ],
      ),
    );
  }
}

class _OverlappingSquaresLogo extends StatelessWidget {
  final double size;

  const _OverlappingSquaresLogo({required this.size});

  @override
  Widget build(BuildContext context) {
    final square = size * 0.65;
    final offset = size * 0.2;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              width: square,
              height: square,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF22C55E), Color(0xFF15803D)],
                ),
                borderRadius: BorderRadius.circular(size * 0.15),
              ),
            ),
          ),
          Positioned(
            top: offset,
            left: offset,
            child: Container(
              width: square,
              height: square,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF22C55E).withOpacity(0.6),
                    const Color(0xFF15803D).withOpacity(0.8),
                  ],
                ),
                borderRadius: BorderRadius.circular(size * 0.15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SaturnPhoneScene extends StatelessWidget {
  final AnimationController orbitController;
  final AnimationController phoneController;
  final double sceneWidth;
  final double phoneWidth;
  final bool compact;

  const _SaturnPhoneScene({
    required this.orbitController,
    required this.phoneController,
    required this.sceneWidth,
    required this.phoneWidth,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: orbitController,
      builder: (context, child) {
        final orbit = _SocialSaturnOrbit.compute(
          progress: orbitController.value,
          width: sceneWidth,
          compact: compact,
        );
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            ...orbit.backBadges,
            _CasualMySnapsPhone(
              width: phoneWidth,
              controller: phoneController,
            ),
            ...orbit.frontBadges,
          ],
        );
      },
    );
  }
}

class _SocialSaturnOrbit {
  final List<Widget> backBadges;
  final List<Widget> frontBadges;

  const _SocialSaturnOrbit({
    required this.backBadges,
    required this.frontBadges,
  });

  static _SocialSaturnOrbit compute({
    required double progress,
    required double width,
    required bool compact,
  }) {
    final rx =
        math.min(width * (compact ? 0.47 : 0.44), compact ? 178.0 : 285.0);
    final ry = compact ? 24.0 : 34.0;
    final t = progress * 2 * math.pi;
    final backBadges = <Widget>[];
    final frontBadges = <Widget>[];

    for (var i = 0; i < _platforms.length; i++) {
      final phase = t + (i / _platforms.length) * 2 * math.pi;
      final x = math.cos(phase) * rx;
      final y = math.sin(phase) * ry;
      final front = math.sin(phase) > 0;
      final depth = (math.sin(phase) + 1) / 2;
      final scale = 0.72 + depth * 0.42;
      final opacity = 0.44 + depth * 0.56;
      final badge = Transform.translate(
        offset: Offset(x, y),
        child: Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
            child: _OrbitBadge(platform: _platforms[i], compact: compact),
          ),
        ),
      );
      if (front) {
        frontBadges.add(badge);
      } else {
        backBadges.add(badge);
      }
    }

    return _SocialSaturnOrbit(
      backBadges: backBadges,
      frontBadges: frontBadges,
    );
  }

  static const _platforms = [
    _PlatformBadge('Instagram', Color(0xFFE1306C), Icons.camera_alt_rounded),
    _PlatformBadge('YouTube', Color(0xFFFF0033), Icons.play_arrow_rounded),
    _PlatformBadge('Shorts', Color(0xFFFF0033), Icons.smart_display_rounded),
    _PlatformBadge('LinkedIn', Color(0xFF0A66C2), Icons.business_rounded),
    _PlatformBadge('X', Color(0xFF111827), Icons.alternate_email_rounded),
    _PlatformBadge('Reddit', Color(0xFFFF4500), Icons.forum_rounded),
    _PlatformBadge('Word', Color(0xFF2563EB), Icons.description_rounded),
    _PlatformBadge('Excel', Color(0xFF16A34A), Icons.table_chart_rounded),
    _PlatformBadge('Text', Color(0xFF475569), Icons.notes_rounded),
    _PlatformBadge('JPG', Color(0xFF9333EA), Icons.image_rounded),
    _PlatformBadge('PNG', Color(0xFF0891B2), Icons.photo_library_rounded),
  ];
}

class _OrbitBadge extends StatelessWidget {
  final _PlatformBadge platform;
  final bool compact;

  const _OrbitBadge({required this.platform, required this.compact});

  @override
  Widget build(BuildContext context) {
    final size = compact ? 50.0 : 66.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.94),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: Responsive.wp(18),
            offset: Offset(0, Responsive.wp(8)),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            platform.icon,
            color: platform.color,
            size: Responsive.sp(compact ? 18 : 23),
          ),
          SizedBox(height: Responsive.wp(3)),
          Text(
            platform.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(compact ? 7.2 : 8.4),
              fontWeight: FontWeight.w900,
              color: platform.color,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

class _CasualMySnapsPhone extends StatelessWidget {
  final double width;
  final AnimationController controller;

  const _CasualMySnapsPhone({
    required this.width,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * 1.48;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final bob = math.sin(controller.value * 2 * math.pi) * 7;
        return Transform.translate(
          offset: Offset(0, bob),
          child: Transform.rotate(
            angle: -0.10 + math.sin(controller.value * 2 * math.pi) * 0.015,
            child: child,
          ),
        );
      },
      child: Container(
        width: width,
        height: height,
        padding: EdgeInsets.all(Responsive.wp(9)),
        decoration: BoxDecoration(
          color: const Color(0xFF171717),
          borderRadius: BorderRadius.circular(Responsive.wp(38)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.22),
              blurRadius: Responsive.wp(34),
              offset: Offset(0, Responsive.wp(18)),
            ),
          ],
        ),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Responsive.wp(30)),
              child: Container(
                color: Colors.white,
                child: Stack(
                  children: [
                    const Positioned.fill(child: _SoftGridBackdrop()),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        Responsive.pp(18),
                        Responsive.pp(42),
                        Responsive.pp(18),
                        Responsive.pp(18),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '9:41',
                                style: GoogleFonts.inter(
                                  fontSize: Responsive.sp(10),
                                  fontWeight: FontWeight.w900,
                                  color: const Color(0xFF18181B),
                                ),
                              ),
                              Text(
                                '•••',
                                style: GoogleFonts.inter(
                                  fontSize: Responsive.sp(16),
                                  fontWeight: FontWeight.w900,
                                  color: const Color(0xFF18181B),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: Responsive.wp(18)),
                          Text(
                            'LIBRARY',
                            style: GoogleFonts.inter(
                              fontSize: Responsive.sp(10),
                              letterSpacing: 0,
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF8B8B95),
                            ),
                          ),
                          Text(
                            'My Snaps',
                            style: GoogleFonts.playfairDisplay(
                              fontSize: Responsive.sp(27),
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF18181B),
                              height: 1.0,
                            ),
                          ),
                          SizedBox(height: Responsive.wp(16)),
                          _SnapPreviewCard(
                            color: const Color(0xFFFF5C62),
                            label: 'YOUTUBE',
                            title: 'How AI changed design',
                            detail: 'Transcript + summary',
                            icon: Icons.play_arrow_rounded,
                          ),
                          SizedBox(height: Responsive.wp(12)),
                          _SnapPreviewCard(
                            color: const Color(0xFFE0529C),
                            label: 'REEL',
                            title: '30-second pasta recipe',
                            detail: 'Caption + visual context',
                            icon: Icons.camera_alt_rounded,
                          ),
                          SizedBox(height: Responsive.wp(12)),
                          _SnapPreviewCard(
                            color: const Color(0xFF2FA8DC),
                            label: 'LINKEDIN',
                            title: 'Pricing lessons for SaaS',
                            detail: 'Key ideas extracted',
                            icon: Icons.business_rounded,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: Responsive.wp(8),
              left: width * 0.34,
              right: width * 0.34,
              child: Container(
                height: Responsive.wp(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF171717),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapPreviewCard extends StatelessWidget {
  final Color color;
  final String label;
  final String title;
  final String detail;
  final IconData icon;

  const _SnapPreviewCard({
    required this.color,
    required this.label,
    required this.title,
    required this.detail,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Responsive.pp(9)),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.86),
        borderRadius: BorderRadius.circular(Responsive.wp(18)),
        border: Border.all(color: Colors.black.withOpacity(0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: Responsive.wp(16),
            offset: Offset(0, Responsive.wp(7)),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: Responsive.wp(48),
            height: Responsive.wp(48),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(Responsive.wp(14)),
            ),
            child: Icon(icon, color: Colors.white, size: Responsive.sp(22)),
          ),
          SizedBox(width: Responsive.wp(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(9),
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
                SizedBox(height: Responsive.wp(2)),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(11.5),
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF18181B),
                  ),
                ),
                SizedBox(height: Responsive.wp(2)),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(9.5),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF71717A),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: Responsive.wp(6)),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: Responsive.pp(7),
              vertical: Responsive.pp(4),
            ),
            decoration: BoxDecoration(
              color: const Color(0xFFFFE4F3),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '+AI',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(9),
                fontWeight: FontWeight.w900,
                color: const Color(0xFFDB2777),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlatformBadge {
  final String label;
  final Color color;
  final IconData icon;

  const _PlatformBadge(this.label, this.color, this.icon);
}

class _SocialSaveAnimation extends StatelessWidget {
  final _Feature feature;
  final bool isActive;
  final bool isDark;
  final AnimationController floatController;

  const _SocialSaveAnimation({
    required this.feature,
    required this.isActive,
    required this.isDark,
    required this.floatController,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.clamp(280.0, 430.0);
        final phoneWidth = (maxWidth * 0.43).clamp(128.0, 178.0);

        return SizedBox(
          width: maxWidth,
          child: Column(
            children: [
              _buildSocialOrbit(maxWidth),
              SizedBox(height: Responsive.wp(14)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: _SharePhoneMockup(
                      width: phoneWidth,
                      feature: feature,
                      isDark: isDark,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: Responsive.wp(6)),
                    child: AnimatedBuilder(
                      animation: floatController,
                      builder: (context, child) {
                        return Transform.translate(
                          offset: Offset(floatController.value * 5 - 2.5, 0),
                          child: child,
                        );
                      },
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        color: feature.gradient[0],
                        size: Responsive.sp(26),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _AiPhoneMockup(
                      width: phoneWidth,
                      feature: feature,
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
            ],
          ),
        )
            .animate(target: isActive ? 1 : 0)
            .fadeIn(duration: 520.ms)
            .slideY(begin: 0.08)
            .scale(begin: const Offset(0.96, 0.96));
      },
    );
  }

  Widget _buildSocialOrbit(double maxWidth) {
    final icons = [
      _SocialIconData('IG', const Color(0xFFE1306C), Icons.camera_alt_rounded),
      _SocialIconData('YT', const Color(0xFFFF0033), Icons.play_arrow_rounded),
      _SocialIconData('in', const Color(0xFF0A66C2), Icons.business_rounded),
      _SocialIconData('X', const Color(0xFF111827), Icons.alternate_email),
      _SocialIconData('FB', const Color(0xFF1877F2), Icons.thumb_up_rounded),
      _SocialIconData('WA', const Color(0xFF25D366), Icons.chat_rounded),
    ];

    return AnimatedBuilder(
      animation: floatController,
      builder: (context, child) {
        return Container(
          height: Responsive.wp(120).clamp(104, 132),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Responsive.wp(24)),
            gradient: LinearGradient(
              colors: [
                feature.gradient[0].withOpacity(isDark ? 0.22 : 0.13),
                feature.gradient[1].withOpacity(isDark ? 0.18 : 0.1),
              ],
            ),
            border: Border.all(color: feature.gradient[0].withOpacity(0.24)),
            boxShadow: [
              BoxShadow(
                color: feature.gradient[0].withOpacity(0.16),
                blurRadius: Responsive.wp(28),
                offset: Offset(0, Responsive.wp(12)),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _ShareFlowPainter(
                    color: feature.gradient[0].withOpacity(0.28),
                    progress: floatController.value,
                  ),
                ),
              ),
              Container(
                width: Responsive.wp(68),
                height: Responsive.wp(68),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Responsive.wp(20)),
                  gradient: LinearGradient(colors: feature.gradient),
                  boxShadow: [
                    BoxShadow(
                      color: feature.gradient[0].withOpacity(0.35),
                      blurRadius: Responsive.wp(20),
                      offset: Offset(0, Responsive.wp(8)),
                    ),
                  ],
                ),
                child: const Icon(Icons.hub_rounded, color: Colors.white),
              ),
              ...List.generate(icons.length, (index) {
                final angle = (index / icons.length) * math.pi * 2 +
                    floatController.value * 0.35;
                final radiusX = maxWidth * 0.34;
                final radiusY = Responsive.wp(38).clamp(30, 44);
                return Transform.translate(
                  offset: Offset(
                    math.cos(angle) * radiusX,
                    math.sin(angle) * radiusY,
                  ),
                  child: _SocialIconBadge(data: icons[index]),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

class _SharePhoneMockup extends StatelessWidget {
  final double width;
  final _Feature feature;
  final bool isDark;

  const _SharePhoneMockup({
    required this.width,
    required this.feature,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * 1.72;
    return Center(
      child: Container(
        width: width,
        height: height,
        padding: EdgeInsets.all(Responsive.wp(8)),
        decoration: _phoneDecoration(isDark, feature),
        child: Column(
          children: [
            _phoneHandle(isDark),
            SizedBox(height: Responsive.wp(8)),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(Responsive.wp(18)),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Responsive.wp(18)),
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xFF111827),
                                Color(0xFF1F2937),
                                Color(0xFF064E3B),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: Responsive.wp(10),
                      right: Responsive.wp(10),
                      bottom: Responsive.wp(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Cooking reel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: Responsive.sp(11),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: Responsive.wp(5)),
                          Text(
                            'Saved from Instagram',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              color: Colors.white70,
                              fontSize: Responsive.sp(9.5),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      right: Responsive.wp(10),
                      top: Responsive.wp(24),
                      child: Column(
                        children: [
                          _sideAction(Icons.favorite_border_rounded, '114K'),
                          SizedBox(height: Responsive.wp(11)),
                          _sideAction(Icons.chat_bubble_outline_rounded, '250'),
                          SizedBox(height: Responsive.wp(11)),
                          _sideAction(Icons.send_rounded, 'Share',
                              highlighted: true),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: Responsive.wp(8)),
            _miniShareSheet(),
          ],
        ),
      ),
    );
  }

  Widget _sideAction(IconData icon, String label, {bool highlighted = false}) {
    return Column(
      children: [
        Container(
          width: Responsive.wp(highlighted ? 34 : 28),
          height: Responsive.wp(highlighted ? 34 : 28),
          decoration: BoxDecoration(
            color: highlighted ? feature.gradient[0] : Colors.white12,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withOpacity(0.3)),
          ),
          child: Icon(icon, size: Responsive.sp(14), color: Colors.white),
        ),
        SizedBox(height: Responsive.wp(3)),
        Text(
          label,
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: Responsive.sp(7.5),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _miniShareSheet() {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(9),
        vertical: Responsive.pp(7),
      ),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.08) : Colors.white,
        borderRadius: BorderRadius.circular(Responsive.wp(14)),
        border: Border.all(color: feature.gradient[0].withOpacity(0.18)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _tinyAppIcon('info', feature.gradient[0]),
          SizedBox(width: Responsive.wp(6)),
          Flexible(
            child: Text(
              'Share to InfoSnap',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(9.5),
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiPhoneMockup extends StatelessWidget {
  final double width;
  final _Feature feature;
  final bool isDark;

  const _AiPhoneMockup({
    required this.width,
    required this.feature,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * 1.72;
    return Center(
      child: Container(
        width: width,
        height: height,
        padding: EdgeInsets.all(Responsive.wp(8)),
        decoration: _phoneDecoration(isDark, feature),
        child: Column(
          children: [
            _phoneHandle(isDark),
            SizedBox(height: Responsive.wp(8)),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.all(Responsive.wp(10)),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : Colors.white,
                  borderRadius: BorderRadius.circular(Responsive.wp(18)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: Responsive.wp(24),
                          height: Responsive.wp(24),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: feature.gradient),
                            borderRadius:
                                BorderRadius.circular(Responsive.wp(8)),
                          ),
                          child: Icon(Icons.auto_awesome_rounded,
                              color: Colors.white, size: Responsive.sp(13)),
                        ),
                        SizedBox(width: Responsive.wp(7)),
                        Expanded(
                          child: Text(
                            'AI parsing',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: Responsive.sp(11),
                              fontWeight: FontWeight.w900,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: Responsive.wp(12)),
                    _aiRow('Title', 'Viral cheesy masala pasta'),
                    _aiRow('Caption', 'Recipe steps + ingredients'),
                    _aiRow('Transcript', 'Onion, garlic, tomato...'),
                    _aiRow('Key info', 'Quick dinner recipe'),
                    const Spacer(),
                    Wrap(
                      spacing: Responsive.wp(5),
                      runSpacing: Responsive.wp(5),
                      children: [
                        _tag('recipe'),
                        _tag('pasta'),
                        _tag('social'),
                      ],
                    ),
                    SizedBox(height: Responsive.wp(9)),
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(
                        horizontal: Responsive.pp(8),
                        vertical: Responsive.pp(7),
                      ),
                      decoration: BoxDecoration(
                        color: feature.gradient[0].withOpacity(0.12),
                        borderRadius: BorderRadius.circular(Responsive.wp(10)),
                      ),
                      child: Text(
                        'Ready for SnapBot',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(9.5),
                          color: feature.gradient[0],
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _aiRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.wp(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(7.5),
              letterSpacing: 0,
              color: feature.gradient[0],
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: Responsive.wp(3)),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(9.5),
              height: 1.25,
              color: isDark ? Colors.white70 : Colors.black.withOpacity(0.65),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(7),
        vertical: Responsive.pp(4),
      ),
      decoration: BoxDecoration(
        color: feature.gradient[1].withOpacity(0.12),
        borderRadius: BorderRadius.circular(Responsive.wp(99)),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: Responsive.sp(7.8),
          color: feature.gradient[1],
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

BoxDecoration _phoneDecoration(bool isDark, _Feature feature) {
  return BoxDecoration(
    color: isDark ? Colors.white.withOpacity(0.08) : Colors.white,
    borderRadius: BorderRadius.circular(Responsive.wp(24)),
    border: Border.all(
      color: isDark ? Colors.white12 : Colors.black.withOpacity(0.08),
    ),
    boxShadow: [
      BoxShadow(
        color: feature.gradient[0].withOpacity(0.18),
        blurRadius: Responsive.wp(22),
        offset: Offset(0, Responsive.wp(10)),
      ),
    ],
  );
}

Widget _phoneHandle(bool isDark) {
  return Container(
    width: Responsive.wp(34),
    height: Responsive.wp(4),
    decoration: BoxDecoration(
      color: isDark ? Colors.white24 : Colors.black12,
      borderRadius: BorderRadius.circular(Responsive.wp(10)),
    ),
  );
}

Widget _tinyAppIcon(String text, Color color) {
  return Container(
    width: Responsive.wp(22),
    height: Responsive.wp(22),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(Responsive.wp(7)),
    ),
    child: Center(
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: Responsive.sp(6.8),
          color: Colors.white,
          fontWeight: FontWeight.w900,
        ),
      ),
    ),
  );
}

class _SocialIconBadge extends StatelessWidget {
  final _SocialIconData data;

  const _SocialIconBadge({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Responsive.wp(42),
      height: Responsive.wp(42),
      decoration: BoxDecoration(
        color: data.color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.45)),
        boxShadow: [
          BoxShadow(
            color: data.color.withOpacity(0.35),
            blurRadius: Responsive.wp(14),
            offset: Offset(0, Responsive.wp(6)),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(data.icon,
              color: Colors.white.withOpacity(0.96), size: Responsive.sp(18)),
          Positioned(
            right: Responsive.wp(7),
            bottom: Responsive.wp(6),
            child: Text(
              data.label,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(7),
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SocialIconData {
  final String label;
  final Color color;
  final IconData icon;

  const _SocialIconData(this.label, this.color, this.icon);
}

class _ShareFlowPainter extends CustomPainter {
  final Color color;
  final double progress;

  _ShareFlowPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = color;

    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.76,
        height: size.height * 0.58,
      ),
      paint,
    );

    final dotPaint = Paint()..color = color.withOpacity(0.65);
    for (var i = 0; i < 5; i++) {
      final t = (progress + i / 5) * math.pi * 2;
      final dot = Offset(
        center.dx + math.cos(t) * size.width * 0.38,
        center.dy + math.sin(t) * size.height * 0.29,
      );
      canvas.drawCircle(dot, 2.2, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ShareFlowPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

// Animated gradient background painter
class _GradientBackgroundPainter extends CustomPainter {
  final double progress;
  final List<Color> colors;
  final bool isDark;

  _GradientBackgroundPainter({
    required this.progress,
    required this.colors,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Base color
    final basePaint = Paint()
      ..color = isDark ? const Color(0xFF0a0f1a) : Colors.white;
    canvas.drawRect(rect, basePaint);

    // Animated gradient blobs
    final angle = progress * 2 * math.pi;
    final centerX = size.width * 0.5 + math.cos(angle) * size.width * 0.2;
    final centerY = size.height * 0.3 + math.sin(angle) * size.height * 0.1;

    final gradient1 = RadialGradient(
      center: Alignment(
        (centerX / size.width) * 2 - 1,
        (centerY / size.height) * 2 - 1,
      ),
      radius: 0.8,
      colors: [
        colors[0].withOpacity(isDark ? 0.08 : 0.06),
        colors[0].withOpacity(0),
      ],
    );

    final gradient2 = RadialGradient(
      center: Alignment(
        -math.cos(angle + math.pi / 3) * 0.5,
        math.sin(angle + math.pi / 3) * 0.3 + 0.4,
      ),
      radius: 0.6,
      colors: [
        colors[1].withOpacity(isDark ? 0.06 : 0.04),
        colors[1].withOpacity(0),
      ],
    );

    canvas.drawRect(rect, Paint()..shader = gradient1.createShader(rect));
    canvas.drawRect(rect, Paint()..shader = gradient2.createShader(rect));
  }

  @override
  bool shouldRepaint(covariant _GradientBackgroundPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.colors != colors ||
        oldDelegate.isDark != isDark;
  }
}

class _Feature {
  final IconData icon;
  final String title;
  final String subtitle;
  final String description;
  final List<Color> gradient;
  final List<String> points;
  final bool isSocialSaveHero;
  final bool isAiUnderstandsHero;
  final bool isSnapBotHero;
  final bool isSmartRecallHero;

  const _Feature({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.gradient,
    required this.points,
    this.isSocialSaveHero = false,
    this.isAiUnderstandsHero = false,
    this.isSnapBotHero = false,
    this.isSmartRecallHero = false,
  });
}
