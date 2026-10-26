import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zegoweb/zegoweb.dart';

import 'package:zegoweb_ui/src/models/zego_audio_settings.dart';
import 'package:zegoweb_ui/src/zego_call_config.dart';
import 'package:zegoweb_ui/src/zego_call_state.dart';
import 'package:zegoweb_ui/src/zego_layout_mode.dart';
import 'package:zegoweb_ui/src/zego_participant.dart';

/// Manages the entire call lifecycle, participant state, and media controls.
///
/// Owns a [ZegoEngine] instance — creates it on [join], destroys it on
/// [leave]. Widgets rebuild via [ListenableBuilder] or [AnimatedBuilder].
class ZegoCallController extends ChangeNotifier {
  ZegoCallController({
    required this.engineConfig,
    required this.callConfig,
    @visibleForTesting
    Future<ZegoEngine> Function(ZegoEngineConfig config)? engineFactory,
  }) : _currentLayout = callConfig.layout,
       _hideNoVideoTiles = callConfig.hideNoVideoTiles,
       _engineFactory = engineFactory;

  /// Test hook that replaces [ZegoWeb.loadScript] + [ZegoWeb.createEngine].
  final Future<ZegoEngine> Function(ZegoEngineConfig config)? _engineFactory;

  /// Engine configuration used to create the [ZegoEngine] on [join].
  final ZegoEngineConfig engineConfig;

  /// Call configuration (room, user, UI flags).
  final ZegoCallConfig callConfig;

  // ---------------------------------------------------------------------------
  // Reactive state
  // ---------------------------------------------------------------------------

  ZegoCallState _state = ZegoCallState.idle;

  /// Current call state.
  ZegoCallState get state => _state;

  final List<ZegoParticipant> _participants = [];

  /// Unmodifiable snapshot of the current participant list.
  List<ZegoParticipant> get participants => List.unmodifiable(_participants);

  /// Participants after applying the hide-no-video filter.
  /// All layout widgets should consume this instead of raw [participants].
  List<ZegoParticipant> get filteredParticipants {
    if (!_hideNoVideoTiles) return participants;
    return List.unmodifiable(
      _participants.where(
        (p) => p.isLocal || p.stream != null || !p.isCameraOff,
      ),
    );
  }

  ZegoLocalStream? _localStream;

  /// The local media stream, available after [join] completes.
  ZegoLocalStream? get localStream => _localStream;

  ZegoLayoutMode _currentLayout;

  /// The currently active layout mode.
  ZegoLayoutMode get currentLayout => _currentLayout;

  bool _isMicOn = true;

  /// Whether the local microphone is enabled.
  bool get isMicOn => _isMicOn;

  bool _isCameraOn = true;

  /// Whether the local camera is enabled.
  bool get isCameraOn => _isCameraOn;

  bool _isScreenSharing = false;

  /// Whether screen sharing is currently active.
  bool get isScreenSharing => _isScreenSharing;

  ZegoError? _lastError;

  /// The most recent error, if any.
  ZegoError? get lastError => _lastError;

  int _activeSpeakerIndex = -1;

  /// Index of the active speaker within [participants].
  int get activeSpeakerIndex => _activeSpeakerIndex;

  ZegoAudioSettings _audioSettings = const ZegoAudioSettings();

  /// Current audio processing settings (AEC / ANS / AGC).
  ZegoAudioSettings get audioSettings => _audioSettings;

  bool _updatingAudioSettings = false;

  // --- Layout picker state ---

  int? _gridColumns;

  /// Grid column override from the tile size slider. Null = auto-calculated.
  int? get gridColumns => _gridColumns;

  bool _hideNoVideoTiles = false;

  /// Whether to hide participants with camera off and no stream.
  bool get hideNoVideoTiles => _hideNoVideoTiles;

  String? _pinnedUserId;

  /// User ID of the pinned participant. Null = no pin.
  String? get pinnedUserId => _pinnedUserId;

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  // Active speaker debounce — prevents rapid switching when sound levels
  // fluctuate briefly. A new candidate must hold the loudest position for
  // 500 ms before becoming the active speaker.
  Timer? _activeSpeakerDebounceTimer;
  String? _activeSpeakerCandidate;

  double _debugThreshold = 10.0; // 0–100 ZEGO scale
  Duration _debugDebounce = const Duration(milliseconds: 500);

