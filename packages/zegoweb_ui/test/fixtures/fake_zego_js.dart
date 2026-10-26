// Copied from packages/zegoweb/test/fixtures/fake_zego_js.dart — the web
// test compiler cannot import files from outside this package.
// packages/zegoweb/test/fixtures/fake_zego_js.dart
//
// Hand-written Dart class mimicking the shape of `window.ZegoExpressEngine`,
// exported to JS via `dart:js_interop`. Used by every test that exercises the
// interop layer, event bridge, or engine wrapper without loading the real SDK.
//
// The fixture exposes TWO levels of API:
//
//   - Low-level primitives for interop-layer tests (Tasks 16–20):
//       * `asJs()` returns a `JSObject` whose properties are `.toJS`-wrapped
//         Dart closures that either return queued promise results or invoke
//         registered listeners.
//       * `driveEvent(name, payload)` fires raw JS payloads at registered
//         listeners.
//       * `enqueueResolved(method, value)` / `enqueueRejectedWith*` push
//         promise outcomes onto a per-method queue.
//       * `installAsWindowGlobal()` / `uninstall()` for SdkLoader tests.
//
//   - High-level typed convenience for engine tests (Tasks 24–30).
//
// Not part of the shipped package; lives under test/fixtures/.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Record of a `loginRoom` invocation.
class FakeLoginCall {
  FakeLoginCall({
    required this.roomId,
    required this.token,
    required this.userId,
    required this.userName,
  });
  final String roomId;
  final String token;
  final String userId;
  final String userName;
}

/// Record of a `startPublishingStream` invocation.
class FakePublishCall {
  FakePublishCall({required this.streamId});
  final String streamId;
}

/// Record of a `renewToken(token, [roomID])` invocation.
class FakeRenewCall {
  FakeRenewCall({required this.token, required this.roomId});
  final String token;
  final String roomId;
}

class FakeZegoJs {
  FakeZegoJs();

  // ---------------------------------------------------------------------------
  // Low-level state
  // ---------------------------------------------------------------------------

  final Map<String, List<JSFunction>> _listeners = <String, List<JSFunction>>{};
  final Map<String, List<_PendingResult>> _queued =
      <String, List<_PendingResult>>{};
  final Map<String, int> callCounts = <String, int>{};
  final Map<String, List<List<Object?>>> callArgs =
      <String, List<List<Object?>>>{};

  bool _installed = false;
  JSAny? _previousCtor;

  int? lastAppId;
  String? lastServer;

  // ---------------------------------------------------------------------------
  // High-level typed state
  // ---------------------------------------------------------------------------

  final List<FakeLoginCall> loginCalls = <FakeLoginCall>[];
  final List<String> logoutCalls = <String>[];
  final List<FakePublishCall> publishCalls = <FakePublishCall>[];
  final List<String> stopPublishCalls = <String>[];
  final List<String> stopPlayCalls = <String>[];
  final List<FakeRenewCall> renewTokenCalls = <FakeRenewCall>[];

  /// Controls the streamID returned by the next `createStream` call.
  String nextCreatedStreamId = 'fake-local';

  /// Device fakes. Each tuple is `(deviceId, deviceName)`.
  List<(String, String)> cameras = const [];
  List<(String, String)> microphones = const [];

  /// Most-recent device/mute arguments captured from the engine under test.
  String? usedCamera;
  String? usedMic;
  bool? lastMuteMic;
  bool? lastEnableCam;

  // ---------------------------------------------------------------------------
  // Low-level driving API
  // ---------------------------------------------------------------------------

  /// Fire an event with a single JS payload (legacy 1-arg form — still used
  /// by the smoke test and by emit helpers that wrap object-shaped events
  /// like publisherStateUpdate / playerStateUpdate).
  void driveEvent(String name, JSAny? payload) {
    final list = _listeners[name];
    if (list == null) return;
    for (final cb in List<JSFunction>.of(list)) {
      cb.callAsFunction(null, payload);
    }
  }

  /// Fire an event with up to 4 positional arguments matching the real
  /// SDK's multi-arg callback shape
  /// (e.g. roomStateUpdate(roomID, state, errorCode, extendedData)).
  void driveEventArgs(String name, List<JSAny?> args) {
    final list = _listeners[name];
    if (list == null) return;
    final a0 = args.isNotEmpty ? args[0] : null;
    final a1 = args.length > 1 ? args[1] : null;
    final a2 = args.length > 2 ? args[2] : null;
    final a3 = args.length > 3 ? args[3] : null;
    for (final cb in List<JSFunction>.of(list)) {
      cb.callAsFunction(null, a0, a1, a2, a3);
    }
  }

