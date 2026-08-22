import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/api_service.dart';
import '../../core/services/groups_realtime_service.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';
import 'widgets/group_avatar.dart';

enum _GroupsView { groups, discover }

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  final _api = ApiService();
  final _discoverController = TextEditingController();

  List<GroupSummary> _groups = const [];
  List<GroupSummary> _discoverGroups = const [];
  bool _loading = true;
  bool _discoverLoading = false;
  _GroupsView _selectedView = _GroupsView.groups;
  GroupsRealtimeSubscription? _realtime;
  Timer? _refreshDebounce;
  Timer? _discoverDebounce;

  static const _green = Color(0xFF22C55E);
  static const _dark = Color(0xFF18181B);

  @override
  void initState() {
    super.initState();
    final cachedGroups = _api.cachedGroups;
    if (cachedGroups.isNotEmpty) {
      _groups = cachedGroups;
      _loading = false;
      _loadGroups(showLoader: false, forceRefresh: false);
    } else {
      _loadPersistedGroupsThenRefresh();
    }
    _subscribeRealtime();
  }

  Future<void> _loadPersistedGroupsThenRefresh() async {
    final groups = await _api.loadPersistedGroups();
    if (!mounted) return;
    if (groups.isNotEmpty) {
      setState(() {
        _groups = groups;
        _loading = false;
      });
      unawaited(_loadGroups(showLoader: false, forceRefresh: true));
    } else {
      await _loadGroups(showLoader: true, forceRefresh: false);
    }
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _discoverDebounce?.cancel();
    _discoverController.dispose();
    unawaited(_realtime?.dispose());
    super.dispose();
  }

  void _subscribeRealtime() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    _realtime = GroupsRealtimeService.instance.subscribeToUser(
      onEvent: (event) {
        if (event.isGroupsListChanged) _scheduleRealtimeRefresh();
      },
      onResumeRefresh: _scheduleRealtimeRefresh,
    );
  }

  void _scheduleRealtimeRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(
      const Duration(milliseconds: 450),
      () => _loadGroups(showLoader: false, forceRefresh: true),
    );
  }

  Future<void> _loadGroups({
    required bool showLoader,
    bool forceRefresh = false,
  }) async {
    if (showLoader && mounted) {
      setState(() => _loading = true);
    }
    final groups = await _api.fetchGroupsCached(forceRefresh: forceRefresh);
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  Future<void> _runDiscoverSearch(String value) async {
    final query = value.trim();
    if (query.length < 2) {
      if (!mounted) return;
      setState(() {
        _discoverLoading = false;
        _discoverGroups = const [];
      });
      return;
    }
    setState(() => _discoverLoading = true);
    final groups = await _api.discoverGroups(query);
    if (!mounted || _discoverController.text.trim() != query) return;
    setState(() {
      _discoverGroups = groups;
      _discoverLoading = false;
    });
  }

  void _onDiscoverChanged(String value) {
    _discoverDebounce?.cancel();
    _discoverDebounce = Timer(
      const Duration(milliseconds: 280),
      () => _runDiscoverSearch(value),
    );
  }

  void _refresh() {
    if (_selectedView == _GroupsView.discover) {
      _runDiscoverSearch(_discoverController.text);
      return;
    }
    _loadGroups(showLoader: _groups.isEmpty, forceRefresh: true);
  }

  Future<void> _openGroup(GroupSummary group) async {
    setState(() {
      _groups = _groups
          .map((item) =>
              item.id == group.id ? item.copyWith(unreadCount: 0) : item)
          .toList();
    });
    await context.push('/groups/${group.id}');
    if (!mounted) return;
    _loadGroups(showLoader: false, forceRefresh: true);
    if (_discoverController.text.trim().length >= 2) {
      _runDiscoverSearch(_discoverController.text);
    }
  }

  Future<void> _createGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Create group',
          style: GoogleFonts.spaceGrotesk(
            fontSize: Responsive.sp(17),
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SizedBox(
          width: Responsive.width > 360
              ? Responsive.wp(280)
              : Responsive.width - Responsive.pp(64),
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 20,
            style: GoogleFonts.inter(fontSize: Responsive.sp(13)),
            decoration: InputDecoration(
              labelText: 'Group name',
              counterText: '',
              hintText: 'e.g. Weekend plans',
              labelStyle: GoogleFonts.inter(fontSize: Responsive.sp(12)),
              hintStyle: GoogleFonts.inter(fontSize: Responsive.sp(12)),
              contentPadding: EdgeInsets.symmetric(
                horizontal: Responsive.pp(12),
                vertical: Responsive.pp(11),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(fontSize: Responsive.sp(12)),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(
              'Create',
              style: GoogleFonts.inter(fontSize: Responsive.sp(12)),
            ),
          ),
        ],
      ),
    );
    if (name == null || name.length < 2) return;
    if (!mounted) return;
    if (name.length > 20) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Group name can be at most 20 characters'),
        ),
      );
      return;
    }

    final optimisticId = 'creating-${DateTime.now().microsecondsSinceEpoch}';
    final optimisticGroup = GroupSummary(
      id: optimisticId,
      name: name,
      role: 'admin',
      status: 'creating',
      memberCount: 1,
      unreadCount: 0,
      latestActivityAt: DateTime.now(),
      latestActivityTitle: name,
      latestActivityType: 'group_created',
      createdAt: DateTime.now(),
    );
    setState(() {
      _groups = [optimisticGroup, ..._groups];
      _loading = false;
      _selectedView = _GroupsView.groups;
    });

    final group = await _api.createGroup(name);
    if (!mounted) return;
    if (group == null) {
      setState(() {
        _groups = _groups.where((item) => item.id != optimisticId).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create group')),
      );
      return;
    }
    setState(() {
      _groups = [
        group,
        ..._groups
            .where((item) => item.id != group.id && item.id != optimisticId),
      ];
    });
    unawaited(_loadGroups(showLoader: false, forceRefresh: true));
    if (!context.mounted) return;
    if (mounted) {
      context.push('/groups/${group.id}');
    }
  }

  Future<void> _respond(GroupSummary group, bool accept) async {
    final previous = _groups;
    setState(() {
      _groups = accept
          ? _groups
              .map((item) => item.id == group.id
                  ? item.copyWith(status: 'active', unreadCount: 0)
                  : item)
              .toList()
          : _groups.where((item) => item.id != group.id).toList();
    });

    final ok = accept
        ? await _api.acceptGroupInvite(group.id)
        : await _api.declineGroupInvite(group.id);
    if (!mounted) return;
    if (!ok) {
      setState(() => _groups = previous);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(ok ? 'Updated invite' : 'Could not update invite')),
    );
    if (ok) unawaited(_loadGroups(showLoader: false, forceRefresh: true));
  }

  Future<void> _requestJoin(GroupSummary group) async {
    final previous = _discoverGroups;
    setState(() {
      _discoverGroups = _discoverGroups
          .map((item) =>
              item.id == group.id ? item.copyWith(status: 'requested') : item)
          .toList();
    });
    final ok = await _api.requestJoinGroup(group.id);
    if (!mounted) return;
    if (!ok) {
      setState(() => _discoverGroups = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send join request')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Join request sent for ${group.name}')),
    );
    unawaited(_loadGroups(showLoader: false, forceRefresh: true));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      floatingActionButton: _selectedView == _GroupsView.groups
          ? FloatingActionButton.extended(
              onPressed: _createGroup,
              backgroundColor: _green,
              icon: const Icon(Icons.group_add_rounded, color: Colors.white),
              label: const Text(
                'New group',
                style: TextStyle(color: Colors.white),
              ),
            )
          : null,
      body: Stack(
        children: [
          const Positioned.fill(child: SoftGridBackground()),
          SafeArea(
            child: Column(
              children: [
                _Header(
                  selectedView: _selectedView,
                  discoverController: _discoverController,
                  onRefresh: _refresh,
                  onViewChanged: (view) {
                    setState(() => _selectedView = view);
                    if (view == _GroupsView.discover &&
                        _discoverController.text.trim().length >= 2 &&
                        _discoverGroups.isEmpty) {
                      unawaited(_runDiscoverSearch(_discoverController.text));
                    }
                  },
                  onDiscoverChanged: _onDiscoverChanged,
                ),
                Expanded(
                  child: _selectedView == _GroupsView.groups
                      ? _buildGroupsList()
                      : _buildDiscoverList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsList() {
    if (_loading && _groups.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_groups.isEmpty) {
      return _EmptyState(onCreate: _createGroup);
    }
    return RefreshIndicator(
      onRefresh: () async => _loadGroups(showLoader: false, forceRefresh: true),
      color: _green,
      child: ListView.separated(
        padding: EdgeInsets.all(Responsive.pp(18)),
        itemCount: _groups.length,
        separatorBuilder: (_, __) => SizedBox(height: Responsive.wp(12)),
        itemBuilder: (context, index) {
          final group = _groups[index];
          return _GroupCard(
            group: group,
            onTap: group.status == 'pending' || group.status == 'creating'
                ? null
                : () => _openGroup(group),
            onAccept:
                group.status == 'pending' ? () => _respond(group, true) : null,
            onDecline:
                group.status == 'pending' ? () => _respond(group, false) : null,
          ).animate().fadeIn(delay: (40 * index).ms).slideY(begin: 0.05);
        },
      ),
    );
  }

  Widget _buildDiscoverList() {
    final query = _discoverController.text.trim();
    final visibleDiscoverGroups = _discoverGroups;
    if (query.length < 2) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Responsive.pp(28)),
          child: Text(
            'Search a group by name and send a request to join. The group admin will receive a notification and can approve or deny it.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(13),
              height: 1.45,
              color: Colors.grey.shade700,
            ),
          ),
        ),
      );
    }
    if (_discoverLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visibleDiscoverGroups.isEmpty) {
      return Center(
        child: Text(
          'No groups found for "$query"',
          style: GoogleFonts.inter(
            fontSize: Responsive.sp(13),
            color: Colors.grey.shade700,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _runDiscoverSearch(query),
      color: _green,
      child: ListView.separated(
        padding: EdgeInsets.all(Responsive.pp(18)),
        itemCount: visibleDiscoverGroups.length,
        separatorBuilder: (_, __) => SizedBox(height: Responsive.wp(12)),
        itemBuilder: (context, index) {
          final group = visibleDiscoverGroups[index];
          return _DiscoverGroupCard(
            group: group,
            onRequestJoin:
                (group.status != 'active' && group.status != 'pending')
                    ? () => _requestJoin(group)
                    : null,
            onOpen: group.status == 'active' ? () => _openGroup(group) : null,
          ).animate().fadeIn(delay: (30 * index).ms).slideY(begin: 0.04);
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final _GroupsView selectedView;
  final TextEditingController discoverController;
  final ValueChanged<_GroupsView> onViewChanged;
  final ValueChanged<String> onDiscoverChanged;
  final VoidCallback onRefresh;

  const _Header({
    required this.selectedView,
    required this.discoverController,
    required this.onViewChanged,
    required this.onDiscoverChanged,
    required this.onRefresh,
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
      padding: EdgeInsets.fromLTRB(
        Responsive.pp(10),
        Responsive.pp(12),
        Responsive.pp(10),
        Responsive.pp(12),
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE0F2FE), Color(0xFFC7E9FB), Color(0xFFD1FAE5)],
        ),
        borderRadius: BorderRadius.circular(Responsive.wp(22)),
        border: Border.all(color: Colors.white.withOpacity(0.55)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0EA5E9).withOpacity(0.14),
            blurRadius: Responsive.wp(20),
            offset: Offset(0, Responsive.wp(8)),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Leading icon chip matching the bottom-nav Groups tab.
              Container(
                width: Responsive.wp(40),
                height: Responsive.wp(40),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(Responsive.wp(12)),
                  border: Border.all(color: Colors.white.withOpacity(0.9)),
                ),
                child: Icon(
                  Icons.groups_rounded,
                  size: Responsive.sp(20),
                  color: const Color(0xFF0369A1),
                ),
              ),
              SizedBox(width: Responsive.wp(12)),
              Expanded(
                child: Text(
                  'Groups',
                  style: GoogleFonts.spaceGrotesk(
                    color: const Color(0xFF0F172A),
                    fontSize: Responsive.sp(19),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                onPressed: onRefresh,
                icon: const Icon(
                  Icons.refresh_rounded,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
          SizedBox(height: Responsive.wp(10)),
          Row(
            children: [
              Expanded(
                child: _HeaderTab(
                  label: 'Groups',
                  selected: selectedView == _GroupsView.groups,
                  onTap: () => onViewChanged(_GroupsView.groups),
                ),
              ),
              SizedBox(width: Responsive.wp(10)),
              Expanded(
                child: _HeaderTab(
                  label: 'Discover',
                  selected: selectedView == _GroupsView.discover,
                  onTap: () => onViewChanged(_GroupsView.discover),
                ),
              ),
            ],
          ),
          if (selectedView == _GroupsView.discover) ...[
            SizedBox(height: Responsive.wp(10)),
            StatefulBuilder(
              builder: (context, setInnerState) => TextField(
                controller: discoverController,
                onChanged: (value) {
                  setInnerState(() {});
                  onDiscoverChanged(value);
                },
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(12.5),
                  color: const Color(0xFF0F172A),
                ),
                cursorColor: const Color(0xFF0F172A),
                decoration: InputDecoration(
                  hintText: 'Search groups by name',
                  hintStyle: GoogleFonts.inter(
                    fontSize: Responsive.sp(12.5),
                    color: const Color(0xFF475569),
                  ),
                  prefixIcon: const Icon(Icons.search_rounded,
                      color: Color(0xFF334155)),
                  suffixIcon: discoverController.text.isNotEmpty
                      ? IconButton(
                          onPressed: () {
                            discoverController.clear();
                            setInnerState(() {});
                            onDiscoverChanged('');
                          },
                          icon: const Icon(Icons.close_rounded,
                              color: Color(0xFF334155)),
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.85),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Responsive.wp(16)),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _HeaderTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color:
          selected ? _GroupsScreenState._green : Colors.white.withOpacity(0.82),
      borderRadius: BorderRadius.circular(Responsive.wp(15)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Responsive.wp(15)),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(14),
            vertical: Responsive.pp(12),
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.inter(
                color: selected ? Colors.white : _GroupsScreenState._dark,
                fontSize: Responsive.sp(11.8),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final GroupSummary group;
  final VoidCallback? onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  const _GroupCard({
    required this.group,
    this.onTap,
    this.onAccept,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final pending = group.status == 'pending';
    final creating = group.status == 'creating';
    final activityDescription = (group.latestActivityDescription ?? '').trim();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(Responsive.wp(18)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Responsive.wp(18)),
        child: Padding(
          padding: EdgeInsets.all(Responsive.pp(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GroupAvatar(
                    seed: group.id,
                    name: group.name,
                    imageUrl: group.avatarUrl,
                    size: Responsive.wp(42),
                    borderRadius: Responsive.wp(14),
                  ),
                  SizedBox(width: Responsive.wp(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: Responsive.sp(13.5),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: Responsive.wp(3)),
                        Text(
                          creating
                              ? 'Creating...'
                              : pending
                                  ? 'Invited by ${group.invitedBy?.displayName ?? 'someone'}'
                                  : '${group.memberCount} members',
                          style: GoogleFonts.inter(
                            fontSize: Responsive.sp(9.8),
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (creating)
                    SizedBox(
                      width: Responsive.wp(18),
                      height: Responsive.wp(18),
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (group.unreadCount > 0)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: Responsive.wp(9),
                        vertical: Responsive.wp(5),
                      ),
                      decoration: BoxDecoration(
                        color: _GroupsScreenState._green,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${group.unreadCount}',
                        style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: Responsive.sp(9.5),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
              if (!pending && !creating) ...[
                SizedBox(height: Responsive.wp(11)),
                Text(
                  group.latestActivitySummary,
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(11.2),
                    fontWeight: FontWeight.w700,
                    color: _GroupsScreenState._dark,
                    height: 1.3,
                  ),
                ),
                if (activityDescription.isNotEmpty) ...[
                  SizedBox(height: Responsive.wp(6)),
                  Text(
                    activityDescription,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(10.8),
                      color: const Color(0xFF64748B),
                      height: 1.42,
                    ),
                  ),
                ],
              ],
              if (pending) ...[
                SizedBox(height: Responsive.wp(14)),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onDecline,
                        child: const Text('Decline'),
                      ),
                    ),
                    SizedBox(width: Responsive.wp(10)),
                    Expanded(
                      child: FilledButton(
                        onPressed: onAccept,
                        child: const Text('Accept'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscoverGroupCard extends StatelessWidget {
  final GroupSummary group;
  final VoidCallback? onRequestJoin;
  final VoidCallback? onOpen;

  const _DiscoverGroupCard({
    required this.group,
    this.onRequestJoin,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final status = group.status;
    final isRequested = status == 'requested';
    final isMember = status == 'active';

    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(Responsive.wp(18)),
      child: InkWell(
        onTap: isMember ? onOpen : null,
        borderRadius: BorderRadius.circular(Responsive.wp(18)),
        child: Padding(
          padding: EdgeInsets.all(Responsive.pp(12)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GroupAvatar(
                seed: group.id,
                name: group.name,
                imageUrl: group.avatarUrl,
                size: Responsive.wp(42),
                borderRadius: Responsive.wp(14),
              ),
              SizedBox(width: Responsive.wp(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: Responsive.sp(13.5),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: Responsive.wp(4)),
                    Text(
                      '${group.memberCount} members',
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(9.8),
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: Responsive.wp(8)),
                    Text(
                      group.latestActivitySummary,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(10.8),
                        fontWeight: FontWeight.w700,
                        height: 1.32,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: Responsive.wp(10)),
              FilledButton.tonal(
                onPressed:
                    isMember ? onOpen : (isRequested ? null : onRequestJoin),
                style: FilledButton.styleFrom(
                  backgroundColor: isMember
                      ? const Color(0xFFDCFCE7)
                      : (isRequested ? const Color(0xFFE0F2FE) : null),
                ),
                child: Text(
                  isMember
                      ? 'Open'
                      : (isRequested ? 'Requested' : 'Request to join'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Responsive.pp(28)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.groups_2_rounded,
              size: Responsive.sp(62),
              color: _GroupsScreenState._green,
            ),
            SizedBox(height: Responsive.wp(16)),
            Text(
              'Create your first group',
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                fontSize: Responsive.sp(22),
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: Responsive.wp(8)),
            Text(
              'Invite up to 10 people and share snaps without changing your personal SnapBot search.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(color: Colors.grey.shade600),
            ),
            SizedBox(height: Responsive.wp(18)),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New group'),
            ),
          ],
        ),
      ),
    );
  }
}
