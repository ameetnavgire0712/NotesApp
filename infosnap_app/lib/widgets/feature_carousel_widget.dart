import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/theme/app_colors.dart';
import '../core/utils/responsive.dart';

/// Compact Feature Carousel Widget - Theme-aware, minimal design
class FeatureCarouselWidget extends StatefulWidget {
  final double? height;
  final bool autoPlay;
  final Duration autoPlayDuration;
  final EdgeInsets? padding;

  const FeatureCarouselWidget({
    super.key,
    this.height,
    this.autoPlay = true,
    this.autoPlayDuration = const Duration(seconds: 5),
    this.padding,
  });

  @override
  State<FeatureCarouselWidget> createState() => _FeatureCarouselWidgetState();
}

class _FeatureCarouselWidgetState extends State<FeatureCarouselWidget> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  static const List<_FeatureCard> _features = [
    _FeatureCard(
      icon: Icons.cloud_download_outlined,
      title: 'Save Anything',
      description:
          'Web pages, documents, images—AI extracts and understands it all',
    ),
    _FeatureCard(
      icon: Icons.auto_awesome_outlined,
      title: 'AI Organization',
      description: 'Automatic tagging and categorization—no folders needed',
    ),
    _FeatureCard(
      icon: Icons.lightbulb_outline_rounded,
      title: 'Smart Recall',
      description: 'AI surfaces relevant saved content as you browse',
    ),
    _FeatureCard(
      icon: Icons.chat_outlined,
      title: 'Ask Snapbot',
      description: 'Chat with your knowledge base in natural language',
    ),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.autoPlay) {
      _startAutoPlay();
    }
  }

  void _startAutoPlay() {
    Future.delayed(widget.autoPlayDuration, () {
      if (mounted) {
        final nextIndex = (_currentIndex + 1) % _features.length;
        _pageController.animateToPage(
          nextIndex,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
        _startAutoPlay();
      }
    });
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
    final effectiveHeight = widget.height ?? Responsive.wp(140);

    return Container(
      height: effectiveHeight,
      padding: widget.padding,
      child: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemCount: _features.length,
              itemBuilder: (context, index) {
                return _buildCard(
                  _features[index],
                  index == _currentIndex,
                  isDark,
                  colorScheme,
                );
              },
            ),
          ),

          SizedBox(height: Responsive.wp(12)),

          // Dot indicators
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              _features.length,
              (index) => GestureDetector(
                onTap: () {
                  _pageController.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: EdgeInsets.symmetric(horizontal: Responsive.wp(3)),
                  width: _currentIndex == index
                      ? Responsive.wp(16)
                      : Responsive.wp(6),
                  height: Responsive.wp(6),
                  decoration: BoxDecoration(
                    color: _currentIndex == index
                        ? AppColors.primary
                        : (isDark ? AppColors.border : AppColors.borderLight),
                    borderRadius: BorderRadius.circular(Responsive.wp(3)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(
    _FeatureCard feature,
    bool isActive,
    bool isDark,
    ColorScheme colorScheme,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(16)),
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(Responsive.wp(16)),
          border: Border.all(
            color: isDark ? AppColors.border : AppColors.borderLight,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(Responsive.pp(16)),
          child: Row(
            children: [
              // Icon
              Container(
                width: Responsive.wp(52),
                height: Responsive.wp(52),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(isDark ? 0.2 : 0.1),
                  borderRadius: BorderRadius.circular(Responsive.wp(14)),
                ),
                child: Icon(
                  feature.icon,
                  color: AppColors.primary,
                  size: Responsive.sp(24),
                ),
              )
                  .animate(target: isActive ? 1 : 0)
                  .scale(duration: 250.ms, curve: Curves.easeOut),

              SizedBox(width: Responsive.wp(14)),

              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      feature.title,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: Responsive.sp(16),
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: Responsive.wp(4)),
                    Text(
                      feature.description,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(13),
                        color: colorScheme.onSurface.withOpacity(0.7),
                        height: 1.4,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ).animate(target: isActive ? 1 : 0).fadeIn(duration: 250.ms);
  }
}

class _FeatureCard {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
  });
}