  void enqueueResolved(String method, JSAny? value) {
    _queued
        .putIfAbsent(method, () => <_PendingResult>[])
        .add(_PendingResult.resolved(value));
  }

  void enqueueRejectedWithCode(String method, int code, String message) {
    _queued.putIfAbsent(method, () => <_PendingResult>[]).add(
          _PendingResult.rejected(
            <String, Object?>{'code': code, 'message': message}.jsify(),
          ),
        );
  }

  void enqueueRejectedWith(String method, JSAny? error) {
    _queued
        .putIfAbsent(method, () => <_PendingResult>[])
        .add(_PendingResult.rejected(error));
  }

  int listenerCount(String eventName) => _listeners[eventName]?.length ?? 0;

  // ---------------------------------------------------------------------------
  // High-level failure injection
  // ---------------------------------------------------------------------------

  void rejectNextLogin({required int code, required String message}) {
    enqueueRejectedWithCode('loginRoom', code, message);
  }

  /// Queue a rejection for the next `createStream` call shaped like a
  /// browser `DOMException` with a `.name` string (e.g. `NotAllowedError`).
  void rejectNextCreateStream({
    required String jsName,
    required String message,
  }) {
    final err = <String, Object?>{'name': jsName, 'message': message}.jsify();
    enqueueRejectedWith('createStream', err);
  }

  // ---------------------------------------------------------------------------
  // High-level event emitters
  // ---------------------------------------------------------------------------

  /// Fires `roomStateUpdate(roomID, state, errorCode, extendedData)` — the
  /// real SDK uses 4 positional args, NOT a single object.
  /// `errorCode` and `extendedData` are forwarded as null when omitted so
  /// tests can assert distinct "absent" vs "0/empty" cases.
  void emitRoomStateUpdate(
    String roomId,
    String state, {
    int? errorCode,
    String? extendedData,
  }) {
    driveEventArgs('roomStateUpdate', <JSAny?>[
      roomId.toJS,
      state.toJS,
      errorCode?.toJS,
      extendedData?.toJS,
    ]);
  }

  /// Fires `publisherStateUpdate(result)` — single object arg.
  void emitPublisherStateUpdate(
    String streamId,
    String state,
    int errorCode,
    String message,
  ) {
    driveEvent(
      'publisherStateUpdate',
      <String, Object?>{
        'streamID': streamId,
        'state': state,
        'errorCode': errorCode,
        'extendedData': message,
      }.jsify(),
    );
  }

  /// Fires `playerStateUpdate(result)` — single object arg.
  void emitPlayerStateUpdate(
    String streamId,
    String state,
    int errorCode,
    String message,
  ) {
    driveEvent(
      'playerStateUpdate',
      <String, Object?>{
        'streamID': streamId,
        'state': state,
        'errorCode': errorCode,
        'extendedData': message,
      }.jsify(),
    );
  }

  /// Fires `roomStreamUpdate(roomID, updateType, streamList, extendedData)` —
  /// 4 positional args. Each stream tuple is `(streamId, userId, userName)`.
  void emitRoomStreamUpdate(
    String roomId,
    Object updateType, // ZegoUpdateType.add / delete — kept loose
    List<(String, String, String)> streams,
  ) {
    final streamsJs = streams
        .map(
          (t) => <String, Object?>{
            'streamID': t.$1,
            'user': <String, Object?>{'userID': t.$2, 'userName': t.$3},
          },
        )
        .toList();
    driveEventArgs('roomStreamUpdate', <JSAny?>[
      roomId.toJS,
      updateType.toString().split('.').last.toJS,
      streamsJs.jsify(),
      ''.toJS,
    ]);
  }

  /// Fires `tokenWillExpire(roomID)` — single string arg in the 3.12 SDK.
  /// `remainingSeconds` is retained for test convenience but the real SDK
  /// does not pass it.
  void emitTokenWillExpire(String roomId, int remainingSeconds) {
    driveEventArgs('tokenWillExpire', <JSAny?>[roomId.toJS]);
  }

  // ---------------------------------------------------------------------------
  // Install / uninstall (for SdkLoader tests)
  // ---------------------------------------------------------------------------

  void installAsWindowGlobal() {
    if (_installed) return;
    _previousCtor = _getWindowProperty('ZegoExpressEngine');
    final self = this;
    final ctor = (int appID, String server) {
      self.lastAppId = appID;
      self.lastServer = server;
      return self.asJs();
    }.toJS;
    _setWindowProperty('ZegoExpressEngine', ctor);
    _installed = true;
  }

