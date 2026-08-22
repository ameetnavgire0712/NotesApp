import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api_service.dart';
import '../services/groups_realtime_service.dart';
import 'notes_provider.dart';

enum UploadStatus { idle, uploading, completed, failed, cancelled }

class UploadTaskState {
  final String clientId;
  final UploadStatus status;
  final String? traceId;
  final String? itemName;
  final String? errorMessage;
  final String? currentStep;
  final String? optimisticNoteId;
  final bool bannerHidden;

  const UploadTaskState({
    required this.clientId,
    this.status = UploadStatus.uploading,
    this.traceId,
    this.itemName,
    this.errorMessage,
    this.currentStep,
    this.optimisticNoteId,
    this.bannerHidden = false,
  });

  bool get isUploading => status == UploadStatus.uploading;
  bool get isCompleted => status == UploadStatus.completed;
  bool get isFailed => status == UploadStatus.failed;
  bool get isCancelled => status == UploadStatus.cancelled;
  bool get isTerminal => isCompleted || isFailed || isCancelled;

  UploadTaskState copyWith({
    UploadStatus? status,
    String? traceId,
    String? itemName,
    String? errorMessage,
    String? currentStep,
    String? optimisticNoteId,
    bool? bannerHidden,
  }) {
    return UploadTaskState(
      clientId: clientId,
      status: status ?? this.status,
      traceId: traceId ?? this.traceId,
      itemName: itemName ?? this.itemName,
      errorMessage: errorMessage ?? this.errorMessage,
      currentStep: currentStep ?? this.currentStep,
      optimisticNoteId: optimisticNoteId ?? this.optimisticNoteId,
      bannerHidden: bannerHidden ?? this.bannerHidden,
    );
  }
}

class UploadState {
  final List<UploadTaskState> tasks;

  const UploadState({this.tasks = const []});

  UploadTaskState? get primaryTask {
    for (final task in tasks) {
      if (task.isUploading && !task.bannerHidden) return task;
    }
    for (final task in tasks) {
      if (!task.bannerHidden) return task;
    }
    return tasks.isNotEmpty ? tasks.first : null;
  }

  List<UploadTaskState> get activeTasks =>
      tasks.where((task) => task.isUploading).toList(growable: false);

  int get activeCount => activeTasks.length;
  bool get hasMultipleActive => activeCount > 1;

  UploadStatus get status => primaryTask?.status ?? UploadStatus.idle;
  String? get traceId => primaryTask?.traceId;
  String? get itemName => primaryTask?.itemName;
  String? get errorMessage => primaryTask?.errorMessage;
  String? get currentStep => primaryTask?.currentStep;
  String? get optimisticNoteId => primaryTask?.optimisticNoteId;
  bool get bannerHidden =>
      tasks.isNotEmpty && tasks.every((task) => task.bannerHidden);

  bool get isUploading => activeCount > 0;
  bool get isCompleted => status == UploadStatus.completed;
  bool get isFailed => status == UploadStatus.failed;
  bool get isCancelled => status == UploadStatus.cancelled;
  bool get isIdle => tasks.isEmpty;

  UploadState copyWith({List<UploadTaskState>? tasks}) {
    return UploadState(tasks: tasks ?? this.tasks);
  }
}

final uploadProvider =
    StateNotifierProvider<UploadNotifier, UploadState>((ref) {
  return UploadNotifier(ref);
});

