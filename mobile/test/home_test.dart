import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openflow/main.dart';
import 'package:openflow/src/app_controller.dart';
import 'package:openflow/src/demo_transport.dart';
import 'package:openflow/src/protocol.dart';

void main() {
  testWidgets(
    'demo identifies simulation and connects without native Bluetooth',
    (tester) async {
      final controller = OpenFlowController(demo: true);
      try {
        await tester.pumpWidget(OpenFlowApp(controller: controller));

        expect(find.text('DEMO'), findsOneWidget);
        expect(find.textContaining('No Bluetooth connection'), findsOneWidget);
        expect(find.text('Recover interrupted update'), findsOneWidget);
        expect(
          find.textContaining('Current is fixed at 0.002 A'),
          findsOneWidget,
        );
        expect(find.byType(Slider), findsNothing);
        expect(find.byType(RangeSlider), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Enter bootloader'), findsNothing);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('stop-button')))
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('Find headset'));
        await tester.pump();
        expect(controller.devices, hasLength(1));
        await tester.tap(find.text(controller.devices.single.displayName));
        await tester.pumpAndSettle();

        expect(controller.session.ready, isTrue);
        expect(find.text('Connected · Ready'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('stop-button')))
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Install firmware'),
              )
              .onPressed,
          isNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );

  testWidgets('STOP stays enabled during another device operation', (
    tester,
  ) async {
    final controller = OpenFlowController(demo: true);
    final transport = _BlockedSoundTransport();
    try {
      await controller.session.attach(transport, deviceId: 'widget-test');
      await tester.pumpWidget(OpenFlowApp(controller: controller));

      final beep = controller.session.beep();
      await tester.pump();
      expect(controller.session.busy, isTrue);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('stop-button')))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Self diagnostic'),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('stop-button')));
      transport.releaseSound.complete();
      await beep;
      await tester.pumpAndSettle();
      expect(transport.statusWrites, contains(StimStatus.rampDown.code));
    } finally {
      if (!transport.releaseSound.isCompleted) {
        transport.releaseSound.complete();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets(
    'narrow layout and large text keep STOP visible without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = OpenFlowController(demo: true);
      try {
        await tester.pumpWidget(OpenFlowApp(controller: controller));

        expect(tester.takeException(), isNull);
        final stop = find.byKey(const ValueKey('stop-button'));
        expect(tester.getRect(stop).bottom, lessThanOrEqualTo(740));
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -1800),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(stop).bottom, lessThanOrEqualTo(740));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );
}

class _BlockedSoundTransport extends DemoTransport {
  final releaseSound = Completer<void>();
  final List<int> statusWrites = [];

  @override
  Future<void> write(
    String service,
    String characteristic,
    List<int> value,
  ) async {
    if (characteristic == StimUuids.sound) await releaseSound.future;
    if (characteristic == StimUuids.stimulationStatus) {
      statusWrites.add(value.single);
    }
    await super.write(service, characteristic, value);
  }
}