  /// The sound-level threshold (0–100 ZEGO scale) a stream must exceed before
  /// it's considered a speaker candidate. Adjust at runtime via the debug panel.
  double get debugThreshold => _debugThreshold;
  set debugThreshold(double v) {
    _debugThreshold = v.clamp(0.0, 100.0);
    notifyListeners();
  }

  /// The debounce window a candidate must hold before becoming the active
  /// speaker. Adjust at runtime via the debug panel.
  Duration get debugDebounce => _debugDebounce;
  set debugDebounce(Duration v) {
    _debugDebounce = v;
    notifyListeners();
  }

  bool _disposed = false;

  ZegoEngine? _engine;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, ZegoRemoteStream> _remoteStreams = {};

  final StreamController<String> _debugLogController =
      StreamController<String>.broadcast();

  /// Broadcast stream of debug log lines for the audio debug overlay.
  /// Only emits when [callConfig.showAudioDebugOverlay] is true.
  Stream<String> get debugLog => _debugLogController.stream;

  void _audioDebugEmit(String line) {
    if (!callConfig.showAudioDebugOverlay) return;
    if (!_debugLogController.isClosed) _debugLogController.add(line);
  }

  final StreamController<double> _debugMicLevelController =
      StreamController<double>.broadcast();
  StreamSubscription<double>? _debugMicLevelSub;

  /// Raw local mic level stream (0.0–1.0) from Web Audio API, 100 ms interval.
  /// Emits once the engine is initialized (after [startPreview] or [join]).
  Stream<double> get debugMicLevel => _debugMicLevelController.stream;

  List<ZegoDeviceInfo> _cameras = [];
  List<ZegoDeviceInfo> get cameras => _cameras;

  List<ZegoDeviceInfo> _microphones = [];
  List<ZegoDeviceInfo> get microphones => _microphones;

  String _selectedCameraId = '';

  /// The device ID of the currently selected camera.
  String get selectedCameraId => _selectedCameraId;

  String _selectedMicrophoneId = '';

  /// The device ID of the currently selected microphone.
  String get selectedMicrophoneId => _selectedMicrophoneId;

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Initialize the engine and create a local stream for pre-join preview.
  /// Does NOT join the room — call [join] for that.
  Future<void> startPreview() async {
    if (_engine != null) return; // already initialized
    _setState(ZegoCallState.preJoin);
    ZegoLog.info('CallController.startPreview');

    try {
      _engine = await _createEngine();
      _debugMicLevelSub?.cancel();
      _debugMicLevelSub = _engine!.debugLocalMicLevel.listen((level) {
        if (!_debugMicLevelController.isClosed) _debugMicLevelController.add(level);
      });
      _localStream = await _engine!.createLocalStream(
        config: ZegoStreamConfig(
          echoCancellation: _audioSettings.echoCancellation,
          noiseSuppression: _audioSettings.noiseSuppression,
          autoGainControl: _audioSettings.autoGainControl,
        ),
      );
      _cameras = await _engine!.getCameras();
      _microphones = await _engine!.getMicrophones();
      if (_cameras.isNotEmpty) _selectedCameraId = _cameras.first.deviceId;
      if (_microphones.isNotEmpty) {
        _selectedMicrophoneId = _microphones.first.deviceId;
      }
      ZegoLog.info(
        'CallController.startPreview complete — '
        'cameras=${_cameras.length} mics=${_microphones.length}',
      );
      notifyListeners();
    } catch (e) {
      ZegoLog.error('CallController.startPreview failed: $e');
      _lastError = e is ZegoError ? e : ZegoError(-1, e.toString());
      notifyListeners();
    }
  }

