import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_colors.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/api_service.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _isSigningOut = false;
  bool _billingLoading = true;
  bool _billingActionLoading = false;
  BillingStatus? _billingStatus;
  String? _localAvatarUrl;
  bool _avatarUploading = false;

  @override
  void initState() {
    super.initState();
    _loadBillingStatus();
  }

  Future<void> _loadBillingStatus() async {
    final status = await ApiService().fetchBillingStatus();
    if (!mounted) return;
    setState(() {
      _billingStatus = status;
      _billingLoading = false;
    });
  }

  String _contentTypeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }

  Future<void> _pickAndUploadAvatar() async {
    if (_avatarUploading) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    if (!mounted || picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _avatarUploading = true);
    final avatarUrl = await ApiService().uploadUserAvatar(
      bytes: bytes,
      filename: picked.name,
      contentType: _contentTypeFor(picked.name),
    );
    if (!mounted) return;
    if (avatarUrl != null) {
      // Persist into Supabase auth user metadata so the photoUrl is restored
      // on next sign-in.
      try {
        await Supabase.instance.client.auth.updateUser(
          UserAttributes(data: {'avatar_url': avatarUrl}),
        );
      } catch (e) {
        debugPrint('updateUser metadata failed: $e');
      }
      // Update authUserProvider so other screens (Home header) refresh.
      ref.read(authUserProvider.notifier).setPhotoUrl(avatarUrl);
    }
    if (!mounted) return;
    setState(() {
      _avatarUploading = false;
      if (avatarUrl != null) _localAvatarUrl = avatarUrl;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          avatarUrl != null
              ? 'Profile picture updated'
              : 'Could not upload profile picture',
        ),
      ),
    );
  }

  Future<void> _runBillingAction(
      Future<BillingStatus?> Function() action, String successMessage) async {
    if (_billingActionLoading) return;
    setState(() => _billingActionLoading = true);
    final status = await action();
    if (!mounted) return;
    setState(() {
      _billingStatus = status ?? _billingStatus;
      _billingActionLoading = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(status == null ? 'Could not update plan' : successMessage),
        backgroundColor: status == null ? AppColors.error : AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleSignOut() async {
    setState(() => _isSigningOut = true);

    try {
      // Sign out via auth service
      await ref.read(authUserProvider.notifier).signOut();

      // Small delay to ensure Supabase auth state change is processed
      await Future.delayed(const Duration(milliseconds: 300));

      // Navigate to splash screen
      if (mounted) {
        // Use pushReplacement to clear the navigation stack
        GoRouter.of(context).go('/splash');
      }
    } catch (e) {
      debugPrint('Sign out error: $e');
      if (mounted) {
        setState(() => _isSigningOut = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign out failed. Please try again.')),
        );
      }
    }
  }

  void _showSignOutDialog() {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        insetPadding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(20),
          vertical: Responsive.pp(24),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(16)),
        ),
        title: Text(
          'Sign Out',
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: Responsive.sp(18),
          ),
        ),
        content: Text(
          'Are you sure you want to sign out?',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withOpacity(0.8),
            fontSize: Responsive.sp(14),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                fontSize: Responsive.sp(14),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _handleSignOut();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Responsive.wp(8)),
              ),
            ),
            child: Text(
              'Sign Out',
              style:
                  TextStyle(color: Colors.white, fontSize: Responsive.sp(14)),
            ),
          ),
        ],
      ),
    );
  }

  void _showHelpCenter() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _HelpCenterSheet(
        guides: const [
          _HelpGuide(
            title: 'Upload from Android',
            subtitle: 'What you can save from the InfoSnap Android app.',
            icon: Icons.cloud_upload_outlined,
            colors: [Color(0xFF06B6D4), Color(0xFF22C55E)],
            visual: _HelpVisual.androidUpload,
            tips: [
              'Use Save URL for regular webpages, articles, blogs, and other non-social-media links.',
              'Use Quick Note for thoughts, reminders, ideas, or any text you want SnapBot to find later.',
              'Upload files like PDF, Word, TXT, HTML, Markdown, RTF, CSV, XML, and JSON. You can also upload images from gallery, camera, or screenshots.',
            ],
          ),
          _HelpGuide(
            title: 'Chrome extension',
            subtitle: 'Save desktop web pages, files, notes, and screenshots.',
            icon: Icons.extension_rounded,
            colors: [Color(0xFF059669), Color(0xFF0F766E)],
            visual: _HelpVisual.chromeExtension,
            tips: [
              'Use the Chrome extension when you are browsing from a laptop or desktop.',
              'Open the extension on any webpage and tap Save this Webpage. InfoSnap extracts the page contents and saves it so you can find it later from SnapBot on Android.',
              'The extension also has a unique Take Screenshot feature that saves the current screen as an image. This is only available in the Chrome extension.',
            ],
          ),
          _HelpGuide(
            title: 'Share from social media',
            subtitle:
                'Share reels, shorts, posts, videos, and articles directly into InfoSnap.',
            icon: Icons.ios_share_rounded,
            colors: [Color(0xFF14B8A6), Color(0xFF2563EB)],
            visual: _HelpVisual.socialShare,
            supportedPlatforms: [
              'Instagram',
              'YouTube',
              'YouTube Shorts',
              'LinkedIn',
              'X / Twitter',
              'Reddit',
              'Web articles',
            ],
            detail:
                'Share from the source app, choose InfoSnap, then add a tag and a helpful description before saving.',
            tips: [
              'Tags work like folders. Use them to organize similar content together, such as recipes, design, finance, travel, or work.',
              'Use the description field to write what you want to remember about the reel. Many reels and social posts do not have enough text in the caption or transcript; this is when your description helps SnapBot find it later.',
              'InfoSnap tries to extract the source title, captions, descriptions, transcripts, visible page metadata, article text, and platform-specific content wherever the source makes it available.',
            ],
          ),
          _HelpGuide(
            title: 'SnapBot search tips',
            subtitle: 'Ask naturally, then refine when needed.',
            icon: Icons.chat_bubble_outline_rounded,
            colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
            visual: _HelpVisual.snapbotSearch,
            tips: [
              'Ask in natural language, just like you would describe the memory: "places to eat", "website design ideas", or "that pasta reel I saved".',
              'Use Filter by Tag to limit SnapBot to one area, such as food, work, recipes, or travel.',
              'Use Search Deeper when the first results are related but you want SnapBot to look harder across more saved snaps.',
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authUserProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final displayName =
        user?.displayName ?? user?.email.split('@').first ?? 'User';
    final email = user?.email ?? 'Not signed in';
    final userId = user?.id ?? '';
    final userInitial = email.isNotEmpty ? email[0].toUpperCase() : 'U';

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        title: Text(
          'Profile',
          style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.bold,
            fontSize: Responsive.sp(20),
            color: colorScheme.onSurface,
          ),
        ),
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: HexagonBackground()),
          _isSigningOut
              ? Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: EdgeInsets.all(Responsive.pp(20)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Account Information Card
                      Container(
                        padding: EdgeInsets.all(Responsive.pp(20)),
                        decoration: BoxDecoration(
                          color: colorScheme.surface,
                          borderRadius:
                              BorderRadius.circular(Responsive.wp(16)),
                          border: Border.all(
                              color: isDark
                                  ? AppColors.border
                                  : AppColors.borderLight),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Account Information',
                              style: GoogleFonts.inter(
                                fontSize: Responsive.sp(16),
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(height: Responsive.wp(16)),

                            // Profile row with avatar
                            Row(
                              children: [
                                _buildProfileAvatar(
                                  photoUrl:
                                      _localAvatarUrl ?? user?.photoUrl,
                                  initial: userInitial,
                                ),
                                SizedBox(width: Responsive.wp(14)),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        displayName,
                                        style: GoogleFonts.inter(
                                          fontSize: Responsive.sp(16),
                                          fontWeight: FontWeight.w600,
                                          color: colorScheme.onSurface,
                                        ),
                                      ),
                                      SizedBox(height: Responsive.wp(2)),
                                      Text(
                                        email,
                                        style: TextStyle(
                                          color: isDark
                                              ? colorScheme.onSurface
                                                  .withOpacity(0.7)
                                              : Colors.black,
                                          fontSize: Responsive.sp(13),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),

                            SizedBox(height: Responsive.wp(16)),
                            Divider(
                                color: isDark
                                    ? AppColors.border
                                    : AppColors.borderLight,
                                height: 1),
                            SizedBox(height: Responsive.wp(16)),

                            // User ID row
                            Row(
                              children: [
                                Text(
                                  'User ID',
                                  style: TextStyle(
                                    color: isDark
                                        ? colorScheme.onSurface.withOpacity(0.5)
                                        : const Color(0xFF374151),
                                    fontSize: Responsive.sp(13),
                                  ),
                                ),
                                Spacer(),
                                GestureDetector(
                                  onTap: () {
                                    Clipboard.setData(
                                        ClipboardData(text: userId));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('User ID copied'),
                                        backgroundColor: AppColors.primary,
                                        behavior: SnackBarBehavior.floating,
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        userId.length > 12
                                            ? '${userId.substring(0, 12)}...'
                                            : userId,
                                        style: GoogleFonts.robotoMono(
                                          fontSize: Responsive.sp(12),
                                          color: isDark
                                              ? colorScheme.onSurface
                                                  .withOpacity(0.7)
                                              : Colors.black,
                                        ),
                                      ),
                                      SizedBox(width: Responsive.wp(6)),
                                      Icon(
                                        Icons.copy_rounded,
                                        size: Responsive.sp(14),
                                        color: isDark
                                            ? colorScheme.onSurface
                                                .withOpacity(0.5)
                                            : const Color(0xFF374151),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ).animate().fadeIn().slideY(begin: 0.05),

                      SizedBox(height: Responsive.wp(20)),

                      _buildPlanCard(context)
                          .animate(delay: 150.ms)
                          .fadeIn()
                          .slideY(begin: 0.05),

                      SizedBox(height: Responsive.wp(20)),

                      SizedBox(height: Responsive.wp(24)),

                      // Support section
                      Text(
                        'Support',
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(14),
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? colorScheme.onSurface.withOpacity(0.7)
                              : Colors.black,
                        ),
                      ).animate(delay: 350.ms).fadeIn(),

                      SizedBox(height: Responsive.wp(12)),

                      _SettingsCard(
                        isDark: isDark,
                        children: [
                          _SettingsTile(
                            icon: Icons.help_outline_rounded,
                            title: 'Help Center',
                            subtitle: 'Guides for sharing, tags, and SnapBot',
                            onTap: _showHelpCenter,
                          ),
                          _SettingsDivider(),
                          _SettingsTile(
                            icon: Icons.auto_awesome_rounded,
                            title: 'Your Recap',
                            subtitle: 'See your saved-content recap',
                            onTap: () {
                              context.push('/recap');
                            },
                          ),
                          _SettingsDivider(),
                          _SettingsTile(
                            icon: Icons.auto_awesome_rounded,
                            title: 'Explore Features',
                            subtitle: 'Learn what InfoSnap can do',
                            onTap: () {
                              context.push('/features');
                            },
                          ),
                          _SettingsDivider(),
                          _SettingsTile(
                            icon: Icons.feedback_rounded,
                            title: 'Send Feedback',
                            onTap: () {
                              // TODO: Open feedback form
                            },
                          ),
                        ],
                      ).animate(delay: 400.ms).fadeIn().slideY(begin: 0.05),

                      SizedBox(height: Responsive.wp(32)),

                      // Sign out button
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _showSignOutDialog,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.error,
                            side: BorderSide(
                                color: AppColors.error.withOpacity(0.5)),
                            padding: EdgeInsets.symmetric(
                                vertical: Responsive.pp(14)),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(12)),
                            ),
                          ),
                          icon: Icon(Icons.logout_rounded),
                          label: Text(
                            'Sign Out',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ).animate(delay: 500.ms).fadeIn(),

                      SizedBox(height: Responsive.wp(40)),

                      // Footer
                      Center(
                        child: Column(
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'info',
                                  style: GoogleFonts.spaceGrotesk(
                                    color: isDark
                                        ? colorScheme.onSurface.withOpacity(0.5)
                                        : const Color(0xFF374151),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'Snap',
                                  style: GoogleFonts.spaceGrotesk(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '.ai',
                                  style: GoogleFonts.spaceGrotesk(
                                    color: isDark
                                        ? colorScheme.onSurface.withOpacity(0.5)
                                        : const Color(0xFF374151),
                                    fontWeight: FontWeight.w300,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: Responsive.wp(4)),
                            Text(
                              'Made with ❤️ for your second brain',
                              style: TextStyle(
                                color: isDark
                                    ? colorScheme.onSurface.withOpacity(0.5)
                                    : const Color(0xFF374151),
                                fontSize: Responsive.sp(12),
                              ),
                            ),
                          ],
                        ),
                      ).animate(delay: 600.ms).fadeIn(),
                    ],
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildStatsGridLoading(BuildContext context) {
    return Row(
      children: [
        _buildStatCardLoading(context),
        SizedBox(width: Responsive.wp(12)),
        _buildStatCardLoading(context),
        SizedBox(width: Responsive.wp(12)),
        _buildStatCardLoading(context),
      ],
    ).animate().fadeIn(delay: 200.ms);
  }

  Widget _buildStatCardLoading(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(
            vertical: Responsive.pp(20), horizontal: Responsive.pp(12)),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          border: Border.all(
              color: isDark ? AppColors.border : AppColors.borderLight),
        ),
        child: Column(
          children: [
            Container(
              width: Responsive.wp(32),
              height: Responsive.wp(24),
              decoration: BoxDecoration(
                color: isDark ? AppColors.border : AppColors.borderLight,
                borderRadius: BorderRadius.circular(Responsive.wp(4)),
              ),
            ),
            SizedBox(height: Responsive.wp(6)),
            Container(
              width: Responsive.wp(60),
              height: Responsive.wp(12),
              decoration: BoxDecoration(
                color: isDark ? AppColors.border : AppColors.borderLight,
                borderRadius: BorderRadius.circular(Responsive.wp(4)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsGrid(BuildContext context, NotesStats? stats) {
    return Row(
      children: [
        _buildStatCard(
          context: context,
          value: stats?.totalNotes.toString() ?? '-',
          label: 'Notes Saved',
          icon: '📝',
        ),
        SizedBox(width: Responsive.wp(12)),
        _buildStatCard(
          context: context,
          value: stats?.googleSearches.toString() ?? '-',
          label: 'Google Searches',
          icon: '🔍',
        ),
        SizedBox(width: Responsive.wp(12)),
        _buildStatCard(
          context: context,
          value: stats?.dashboardSearches.toString() ?? '-',
          label: 'Chat Searches',
          icon: '💬',
        ),
      ],
    ).animate(delay: 200.ms).fadeIn().slideY(begin: 0.05);
  }

  Widget _buildStatCard({
    required BuildContext context,
    required String value,
    required String label,
    required String icon,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(
            vertical: Responsive.pp(20), horizontal: Responsive.pp(12)),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          border: Border.all(
              color: isDark ? AppColors.border : AppColors.borderLight),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: GoogleFonts.spaceGrotesk(
                fontSize: Responsive.sp(24),
                fontWeight: FontWeight.bold,
                color: AppColors.primary,
              ),
            ),
            SizedBox(height: Responsive.wp(4)),
            Text(
              '$icon $label',
              style: TextStyle(
                fontSize: Responsive.sp(11),
                color: isDark
                    ? theme.colorScheme.onSurface.withOpacity(0.5)
                    : const Color(0xFF374151),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlanCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final status = _billingStatus;
    final isPremium = status?.isPremium == true;
    final planTitle = _billingLoading
        ? 'Loading plan'
        : isPremium
            ? 'Premium'
            : 'Free';
    final planSubtitle = _billingLoading
        ? 'Checking your monthly limits'
        : status == null
            ? 'Plan limits unavailable'
            : isPremium && status.isCancelledPremium
                ? 'Premium ends ${_formatDate(status.currentPeriodEnd)}'
                : '${status.uploads.limit} uploads, ${status.googleSearches.limit} Google searches, and ${status.snapbotSearches.limit} SnapBot searches each month';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Responsive.pp(18)),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(Responsive.wp(16)),
        border: Border.all(
          color: isDark ? AppColors.border : AppColors.borderLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: Responsive.wp(42),
                height: Responsive.wp(42),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(Responsive.wp(12)),
                ),
                child: Icon(
                  isPremium
                      ? Icons.workspace_premium_rounded
                      : Icons.card_membership_rounded,
                  color: AppColors.primary,
                  size: Responsive.sp(22),
                ),
              ),
              SizedBox(width: Responsive.wp(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      planTitle,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(16),
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    SizedBox(height: Responsive.wp(3)),
                    Text(
                      planSubtitle,
                      style: TextStyle(
                        fontSize: Responsive.sp(12),
                        color: isDark
                            ? colorScheme.onSurface.withOpacity(0.62)
                            : const Color(0xFF374151),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: Responsive.wp(16)),
          if (_billingLoading)
            LinearProgressIndicator(
              minHeight: Responsive.wp(4),
              color: AppColors.primary,
              backgroundColor: AppColors.primary.withOpacity(0.12),
            )
          else if (status == null)
            Text(
              'Plan details are unavailable right now.',
              style: TextStyle(
                fontSize: Responsive.sp(12),
                color: AppColors.error,
              ),
            )
          else ...[
            _buildUsageRow(
              context,
              label: 'Uploads',
              usage: status.uploads,
              icon: Icons.cloud_upload_outlined,
            ),
            SizedBox(height: Responsive.wp(12)),
            _buildUsageRow(
              context,
              label: 'SnapBot searches',
              usage: status.snapbotSearches,
              icon: Icons.chat_bubble_outline_rounded,
            ),
            SizedBox(height: Responsive.wp(12)),
            _buildUsageRow(
              context,
              label: 'Google searches',
              usage: status.googleSearches,
              icon: Icons.search_rounded,
            ),
            SizedBox(height: Responsive.wp(16)),
            SizedBox(
              width: double.infinity,
              child: isPremium
                  ? OutlinedButton.icon(
                      onPressed: _billingActionLoading
                          ? null
                          : () => _runBillingAction(
                                status.isCancelledPremium
                                    ? ApiService().reactivatePremium
                                    : ApiService().cancelPremium,
                                status.isCancelledPremium
                                    ? 'Premium reactivated'
                                    : 'Premium cancellation scheduled',
                              ),
                      icon: _billingActionLoading
                          ? SizedBox(
                              width: Responsive.wp(16),
                              height: Responsive.wp(16),
                              child: CircularProgressIndicator(
                                strokeWidth: Responsive.wp(2),
                              ),
                            )
                          : Icon(status.isCancelledPremium
                              ? Icons.restart_alt_rounded
                              : Icons.cancel_outlined),
                      label: Text(status.isCancelledPremium
                          ? 'Reactivate Premium'
                          : 'End Premium Subscription'),
                    )
                  : ElevatedButton.icon(
                      onPressed: _billingActionLoading
                          ? null
                          : () => _runBillingAction(
                                ApiService().upgradeToPremiumDev,
                                'Premium enabled',
                              ),
                      icon: _billingActionLoading
                          ? SizedBox(
                              width: Responsive.wp(16),
                              height: Responsive.wp(16),
                              child: CircularProgressIndicator(
                                strokeWidth: Responsive.wp(2),
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.workspace_premium_rounded),
                      label: const Text('Upgrade to Premium'),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUsageRow(
    BuildContext context, {
    required String label,
    required BillingUsage usage,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: Responsive.sp(15), color: AppColors.primary),
            SizedBox(width: Responsive.wp(7)),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: Responsive.sp(12),
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            Text(
              '${usage.used}/${usage.limit}',
              style: GoogleFonts.robotoMono(
                fontSize: Responsive.sp(12),
                color: isDark
                    ? theme.colorScheme.onSurface.withOpacity(0.7)
                    : const Color(0xFF374151),
              ),
            ),
          ],
        ),
        SizedBox(height: Responsive.wp(7)),
        ClipRRect(
          borderRadius: BorderRadius.circular(Responsive.wp(999)),
          child: LinearProgressIndicator(
            value: usage.fraction,
            minHeight: Responsive.wp(6),
            color: usage.fraction >= 0.9 ? AppColors.error : AppColors.primary,
            backgroundColor: isDark
                ? AppColors.border.withOpacity(0.7)
                : AppColors.borderLight,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'at period end';
    return '${date.day}/${date.month}/${date.year}';
  }

  Widget _buildProfileAvatar({String? photoUrl, required String initial}) {
    final radius = Responsive.wp(36); // larger than the previous 28
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
    return GestureDetector(
      onTap: _avatarUploading ? null : _pickAndUploadAvatar,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: radius * 2,
            height: radius * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary.withOpacity(0.1),
              border: Border.all(
                color: AppColors.primary.withOpacity(0.4),
                width: 2,
              ),
              image: hasPhoto
                  ? DecorationImage(
                      image: NetworkImage(photoUrl),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            alignment: Alignment.center,
            child: hasPhoto
                ? null
                : Text(
                    initial,
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: Responsive.sp(26),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: Responsive.wp(22),
              height: Responsive.wp(22),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary,
                border: Border.all(color: Colors.white, width: 2),
              ),
              alignment: Alignment.center,
              child: _avatarUploading
                  ? SizedBox(
                      width: Responsive.wp(12),
                      height: Responsive.wp(12),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Icon(
                      Icons.camera_alt_rounded,
                      size: Responsive.sp(12),
                      color: Colors.white,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _HelpVisual {
  standard,
  androidUpload,
  chromeExtension,
  socialShare,
  snapbotSearch,
}

class _HelpGuide {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> colors;
  final List<String> tips;
  final _HelpVisual visual;
  final List<String> supportedPlatforms;
  final String? detail;

  const _HelpGuide({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.colors,
    required this.tips,
    this.visual = _HelpVisual.standard,
    this.supportedPlatforms = const [],
    this.detail,
  });
}

class _HelpCenterSheet extends StatefulWidget {
  final List<_HelpGuide> guides;

  const _HelpCenterSheet({required this.guides});

  @override
  State<_HelpCenterSheet> createState() => _HelpCenterSheetState();
}

class _HelpCenterSheetState extends State<_HelpCenterSheet> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.78,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(Responsive.wp(24)),
        ),
      ),
      child: Column(
        children: [
          SizedBox(height: Responsive.wp(10)),
          Container(
            width: Responsive.wp(42),
            height: Responsive.wp(4),
            decoration: BoxDecoration(
              color: isDark ? AppColors.border : AppColors.borderLight,
              borderRadius: BorderRadius.circular(Responsive.wp(999)),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              Responsive.pp(20),
              Responsive.pp(18),
              Responsive.pp(10),
              Responsive.pp(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Help Center',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: Responsive.sp(20),
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.guides.length,
              onPageChanged: (value) => setState(() => _index = value),
              itemBuilder: (context, index) {
                final guide = widget.guides[index];
                return SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    Responsive.pp(20),
                    0,
                    Responsive.pp(20),
                    Responsive.pp(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(Responsive.pp(22)),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: guide.colors),
                          borderRadius:
                              BorderRadius.circular(Responsive.wp(20)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: Responsive.wp(68),
                              height: Responsive.wp(68),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.18),
                                borderRadius:
                                    BorderRadius.circular(Responsive.wp(20)),
                              ),
                              child: Icon(
                                guide.icon,
                                color: Colors.white,
                                size: Responsive.sp(34),
                              ),
                            ),
                            SizedBox(height: Responsive.wp(28)),
                            Text(
                              guide.title,
                              style: GoogleFonts.spaceGrotesk(
                                color: Colors.white,
                                fontSize: Responsive.sp(24),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: Responsive.wp(6)),
                            Text(
                              guide.subtitle,
                              style: GoogleFonts.inter(
                                color: Colors.white.withOpacity(0.88),
                                fontSize: Responsive.sp(13),
                                height: 1.4,
                              ),
                            ),
                            if (guide.supportedPlatforms.isNotEmpty) ...[
                              SizedBox(height: Responsive.wp(14)),
                              Wrap(
                                spacing: Responsive.wp(6),
                                runSpacing: Responsive.wp(6),
                                children: guide.supportedPlatforms
                                    .map(
                                      (platform) => Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: Responsive.pp(9),
                                          vertical: Responsive.pp(5),
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.16),
                                          borderRadius: BorderRadius.circular(
                                              Responsive.wp(999)),
                                        ),
                                        child: Text(
                                          platform,
                                          style: GoogleFonts.inter(
                                            color: Colors.white,
                                            fontSize: Responsive.sp(10),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                          ],
                        ),
                      ),
                      SizedBox(height: Responsive.wp(20)),
                      if (guide.visual == _HelpVisual.socialShare)
                        _SocialShareGuideContent(guide: guide)
                      else if (guide.visual == _HelpVisual.snapbotSearch)
                        _SnapBotGuideContent(guide: guide)
                      else if (guide.visual == _HelpVisual.chromeExtension)
                        _ChromeExtensionGuideContent(guide: guide)
                      else if (guide.visual == _HelpVisual.androidUpload)
                        _AndroidUploadGuideContent(guide: guide)
                      else ...[
                        if (guide.detail != null) ...[
                          Text(
                            guide.detail!,
                            style: GoogleFonts.inter(
                              color:
                                  theme.colorScheme.onSurface.withOpacity(0.8),
                              fontSize: Responsive.sp(13),
                              height: 1.45,
                            ),
                          ),
                          SizedBox(height: Responsive.wp(14)),
                        ],
                        ...guide.tips.map(
                          (tip) => Padding(
                            padding: EdgeInsets.only(bottom: Responsive.wp(12)),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: AppColors.primary,
                                  size: Responsive.sp(18),
                                ),
                                SizedBox(width: Responsive.wp(10)),
                                Expanded(
                                  child: Text(
                                    tip,
                                    style: GoogleFonts.inter(
                                      color: theme.colorScheme.onSurface,
                                      fontSize: Responsive.sp(13),
                                      height: 1.45,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              Responsive.pp(20),
              Responsive.pp(8),
              Responsive.pp(20),
              bottomPadding + Responsive.pp(16),
            ),
            child: Row(
              children: [
                ...List.generate(
                  widget.guides.length,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: EdgeInsets.only(right: Responsive.wp(6)),
                    width: i == _index ? Responsive.wp(22) : Responsive.wp(7),
                    height: Responsive.wp(7),
                    decoration: BoxDecoration(
                      color: i == _index
                          ? AppColors.primary
                          : theme.colorScheme.onSurface.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(Responsive.wp(999)),
                    ),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    if (_index == widget.guides.length - 1) {
                      Navigator.pop(context);
                    } else {
                      _controller.nextPage(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                  child: Text(
                      _index == widget.guides.length - 1 ? 'Done' : 'Next'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpScreenshot extends StatelessWidget {
  final String assetPath;
  final double aspectRatio;

  const _HelpScreenshot({
    required this.assetPath,
    required this.aspectRatio,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = Responsive.wp(290);
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth < maxWidth
                  ? constraints.maxWidth
                  : maxWidth,
            ),
            child: Container(
              padding: EdgeInsets.all(Responsive.pp(6)),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(Responsive.wp(20)),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withOpacity(0.14)
                      : Colors.black.withOpacity(0.08),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.28 : 0.14),
                    blurRadius: Responsive.wp(18),
                    offset: Offset(0, Responsive.wp(8)),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Responsive.wp(15)),
                child: AspectRatio(
                  aspectRatio: aspectRatio,
                  child: Image.asset(
                    assetPath,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SocialShareGuideContent extends StatelessWidget {
  final _HelpGuide guide;

  const _SocialShareGuideContent({required this.guide});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Below are the steps to share a reel from Instagram.',
          style: GoogleFonts.spaceGrotesk(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: Responsive.sp(17),
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: Responsive.wp(6)),
        Text(
          'The same flow also works for supported shorts, posts, videos, and articles.',
          style: GoogleFonts.inter(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.68),
            fontSize: Responsive.sp(12),
            height: 1.4,
          ),
        ),
        SizedBox(height: Responsive.wp(18)),
        const _GuideScreenshotStep(
          title: '1. Tap the share button on the reel',
          body:
              'Open the reel, short, post, video, or article you want to save. Tap the share button highlighted on the screen.',
          assetPath: 'assets/help/share_reel_button.jpg',
          aspectRatio: 9 / 16,
          icon: Icons.touch_app_rounded,
        ),
        SizedBox(height: Responsive.wp(18)),
        const _GuideScreenshotStep(
          title: '2. Tap Share in the platform tray',
          body:
              'Some apps first open their own sharing tray. Tap Share again to open the Android share sheet.',
          assetPath: 'assets/help/share_system_sheet.jpg',
          aspectRatio: 16 / 8,
          icon: Icons.ios_share_rounded,
        ),
        SizedBox(height: Responsive.wp(18)),
        const _GuideScreenshotStep(
          title: '3. Choose InfoSnap',
          body:
              'From the Android share sheet, tap the InfoSnap app icon to send the content into InfoSnap.',
          assetPath: 'assets/help/share_infosnap_target.jpg',
          aspectRatio: 16 / 10,
          icon: Icons.apps_rounded,
        ),
        SizedBox(height: Responsive.wp(18)),
        const _GuideScreenshotStep(
          title: '4. Add a tag and description',
          body:
              'Tags are like folders used to efficiently organize similar content. Use the description field to enter a detailed description so SnapBot can easily find this reel later.',
          assetPath: 'assets/help/save_shared_url_dialog.jpg',
          aspectRatio: 9 / 16,
          icon: Icons.edit_note_rounded,
        ),
        SizedBox(height: Responsive.wp(18)),
        _GuideTextBlock(
          title: 'Organize with tags',
          body: guide.tips.isNotEmpty ? guide.tips[0] : '',
          icon: Icons.sell_outlined,
        ),
        SizedBox(height: Responsive.wp(10)),
        _GuideTextBlock(
          title: 'Why descriptions matter',
          body: guide.tips.length > 1 ? guide.tips[1] : '',
          icon: Icons.edit_note_rounded,
        ),
        SizedBox(height: Responsive.wp(10)),
        _GuideTextBlock(
          title: 'What InfoSnap captures',
          body: guide.tips.length > 2 ? guide.tips[2] : '',
          icon: Icons.auto_awesome_rounded,
        ),
      ],
    );
  }
}

class _GuideScreenshotStep extends StatelessWidget {
  final String title;
  final String body;
  final String assetPath;
  final double aspectRatio;
  final IconData icon;

  const _GuideScreenshotStep({
    required this.title,
    required this.body,
    required this.assetPath,
    required this.aspectRatio,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _GuideTextBlock(
          title: title,
          body: body,
          icon: icon,
        ),
        SizedBox(height: Responsive.wp(10)),
        _HelpScreenshot(assetPath: assetPath, aspectRatio: aspectRatio),
      ],
    );
  }
}

class _SnapBotGuideContent extends StatelessWidget {
  final _HelpGuide guide;

  const _SnapBotGuideContent({required this.guide});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Example: finding saved food recommendations',
          style: GoogleFonts.spaceGrotesk(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: Responsive.sp(17),
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: Responsive.wp(6)),
        Text(
          'Type what you remember, review the matching sources, then narrow results with tags or search deeper when needed.',
          style: GoogleFonts.inter(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.68),
            fontSize: Responsive.sp(12),
            height: 1.4,
          ),
        ),
        SizedBox(height: Responsive.wp(14)),
        const _HelpScreenshot(
          assetPath: 'assets/help/snapbot_search_example.jpg',
          aspectRatio: 9 / 16,
        ),
        SizedBox(height: Responsive.wp(18)),
        _GuideTextBlock(
          title: 'Ask naturally',
          body: guide.tips.isNotEmpty ? guide.tips[0] : '',
          icon: Icons.chat_bubble_outline_rounded,
        ),
        SizedBox(height: Responsive.wp(10)),
        _GuideTextBlock(
          title: 'Filter by tag',
          body: guide.tips.length > 1 ? guide.tips[1] : '',
          icon: Icons.filter_alt_outlined,
        ),
        SizedBox(height: Responsive.wp(10)),
        _GuideTextBlock(
          title: 'Search deeper',
          body: guide.tips.length > 2 ? guide.tips[2] : '',
          icon: Icons.travel_explore_rounded,
        ),
      ],
    );
  }
}

class _AndroidUploadGuideContent extends StatelessWidget {
  final _HelpGuide guide;

  const _AndroidUploadGuideContent({required this.guide});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Save from the InfoSnap Android app',
          style: GoogleFonts.spaceGrotesk(
            color: theme.colorScheme.onSurface,
            fontSize: Responsive.sp(17),
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: Responsive.wp(6)),
        Text(
          'Use the upload menu for links, quick notes, files, and images that you want to keep searchable.',
          style: GoogleFonts.inter(
            color: theme.colorScheme.onSurface.withOpacity(0.68),
            fontSize: Responsive.sp(12),
            height: 1.4,
          ),
        ),
        SizedBox(height: Responsive.wp(14)),
        const _HelpScreenshot(
          assetPath: 'assets/help/android_upload_options.jpg',
          aspectRatio: 9 / 16,
        ),
        SizedBox(height: Responsive.wp(16)),
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(Responsive.pp(14)),
          decoration: BoxDecoration(
            color: AppColors.warning.withOpacity(0.12),
            borderRadius: BorderRadius.circular(Responsive.wp(14)),
            border: Border.all(color: AppColors.warning.withOpacity(0.28)),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Important: ',
                  style: GoogleFonts.inter(fontWeight: FontWeight.w900),
                ),
                const TextSpan(
                  text:
                      'for social media content, use the share button inside the social media app. Do not use Save URL from the Android upload page for social media links. Save URL is only for non-social-media webpages.',
                ),
              ],
            ),
            style: GoogleFonts.inter(
              color: theme.colorScheme.onSurface,
              fontSize: Responsive.sp(12),
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(height: Responsive.wp(16)),
        _GuideTextBlock(
          title: 'Save URL',
          body: guide.tips.isNotEmpty ? guide.tips[0] : '',
          icon: Icons.link_rounded,
        ),
        SizedBox(height: Responsive.wp(10)),
        _GuideTextBlock(
          title: 'Quick Note',
          body: guide.tips.length > 1 ? guide.tips[1] : '',
          icon: Icons.edit_note_rounded,
        ),
        SizedBox(height: Responsive.wp(10)),
        _GuideTextBlock(
          title: 'Upload files and images',
          body: guide.tips.length > 2 ? guide.tips[2] : '',
          icon: Icons.file_upload_outlined,
        ),
      ],
    );
  }
}

class _ChromeExtensionGuideContent extends StatelessWidget {
  final _HelpGuide guide;

  const _ChromeExtensionGuideContent({required this.guide});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Save from your laptop or desktop',
          style: GoogleFonts.spaceGrotesk(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: Responsive.sp(17),
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: Responsive.wp(6)),
        Text(
          'The Chrome extension is for content you discover while browsing on a computer.',
          style: GoogleFonts.inter(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.68),
            fontSize: Responsive.sp(12),
            height: 1.4,
          ),
        ),
        SizedBox(height: Responsive.wp(14)),
        const _ChromeExtensionMockup(),
        SizedBox(height: Responsive.wp(18)),
        _GuideTextBlock(
          title: 'Use it on desktop web pages',
          body: guide.tips.isNotEmpty ? guide.tips[0] : '',
          icon: Icons.desktop_windows_outlined,
        ),
        SizedBox(height: Responsive.wp(10)),
        _GuideTextBlock(
          title: 'Save this Webpage',
          body: guide.tips.length > 1 ? guide.tips[1] : '',
          icon: Icons.public_rounded,
        ),
        SizedBox(height: Responsive.wp(10)),
        _GuideTextBlock(
          title: 'Screenshot-only extension feature',
          body: guide.tips.length > 2 ? guide.tips[2] : '',
          icon: Icons.photo_camera_outlined,
        ),
      ],
    );
  }
}

class _ChromeExtensionMockup extends StatelessWidget {
  const _ChromeExtensionMockup();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: Responsive.wp(320)),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(Responsive.wp(22)),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.14)
                : Colors.black.withOpacity(0.08),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.28 : 0.14),
              blurRadius: Responsive.wp(18),
              offset: Offset(0, Responsive.wp(8)),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Responsive.wp(22)),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(
                  Responsive.pp(18),
                  Responsive.pp(18),
                  Responsive.pp(18),
                  Responsive.pp(16),
                ),
                decoration: const BoxDecoration(
                  image: DecorationImage(
                    image: AssetImage('assets/icon_background.png'),
                    fit: BoxFit.cover,
                    opacity: 0.72,
                  ),
                  color: Color(0xFF111827),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/icon_foreground.png',
                          width: Responsive.wp(36),
                          height: Responsive.wp(36),
                          fit: BoxFit.contain,
                        ),
                        SizedBox(width: Responsive.wp(8)),
                        Text(
                          'infoSnap.ai',
                          style: GoogleFonts.spaceGrotesk(
                            color: Colors.white,
                            fontSize: Responsive.sp(24),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: Responsive.wp(8)),
                    Text(
                      'Save Anything, find it instantly',
                      style: GoogleFonts.inter(
                        color: Colors.white.withOpacity(0.88),
                        fontSize: Responsive.sp(13),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.all(Responsive.pp(16)),
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(Responsive.pp(14)),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(Responsive.wp(14)),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: Responsive.wp(18),
                            backgroundColor: AppColors.primary,
                            child: Text(
                              'A',
                              style: GoogleFonts.inter(
                                color: Colors.white,
                                fontSize: Responsive.sp(15),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          SizedBox(width: Responsive.wp(12)),
                          Expanded(
                            child: Text(
                              'Good to see you!',
                              style: GoogleFonts.inter(
                                color: AppColors.primary,
                                fontSize: Responsive.sp(13),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.settings_rounded,
                            color: const Color(0xFF111827),
                            size: Responsive.sp(20),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: Responsive.wp(14)),
                    const _ExtensionActionButton(
                      icon: Icons.photo_camera_outlined,
                      title: 'Take Screenshot',
                      emphasis: true,
                    ),
                    SizedBox(height: Responsive.wp(10)),
                    const _ExtensionActionButton(
                      icon: Icons.folder_open_rounded,
                      title: 'Upload File',
                      caption: 'Supports: PDF, DOC, TXT, PNG, JPEG',
                    ),
                    SizedBox(height: Responsive.wp(10)),
                    const _ExtensionActionButton(
                      icon: Icons.edit_note_rounded,
                      title: 'Take Notes',
                    ),
                    SizedBox(height: Responsive.wp(10)),
                    const _ExtensionActionButton(
                      icon: Icons.public_rounded,
                      title: 'Save this Webpage',
                      caption: 'Saves page as searchable PDF',
                      emphasis: true,
                    ),
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

class _ExtensionActionButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? caption;
  final bool emphasis;

  const _ExtensionActionButton({
    required this.icon,
    required this.title,
    this.caption,
    this.emphasis = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(16),
            vertical: Responsive.pp(13),
          ),
          decoration: BoxDecoration(
            color: emphasis
                ? AppColors.primary
                : AppColors.primary.withOpacity(0.88),
            borderRadius: BorderRadius.circular(Responsive.wp(12)),
            image: const DecorationImage(
              image: AssetImage('assets/icon_background.png'),
              fit: BoxFit.cover,
              opacity: 0.12,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withOpacity(0.22),
                blurRadius: Responsive.wp(10),
                offset: Offset(0, Responsive.wp(5)),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: Responsive.sp(20)),
              SizedBox(width: Responsive.wp(12)),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: Responsive.sp(14),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (caption != null) ...[
          SizedBox(height: Responsive.wp(5)),
          Text(
            caption!,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.54),
              fontSize: Responsive.sp(10),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

class _GuideTextBlock extends StatelessWidget {
  final String title;
  final String body;
  final IconData icon;

  const _GuideTextBlock({
    required this.title,
    required this.body,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.primary, size: Responsive.sp(18)),
        SizedBox(width: Responsive.wp(10)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  color: theme.colorScheme.onSurface,
                  fontSize: Responsive.sp(13),
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: Responsive.wp(4)),
              Text(
                body,
                style: GoogleFonts.inter(
                  color: theme.colorScheme.onSurface.withOpacity(0.78),
                  fontSize: Responsive.sp(12),
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  final bool isDark;

  const _SettingsCard({required this.children, this.isDark = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Responsive.wp(16)),
        border: Border.all(
            color: isDark ? AppColors.border : AppColors.borderLight),
      ),
      child: Column(children: children),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Responsive.wp(16)),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(16),
          vertical: Responsive.pp(14),
        ),
        child: Row(
          children: [
            Container(
              width: Responsive.wp(40),
              height: Responsive.wp(40),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(Responsive.wp(10)),
              ),
              child:
                  Icon(icon, color: AppColors.primary, size: Responsive.sp(20)),
            ),
            SizedBox(width: Responsive.wp(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: Responsive.sp(14),
                      color:
                          isDark ? theme.colorScheme.onSurface : Colors.black,
                    ),
                  ),
                  if (subtitle != null) ...[
                    SizedBox(height: Responsive.wp(2)),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: isDark
                            ? theme.colorScheme.onSurface.withOpacity(0.5)
                            : const Color(0xFF374151),
                        fontSize: Responsive.sp(12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onTap != null)
              Icon(
                Icons.chevron_right_rounded,
                size: Responsive.sp(24),
                color: isDark
                    ? theme.colorScheme.onSurface.withOpacity(0.5)
                    : const Color(0xFF374151),
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(16)),
      child: Divider(
          height: 1, color: isDark ? AppColors.border : AppColors.borderLight),
    );
  }
}

class _SettingsTileWithSwitch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsTileWithSwitch({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(16),
        vertical: Responsive.pp(14),
      ),
      child: Row(
        children: [
          Container(
            width: Responsive.wp(40),
            height: Responsive.wp(40),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(Responsive.wp(10)),
            ),
            child:
                Icon(icon, color: AppColors.primary, size: Responsive.sp(20)),
          ),
          SizedBox(width: Responsive.wp(14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: Responsive.sp(14),
                    color: isDark ? theme.colorScheme.onSurface : Colors.black,
                  ),
                ),
                if (subtitle != null) ...[
                  SizedBox(height: Responsive.wp(2)),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: isDark
                          ? theme.colorScheme.onSurface.withOpacity(0.5)
                          : const Color(0xFF374151),
                      fontSize: Responsive.sp(12),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}
