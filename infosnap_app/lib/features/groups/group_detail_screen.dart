import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/api_service.dart';
import '../../core/services/groups_realtime_service.dart';
import '../../core/services/thumbnail_cache_manager.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';
import 'widgets/group_avatar.dart';
import '../notes/widgets/snap_preview_surface.dart';

class GroupDetailScreen extends StatefulWidget {
  final String groupId;

  const GroupDetailScreen({super.key, required this.groupId});

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  final _api = ApiService();
  GroupDetail? _detail;
  GroupSummary? _seedGroup;
  bool _loading = true;
  bool _avatarUploading = false;
  bool _handlingRequest = false;
  GroupsRealtimeSubscription? _realtime;
  Timer? _refreshDebounce;

  static const _green = Color(0xFF22C55E);
  static const _dark = Color(0xFF18181B);

  @override
  void initState() {
    super.initState();
    _seedGroup = _findSeedGroup();
    _load(showLoader: true);
    _subscribeRealtime();
  }

  GroupSummary? _findSeedGroup() {
    for (final group in _api.cachedGroups) {
      if (group.id == widget.groupId) return group;
    }
    return null;
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    unawaited(_realtime?.dispose());
    super.dispose();
  }

  void _subscribeRealtime() {
    _realtime = GroupsRealtimeService.instance.subscribeToUser(
      groupId: widget.groupId,
      onEvent: _handleRealtimeEvent,
      onResumeRefresh: _scheduleRealtimeRefresh,
    );
  }

  void _handleRealtimeEvent(GroupsRealtimeEvent event) {
    if (event.isReaction) {
      _applyReactionDelta(event);
      return;
    }
    if (event.isGroupChanged) {
      _scheduleRealtimeRefresh();
    }
  }

  void _applyReactionDelta(GroupsRealtimeEvent event) {
    final detail = _detail;
    if (detail == null || event.snapId == null) return;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final isMine = currentUserId != null && event.userId == currentUserId;

    setState(() {
      _detail = GroupDetail(
        group: detail.group,
        members: detail.members,
        joinRequests: detail.joinRequests,
        snaps: detail.snaps.map((snap) {
          if (snap.id != event.snapId) return snap;
          final reactions = Map<String, int>.from(snap.reactions);
          var myReaction = snap.myReaction;

          if (isMine &&
              event.op == 'add' &&
              myReaction != null &&
              myReaction.isNotEmpty &&
              myReaction != event.emoji) {
            final previousCount = (reactions[myReaction] ?? 0) - 1;
            if (previousCount <= 0) {
              reactions.remove(myReaction);
            } else {
              reactions[myReaction] = previousCount;
            }
          }

          if (event.op == 'remove') {
            final removedEmoji = event.emoji;
            if (removedEmoji != null && removedEmoji.isNotEmpty) {
              final nextCount = (reactions[removedEmoji] ?? 0) - 1;
              if (nextCount <= 0) {
                reactions.remove(removedEmoji);
              } else {
                reactions[removedEmoji] = nextCount;
              }
            }
            if (isMine) myReaction = null;
          } else if (event.emoji != null && event.emoji!.isNotEmpty) {
            reactions[event.emoji!] = (reactions[event.emoji!] ?? 0) + 1;
            if (isMine) myReaction = event.emoji;
          }

          return snap.copyWith(
            myReaction: myReaction,
            reactions: reactions,
          );
        }).toList(growable: false),
      );
    });
  }

