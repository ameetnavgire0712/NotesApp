import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../utils/responsive.dart';

class TagInputField extends StatefulWidget {
  const TagInputField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.isDark,
    this.labelText,
    this.prefixIcon,
    this.fillColor,
    this.contentPadding,
    this.borderRadius,
    this.style,
    this.hintStyle,
    this.autofocus = false,
    this.maxLength,
  });

  final TextEditingController controller;
  final String hintText;
  final bool isDark;
  final String? labelText;
  final IconData? prefixIcon;
  final Color? fillColor;
  final EdgeInsetsGeometry? contentPadding;
  final BorderRadius? borderRadius;
  final TextStyle? style;
  final TextStyle? hintStyle;
  final bool autofocus;
  final int? maxLength;

  @override
  State<TagInputField> createState() => _TagInputFieldState();
}

class _TagInputFieldState extends State<TagInputField> {
  final FocusNode _focusNode = FocusNode();
  Timer? _hideTimer;

  List<String> _availableTags = const [];
  bool _isLoading = false;
  bool _hasLoaded = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
    widget.controller.addListener(_handleTextChange);
  }

  @override
  void didUpdateWidget(covariant TagInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTextChange);
      widget.controller.addListener(_handleTextChange);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _focusNode.removeListener(_handleFocusChange);
    widget.controller.removeListener(_handleTextChange);
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _ensureTagsLoaded({bool forceRefresh = false}) async {
    if (_isLoading || (_hasLoaded && !forceRefresh)) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final tags = await ApiService().fetchTags(forceRefresh: forceRefresh);
    if (!mounted) {
      return;
    }

    final uniqueTags = <String>[];
    final seen = <String>{};
    for (final tag in tags) {
      final value = tag.trim();
      if (value.isEmpty || !seen.add(value)) {
        continue;
      }
      uniqueTags.add(value);
    }

    setState(() {
      _availableTags = uniqueTags;
      _hasLoaded = true;
      _isLoading = false;
    });
  }

  void _handleFocusChange() {
    _hideTimer?.cancel();
    if (_focusNode.hasFocus) {
      _ensureTagsLoaded();
      setState(() {});
      return;
    }

    _hideTimer = Timer(const Duration(milliseconds: 120), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _handleTextChange() {
    if (_focusNode.hasFocus && !_hasLoaded) {
      _ensureTagsLoaded();
    }
    if (mounted) {
      setState(() {});
    }
  }

  List<String> get _filteredTags {
    final query = widget.controller.text.trim().toLowerCase();
    if (query.isEmpty) {
      return _availableTags;
    }
    return _availableTags
        .where((tag) => tag.toLowerCase().contains(query))
        .toList();
  }

  bool get _showDropdown =>
      _focusNode.hasFocus && (_isLoading || _filteredTags.isNotEmpty);

  void _selectTag(String tag) {
    _hideTimer?.cancel();
    widget.controller.value = TextEditingValue(
      text: tag,
      selection: TextSelection.collapsed(offset: tag.length),
    );
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final borderRadius =
        widget.borderRadius ?? BorderRadius.circular(Responsive.wp(12));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          maxLength: widget.maxLength,
          style: widget.style ??
              GoogleFonts.inter(
                fontSize: Responsive.sp(14),
                color: widget.isDark ? Colors.white : Colors.black,
              ),
          decoration: InputDecoration(
            hintText: widget.hintText,
            labelText: widget.labelText,
            hintStyle: widget.hintStyle ??
                GoogleFonts.inter(
                  fontSize: Responsive.sp(14),
                  color: widget.isDark ? Colors.grey[500] : Colors.grey[400],
                ),
            prefixIcon: widget.prefixIcon == null
                ? null
                : Icon(
                    widget.prefixIcon,
                    size: Responsive.sp(18),
                    color: widget.isDark ? Colors.grey[400] : Colors.grey[500],
                  ),
            filled: true,
            fillColor: widget.fillColor ??
                (widget.isDark
                    ? const Color(0xFF374151)
                    : const Color(0xFFF1F5F9)),
            border: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: BorderSide.none,
            ),
            contentPadding: widget.contentPadding ??
                EdgeInsets.symmetric(
                  horizontal: Responsive.pp(14),
                  vertical: Responsive.pp(12),
                ),
            counterText: '',
          ),
        ),
        if (_showDropdown) ...[
          SizedBox(height: Responsive.wp(6)),
          Material(
            elevation: 6,
            color: widget.isDark ? const Color(0xFF1F2937) : Colors.white,
            borderRadius: borderRadius,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: widget.isDark ? const Color(0xFF1F2937) : Colors.white,
                borderRadius: borderRadius,
                border: Border.all(
                  color: widget.isDark
                      ? const Color(0xFF4B5563)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: _isLoading
                  ? Padding(
                      padding: EdgeInsets.all(Responsive.pp(12)),
                      child: Row(
                        children: [
                          SizedBox(
                            width: Responsive.wp(16),
                            height: Responsive.wp(16),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: Responsive.wp(10)),
                          Text(
                            'Loading tags...',
                            style: GoogleFonts.inter(
                              fontSize: Responsive.sp(13),
                              color: widget.isDark
                                  ? Colors.white70
                                  : const Color(0xFF475569),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.symmetric(vertical: Responsive.pp(4)),
                      itemCount: _filteredTags.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        color: widget.isDark
                            ? const Color(0xFF374151)
                            : const Color(0xFFE2E8F0),
                      ),
                      itemBuilder: (context, index) {
                        final tag = _filteredTags[index];
                        return InkWell(
                          onTap: () => _selectTag(tag),
                          borderRadius: borderRadius,
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: Responsive.pp(14),
                              vertical: Responsive.pp(10),
                            ),
                            child: Text(
                              tag,
                              style: GoogleFonts.inter(
                                fontSize: Responsive.sp(13),
                                color: widget.isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ],
    );
  }
}
