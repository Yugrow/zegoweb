@TestOn('chrome')
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zegoweb/zegoweb.dart';
import 'package:zegoweb_ui/src/zego_call_config.dart';
import 'package:zegoweb_ui/src/zego_call_controller.dart';
import 'package:zegoweb_ui/src/zego_call_state.dart';
import 'package:zegoweb_ui/src/zego_layout_mode.dart';

import 'fixtures/fake_zego_js.dart';

void main() {
  group('ZegoCallController', () {
    late ZegoCallController controller;

    setUp(() {
      controller = ZegoCallController(
        engineConfig: ZegoEngineConfig(
          appId: 1,
          server: 'wss://example.com',
          scenario: ZegoScenario.communication,
          tokenProvider: () async => 'token',
        ),
        callConfig: const ZegoCallConfig(roomId: 'r1', userId: 'u1'),
      );
    });

    tearDown(() => controller.dispose());

    test('initial state is idle', () {
      expect(controller.state, ZegoCallState.idle);
    });

    test('initial participants is empty', () {
      expect(controller.participants, isEmpty);
    });

    test('initial layout comes from config', () {
      expect(controller.currentLayout, ZegoLayoutMode.grid);
    });

    test('initial mic and camera are on', () {
      expect(controller.isMicOn, isTrue);
      expect(controller.isCameraOn, isTrue);
    });

    test('initial isScreenSharing is false', () {
      expect(controller.isScreenSharing, isFalse);
    });

    test('switchLayout changes currentLayout and notifies', () {
      var notified = false;
      controller.addListener(() => notified = true);
      controller.switchLayout(ZegoLayoutMode.sidebar);
      expect(controller.currentLayout, ZegoLayoutMode.sidebar);
      expect(notified, isTrue);
    });

    test('switchLayout cycles through all modes', () {
      controller.switchLayout(ZegoLayoutMode.sidebar);
      expect(controller.currentLayout, ZegoLayoutMode.sidebar);
      controller.switchLayout(ZegoLayoutMode.pip);
      expect(controller.currentLayout, ZegoLayoutMode.pip);
      controller.switchLayout(ZegoLayoutMode.grid);
      expect(controller.currentLayout, ZegoLayoutMode.grid);
    });

    test('is a ChangeNotifier', () {
      expect(controller, isA<ChangeNotifier>());
    });

    group('debug surface', () {
      test('debugThreshold defaults to 10.0', () {
        expect(controller.debugThreshold, 10.0);
      });

      test('debugThreshold setter clamps to 0–100', () {
        controller.debugThreshold = 25.0;
        expect(controller.debugThreshold, 25.0);

        controller.debugThreshold = -5.0;
        expect(controller.debugThreshold, 0.0);

        controller.debugThreshold = 150.0;
        expect(controller.debugThreshold, 100.0);
      });

      test('debugThreshold setter notifies listeners', () {
        var notified = false;
        controller.addListener(() => notified = true);
        controller.debugThreshold = 20.0;
        expect(notified, isTrue);
      });

      test('debugDebounce defaults to 500 ms', () {
        expect(controller.debugDebounce, const Duration(milliseconds: 500));
      });

      test('debugDebounce setter stores value', () {
        controller.debugDebounce = const Duration(milliseconds: 800);
        expect(controller.debugDebounce, const Duration(milliseconds: 800));
      });

      test('debugLog is a broadcast stream', () {
        expect(controller.debugLog.isBroadcast, isTrue);
      });

      test('debugLog allows multiple subscribers', () {
        final sub1 = controller.debugLog.listen((_) {});
        final sub2 = controller.debugLog.listen((_) {});
        sub1.cancel();
        sub2.cancel();
      });

      test('debugMicLevel returns a stream', () {
        expect(controller.debugMicLevel, isA<Stream<double>>());
      });
    });
  });

  // A join that fails after loginRoom must log out, otherwise the next join
  // is rejected by the SDK with 1002001 ("login rooms exceeds the upper
  // limit").
  group('ZegoCallController failed join', () {
    late FakeZegoJs fake;
    late ZegoCallController controller;
    var disposed = false;

    setUp(() {
      fake = FakeZegoJs();
      disposed = false;
      controller = ZegoCallController(
        engineConfig: ZegoEngineConfig(
          appId: 1,
          server: 'wss://example.com',
          scenario: ZegoScenario.communication,
          tokenProvider: () async => 'token',
        ),
        callConfig: const ZegoCallConfig(roomId: 'r1', userId: 'u1'),
        engineFactory: (config) async => ZegoEngine.test(
          js: fake.asJs(),
          tokenProvider: config.tokenProvider,
        ),
      );
    });

    tearDown(() {
      if (!disposed) controller.dispose();
    });

    test('logs out of the room when creating the local stream fails',
        () async {
      fake.rejectNextCreateStream(
        jsName: 'NotAllowedError',
        message: 'Permission denied',
      );

      await expectLater(controller.join(), throwsA(isA<ZegoError>()));

      expect(fake.loginCalls, hasLength(1));
      expect(fake.logoutCalls, ['r1']);
      expect(controller.state, ZegoCallState.idle);
      expect(controller.lastError, isNotNull);
    });

    test('does not log out when loginRoom itself fails', () async {
      fake.rejectNextLogin(code: 1102016, message: 'token error');

      await expectLater(controller.join(), throwsA(isA<ZegoError>()));

      expect(fake.logoutCalls, isEmpty);
      expect(controller.state, ZegoCallState.idle);
    });

    // Mirrors the BUGS-372 repro: camera still blocked, Join tapped twice.
    // Before the fix the second loginRoom ran while still logged in.
    test('a second failed join logs in and out again', () async {
      for (var i = 0; i < 2; i++) {
        fake.rejectNextCreateStream(
          jsName: 'NotAllowedError',
          message: 'Permission denied',
        );
        await expectLater(controller.join(), throwsA(isA<ZegoError>()));
      }

      expect(fake.loginCalls, hasLength(2));
      expect(fake.logoutCalls, ['r1', 'r1']);
      expect(controller.state, ZegoCallState.idle);
    });

    test('dispose after a failed join destroys the engine', () async {
      fake.rejectNextCreateStream(
        jsName: 'NotAllowedError',
        message: 'Permission denied',
      );
      await expectLater(controller.join(), throwsA(isA<ZegoError>()));

      controller.dispose();
      disposed = true;
      await Future<void>.delayed(Duration.zero);

      expect(fake.callCounts['destroyEngine'], 1);
    });
  });
}