  void _scheduleRealtimeRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(
      const Duration(milliseconds: 450),
      () => _load(showLoader: false),
    );
  }

  Future<void> _load({required bool showLoader}) async {
    if (showLoader && mounted) {
      setState(() => _loading = true);
    }
    final detail = await _api.fetchGroup(widget.groupId);
    unawaited(_api.markGroupSeen(widget.groupId));
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _seedGroup = detail?.group ?? _seedGroup;
      _loading = false;
    });
  }

  void _refresh() {
    _load(showLoader: _detail == null);
  }

  Future<void> _pickGroupPhoto() async {
    if (_avatarUploading) return;
    final photo = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
    );
    if (!mounted || photo == null) return;
    final bytes = await photo.readAsBytes();
    if (!mounted) return;
    setState(() => _avatarUploading = true);
    final avatarUrl = await _api.uploadGroupAvatar(
      widget.groupId,
      bytes: bytes,
      filename: photo.name,
      contentType: _contentTypeForPath(photo.name),
    );
    if (!mounted) return;
    setState(() {
      _avatarUploading = false;
      if (avatarUrl != null && _detail != null) {
        _detail = GroupDetail(
          group: _detail!.group.copyWith(avatarUrl: avatarUrl),
          members: _detail!.members,
          joinRequests: _detail!.joinRequests,
          snaps: _detail!.snaps,
        );
        _seedGroup = _detail!.group;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          avatarUrl != null
              ? 'Group image updated'
              : 'Could not upload group image',
        ),
      ),
    );
    if (avatarUrl != null) {
      unawaited(_load(showLoader: false));
    }
  }

  Future<void> _invite() async {
    final result = await showDialog<_InviteTarget>(
      context: context,
      builder: (_) => _InviteDialog(api: _api),
    );
    if (result == null) return;
    final ok = await _api.inviteToGroup(
      widget.groupId,
      userId: result.userId,
      email: result.email,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Invite sent' : 'Could not send invite')),
    );
    if (!ok) return;
    setState(() {
      final detail = _detail;
      if (detail == null) return;
      final pendingMember = GroupMember(
        id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
        userId: result.user?.id ?? result.userId,
        invitedEmail: result.email,
        role: 'member',
        status: 'pending',
        profile: result.user,
      );
      _detail = GroupDetail(
        group: detail.group.copyWith(
          memberCount: detail.group.memberCount + 1,
        ),
        members: [
          ...detail.members.where((member) =>
              member.userId != pendingMember.userId ||
              pendingMember.userId == null),
          pendingMember,
        ],
        joinRequests: detail.joinRequests,
        snaps: detail.snaps,
      );
    });
    unawaited(_load(showLoader: false));
  }

  Future<void> _leave() async {
    final detail = _detail;
    if (detail == null) return;
    String? successorUserId;
    if (detail.group.role == 'admin') {
      final candidates = detail.members
          .where((member) => member.status == 'active' && member.userId != null)
          .where((member) =>
              member.userId != Supabase.instance.client.auth.currentUser?.id)
          .toList();
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Add another active member before the admin can leave this group.'),
          ),
        );
        return;
      }
      successorUserId = await _pickSuccessor(candidates);
      if (!mounted || successorUserId == null) return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Leave group?',
          style: GoogleFonts.spaceGrotesk(
            fontSize: Responsive.sp(17),
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          successorUserId == null
              ? 'You will stop seeing snaps shared in this group.'
              : 'You will stop seeing snaps shared in this group and the selected member will become the admin.',
          style: GoogleFonts.inter(fontSize: Responsive.sp(12.5)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(fontSize: Responsive.sp(12)),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Leave',
              style: GoogleFonts.inter(fontSize: Responsive.sp(12)),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final left =
        await _api.leaveGroup(widget.groupId, successorUserId: successorUserId);
    if (!mounted) return;
    if (left) {
      context.go('/groups');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not leave group')),
      );
    }
  }

  Future<void> _shareFromMySnaps(String groupName) async {
    await context.push(
      '/notes?share_to_group=${Uri.encodeQueryComponent(widget.groupId)}&group_name=${Uri.encodeQueryComponent(groupName)}',
    );
    _load(showLoader: false);
  }

  Future<void> _approveJoinRequest(GroupMember member) async {
    if (_handlingRequest) return;
    setState(() => _handlingRequest = true);
    final ok = await _api.approveJoinRequest(widget.groupId, member.id);
    if (!mounted) return;
    setState(() => _handlingRequest = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text(ok ? 'Join request approved' : 'Could not approve request')),
    );
    if (ok) unawaited(_load(showLoader: false));
  }

  Future<void> _denyJoinRequest(GroupMember member) async {
    if (_handlingRequest) return;
    setState(() => _handlingRequest = true);
    final ok = await _api.denyJoinRequest(widget.groupId, member.id);
    if (!mounted) return;
    setState(() => _handlingRequest = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(ok ? 'Join request denied' : 'Could not deny request')),
    );
    if (ok) unawaited(_load(showLoader: false));
  }

  Future<void> _makeAdmin(GroupMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Make admin?',
          style: GoogleFonts.spaceGrotesk(
            fontSize: Responsive.sp(17),
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          '${member.displayNameOnly} will become the only admin of this group.',
          style: GoogleFonts.inter(fontSize: Responsive.sp(12.5)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
    if (confirmed != true || member.userId == null) return;
    final ok = await _api.transferGroupAdmin(widget.groupId, member.userId!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Admin updated' : 'Could not update admin')),
    );
    if (ok) unawaited(_load(showLoader: false));
  }

  Future<String?> _pickSuccessor(List<GroupMember> candidates) async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Select next admin',
          style: GoogleFonts.spaceGrotesk(
            fontSize: Responsive.sp(17),
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SizedBox(
          width: Responsive.width > 380
              ? Responsive.wp(300)
              : Responsive.width - Responsive.pp(64),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: candidates
                .map(
                  (member) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      child: Text(member.displayNameOnly.characters.first
                          .toUpperCase()),
                    ),
                    title: Text(member.displayNameOnly),
                    subtitle: Text(member.displayEmail),
                    onTap: () => Navigator.of(ctx).pop(member.userId),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }

  String _contentTypeForPath(String path) {
    final value = path.toLowerCase();
    if (value.endsWith('.png')) return 'image/png';
    if (value.endsWith('.webp')) return 'image/webp';
    if (value.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          const Positioned.fill(child: SoftGridBackground()),
          SafeArea(
            child: Builder(
              builder: (context) {
                final detail = _detail;
                final seedGroup = _seedGroup;
                return Column(
                  children: [
                    _Header(
                      title: detail?.group.name ?? seedGroup?.name ?? 'Group',
                      avatarUrl:
                          detail?.group.avatarUrl ?? seedGroup?.avatarUrl,
                      memberCount:
                          detail?.members.length ?? seedGroup?.memberCount ?? 0,
                      groupSeed: widget.groupId,
                      onPickPhoto: detail == null ? null : _pickGroupPhoto,
                      onInvite: detail == null ? null : _invite,
                      onLeave: detail == null ? null : _leave,
                      photoBusy: _avatarUploading,
                    ),
                    Expanded(
                      child: _loading && detail == null
                          ? const Center(child: CircularProgressIndicator())
                          : detail == null
                              ? _ErrorState(onRetry: _refresh)
                              : RefreshIndicator(
                                  onRefresh: () async =>
                                      _load(showLoader: false),
                                  color: _green,
                                  child: ListView(
                                    padding: EdgeInsets.fromLTRB(
                                      Responsive.pp(16),
                                      Responsive.pp(14),
                                      Responsive.pp(16),
                                      Responsive.pp(96),
                                    ),
                                    children: [
                                      if (detail.joinRequests.isNotEmpty &&
                                          detail.group.role == 'admin') ...[
                                        _JoinRequestsCard(
                                          members: detail.joinRequests,
                                          busy: _handlingRequest,
                                          onApprove: _approveJoinRequest,
                                          onDeny: _denyJoinRequest,
                                        ),
                                        SizedBox(height: Responsive.wp(14)),
                                      ],
                                      _MembersStrip(
                                        members: detail.members,
                                        currentUserId: Supabase.instance.client
                                            .auth.currentUser?.id,
                                        isAdmin: detail.group.role == 'admin',
                                        onMakeAdmin: _makeAdmin,
                                      ),
                                      SizedBox(height: Responsive.wp(14)),
                                      _SectionTitle(count: detail.snaps.length),
                                      SizedBox(height: Responsive.wp(12)),
                                      if (detail.snaps.isEmpty)
                                        _EmptySnaps()
                                      else
                                        _GroupSnapGrid(
                                          groupId: widget.groupId,
                                          snaps: detail.snaps,
                                          onReacted: () {},
                                        ),
                                    ],
                                  ),
                                ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_detail != null)
            _ShareSnapBar(
              onTap: () => _shareFromMySnaps(_detail!.group.name),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String groupSeed;
  final String? avatarUrl;
  final int memberCount;
  final VoidCallback? onPickPhoto;
  final VoidCallback? onInvite;
  final VoidCallback? onLeave;
  final bool photoBusy;

  const _Header({
    required this.title,
    required this.groupSeed,
    required this.avatarUrl,
    required this.memberCount,
    this.onPickPhoto,
    this.onInvite,
    this.onLeave,
    this.photoBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(
        Responsive.pp(12),
        Responsive.pp(8),
        Responsive.pp(12),
        Responsive.pp(8),
      ),
      padding: EdgeInsets.all(Responsive.pp(12)),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE0F2FE), Color(0xFFC7E9FB), Color(0xFFD1FAE5)],
        ),
        borderRadius: BorderRadius.circular(Responsive.wp(24)),
        border: Border.all(color: Colors.white.withOpacity(0.55)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0EA5E9).withOpacity(0.14),
            blurRadius: Responsive.wp(20),
            offset: Offset(0, Responsive.wp(8)),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          IconButton(
            onPressed: () => context.pop(),
            icon: const Icon(
              Icons.arrow_back_rounded,
              color: Color(0xFF0F172A),
            ),
          ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onPickPhoto,
                  borderRadius: BorderRadius.circular(Responsive.wp(16)),
                  child: Stack(
                    children: [
                      GroupAvatar(
                        seed: groupSeed,
                        name: title,
                        imageUrl: avatarUrl,
                        size: Responsive.wp(58),
                        borderRadius: Responsive.wp(18),
                        fallbackIcon: Icons.groups_2_rounded,
                      ),
                      if (photoBusy)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.18),
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(18)),
                            ),
                            child: const Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: -Responsive.wp(5),
                bottom: -Responsive.wp(5),
                child: Container(
                  padding: EdgeInsets.all(Responsive.pp(4)),
                  decoration: const BoxDecoration(
                    color: Color(0xFFF59E0B),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.photo_camera_rounded,
                    color: Colors.white,
                    size: Responsive.sp(14),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(width: Responsive.wp(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceGrotesk(
                    color: const Color(0xFF0F172A),
                    fontSize: Responsive.sp(16),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '$memberCount members',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: const Color(0xFF334155),
                    fontSize: Responsive.sp(10),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onInvite,
            icon: const Icon(Icons.person_add_alt_1_rounded,
                color: Color(0xFF0F172A)),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Color(0xFF0F172A)),
            onSelected: (value) {
              if (value == 'leave') onLeave?.call();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'leave', child: Text('Leave group')),
            ],
          ),
        ],
      ),
    );
  }
}

class _MembersStrip extends StatelessWidget {
  final List<GroupMember> members;
  final String? currentUserId;
  final bool isAdmin;
  final ValueChanged<GroupMember>? onMakeAdmin;

  const _MembersStrip({
    required this.members,
    this.currentUserId,
    this.isAdmin = false,
    this.onMakeAdmin,
  });

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.symmetric(horizontal: Responsive.pp(12)),
        childrenPadding: EdgeInsets.fromLTRB(
          Responsive.pp(12),
          0,
          Responsive.pp(12),
          Responsive.pp(12),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(18)),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(18)),
        ),
        backgroundColor: Colors.white.withOpacity(0.92),
        collapsedBackgroundColor: Colors.white.withOpacity(0.92),
        leading: const Icon(Icons.people_alt_rounded,
            color: _GroupDetailScreenState._green),
        title: Text(
          'Members (${members.length}/10)',
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(12),
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          members.take(3).map((m) => m.displayNameOnly).join(', '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(fontSize: Responsive.sp(9.8)),
        ),
        children: members.map((member) {
          final pending = member.status == 'pending';
          final isCurrentUser =
              member.userId != null && member.userId == currentUserId;
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor:
                  pending ? Colors.amber.shade100 : const Color(0xFFDCFCE7),
              child:
                  Text(member.displayNameOnly.characters.first.toUpperCase()),
            ),
            title: Text(
              member.role == 'admin'
                  ? '${member.displayNameOnly} (Admin)'
                  : member.displayNameOnly,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(11),
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: isCurrentUser ? const Text('You') : null,
            trailing: pending
                ? Text(
                    'Pending',
                    style: GoogleFonts.inter(
                      color: const Color(0xFFD97706),
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : isAdmin &&
                        !isCurrentUser &&
                        member.status == 'active' &&
                        member.role != 'admin'
                    ? TextButton(
                        onPressed: () => onMakeAdmin?.call(member),
                        child: const Text('Make admin'),
                      )
                    : null,
          );
        }).toList(),
      ),
    );
  }
}

class _JoinRequestsCard extends StatelessWidget {
  final List<GroupMember> members;
  final bool busy;
  final ValueChanged<GroupMember> onApprove;
  final ValueChanged<GroupMember> onDeny;

  const _JoinRequestsCard({
    required this.members,
    required this.busy,
    required this.onApprove,
    required this.onDeny,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Responsive.pp(14)),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.92),
        borderRadius: BorderRadius.circular(Responsive.wp(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Join requests',
            style: GoogleFonts.spaceGrotesk(
              fontSize: Responsive.sp(15),
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: Responsive.wp(10)),
          ...members.map(
            (member) => Padding(
              padding: EdgeInsets.only(bottom: Responsive.wp(10)),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: const Color(0xFFDCFCE7),
                    child: Text(
                        member.displayNameOnly.characters.first.toUpperCase()),
                  ),
                  SizedBox(width: Responsive.wp(10)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          member.displayNameOnly,
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(11.5),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (member.displayEmail.isNotEmpty)
                          Text(
                            member.displayEmail,
                            style: GoogleFonts.inter(
                              fontSize: Responsive.sp(9.8),
                              color: const Color(0xFF64748B),
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => onDeny(member),
                    child: const Text('Deny'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : () => onApprove(member),
                    child: const Text('Accept'),
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

class _SectionTitle extends StatelessWidget {
  final int count;

  const _SectionTitle({required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Latest snaps',
            style: GoogleFonts.spaceGrotesk(
              fontSize: Responsive.sp(16),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(
          '$count / 20',
          style: GoogleFonts.inter(
            color: const Color(0xFF64748B),
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _GroupSnapGrid extends StatelessWidget {
  final String groupId;
  final List<GroupSnap> snaps;
  final VoidCallback onReacted;

  const _GroupSnapGrid({
    required this.groupId,
    required this.snaps,
    required this.onReacted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: snaps
          .map(
            (snap) => Padding(
              padding: EdgeInsets.only(bottom: Responsive.pp(16)),
              child: _GroupSnapTile(
                groupId: groupId,
                snap: snap,
                onReacted: onReacted,
              ),
            ),
          )
          .toList(),
    );
  }
}

class _GroupSnapTile extends StatefulWidget {
  final String groupId;
  final GroupSnap snap;
  final VoidCallback onReacted;

  const _GroupSnapTile({
    required this.groupId,
    required this.snap,
    required this.onReacted,
  });

  @override
  State<_GroupSnapTile> createState() => _GroupSnapTileState();
}

class _GroupSnapTileState extends State<_GroupSnapTile> {
  late Map<String, int> _reactions;
  String? _myReaction;

  @override
  void initState() {
    super.initState();
    _syncFromWidget();
  }

  @override
  void didUpdateWidget(covariant _GroupSnapTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snap.id != widget.snap.id ||
        oldWidget.snap.myReaction != widget.snap.myReaction ||
        oldWidget.snap.reactions != widget.snap.reactions) {
      _syncFromWidget();
    }
  }

  void _syncFromWidget() {
    _reactions = Map<String, int>.from(widget.snap.reactions);
    _myReaction = widget.snap.myReaction;
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.snap;
    final description = (snap.description ?? snap.contentPreview ?? '').trim();
    final sharedBy =
        (snap.sharedByName == null || snap.sharedByName!.trim().isEmpty)
            ? 'Someone'
            : snap.sharedByName!.trim();
    final platform = snap.platformSource;
    final isSocialPlatform = platform != null;
    final sharedAt = _formatSharedAt(snap.sharedAt);

    return Material(
      elevation: 12,
      shadowColor: Colors.black.withOpacity(0.16),
      color: Colors.white,
      borderRadius: BorderRadius.circular(Responsive.wp(18)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isSocialPlatform
            ? null
            : () => context.push('/notes/${snap.noteId}', extra: snap.toNote()),
        onLongPress: () => _showReactionPicker(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                _GroupSnapMedia(
                  title: snap.title,
                  description: description,
                  originalFilename: snap.originalFilename,
                  contentType: snap.fileType,
                  imageUrl: snap.thumbnailUrl,
                  socialSource: platform,
                  sourceUrl: snap.sourceUrl,
                  fallbackAspectRatio:
                      _fallbackMediaAspectRatio(snap, platform),
                ),
                if (platform != null)
                  Positioned(
                    top: Responsive.pp(10),
                    left: Responsive.pp(10),
                    child: _GroupPlatformBadge(source: platform),
                  ),
                if (_reactions.isNotEmpty)
                  Positioned(
                    bottom: Responsive.pp(10),
                    right: Responsive.pp(10),
                    child: _ReactionSummary(
                      reactions: _reactions,
                      selected: _myReaction,
                    ),
                  ),
              ],
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                Responsive.pp(14),
                Responsive.pp(12),
                Responsive.pp(14),
                Responsive.pp(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SharedMetaRow(sharedBy: sharedBy, sharedAt: sharedAt),
                  SizedBox(height: Responsive.wp(8)),
                  Text(
                    snap.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: Responsive.sp(15),
                      fontWeight: FontWeight.w800,
                      height: 1.12,
                    ),
                  ),
                  if (description.isNotEmpty) ...[
                    SizedBox(height: Responsive.wp(7)),
                    Text(
                      description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(11.5),
                        height: 1.32,
                        color: const Color(0xFF64748B),
                      ),
                    ),
                  ],
                  SizedBox(height: Responsive.wp(10)),
                  Wrap(
                    spacing: Responsive.wp(5),
                    runSpacing: Responsive.wp(5),
                    children: [
                      if (snap.tag != null && snap.tag!.isNotEmpty)
                        _MiniBadge(label: snap.tag!),
                      if (snap.fileType != null && snap.fileType!.isNotEmpty)
                        _MiniBadge(label: snap.fileType!),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSharedAt(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final suffix = local.hour >= 12 ? 'PM' : 'AM';
    if (sameDay) return '$hour:$minute $suffix';
    return '${local.day}/${local.month} $hour:$minute $suffix';
  }

  double _fallbackMediaAspectRatio(GroupSnap snap, String? platform) {
    final source = (platform ?? '').toLowerCase();
    final type = (snap.fileType ?? snap.originalFilename ?? '').toLowerCase();
    final url = (snap.sourceUrl ?? '').toLowerCase();

    if (source == 'instagram') return 9 / 16;
    if (source == 'facebook') return 2 / 3;
    if (source == 'youtube') return 16 / 9;
    if (source == 'linkedin') return 1.91;
    if (source == 'twitter') return 3 / 4;
    if (source == 'reddit' || url.contains('reddit.com')) return 3 / 4;

    if (type.contains('pdf')) return 0.72;
    if (type.contains('doc') || type.contains('word')) return 0.72;
    if (type.contains('sheet') ||
        type.contains('excel') ||
        type.contains('csv')) {
      return 16 / 10;
    }
    if (type.contains('image')) return 1;
    if (type.contains('web') || type.contains('html')) return 16 / 10;

    return 4 / 3;
  }

  Future<void> _showReactionPicker(BuildContext context) async {
    const emojis = ['👍', '❤️', '😂', '😮', '🔥'];
    final emoji = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Responsive.pp(16)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ...emojis.map(
                (emoji) => InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => Navigator.of(ctx).pop(emoji),
                  child: Padding(
                    padding: EdgeInsets.all(Responsive.pp(10)),
                    child: Text(
                      emoji,
                      style: TextStyle(fontSize: Responsive.sp(32)),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Remove reaction',
                onPressed: () => Navigator.of(ctx).pop(''),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
    if (emoji == null) return;
    final previousReaction = _myReaction;
    final previousCounts = Map<String, int>.from(_reactions);
    setState(() {
      if (previousReaction != null && previousReaction.isNotEmpty) {
        final nextCount = (_reactions[previousReaction] ?? 0) - 1;
        if (nextCount <= 0) {
          _reactions.remove(previousReaction);
        } else {
          _reactions[previousReaction] = nextCount;
        }
      }
      _myReaction = emoji.isEmpty ? null : emoji;
      if (_myReaction != null && _myReaction!.isNotEmpty) {
        _reactions[_myReaction!] = (_reactions[_myReaction!] ?? 0) + 1;
      }
    });
    final ok = await ApiService().reactToGroupSnap(
      widget.groupId,
      widget.snap.id,
      emoji.isEmpty ? null : emoji,
    );
    if (ok) {
      widget.onReacted();
    } else if (context.mounted) {
      setState(() {
        _myReaction = previousReaction;
        _reactions = previousCounts;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save reaction')),
      );
    }
  }
}

class _GroupSnapMedia extends StatefulWidget {
  final String title;
  final String? description;
  final String? originalFilename;
  final String? contentType;
  final String? imageUrl;
  final String? socialSource;
  final String? sourceUrl;
  final double fallbackAspectRatio;

  const _GroupSnapMedia({
    required this.title,
    required this.description,
    required this.originalFilename,
    required this.contentType,
    required this.imageUrl,
    required this.socialSource,
    required this.sourceUrl,
    required this.fallbackAspectRatio,
  });

  @override
  State<_GroupSnapMedia> createState() => _GroupSnapMediaState();
}

class _GroupSnapMediaState extends State<_GroupSnapMedia> {
  late List<String> _candidates;
  int _index = 0;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  double? _resolvedAspectRatio;

  @override
  void initState() {
    super.initState();
    _candidates = _buildCandidates(widget.imageUrl);
    _resolveAspectRatio();
  }

  @override
  void didUpdateWidget(covariant _GroupSnapMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _candidates = _buildCandidates(widget.imageUrl);
      _index = 0;
      _resolvedAspectRatio = null;
      _resolveAspectRatio();
    }
  }

  @override
  void dispose() {
    _clearImageListener();
    super.dispose();
  }

  List<String> _buildCandidates(String? url) {
    final primary = url?.trim();
    if (primary == null || primary.isEmpty) return const [];
    final values = <String>[primary];
    if (primary.contains('maxresdefault')) {
      values.add(primary.replaceFirst('maxresdefault', 'hqdefault'));
    }
    return values;
  }

  void _nextFallback() {
    if (_index + 1 >= _candidates.length) return;
    setState(() {
      _index += 1;
      _resolvedAspectRatio = null;
    });
    _resolveAspectRatio();
  }

  void _clearImageListener() {
    final listener = _imageListener;
    final stream = _imageStream;
    if (listener != null && stream != null) {
      stream.removeListener(listener);
    }
    _imageListener = null;
    _imageStream = null;
  }

  void _resolveAspectRatio() {
    _clearImageListener();
    if (_candidates.isEmpty) return;
    final stream = CachedNetworkImageProvider(
      _candidates[_index],
      cacheManager: ThumbnailCacheManager.instance,
    ).resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final width = info.image.width;
        final height = info.image.height;
        if (!mounted || width <= 0 || height <= 0) return;
        setState(() => _resolvedAspectRatio = width / height);
      },
      onError: (_, __) {
        if (mounted && _index + 1 < _candidates.length) _nextFallback();
      },
    );
    _imageStream = stream;
    _imageListener = listener;
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final socialSource = (widget.socialSource ?? '').toLowerCase();
    final sourceUrl = widget.sourceUrl?.trim();
    final hasInteractiveSocial = sourceUrl != null &&
        sourceUrl.isNotEmpty &&
        const {
          'instagram',
          'facebook',
          'linkedin',
          'reddit',
          'twitter',
          'youtube',
        }.contains(socialSource);
    final hasPreviewImage = _candidates.isNotEmpty;
    final resolvedAspectRatio =
        _resolvedAspectRatio ?? widget.fallbackAspectRatio;

    if (hasInteractiveSocial &&
        !(socialSource == 'facebook' && hasPreviewImage)) {
      return AspectRatio(
        aspectRatio: widget.fallbackAspectRatio,
        child: SnapPreviewSurface(
          title: widget.title,
          description: widget.description,
          originalFilename: widget.originalFilename,
          contentType: widget.contentType,
          imageUrl: null,
          socialSource: widget.socialSource,
          sourceUrl: sourceUrl,
          mode: SnapPreviewMode.grid,
          interactive: true,
        ),
      );
    }

    if (!hasPreviewImage) {
      return AspectRatio(
        aspectRatio: widget.fallbackAspectRatio,
        child: SnapPreviewSurface(
          title: widget.title,
          description: widget.description,
          originalFilename: widget.originalFilename,
          contentType: widget.contentType,
          imageUrl: null,
          socialSource: widget.socialSource,
          sourceUrl: widget.sourceUrl,
          mode: SnapPreviewMode.grid,
          interactive: true,
        ),
      );
    }

    if (socialSource == 'facebook') {
      return AspectRatio(
        aspectRatio: resolvedAspectRatio,
        child: SnapPreviewSurface(
          title: widget.title,
          description: widget.description,
          originalFilename: widget.originalFilename,
          contentType: widget.contentType,
          imageUrl: _candidates[_index],
          socialSource: widget.socialSource,
          sourceUrl: widget.sourceUrl,
          mode: SnapPreviewMode.grid,
          interactive: true,
        ),
      );
    }

    final image = _candidates[_index];
    return AspectRatio(
      aspectRatio: resolvedAspectRatio,
      child: Container(
        width: double.infinity,
        color: const Color(0xFFF8FAFC),
        alignment: Alignment.center,
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            1.08,
            0,
            0,
            0,
            0,
            0,
            1.08,
            0,
            0,
            0,
            0,
            0,
            1.08,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: CachedNetworkImage(
            imageUrl: image,
            cacheManager: ThumbnailCacheManager.instance,
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
            alignment: Alignment.center,
            placeholder: (_, __) => _TextSnapFallback(
              title: widget.title,
              description: widget.description,
              contentType: widget.contentType,
            ),
            errorWidget: (_, __, ___) {
              if (_index + 1 < _candidates.length) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _nextFallback(),
                );
              }
              return _TextSnapFallback(
                title: widget.title,
                description: widget.description,
                contentType: widget.contentType,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TextSnapFallback extends StatelessWidget {
  final String title;
  final String? description;
  final String? contentType;

  const _TextSnapFallback({
    required this.title,
    this.description,
    this.contentType,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Responsive.pp(12)),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEFFDF5), Color(0xFFFFF7E6)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _iconFor(contentType),
            color: _GroupDetailScreenState._green,
            size: Responsive.sp(28),
          ),
          SizedBox(height: Responsive.wp(8)),
          Text(
            title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.spaceGrotesk(
              fontSize: Responsive.sp(12),
              fontWeight: FontWeight.w800,
              height: 1.08,
            ),
          ),
          if (description != null && description!.trim().isNotEmpty) ...[
            SizedBox(height: Responsive.wp(6)),
            Text(
              description!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(9.8),
                color: const Color(0xFF64748B),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(String? fileType) {
    final value = (fileType ?? '').toLowerCase();
    if (value.contains('youtube')) return Icons.play_circle_fill_rounded;
    if (value.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (value.contains('image')) return Icons.image_rounded;
    if (value.contains('web')) return Icons.language_rounded;
    if (value.contains('note')) return Icons.sticky_note_2_rounded;
    return Icons.description_rounded;
  }
}

class _SharedMetaRow extends StatelessWidget {
  final String sharedBy;
  final String sharedAt;

  const _SharedMetaRow({
    required this.sharedBy,
    required this.sharedAt,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: Responsive.pp(28),
          height: Responsive.pp(28),
          decoration: BoxDecoration(
            color: const Color(0xFFEFFDF5),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFFBBF7D0)),
          ),
          alignment: Alignment.center,
          child: Text(
            sharedBy.characters.first.toUpperCase(),
            style: GoogleFonts.spaceGrotesk(
              color: _GroupDetailScreenState._green,
              fontSize: Responsive.sp(12),
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        SizedBox(width: Responsive.wp(8)),
        Expanded(
          child: Text(
            '$sharedBy shared this',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              color: const Color(0xFF334155),
              fontSize: Responsive.sp(11.2),
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
        ),
        SizedBox(width: Responsive.wp(8)),
        Text(
          sharedAt,
          style: GoogleFonts.inter(
            color: const Color(0xFF94A3B8),
            fontSize: Responsive.sp(10.2),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _GroupPlatformBadge extends StatelessWidget {
  final String source;

  const _GroupPlatformBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final normalized = source.toLowerCase();
    Color color;
    IconData? icon;
    String? text;

    switch (normalized) {
      case 'youtube':
        color = const Color(0xFFFF0000);
        icon = Icons.play_arrow_rounded;
        break;
      case 'instagram':
        color = const Color(0xFFE1306C);
        icon = Icons.camera_alt_rounded;
        break;
      case 'facebook':
        color = const Color(0xFF1877F2);
        icon = Icons.facebook_rounded;
        break;
      case 'linkedin':
        color = const Color(0xFF0A66C2);
        text = 'in';
        break;
      case 'twitter':
        color = const Color(0xFF111827);
        text = 'X';
        break;
      case 'reddit':
        color = const Color(0xFFFF4500);
        icon = Icons.forum_rounded;
        break;
      default:
        color = const Color(0xFF22C55E);
        icon = Icons.link_rounded;
    }

    return Container(
      width: Responsive.wp(23),
      height: Responsive.wp(23),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: Responsive.wp(8),
            offset: Offset(0, Responsive.wp(3)),
          ),
        ],
      ),
      child: Center(
        child: text != null
            ? Text(
                text,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: Responsive.sp(10),
                  fontWeight: FontWeight.w900,
                ),
              )
            : Icon(icon, color: Colors.white, size: Responsive.sp(14)),
      ),
    );
  }
}

class _ReactionSummary extends StatelessWidget {
  final Map<String, int> reactions;
  final String? selected;

  const _ReactionSummary({required this.reactions, this.selected});

  @override
  Widget build(BuildContext context) {
    final text = reactions.entries
        .where((entry) => entry.value > 0)
        .map((entry) =>
            entry.value == 1 ? entry.key : '${entry.key} ${entry.value}')
        .take(3)
        .join(' ');
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.pp(9),
        vertical: Responsive.pp(5),
      ),
      decoration: BoxDecoration(
        color: selected == null
            ? Colors.black.withOpacity(0.54)
            : const Color(0xFF22C55E).withOpacity(0.90),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontSize: Responsive.sp(12),
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ShareSnapBar extends StatelessWidget {
  final VoidCallback onTap;

  const _ShareSnapBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: Responsive.pp(24),
      right: Responsive.pp(24),
      bottom: Responsive.pp(16) + bottom,
      child: FilledButton.icon(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: _GroupDetailScreenState._green,
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(vertical: Responsive.pp(15)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Responsive.wp(18)),
          ),
          elevation: 8,
          shadowColor: _GroupDetailScreenState._green.withOpacity(0.35),
        ),
        icon: const Icon(Icons.add_rounded),
        label: Text(
          'Share a Snap',
          style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w800,
            fontSize: Responsive.sp(14),
          ),
        ),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String label;

  const _MiniBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.wp(8),
        vertical: Responsive.wp(4),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFEFFDF5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.inter(
          color: const Color(0xFF15803D),
          fontSize: Responsive.sp(9.5),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _InviteDialog extends StatefulWidget {
  final ApiService api;

  const _InviteDialog({required this.api});

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _controller = TextEditingController();
  List<GroupUser> _results = [];
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String value) async {
    setState(() => _loading = true);
    final results = await widget.api.searchUsers(value);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  bool get _looksLikeEmail {
    final text = _controller.text.trim();
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text);
  }

  bool get _hasSearchText => _controller.text.trim().length >= 2;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Invite people',
        style: GoogleFonts.spaceGrotesk(
          fontSize: Responsive.sp(17),
          fontWeight: FontWeight.w800,
        ),
      ),
      content: SizedBox(
        width: Responsive.width > 380
            ? Responsive.wp(300)
            : Responsive.width - Responsive.pp(64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              style: GoogleFonts.inter(fontSize: Responsive.sp(12.5)),
              decoration: InputDecoration(
                labelText: 'Search by name or email',
                labelStyle: GoogleFonts.inter(fontSize: Responsive.sp(12)),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: Responsive.pp(19),
                ),
                helperText:
                    'Use their InfoSnap name or email. New users can be invited by email.',
                helperStyle: GoogleFonts.inter(fontSize: Responsive.sp(10)),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(12),
                  vertical: Responsive.pp(11),
                ),
              ),
              onChanged: (value) {
                if (value.trim().length >= 2) {
                  _search(value);
                } else {
                  setState(() => _results = []);
                }
              },
            ),
            SizedBox(height: Responsive.wp(12)),
            if (_loading) const LinearProgressIndicator(),
            ..._results.map(
              (user) => ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text(
                  user.displayName,
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(12.3),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  user.email,
                  style: GoogleFonts.inter(fontSize: Responsive.sp(10.5)),
                ),
                onTap: () => Navigator.of(context)
                    .pop(_InviteTarget(userId: user.id, user: user)),
              ),
            ),
            if (!_loading &&
                _results.isEmpty &&
                _hasSearchText &&
                !_looksLikeEmail)
              Padding(
                padding: EdgeInsets.only(top: Responsive.wp(6)),
                child: Text(
                  'No matching InfoSnap user found. Try their full email address.',
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(10.8),
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.58),
                  ),
                ),
              ),
            if (!_loading && _results.isEmpty && _looksLikeEmail)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: Icon(
                  Icons.mail_outline_rounded,
                  size: Responsive.pp(20),
                ),
                title: Text(
                  'Invite ${_controller.text.trim()}',
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(12.3),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  'They will get an email invite',
                  style: GoogleFonts.inter(fontSize: Responsive.sp(10.5)),
                ),
                onTap: () => Navigator.of(context)
                    .pop(_InviteTarget(email: _controller.text.trim())),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(fontSize: Responsive.sp(12)),
          ),
        ),
      ],
    );
  }
}

class _InviteTarget {
  final String? userId;
  final String? email;
  final GroupUser? user;

  const _InviteTarget({this.userId, this.email, this.user});
}

class _EmptySnaps extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Responsive.pp(22)),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(Responsive.wp(18)),
      ),
      child: const Text(
          'No snaps shared yet. Open a snap and share it to this group.'),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Reload group'),
      ),
    );
  }
}