  /// Join the call: create engine (if needed), login room, publish local stream.
  Future<void> join() async {
    if (_state != ZegoCallState.idle && _state != ZegoCallState.preJoin) return;
    _setState(ZegoCallState.joining);
    ZegoLog.info(
      'CallController.join room=${callConfig.roomId} '
      'user=${callConfig.userId}',
    );

    try {
      if (_engine == null) {
        _engine = await _createEngine();
        _debugMicLevelSub?.cancel();
        _debugMicLevelSub = _engine!.debugLocalMicLevel.listen((level) {
          if (!_debugMicLevelController.isClosed) _debugMicLevelController.add(level);
        });
      }

      _subscriptions.addAll([
        _engine!.onRoomStreamUpdate.listen(_onRoomStreamUpdate),
        _engine!.onRoomUserUpdate.listen(_onRoomUserUpdate),
        _engine!.onError.listen(_onError),
      ]);

      _subscriptions.add(
        _engine!.onSoundLevelUpdate.listen(_onSoundLevelUpdate),
      );
      _subscriptions.add(
        _engine!.onRemoteCameraStatusUpdate.listen(_onRemoteCameraStatusUpdate),
      );
      _subscriptions.add(
        _engine!.onRemoteMicStatusUpdate.listen(_onRemoteMicStatusUpdate),
      );

      await _engine!.loginRoom(
        callConfig.roomId,
        ZegoUser(
          userId: callConfig.userId,
          userName: callConfig.userName ?? callConfig.userId,
        ),
      );

      _localStream ??= await _engine!.createLocalStream(
        config: ZegoStreamConfig(
          echoCancellation: _audioSettings.echoCancellation,
          noiseSuppression: _audioSettings.noiseSuppression,
          autoGainControl: _audioSettings.autoGainControl,
        ),
      );
      final streamId = (callConfig.streamIdBuilder ??
          ZegoCallConfig.defaultStreamIdBuilder)(
        callConfig.roomId,
        callConfig.userId,
      );
      await _engine!.startPublishing(streamId, _localStream!);
      ZegoLog.info('CallController.join published streamId=$streamId');

      // Add local participant with current mic/camera state from pre-join.
      _participants.insert(
        0,
        ZegoParticipant(
          userId: callConfig.userId,
          userName: callConfig.userName,
          streamId: streamId,
          stream: _isCameraOn ? _localStream : null,
          isMuted: !_isMicOn,
          isCameraOff: !_isCameraOn,
          isLocal: true,
        ),
      );

      ZegoLog.info('CallController.join complete — in call');
      _setState(ZegoCallState.inCall);
    } on ZegoError catch (e) {
      ZegoLog.error('CallController.join failed: $e');
      _lastError = e;
      await _rollBackFailedJoin();
      _setState(ZegoCallState.idle);
      notifyListeners();
      rethrow;
    } catch (e) {
      ZegoLog.error('CallController.join failed: $e');
      _lastError = ZegoError(-1, e.toString());
      await _rollBackFailedJoin();
      _setState(ZegoCallState.idle);
      notifyListeners();
      rethrow;
    }
  }

  Future<ZegoEngine> _createEngine() async {
    if (_engineFactory != null) return _engineFactory(engineConfig);
    await ZegoWeb.loadScript();
    return ZegoWeb.createEngine(engineConfig);
  }

  /// Undo the parts of a failed [join] that would block the next attempt.
  ///
  /// [join] logs in to the room before creating and publishing the local
  /// stream. If a later step fails (e.g. camera blocked), the engine is still
  /// logged in, and the next [join] is rejected by the SDK with 1002001
  /// ("login rooms exceeds the upper limit"). The engine and any preview
  /// stream are kept so the pre-join view keeps working; [leave] or
  /// [dispose] tear them down.
  Future<void> _rollBackFailedJoin() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _participants.clear();
    _remoteStreams.clear();

