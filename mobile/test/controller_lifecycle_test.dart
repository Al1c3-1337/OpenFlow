import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openflow/src/app_controller.dart';
import 'package:openflow/src/demo_transport.dart';
import 'package:openflow/src/protocol.dart';

void main() {
  test(
    'DFU recovery selects a bootloader without normal headset setup',
    () async {
      final controller = OpenFlowController(demo: true);
      const recovery = FlowPeripheral(
        id: 'recovery-id',
        name: 'DfuTarg',
        rssi: -55,
        bootloader: true,
      );
      try {
        await controller.connect(recovery);
        expect(controller.selected, same(recovery));
        expect(controller.session.connected, isFalse);
        expect(controller.session.ready, isFalse);
        expect(controller.session.defaultsApplied, isFalse);
        expect(controller.session.status, StimStatus.unknown);
      } finally {
        controller.dispose();
      }
    },
  );

  test('rapid scans cannot start concurrent operations', () async {
    final controller = OpenFlowController(demo: true);
    try {
      final first = controller.scan();
      await expectLater(controller.scan(), throwsStateError);
      await first;
      expect(controller.devices, hasLength(1));
    } finally {
      controller.dispose();
    }
  });

  test(
    'background cancellation prevents an unfinished scan from restarting',
    () async {
      final controller = OpenFlowController(demo: true);
      try {
        final scan = controller.scan();
        await controller.onBackground();
        await scan;
        expect(controller.scanning, isFalse);
      } finally {
        controller.dispose();
      }
    },
  );

  test('disposing an unfinished scan prevents publishing results', () async {
    final controller = OpenFlowController(demo: true);
    final scan = controller.scan();
    controller.dispose();
    await scan;
    expect(controller.scanning, isFalse);
    expect(controller.devices, isEmpty);
  });

  test(
    'resuming during scan cancellation cannot leave the session backgrounded',
    () async {
      final controller = _DelayedCancellationController();
      try {
        await controller.session.attach(DemoTransport(), deviceId: 'test');
        controller.delayCancellation = true;
        final background = controller.onBackground();
        await controller.onResume();
        controller.releaseCancellation.complete();
        await background;
        expect(
          controller.session.canCommand(StimStatus.selfDiagnostic),
          isTrue,
        );
      } finally {
        if (!controller.releaseCancellation.isCompleted) {
          controller.releaseCancellation.complete();
        }
        controller.dispose();
      }
    },
  );
}

class _DelayedCancellationController extends OpenFlowController {
  _DelayedCancellationController() : super(demo: true);

  bool delayCancellation = false;
  final releaseCancellation = Completer<void>();

  @override
  Future<void> stopScan() async {
    if (delayCancellation) await releaseCancellation.future;
    await super.stopScan();
  }
}
