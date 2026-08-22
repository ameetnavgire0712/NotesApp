import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';

/// Feature Showcase - Clean, minimal, theme-aware design
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

class _FeatureShowcaseScreenState extends State<FeatureShowcaseScreen> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  final List<_Feature> _features = const [
    _Feature(
      icon: Icons.cloud_download_outlined,
      title: 'Save Anything',
      subtitle: 'Web pages, documents, images',
      description:
          'Capture content from anywhere. Our AI extracts and understands it so you can search and ask questions later.',
      points: [
        'Browser extension for one-click saves',
        'Upload PDFs, images, and documents',
        'AI extracts text and key information',
      ],
    ),
    _Feature(
      icon: Icons.auto_awesome_outlined,
      title: 'AI-Powered Organization',
      subtitle: 'No folders. No manual sorting.',
      description:
          'AI automatically tags and categorizes your content. Everything is searchable by meaning, not just keywords.',
      points: [
        'Smart auto-tagging',
        'Semantic search across all content',
        'Find anything by describing it',
      ],
    ),
    _Feature(
      icon: Icons.lightbulb_outline_rounded,
      title: 'Smart Recall',
      subtitle: 'Surfaces what you need, when you need it',
      description:
          'As you browse, InfoSnap recognizes relevant saved content and surfaces it automatically.',
      points: [
        'Chrome extension integration',
        'Context-aware suggestions',
        'Never forget what you saved',
      ],
    ),
    _Feature(
      icon: Icons.chat_outlined,
      title: 'Ask Snapbot',
      subtitle: 'Chat with your knowledge base',
      description:
          'Ask questions in natural language. Snapbot searches your saved content and gives you direct answers.',
      points: [
        '"Where\'s my passport scan?"',
        '"Show invoices from last month"',
        '"What did that article say about..."',
      ],
    ),
  ];

  void _nextSlide() {
    if (_currentIndex < _features.length - 1) {
      _pageController.animateToPage(
        _currentIndex + 1,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onComplete() {
    if (widget.onComplete != null) {
      widget.onComplete!();
    } else {
      context.go('/home');
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Subtle hexagon background
          const Positioned.fill(child: HexagonBackground()),

          SafeArea(
            child: Column(
              children: [
                // Header
                _buildHeader(isDark, colorScheme),

                // Progress indicators
                _buildProgressIndicators(isDark),

                SizedBox(height: Responsive.wp(2)),

                // Content
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    onPageChanged: (index) =>
                        setState(() => _currentIndex = index),
                    itemCount: _features.length,
                    itemBuilder: (context, index) {
                      return _buildFeaturePage(
                        _features[index],
                        index == _currentIndex,
                        isDark,
                        colorScheme,
                      );
                    },
                  ),
                ),

                // Bottom button
                _buildBottomButton(isDark),
              ],
            ),
          ),
        ],
      ),
    );
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
          // Back button or Logo
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
                'Features',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: Responsive.sp(18),
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
          // Skip
          if (widget.showSkip && _currentIndex < _features.length - 1)
            TextButton(
              onPressed: _onComplete,
              child: Text(
                'Skip',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(14),
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicators(bool isDark) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(24)),
      child: Row(
        children: List.generate(_features.length, (index) {
          final isActive = index == _currentIndex;
          final isPast = index < _currentIndex;
          return Expanded(
            child: Container(
              height: Responsive.wp(3),
              margin: EdgeInsets.symmetric(horizontal: Responsive.wp(2)),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Responsive.wp(2)),
                color: isActive || isPast
                    ? AppColors.primary
                    : (isDark ? AppColors.border : AppColors.borderLight),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildFeaturePage(
    _Feature feature,
    bool isActive,
    bool isDark,
    ColorScheme colorScheme,
  ) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: Responsive.wp(4)),

          // Icon with subtle background
          Center(
            child: Container(
              width: Responsive.wp(88),
              height: Responsive.wp(88),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(isDark ? 0.15 : 0.1),
                borderRadius: BorderRadius.circular(Responsive.wp(24)),
              ),
              child: Icon(
                feature.icon,
                size: Responsive.sp(40),
                color: AppColors.primary,
              ),
            )
                .animate(target: isActive ? 1 : 0)
                .fadeIn(duration: 300.ms)
                .scale(begin: Offset(0.9, 0.9), curve: Curves.easeOutBack),
          ),

          SizedBox(height: Responsive.wp(4)),

          // Title
          Center(
            child: Text(
              feature.title,
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: Responsive.sp(28),
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
                height: 1.2,
              ),
            )
                .animate(target: isActive ? 1 : 0)
                .fadeIn(delay: 100.ms, duration: 300.ms)
                .slideY(begin: 0.1),
          ),

          SizedBox(height: 1),

          // Subtitle
          Center(
            child: Text(
              feature.subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(16),
                fontWeight: FontWeight.w500,
                color: AppColors.primary,
              ),
            )
                .animate(target: isActive ? 1 : 0)
                .fadeIn(delay: 150.ms, duration: 300.ms),
          ),

          SizedBox(height: Responsive.wp(3)),

          // Description card
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Responsive.pp(20)),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(Responsive.wp(16)),
              border: Border.all(
                color: isDark ? AppColors.border : AppColors.borderLight,
              ),
            ),
            child: Text(
              feature.description,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(15),
                height: 1.6,
                color: colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
          )
              .animate(target: isActive ? 1 : 0)
              .fadeIn(delay: 200.ms, duration: 300.ms)
              .slideY(begin: 0.05),

          SizedBox(height: Responsive.wp(3)),

          // Feature points
          ...feature.points.asMap().entries.map((entry) {
            return _buildFeaturePoint(
              entry.value,
              entry.key,
              isActive,
              isDark,
              colorScheme,
            );
          }),

          SizedBox(height: Responsive.wp(4)),
        ],
      ),
    );
  }

  Widget _buildFeaturePoint(
    String text,
    int index,
    bool isActive,
    bool isDark,
    ColorScheme colorScheme,
  ) {
    final isQuery = text.startsWith('"') && text.endsWith('"');

    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.wp(1.5)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: Responsive.wp(28),
            height: Responsive.wp(28),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(isDark ? 0.2 : 0.1),
              borderRadius: BorderRadius.circular(Responsive.wp(8)),
            ),
            child: Icon(
              isQuery ? Icons.chat_bubble_outline_rounded : Icons.check_rounded,
              size: Responsive.sp(16),
              color: AppColors.primary,
            ),
          ),
          SizedBox(width: Responsive.wp(12)),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(14),
                height: 1.5,
                color: colorScheme.onSurface.withOpacity(0.85),
                fontStyle: isQuery ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    )
        .animate(target: isActive ? 1 : 0)
        .fadeIn(delay: Duration(milliseconds: 250 + (index * 80)))
        .slideX(begin: 0.05);
  }

  Widget _buildBottomButton(bool isDark) {
    final isLastSlide = _currentIndex == _features.length - 1;

    return Padding(
      padding: EdgeInsets.all(Responsive.pp(24)),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: isLastSlide ? _onComplete : _nextSlide,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            padding: EdgeInsets.symmetric(vertical: Responsive.pp(16)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Responsive.wp(14)),
            ),
            elevation: 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLastSlide) ...[
                Icon(Icons.check_rounded, size: Responsive.sp(20)),
                SizedBox(width: Responsive.wp(8)),
              ],
              Text(
                isLastSlide ? 'Got it' : 'Next',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(16),
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!isLastSlide) ...[
                SizedBox(width: Responsive.wp(8)),
                Icon(Icons.arrow_forward_rounded, size: Responsive.sp(20)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Feature {
  final IconData icon;
  final String title;
  final String subtitle;
  final String description;
  final List<String> points;

  const _Feature({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.points,
  });
}