    try {
      // No-op when loginRoom itself failed.
      await _engine?.logoutRoom();
    } catch (e) {
      ZegoLog.warn('CallController.join rollback logout error: $e');
    }
  }

  /// Leave the call and tear down the engine.
  Future<void> leave() async {
    if (_state == ZegoCallState.leaving) return;
    // Idle with a live engine happens after a failed join — still tear down.
    if (_state == ZegoCallState.idle && _engine == null) return;
    _setState(ZegoCallState.leaving);
    ZegoLog.info('CallController.leave room=${callConfig.roomId}');

    try {
      for (final sub in _subscriptions) {
        await sub.cancel();
      }
      _subscriptions.clear();

      // Release camera/mic hardware before destroying the engine.
      if (_localStream != null) {
        try {
          _engine?.destroyLocalStream(_localStream!);
        } catch (_) {}
      }

      await _engine?.destroy();
      _engine = null;
    } catch (e) {
      ZegoLog.warn('CallController.leave teardown error: $e');
    }

    _debugMicLevelSub?.cancel();
    _debugMicLevelSub = null;
    _activeSpeakerDebounceTimer?.cancel();
    _activeSpeakerDebounceTimer = null;
    _activeSpeakerCandidate = null;

    _localStream = null;
    _participants.clear();
    _remoteStreams.clear();
    _activeSpeakerIndex = -1;
    _gridColumns = null;
    _pinnedUserId = null;
    _setState(ZegoCallState.idle);
  }

  /// Toggle the microphone.
  void toggleMic() {
    if (_engine == null || _localStream == null) return;
    _isMicOn = !_isMicOn;
    _engine!.muteMicrophone(!_isMicOn);
    _updateLocalParticipant();
    notifyListeners();
  }

  /// Toggle the camera.
  void toggleCamera() {
    if (_engine == null || _localStream == null) return;
    _isCameraOn = !_isCameraOn;
    _engine!.enableCamera(_isCameraOn);
    _updateLocalParticipant();
    notifyListeners();
  }

  /// Switch to a specific layout mode.
  void switchLayout(ZegoLayoutMode mode) {
    if (_currentLayout == mode) return;
    _currentLayout = mode;
    notifyListeners();
  }

  /// Resolves the effective layout when [currentLayout] is [ZegoLayoutMode.auto].
  /// Returns the current layout unchanged for non-auto modes.
  ZegoLayoutMode get resolvedLayout {
    if (_currentLayout != ZegoLayoutMode.auto) return _currentLayout;
    final count = filteredParticipants.length;
    if (_isScreenSharing) return ZegoLayoutMode.sidebar;
    if (count <= 1) return ZegoLayoutMode.spotlight;
    if (count == 2) return ZegoLayoutMode.pip;
    if (count <= 6) return ZegoLayoutMode.grid;
    return ZegoLayoutMode.sidebar;
  }

  /// Set grid columns for the tile size slider.
  void setGridColumns(int? columns) {
    _gridColumns = columns?.clamp(2, 6);
    notifyListeners();
  }

  /// Toggle hiding of tiles without video.
  void setHideNoVideoTiles(bool hide) {
    _hideNoVideoTiles = hide;
    notifyListeners();
  }

  /// Pin a participant by user ID. Pass null to unpin.
  void pinParticipant(String? userId) {
    _pinnedUserId = userId;
    notifyListeners();
  }

  /// Switch camera device.
  Future<void> switchCamera(String deviceId) async {
    await _engine?.useCamera(deviceId);
    _selectedCameraId = deviceId;
    notifyListeners();
  }

  /// Switch microphone device.
  Future<void> switchMicrophone(String deviceId) async {
    await _engine?.useMicrophone(deviceId);
    _selectedMicrophoneId = deviceId;
    notifyListeners();
  }

  /// Start screen sharing (placeholder — requires createStream with screen
  /// config).
  Future<void> startScreenShare() async {
    _isScreenSharing = true;
    notifyListeners();
  }

  /// Stop screen sharing.
  Future<void> stopScreenShare() async {
    _isScreenSharing = false;
    notifyListeners();
  }

  /// Update AEC / ANS / AGC settings. Applies constraints directly to the
  /// existing audio track — no stream recreation, no camera interruption.
  Future<void> updateAudioSettings(ZegoAudioSettings settings) async {
    if (_audioSettings == settings) return;
    if (_updatingAudioSettings) return;
    _updatingAudioSettings = true;
    try {
      _audioSettings = settings;
      notifyListeners();

      if (_state != ZegoCallState.inCall || _engine == null || _localStream == null) return;

      try {
        await _engine!.applyAudioConstraints(
          _localStream!,
          echoCancellation: settings.echoCancellation,
          noiseSuppression: settings.noiseSuppression,
          autoGainControl: settings.autoGainControl,
        );
      } catch (e) {
        _lastError = e is ZegoError ? e : ZegoError(-1, e.toString());
        notifyListeners();
      }
    } finally {
      _updatingAudioSettings = false;
    }
  }

  /// Get available cameras.
  Future<List<ZegoDeviceInfo>> getCameras() async {
    return await _engine?.getCameras() ?? [];
  }

  /// Get available microphones.
  Future<List<ZegoDeviceInfo>> getMicrophones() async {
    return await _engine?.getMicrophones() ?? [];
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  Future<void> _onRoomStreamUpdate(ZegoRoomStreamUpdate update) async {
    if (update.type == ZegoUpdateType.add) {
      for (final streamInfo in update.streams) {
        ZegoLog.info(
          'CallController remote stream ADD '
          'stream=${streamInfo.streamId} user=${streamInfo.user.userId}',
        );
        try {
          final remote = await _engine!.startPlaying(streamInfo.streamId);
          _remoteStreams[streamInfo.streamId] = remote;

          // If the participant already exists (added from roomUserUpdate),
          // update it with the stream. Otherwise add a new one.
          final existingIdx = _participants.indexWhere(
            (p) => p.userId == streamInfo.user.userId && !p.isLocal,
          );
          if (existingIdx >= 0) {
            _participants[existingIdx] = ZegoParticipant(
              userId: streamInfo.user.userId,
              userName: streamInfo.user.userName,
              streamId: streamInfo.streamId,
              stream: remote,
            );
          } else {
            _participants.add(ZegoParticipant(
              userId: streamInfo.user.userId,
              userName: streamInfo.user.userName,
              streamId: streamInfo.streamId,
              stream: remote,
            ));
          }
          ZegoLog.info(
            'CallController playing remote stream=${streamInfo.streamId} '
            'participants=${_participants.length}',
          );
        } catch (e) {
          ZegoLog.error(
            'CallController startPlaying failed '
            'stream=${streamInfo.streamId} user=${streamInfo.user.userId}: $e',
          );
        }
      }
    } else {
      for (final streamInfo in update.streams) {
        ZegoLog.info(
          'CallController remote stream REMOVE '
          'stream=${streamInfo.streamId} user=${streamInfo.user.userId}',
        );

        try {
          await _engine!.stopPlaying(streamInfo.streamId);
        } catch (_) {}
        _remoteStreams.remove(streamInfo.streamId);

        // Clear stream from participant but keep them in the list — they
        // are still in the room, just not publishing.
        final idx = _participants.indexWhere(
          (p) => p.userId == streamInfo.user.userId && !p.isLocal,
        );
        if (idx >= 0) {
          _participants[idx] = ZegoParticipant(
            userId: _participants[idx].userId,
            userName: _participants[idx].userName,
            isCameraOff: true,
            isMuted: true,
          );
          // Adjust active speaker index.
          if (_activeSpeakerIndex == idx) {
            _activeSpeakerIndex = -1;
          }
        }
      }
    }
    notifyListeners();
  }

  void _onRoomUserUpdate(ZegoRoomUserUpdate update) {
    ZegoLog.info(
      'CallController roomUserUpdate type=${update.type.name} '
      'users=${update.users.map((u) => u.userId).join(", ")}',
    );
    if (update.type == ZegoUpdateType.add) {
      for (final user in update.users) {
        // Skip if this user already has a participant (from a stream update
        // that arrived first, or if it's the local user).
        final exists = _participants.any((p) => p.userId == user.userId);
        if (!exists) {
          _participants.add(ZegoParticipant(
            userId: user.userId,
            userName: user.userName,
            isCameraOff: true,
            isMuted: true,
          ));
          ZegoLog.info(
            'CallController added stream-less participant '
            'user=${user.userId}',
          );
        }
      }
    } else {
      for (final user in update.users) {
        final removedIdx = _participants.indexWhere(
          (p) => p.userId == user.userId && !p.isLocal,
        );
        if (removedIdx >= 0) {
          // Stop playing any stream for this user.
          final streamId = _participants[removedIdx].streamId;
          if (streamId != null) {
            try {
              _engine?.stopPlaying(streamId);
            } catch (_) {}
            _remoteStreams.remove(streamId);
          }
          _participants.removeAt(removedIdx);
          if (_activeSpeakerIndex == removedIdx) {
            _activeSpeakerIndex = -1;
          } else if (_activeSpeakerIndex > removedIdx) {
            _activeSpeakerIndex--;
          }
          ZegoLog.info(
            'CallController removed participant user=${user.userId}',
          );
        }
      }
    }
    notifyListeners();
  }

  void _onError(ZegoError error) {
    ZegoLog.error('CallController error: $error');
    _lastError = error;
    notifyListeners();
  }

  void _onRemoteCameraStatusUpdate(ZegoRemoteDeviceUpdate update) {
    ZegoLog.verbose(
      'CallController remoteCameraStatus '
      'stream=${update.streamId} active=${update.isActive}',
    );
    final idx = _participantIndexForStream(update.streamId);
    if (idx >= 0) {
      _participants[idx] = _participants[idx].copyWith(
        isCameraOff: !update.isActive,
      );
      notifyListeners();
    }
  }

  void _onRemoteMicStatusUpdate(ZegoRemoteDeviceUpdate update) {
    ZegoLog.verbose(
      'CallController remoteMicStatus '
      'stream=${update.streamId} active=${update.isActive}',
    );
    final idx = _participantIndexForStream(update.streamId);
    if (idx >= 0) {
      _participants[idx] = _participants[idx].copyWith(
        isMuted: !update.isActive,
      );
      notifyListeners();
    }
  }

  void _onSoundLevelUpdate(ZegoSoundLevelUpdate update) {
    // Find the loudest stream above threshold.
    ZegoSoundLevelInfo? loudest;
    for (final info in update.levels) {
      if (info.soundLevel >= _debugThreshold) {
        if (loudest == null || info.soundLevel > loudest.soundLevel) {
          loudest = info;
        }
      }
    }

    final candidateId = loudest?.streamId;

    if (candidateId == null) {
      _audioDebugEmit(
        '${update.levels.map((l) => '${l.streamId.split("-").last}:${l.soundLevel.toStringAsFixed(1)}').join(" | ")} → silence',
      );
      // Silence — clear immediately, no debounce.
      _activeSpeakerDebounceTimer?.cancel();
      _activeSpeakerDebounceTimer = null;
      _activeSpeakerCandidate = null;
      _applyActiveSpeaker(null);
      return;
    }

    _audioDebugEmit(
      'loudest: ${candidateId.split("-").last} @ ${loudest!.soundLevel.toStringAsFixed(1)} (thr $_debugThreshold)',
    );

    if (candidateId == _activeSpeakerCandidate) return; // already debouncing

    // Same as current active speaker — cancel pending switch.
    final candidateIndex = _participantIndexForStream(candidateId);
    if (candidateIndex == _activeSpeakerIndex && _activeSpeakerIndex >= 0) {
      _activeSpeakerDebounceTimer?.cancel();
      _activeSpeakerDebounceTimer = null;
      _activeSpeakerCandidate = null;
      return;
    }

    // New candidate — start debounce.
    _activeSpeakerDebounceTimer?.cancel();
    _activeSpeakerCandidate = candidateId;
    _audioDebugEmit('⏱ debounce → ${candidateId.split("-").last}');
    _activeSpeakerDebounceTimer = Timer(_debugDebounce, () {
      if (_activeSpeakerCandidate != null) {
        final sid = _activeSpeakerCandidate!;
        _activeSpeakerCandidate = null;
        _applyActiveSpeaker(sid);
      }
    });
  }

  void _applyActiveSpeaker(String? streamId) {
    final newIndex = streamId == null ? -1 : _participantIndexForStream(streamId);
    if (newIndex == _activeSpeakerIndex) return;
    _activeSpeakerIndex = newIndex;
    if (streamId == null) {
      _audioDebugEmit('★ cleared (silence)');
    } else {
      _audioDebugEmit('★ active speaker → idx $newIndex (${streamId.split("-").last})');
    }
    notifyListeners();
  }

  int _participantIndexForStream(String streamId) {
    for (var i = 0; i < _participants.length; i++) {
      if (_participants[i].streamId == streamId) return i;
    }
    return -1;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _setState(ZegoCallState newState) {
    if (_state == newState) return;
    _state = newState;
    notifyListeners();
  }

  void _updateLocalParticipant() {
    final idx = _participants.indexWhere((p) => p.isLocal);
    if (idx >= 0) {
      _participants[idx] = ZegoParticipant(
        userId: _participants[idx].userId,
        userName: _participants[idx].userName,
        streamId: _participants[idx].streamId,
        stream: _isCameraOn ? _localStream : null,
        isMuted: !_isMicOn,
        isCameraOff: !_isCameraOn,
        isLocal: true,
      );
    }
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debugLogController.close(); // broadcast; safe even with no subscribers
    _debugMicLevelController.close();
    if (_state != ZegoCallState.idle || _engine != null) leave();
    super.dispose();
  }
}