  void uninstall() {
    if (!_installed) return;
    _setWindowProperty('ZegoExpressEngine', _previousCtor);
    _previousCtor = null;
    _installed = false;
  }

  // ---------------------------------------------------------------------------
  // JS-facing surface
  // ---------------------------------------------------------------------------

  JSObject asJs() {
    final obj = JSObject();

    // Event listener management
    obj['on'] = ((JSString name, JSFunction cb) => _on(name.toDart, cb)).toJS;
    obj['off'] = ((JSString name, JSFunction cb) => _off(name.toDart, cb)).toJS;

    // Synchronous methods — these must return a Dart value directly
    // (bool / null), NOT a JSPromise wrapper, to match the real 3.12 SDK.

    obj['setLogConfig'] = ((JSObject cfg) {
      _record('setLogConfig', <Object?>[cfg]);
    }).toJS;

    // loginRoom(roomId, token, user, [config]) — ASYNC, returns Promise<boolean>.
    obj['loginRoom'] = ((
      JSString roomId,
      JSString token,
      JSObject user, [
      JSAny? config,
    ]) {
      final userId = (user['userID'] as JSString?)?.toDart ?? '';
      final userName = (user['userName'] as JSString?)?.toDart ?? '';
      loginCalls.add(
        FakeLoginCall(
          roomId: roomId.toDart,
          token: token.toDart,
          userId: userId,
          userName: userName,
        ),
      );
      return _runMethod(
        'loginRoom',
        <JSAny?>[roomId, token, user, config],
      );
    }).toJS;

    // logoutRoom([roomId]) — SYNC void.
    obj['logoutRoom'] = (([JSString? roomId]) {
      if (roomId != null) logoutCalls.add(roomId.toDart);
      _record('logoutRoom', <JSAny?>[roomId]);
    }).toJS;

    // createStream([config]) — ASYNC, returns Promise<MediaStream>.
    obj['createStream'] = (([JSAny? config]) {
      _record('createStream', <Object?>[config]);
      final queue = _queued['createStream'];
      final pending =
          (queue != null && queue.isNotEmpty) ? queue.removeAt(0) : null;
      return JSPromise<JSAny?>(((JSFunction resolve, JSFunction reject) {
        if (pending != null && !pending.isResolved) {
          reject.callAsFunction(null, pending.value);
          return;
        }
        final streamObj = JSObject();
        streamObj['streamID'] = nextCreatedStreamId.toJS;
        resolve.callAsFunction(null, streamObj);
      }).toJS);
    }).toJS;

    // startPublishingStream(streamId, mediaStream, [config]) — SYNC, returns bool.
    obj['startPublishingStream'] = ((
      JSString streamId,
      JSObject mediaStream, [
      JSAny? config,
    ]) {
      publishCalls.add(FakePublishCall(streamId: streamId.toDart));
      _record(
        'startPublishingStream',
        <JSAny?>[streamId, mediaStream, config],
      );
      return true.toJS;
    }).toJS;

    // stopPublishingStream(streamId) — SYNC, returns bool.
    obj['stopPublishingStream'] = ((JSString streamId) {
      stopPublishCalls.add(streamId.toDart);
      _record('stopPublishingStream', <JSAny?>[streamId]);
      return true.toJS;
    }).toJS;

    // startPlayingStream(streamId, [config]) — ASYNC, returns Promise<MediaStream>.
    obj['startPlayingStream'] = ((JSString streamId, [JSAny? config]) {
      _record('startPlayingStream', <Object?>[streamId, config]);
      return JSPromise<JSAny?>(((JSFunction resolve, JSFunction reject) {
        final streamObj = JSObject();
        streamObj['streamID'] = streamId;
        resolve.callAsFunction(null, streamObj);
      }).toJS);
    }).toJS;

    // stopPlayingStream(streamId) — SYNC void.
    obj['stopPlayingStream'] = ((JSString streamId) {
      stopPlayCalls.add(streamId.toDart);
      _record('stopPlayingStream', <JSAny?>[streamId]);
    }).toJS;

    // getCameras() / getMicrophones() — ASYNC.
    obj['getCameras'] = (() {
      return _resolveSync(_toDeviceArray(cameras));
    }).toJS;
    obj['getMicrophones'] = (() {
      return _resolveSync(_toDeviceArray(microphones));
    }).toJS;

    // useVideoDevice(mediaStream, deviceId) — ASYNC.
    obj['useVideoDevice'] = ((JSObject _, JSString deviceId) {
      usedCamera = deviceId.toDart;
      return _resolveSync(null);
    }).toJS;

    // useAudioDevice(mediaStream, deviceId) — ASYNC.
    obj['useAudioDevice'] = ((JSObject _, JSString deviceId) {
      usedMic = deviceId.toDart;
      return _resolveSync(null);
    }).toJS;

    // mutePublishStreamAudio(mediaStream, mute) — SYNC, returns bool.
    obj['mutePublishStreamAudio'] = ((JSObject _, JSBoolean mute) {
      lastMuteMic = mute.toDart;
      return true.toJS;
    }).toJS;

    // mutePublishStreamVideo(mediaStream, mute) — SYNC, returns bool.
    obj['mutePublishStreamVideo'] = ((JSObject _, JSBoolean mute) {
      return true.toJS;
    }).toJS;

    // enableVideoCaptureDevice(mediaStream, enable) — ASYNC (Promise<bool>).
    obj['enableVideoCaptureDevice'] = ((JSObject _, JSBoolean enable) {
      lastEnableCam = enable.toDart;
      return _resolveSync(null);
    }).toJS;

    // renewToken(token, [roomID]) — SYNC, returns bool.
    obj['renewToken'] = ((JSString token, [JSString? roomId]) {
      renewTokenCalls.add(
        FakeRenewCall(
          token: token.toDart,
          roomId: roomId?.toDart ?? '',
        ),
      );
      _record('renewToken', <JSAny?>[token, roomId]);
      return true.toJS;
    }).toJS;

    // destroyStream(mediaStream) — SYNC void.
    obj['destroyStream'] = ((JSObject mediaStream) {
      _record('destroyStream', <JSAny?>[mediaStream]);
    }).toJS;

    // setSoundLevelDelegate(enable, interval?) — SYNC void.
    obj['setSoundLevelDelegate'] = ((JSBoolean enable, [JSNumber? interval]) {
      _record('setSoundLevelDelegate', <JSAny?>[enable, interval]);
    }).toJS;

    // destroyEngine() — SYNC void.
    obj['destroyEngine'] = (() {
      _record('destroyEngine', <JSAny?>[]);
    }).toJS;

    return obj;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _on(String name, JSFunction cb) {
    _record('on', <Object?>[name, cb]);
    _listeners.putIfAbsent(name, () => <JSFunction>[]).add(cb);
  }

  void _off(String name, JSFunction cb) {
    _record('off', <Object?>[name, cb]);
    final list = _listeners[name];
    if (list == null) return;
    list.remove(cb);
    if (list.isEmpty) _listeners.remove(name);
  }

  JSPromise<JSAny?> _runMethod(String name, List<JSAny?> args) {
    _record(name, args);
    final queue = _queued[name];
    final pending =
        (queue != null && queue.isNotEmpty) ? queue.removeAt(0) : null;
    return JSPromise<JSAny?>(((JSFunction resolve, JSFunction reject) {
      if (pending == null) {
        resolve.callAsFunction(null, null);
      } else if (pending.isResolved) {
        resolve.callAsFunction(null, pending.value);
      } else {
        reject.callAsFunction(null, pending.value);
      }
    }).toJS);
  }

  JSPromise<JSAny?> _resolveSync(JSAny? value) {
    return JSPromise<JSAny?>(((JSFunction resolve, JSFunction reject) {
      resolve.callAsFunction(null, value);
    }).toJS);
  }

  JSArray<JSObject> _toDeviceArray(List<(String, String)> devices) {
    final arr = JSArray<JSObject>();
    for (var i = 0; i < devices.length; i++) {
      final d = devices[i];
      final o = JSObject();
      o['deviceID'] = d.$1.toJS;
      o['deviceName'] = d.$2.toJS;
      arr[i] = o;
    }
    return arr;
  }

  void _record(String name, List<Object?> args) {
    callCounts[name] = (callCounts[name] ?? 0) + 1;
    callArgs.putIfAbsent(name, () => <List<Object?>>[]).add(args);
  }

  static JSAny? _getWindowProperty(String key) {
    return (web.window as JSObject)[key];
  }

  static void _setWindowProperty(String key, JSAny? value) {
    (web.window as JSObject)[key] = value;
  }
}

class _PendingResult {
  _PendingResult.resolved(this.value) : isResolved = true;
  _PendingResult.rejected(this.value) : isResolved = false;
  final bool isResolved;
  final JSAny? value;
}
