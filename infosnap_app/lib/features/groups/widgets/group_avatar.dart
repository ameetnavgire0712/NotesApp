import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/responsive.dart';

class GroupAvatar extends StatelessWidget {
  final String seed;
  final String name;
  final String? imageUrl;
  final double size;
  final double borderRadius;
  final IconData fallbackIcon;

  const GroupAvatar({
    super.key,
    required this.seed,
    required this.name,
    required this.size,
    this.imageUrl,
    this.borderRadius = 18,
    this.fallbackIcon = Icons.groups_rounded,
  });

  static const List<List<Color>> _palettes = [
    [Color(0xFF22C55E), Color(0xFF15803D)],
    [Color(0xFF0EA5E9), Color(0xFF1D4ED8)],
    [Color(0xFFF59E0B), Color(0xFFEA580C)],
    [Color(0xFFEC4899), Color(0xFFBE185D)],
    [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
    [Color(0xFF14B8A6), Color(0xFF0F766E)],
    [Color(0xFFEF4444), Color(0xFFB91C1C)],
    [Color(0xFF6366F1), Color(0xFF3730A3)],
  ];

  int get _paletteIndex {
    final base = seed.trim().isNotEmpty ? seed.trim() : name.trim();
    var hash = 0;
    for (final codeUnit in base.codeUnits) {
      hash = (hash + codeUnit) % 2147483647;
    }
    return hash % _palettes.length;
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palettes[_paletteIndex];
    final trimmedUrl = imageUrl?.trim();
    final radius = BorderRadius.circular(borderRadius);

    return ClipRRect(
      borderRadius: radius,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: palette,
          ),
        ),
        child: trimmedUrl != null && trimmedUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: trimmedUrl,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) =>
                    _FallbackAvatar(icon: fallbackIcon),
              )
            : _FallbackAvatar(icon: fallbackIcon),
      ),
    );
  }
}

class _FallbackAvatar extends StatelessWidget {
  final IconData icon;

  const _FallbackAvatar({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.center,
          child: Icon(
            icon,
            color: Colors.white.withOpacity(0.86),
            size: Responsive.sp(24),
          ),
        ),
      ],
    );
  }
}
