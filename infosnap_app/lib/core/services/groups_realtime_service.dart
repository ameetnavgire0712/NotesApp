import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class GroupsRealtimeEvent {
  final String type;
  final String? groupId;
  final String? snapId;
  final String? userId;
  final String? emoji;
  final String? op;
  final String? traceId;
  final String? status;
  final String? noteId;

  const GroupsRealtimeEvent({
    required this.type,
    this.groupId,
    this.snapId,
    this.userId,
    this.emoji,
    this.op,
    this.traceId,
    this.status,
    this.noteId,
  });

  bool get isGroupsListChanged => type == 'groups_list_changed';
  bool get isGroupChanged => type == 'group_changed' && groupId != null;
  bool get isReaction =>
      type == 'reaction' && groupId != null && snapId != null;
  bool get isUploadDone =>
      type == 'upload_done' && traceId != null && status != null;

  factory GroupsRealtimeEvent.fromPayload(Object? raw) {
    Object? payload = raw;
    if (raw is Map && raw['payload'] != null) payload = raw['payload'];
    final map = payload is Map ? payload : const {};
    return GroupsRealtimeEvent(
      type: map['t']?.toString() ?? '',
      groupId: map['g']?.toString(),
      snapId: map['s']?.toString(),
      userId: map['u']?.toString(),
      emoji: map['e']?.toString(),
      op: map['op']?.toString(),
      traceId: map['traceId']?.toString() ?? map['trace_id']?.toString(),
      status: map['status']?.toString(),
      noteId: map['noteId']?.toString() ?? map['note_id']?.toString(),
    );
  }
}

class GroupsRealtimeSubscription {
  final VoidCallback _dispose;
  bool _disposed = false;

  GroupsRealtimeSubscription(this._dispose);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _dispose();
  }
}

class _GroupsListener {
  final String? groupId;
  final ValueChanged<GroupsRealtimeEvent> onEvent;
  final VoidCallback onResumeRefresh;

  const _GroupsListener({
    required this.groupId,
    required this.onEvent,
    required this.onResumeRefresh,
  });
}

class GroupsRealtimeService with WidgetsBindingObserver {
  GroupsRealtimeService._();

  static final GroupsRealtimeService instance = GroupsRealtimeService._();

  final Map<int, _GroupsListener> _listeners = {};
  int _nextListenerId = 0;
  RealtimeChannel? _channel;
  String? _channelUserId;
  bool _lifecycleAttached = false;

  SupabaseClient get _client => Supabase.instance.client;

  @visibleForTesting
  int get activeListenerCount => _listeners.length;

  @visibleForTesting
  String? get activeChannelTopic =>
      _channelUserId == null ? null : 'user:$_channelUserId';

  GroupsRealtimeSubscription subscribeToUser({
    String? groupId,
    required ValueChanged<GroupsRealtimeEvent> onEvent,
    required VoidCallback onResumeRefresh,
  }) {
    _attachLifecycle();
    final id = _nextListenerId++;
    _listeners[id] = _GroupsListener(
      groupId: groupId,
      onEvent: onEvent,
      onResumeRefresh: onResumeRefresh,
    );
    _ensureChannel();
    return GroupsRealtimeSubscription(() {
      _listeners.remove(id);
      if (_listeners.isEmpty) {
        unawaited(_teardownChannel());
      }
    });
  }

  void ensureConnected() {
    _ensureChannel();
  }

  void _attachLifecycle() {
    if (_lifecycleAttached) return;
    _lifecycleAttached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_teardownChannel());
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _ensureChannel();
      for (final listener in List<_GroupsListener>.from(_listeners.values)) {
        listener.onResumeRefresh();
      }
    }
  }

  void _ensureChannel() {
    if (_listeners.isEmpty) return;
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    if (_channel != null && _channelUserId == userId) return;

    unawaited(_teardownChannel());
    _channelUserId = userId;
    _channel = _client
        .channel(
          'user:$userId',
          opts: const RealtimeChannelConfig(
            ack: true,
            self: false,
          ),
        )
        .onBroadcast(
          event: 'groups',
          callback: _handleBroadcast,
        )..subscribe((status, [error]) {
        debugPrint('GROUPS_REALTIME: user:$userId subscription $status $error');
      });
  }

  void _handleBroadcast(Object payload) {
    final event = GroupsRealtimeEvent.fromPayload(payload);
    if (event.type.isEmpty) return;

    for (final listener in List<_GroupsListener>.from(_listeners.values)) {
      if (event.isGroupsListChanged) {
        listener.onEvent(event);
        continue;
      }
      if (event.isUploadDone) {
        listener.onEvent(event);
        continue;
      }
      if (event.groupId != null && listener.groupId == event.groupId) {
        listener.onEvent(event);
      }
    }
  }

  Future<void> _teardownChannel() async {
    final channel = _channel;
    _channel = null;
    _channelUserId = null;
    if (channel == null) return;
    try {
      await _client.removeChannel(channel);
      debugPrint('GROUPS_REALTIME: user channel removed');
    } catch (e) {
      debugPrint('GROUPS_REALTIME: remove user channel failed: $e');
    }
  }
}
