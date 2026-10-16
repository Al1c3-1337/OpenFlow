import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openflow/src/app_controller.dart';
import 'package:openflow/src/demo_transport.dart';
import 'package:openflow/src/flow_firmware_screen.dart';
import 'package:openflow/src/flow_firmware_service.dart';
import 'package:openflow/src/protocol.dart';

const _saved = SavedFirmware(
  path: '/saved/flow-firmware.zip',
  name: 'flow-firmware.zip',
);
const _subscriptionReminder =
    'Please check that you have a valid Flow subscription.';

void main() {
  testWidgets('validates credentials without sending a request', (
    tester,
  ) async {
    final controller = _Controller();
    final service = _Service();
    try {
      await _open(tester, controller, service);
      await tester.tap(find.byKey(const ValueKey('flow-download')));
      await tester.pump();

      expect(find.text('Enter your Flow account email.'), findsOneWidget);
      expect(find.text('Enter your Flow account password.'), findsOneWidget);
      expect(service.requests, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  testWidgets(
    'downloads once, clears password and explicitly selects saved firmware',
    (tester) async {
      final controller = _Controller();
      final service = _Service();
      try {
        await _open(tester, controller, service);
        await _download(tester);
        expect(service.username, 'person@example.com');
        expect(service.password, 'test-password');
        expect(service.requests, 1);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('flow-download')))
              .onPressed,
          isNull,
        );
        service.progress!(0.4);
        await tester.pump();
        expect(find.text('Downloading firmware · 40%'), findsOneWidget);

        service.result.complete(_saved);
        await tester.pumpAndSettle();
        expect(
          find.text('Download verified. The firmware is saved on this device.'),
          findsOneWidget,
        );
        expect(find.text(_saved.path), findsOneWidget);
        final password = tester.widget<TextFormField>(
          find.byKey(const ValueKey('flow-password')),
        );
        expect(password.controller!.text, isEmpty);
        expect(controller.selectedFirmware, isNull);
        expect(controller.installCalls, 0);
        expect(controller.session.logs, isEmpty);

        await tester.ensureVisible(
          find.byKey(const ValueKey('flow-use-firmware')),
        );
        await tester.tap(find.byKey(const ValueKey('flow-use-firmware')));
        await tester.pumpAndSettle();
        expect(controller.selectedFirmware, same(_saved));
        expect(controller.installCalls, 0);
        expect(find.text('Open download'), findsOneWidget);
        expect(service.closed, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );

  for (final (label, error, reason) in <(String, Object, String)>[
    (
      'authentication',
      const FlowFirmwareException('Check your email and password.'),
      'Check your email and password.',
    ),
    (
      'download',
      const FlowFirmwareException('The firmware download timed out.'),
      'The firmware download timed out.',
    ),
    (
      'ZIP extraction',
      const FlowFirmwareException('The firmware ZIP could not be extracted.'),
      'The firmware ZIP could not be extracted.',
    ),
    (
      'missing BIN and DAT',
      const FlowFirmwareException(
        'The firmware ZIP must contain .bin and .dat files.',
      ),
      'The firmware ZIP must contain .bin and .dat files.',
    ),
    (
      'unexpected response',
      StateError('test-password secret-token response body'),
      'The firmware could not be downloaded. Please try again.',
    ),
    (
      'existing subscription reminder',
      const FlowFirmwareException(
        'Download access was denied. $_subscriptionReminder',
      ),
      'Download access was denied.',
    ),
  ]) {
    testWidgets(
      '$label failure shows one subscription reminder and retains saved firmware',
      (tester) async {
        final controller = _Controller();
        final service = _Service(saved: _saved);
        try {
          await _open(tester, controller, service);
          await _download(tester);
          service.result.completeError(error);
          await tester.pumpAndSettle();

          expect(find.text('$reason $_subscriptionReminder'), findsOneWidget);
          expect(find.textContaining('secret-token'), findsNothing);
          expect(
            tester
                .widget<TextFormField>(
                  find.byKey(const ValueKey('flow-password')),
                )
                .controller!
                .text,
            isEmpty,
          );
          expect(find.text(_saved.path), findsOneWidget);
          expect(controller.session.logs, isEmpty);
          expect(controller.selectedFirmware, isNull);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('flow-download')),
                )
                .onPressed,
            isNotNull,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        }
      },
    );
  }

  for (final (error, reason) in <(Object, String)>[
    (
      const FlowFirmwareException(
        'The saved firmware ZIP could not be verified.',
      ),
      'The saved firmware ZIP could not be verified.',
    ),
    (
      StateError('secret-token response body'),
      'The saved firmware could not be opened. Download it again.',
    ),
  ]) {
    testWidgets(
      'saved file failure preserves safe reason and subscription reminder: $reason',
      (tester) async {
        final controller = _Controller();
        final service = _Service(loadError: error);
        try {
          await _open(tester, controller, service);
          expect(find.text('$reason $_subscriptionReminder'), findsOneWidget);
          expect(find.textContaining('secret-token'), findsNothing);
          expect(find.byKey(const ValueKey('flow-use-firmware')), findsNothing);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('flow-download')),
                )
                .onPressed,
            isNotNull,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        }
      },
    );
  }

  testWidgets(
    'leaving during download closes the service and ignores late results',
    (tester) async {
      final controller = _Controller();
      final service = _Service();
      try {
        await _open(tester, controller, service);
        await _download(tester);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(service.closed, isTrue);
        service.progress!(0.5);
        service.result.completeError(
          const FlowFirmwareException('Download cancelled.'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Open download'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(controller.selectedFirmware, isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );

  testWidgets(
    'back during firmware selection does not pop the underlying screen twice',
    (tester) async {
      final controller = _Controller()..selectionGate = Completer<void>();
      final service = _Service(saved: _saved);
      final observer = _PopObserver();
      try {
        await _open(tester, controller, service, observer: observer);
        await tester.ensureVisible(
          find.byKey(const ValueKey('flow-use-firmware')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('flow-use-firmware')));
        await tester.pump();
        await tester.tap(find.byType(BackButton));
        // Complete staging while the departing route is still mounted.
        await tester.pump();
        controller.selectionGate!.complete();
        await tester.pumpAndSettle();
        expect(observer.pops, 1);
        expect(find.text('Open download'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );

  testWidgets(
    'restores saved firmware in demo mode but disables update selection',
    (tester) async {
      final controller = _Controller(simulate: true);
      final service = _Service(saved: _saved);
      try {
        await _open(tester, controller, service);
        expect(find.textContaining('uses a real Flow account'), findsOneWidget);
        expect(find.text(_saved.path), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('flow-use-firmware')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('flow-download')))
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('flow-save-copy')),
              )
              .onPressed,
          isNotNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );

  testWidgets(
    'STOP remains visible and active on a narrow screen during download',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = _Controller();
      final service = _Service(saved: _saved);
      final transport = _Transport();
      try {
        await controller.session.attach(transport, deviceId: 'ui-test');
        await _open(tester, controller, service);
        await _download(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pump();
        final stop = find.byKey(const ValueKey('flow-stop-button'));
        expect(tester.takeException(), isNull);
        expect(tester.getRect(stop).bottom, lessThanOrEqualTo(480));
        expect(tester.widget<FilledButton>(stop).onPressed, isNotNull);
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -2000),
        );
        await tester.pump();
        expect(tester.getRect(stop).bottom, lessThanOrEqualTo(480));
        await tester.tap(stop);
        await tester.pump();
        expect(transport.statusWrites, contains(StimStatus.rampDown.code));
        expect(tester.takeException(), isNull);
        service.result.complete(_saved);
        await tester.pumpAndSettle();
        // The device has entered ramp down; update selection must stay disabled.
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('flow-use-firmware')),
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

  testWidgets('exports the saved ZIP through the native save picker', (
    tester,
  ) async {
    final controller = _Controller();
    final picker = _FilePicker();
    final previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('openflow-ui-export-'),
    ))!;
    final file = File('${directory.path}${Platform.pathSeparator}firmware.zip');
    await tester.runAsync(() => file.writeAsBytes([80, 75, 3, 4, 1, 2, 3]));
    final service = _Service(
      saved: SavedFirmware(path: file.path, name: 'firmware.zip'),
    );
    try {
      await _open(tester, controller, service);
      await tester.ensureVisible(find.byKey(const ValueKey('flow-save-copy')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final button = tester.widget<OutlinedButton>(
          find.byKey(const ValueKey('flow-save-copy')),
        );
        await (button.onPressed! as Future<void> Function())();
      });
      await tester.pumpAndSettle();
      expect(picker.name, 'firmware.zip');
      expect(picker.mime, 'application/zip');
      expect(picker.bytes, [80, 75, 3, 4, 1, 2, 3]);
      expect(
        find.text('A firmware copy was saved to your chosen location.'),
        findsOneWidget,
      );
      expect(controller.selectedFirmware, isNull);
      expect(await tester.runAsync(file.exists), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      FilePickerPlatform.instance = previousPicker;
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}

Future<void> _open(
  WidgetTester tester,
  OpenFlowController controller,
  FlowFirmwareService service, {
  NavigatorObserver? observer,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [?observer],
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => FlowFirmwareScreen(
                  controller: controller,
                  service: service,
                ),
              ),
            ),
            child: const Text('Open download'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open download'));
  await tester.pumpAndSettle();
}

Future<void> _download(WidgetTester tester) async {
  final email = find.byKey(const ValueKey('flow-email'));
  final password = find.byKey(const ValueKey('flow-password'));
  final button = find.byKey(const ValueKey('flow-download'));
  await tester.ensureVisible(email);
  await tester.enterText(email, ' person@example.com ');
  await tester.ensureVisible(password);
  await tester.enterText(password, 'test-password');
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pump();
}

class _Service extends FlowFirmwareService {
  _Service({this.saved, this.loadError});
  final SavedFirmware? saved;
  final Object? loadError;
  final result = Completer<SavedFirmware>();
  int requests = 0;
  String? username;
  String? password;
  bool closed = false;
  void Function(double?)? progress;

  @override
  Future<SavedFirmware?> loadSavedFirmware() async {
    if (loadError != null) throw loadError!;
    return saved;
  }

  @override
  Future<SavedFirmware> loginAndDownload({
    required String username,
    required String password,
    void Function(double?)? onProgress,
  }) {
    requests++;
    this.username = username;
    this.password = password;
    progress = onProgress;
    return result.future;
  }

  @override
  void close() => closed = true;
}

class _Controller extends OpenFlowController {
  _Controller({bool simulate = false}) : super(demo: true) {
    _simulate = simulate;
  }
  bool _simulate = true;
  SavedFirmware? selectedFirmware;
  Completer<void>? selectionGate;
  int installCalls = 0;

  @override
  bool get demo => _simulate;

  @override
  Future<void> useSavedFirmware(SavedFirmware firmware) async {
    await selectionGate?.future;
    selectedFirmware = firmware;
  }

  @override
  Future<void> startDfu() async => installCalls++;
}

class _PopObserver extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => pops++;
}

class _Transport extends DemoTransport {
  final statusWrites = <int>[];

  @override
  Future<void> write(
    String service,
    String characteristic,
    List<int> value,
  ) async {
    if (characteristic == StimUuids.stimulationStatus) {
      statusWrites.add(value.single);
    }
    await super.write(service, characteristic, value);
  }
}

class _FilePicker extends FilePickerPlatform {
  String? name;
  String? mime;
  Uint8List? bytes;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    name = fileName;
    mime = mimeType;
    this.bytes = bytes;
    return Uri.file('/exports/firmware.zip');
  }
}