class UploadNotifier extends StateNotifier<UploadState>
    with WidgetsBindingObserver {
  final Ref _ref;
  final Map<String, Timer> _pollTimers = {};
  final Map<String, Timer> _fallbackPollTimers = {};
  final Set<String> _cancelRequested = {};
  final Set<String> _pausedClientIds = {};
  GroupsRealtimeSubscription? _realtimeSub;

  UploadNotifier(this._ref) : super(const UploadState()) {
    WidgetsBinding.instance.addObserver(this);
    _realtimeSub = GroupsRealtimeService.instance.subscribeToUser(
      onEvent: _handleRealtimeEvent,
      onResumeRefresh: _refreshActiveUploadsOnce,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      for (final task in this.state.activeTasks) {
        if (_pollTimers.containsKey(task.clientId)) {
          _pausedClientIds.add(task.clientId);
        }
      }
      for (final timer in _pollTimers.values) {
        timer.cancel();
      }
      _pollTimers.clear();
    } else if (state == AppLifecycleState.resumed) {
      final paused = List<String>.from(_pausedClientIds);
      _pausedClientIds.clear();
      for (final clientId in paused) {
        final task = _taskByClientId(clientId);
        final traceId = task?.traceId;
        if (task != null &&
            traceId != null &&
            task.isUploading &&
            !_cancelRequested.contains(clientId)) {
          _scheduleFallbackPolling(clientId, traceId);
        }
      }
    }
  }

  String startUpload(String traceId, String itemName) {
    final clientId = startUploading(itemName);
    setTraceId(traceId, clientUploadId: clientId);
    return clientId;
  }

  String startUploading(String itemName) {
    final clientId = 'upload-${DateTime.now().microsecondsSinceEpoch}';
    _cancelRequested.remove(clientId);
    final optimisticId = _addOptimisticUpload(itemName);
    final task = UploadTaskState(
      clientId: clientId,
      itemName: itemName,
      optimisticNoteId: optimisticId,
    );
    state = state.copyWith(tasks: [task, ...state.tasks]);
    return clientId;
  }

  void setTraceId(String traceId, {String? clientUploadId}) {
    final clientId = clientUploadId ?? _firstPendingClientId();
    if (clientId == null) {
      startUpload(traceId, 'Upload');
      return;
    }

    _updateTask(clientId, (task) => task.copyWith(traceId: traceId));
    GroupsRealtimeService.instance.ensureConnected();
    try {
      _ref.read(notesProvider.notifier).refreshSilent();
    } catch (_) {}
    _scheduleFallbackPolling(clientId, traceId);
  }

  void hide({String? clientUploadId}) {
    if (clientUploadId != null) {
      _updateTask(clientUploadId, (task) => task.copyWith(bannerHidden: true));
      return;
    }
    state = state.copyWith(
      tasks: state.tasks
          .map((task) =>
              task.isUploading ? task.copyWith(bannerHidden: true) : task)
          .toList(growable: false),
    );
  }

  Future<void> cancel({String? clientUploadId}) async {
    final task = clientUploadId != null
        ? _taskByClientId(clientUploadId)
        : state.activeTasks.isNotEmpty
            ? state.activeTasks.first
            : state.primaryTask;
    if (task == null) return;

    _cancelRequested.add(task.clientId);
    _pollTimers.remove(task.clientId)?.cancel();
    _fallbackPollTimers.remove(task.clientId)?.cancel();

    final traceId = task.traceId;
    if (traceId != null) {
      try {
        await ApiService().cancelUpload(traceId);
        debugPrint('Upload cancelled: $traceId');
      } catch (e) {
        debugPrint('Cancel error: $e');
      }
    }
    _removeOptimisticUpload(task);
    _updateTask(
      task.clientId,
      (current) => current.copyWith(status: UploadStatus.cancelled),
    );
    _scheduleTaskRemoval(task.clientId, const Duration(seconds: 2));
  }

  void markCompleted({String? clientUploadId}) {
    final task = _resolveTask(clientUploadId);
    if (task == null) return;

    _pollTimers.remove(task.clientId)?.cancel();
    _fallbackPollTimers.remove(task.clientId)?.cancel();
    ApiService().invalidateTagsCache();
    ApiService().invalidateHighlightsCache();

    try {
      _ref.read(notesProvider.notifier).refresh();
    } catch (_) {}
    _removeOptimisticUpload(task);

    if (task.bannerHidden) {
      _removeTask(task.clientId);
      return;
    }

    _updateTask(
      task.clientId,
      (current) => current.copyWith(status: UploadStatus.completed),
    );
    _scheduleTaskRemoval(task.clientId, const Duration(seconds: 3));
  }

  void markFailed(String errorMessage, {String? clientUploadId}) {
    final task = _resolveTask(clientUploadId);
    if (task == null) return;

    _pollTimers.remove(task.clientId)?.cancel();
    _fallbackPollTimers.remove(task.clientId)?.cancel();
    _removeOptimisticUpload(task);
    _updateTask(
      task.clientId,
      (current) => current.copyWith(
        status: UploadStatus.failed,
        errorMessage: errorMessage,
        bannerHidden: false,
      ),
    );
    try {
      _ref.read(notesProvider.notifier).refresh();
    } catch (_) {}
    _scheduleTaskRemoval(task.clientId, const Duration(seconds: 5));
  }

  void reset({String? clientUploadId}) {
    if (clientUploadId != null) {
      final task = _taskByClientId(clientUploadId);
      if (task != null) {
        _pollTimers.remove(task.clientId)?.cancel();
        _fallbackPollTimers.remove(task.clientId)?.cancel();
        _cancelRequested.remove(task.clientId);
        _removeOptimisticUpload(task);
        _removeTask(task.clientId);
      }
      return;
    }

    for (final timer in _pollTimers.values) {
      timer.cancel();
    }
    for (final timer in _fallbackPollTimers.values) {
      timer.cancel();
    }
    _pollTimers.clear();
    _fallbackPollTimers.clear();
    _cancelRequested.clear();
    for (final task in state.tasks) {
      _removeOptimisticUpload(task);
    }
    state = const UploadState();
  }

  void _scheduleFallbackPolling(String clientId, String traceId) {
    _fallbackPollTimers.remove(clientId)?.cancel();
    _fallbackPollTimers[clientId] = Timer(const Duration(seconds: 10), () {
      _fallbackPollTimers.remove(clientId);
      final task = _taskByClientId(clientId);
      if (task == null ||
          !task.isUploading ||
          _cancelRequested.contains(clientId)) {
        return;
      }
      _startPolling(clientId, traceId);
    });
  }

  void _startPolling(String clientId, String traceId) {
    _pollTimers.remove(clientId)?.cancel();
    int pollCount = 0;
    const maxPolls = 24;

    _pollTimers[clientId] =
        Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (_cancelRequested.contains(clientId)) {
        timer.cancel();
        _pollTimers.remove(clientId);
        return;
      }

      pollCount++;
      if (pollCount > maxPolls) {
        timer.cancel();
        _pollTimers.remove(clientId);
        markFailed('Upload timed out', clientUploadId: clientId);
        return;
      }

      try {
        final status = await ApiService().getUploadStatus(traceId);
        if (status == null) return;

        final step = status['current_step'] as String? ?? 'init';
        final uploadStatus = status['status'] as String? ?? '';
        final noteId = status['note_id'] as String?;

        if (noteId != null && noteId.isNotEmpty) {
          await _refreshNotesForServerNote(clientId, noteId);
        }

        final task = _taskByClientId(clientId);
        if (task != null && step != task.currentStep) {
          _updateTask(
              clientId, (current) => current.copyWith(currentStep: step));
          try {
            _ref.read(notesProvider.notifier).refreshSilent();
          } catch (_) {}
        }

        if (step == 'completed' || uploadStatus == 'completed') {
          timer.cancel();
          _pollTimers.remove(clientId);
          markCompleted(clientUploadId: clientId);
        } else if (step == 'failed' || uploadStatus == 'failed') {
          timer.cancel();
          _pollTimers.remove(clientId);
          final errorMsg =
              status['error_message'] as String? ?? 'Processing failed';
          markFailed(errorMsg, clientUploadId: clientId);
        }
      } catch (e) {
        debugPrint('Poll error: $e');
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _realtimeSub?.dispose();
    for (final timer in _fallbackPollTimers.values) {
      timer.cancel();
    }
    for (final timer in _pollTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _handleRealtimeEvent(GroupsRealtimeEvent event) {
    if (!event.isUploadDone) return;
    final traceId = event.traceId;
    if (traceId == null) return;
    final task = state.activeTasks
        .where((item) => item.traceId == traceId)
        .cast<UploadTaskState?>()
        .firstWhere((item) => item != null, orElse: () => null);
    if (task == null) return;
    _fallbackPollTimers.remove(task.clientId)?.cancel();
    _pollTimers.remove(task.clientId)?.cancel();

    if (event.status == 'completed') {
      if (event.noteId != null && event.noteId!.isNotEmpty) {
        unawaited(_refreshNotesForServerNote(task.clientId, event.noteId!));
      }
      markCompleted(clientUploadId: task.clientId);
    } else if (event.status == 'failed') {
      markFailed('Processing failed', clientUploadId: task.clientId);
    }
  }

  void _refreshActiveUploadsOnce() {
    for (final task in state.activeTasks) {
      final traceId = task.traceId;
      if (traceId != null && traceId.isNotEmpty) {
        unawaited(_pollStatusOnce(task.clientId, traceId));
      }
    }
  }

  Future<void> _pollStatusOnce(String clientId, String traceId) async {
    try {
      final status = await ApiService().getUploadStatus(traceId);
      if (status == null) return;
      final step = status['current_step'] as String? ?? 'init';
      final uploadStatus = status['status'] as String? ?? '';
      if (step == 'completed' || uploadStatus == 'completed') {
        markCompleted(clientUploadId: clientId);
      } else if (step == 'failed' || uploadStatus == 'failed') {
        markFailed(
          status['error_message'] as String? ?? 'Processing failed',
          clientUploadId: clientId,
        );
      }
    } catch (e) {
      debugPrint('Upload resume status check failed: $e');
    }
  }

  String? _addOptimisticUpload(String itemName) {
    try {
      return _ref.read(notesProvider.notifier).addOptimisticUpload(
            itemName: itemName,
          );
    } catch (_) {
      return null;
    }
  }

  void _removeOptimisticUpload(UploadTaskState task) {
    try {
      _ref
          .read(notesProvider.notifier)
          .removeOptimisticUpload(task.optimisticNoteId);
    } catch (_) {}
  }

  Future<void> _refreshNotesForServerNote(
      String clientId, String noteId) async {
    try {
      await _ref.read(notesProvider.notifier).refreshSilent();
      final notes = _ref.read(notesProvider).notes;
      final task = _taskByClientId(clientId);
      if (task != null && notes.any((note) => note.id == noteId)) {
        _removeOptimisticUpload(task);
      }
    } catch (_) {}
  }

  UploadTaskState? _resolveTask(String? clientId) {
    if (clientId != null) return _taskByClientId(clientId);
    return state.primaryTask;
  }

  UploadTaskState? _taskByClientId(String clientId) {
    for (final task in state.tasks) {
      if (task.clientId == clientId) return task;
    }
    return null;
  }

  String? _firstPendingClientId() {
    for (final task in state.tasks.reversed) {
      if (task.traceId == null && task.isUploading) return task.clientId;
    }
    return state.activeTasks.isNotEmpty
        ? state.activeTasks.first.clientId
        : null;
  }

  void _updateTask(
    String clientId,
    UploadTaskState Function(UploadTaskState task) update,
  ) {
    var changed = false;
    final next = state.tasks.map((task) {
      if (task.clientId != clientId) return task;
      changed = true;
      return update(task);
    }).toList(growable: false);
    if (changed) state = state.copyWith(tasks: next);
  }

  void _removeTask(String clientId) {
    final next = state.tasks
        .where((task) => task.clientId != clientId)
        .toList(growable: false);
    if (next.length != state.tasks.length) {
      state = state.copyWith(tasks: next);
    }
    _cancelRequested.remove(clientId);
    _pausedClientIds.remove(clientId);
  }

  void _scheduleTaskRemoval(String clientId, Duration delay) {
    Future.delayed(delay, () {
      final task = _taskByClientId(clientId);
      if (task != null && task.isTerminal) {
        _removeTask(clientId);
      }
    });
  }
}
