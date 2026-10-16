import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openflow/src/app_controller.dart';
import 'package:openflow/src/demo_transport.dart';
import 'package:openflow/src/firmware_updater.dart';
import 'package:openflow/src/flow_firmware_service.dart';
import 'package:openflow/src/protocol.dart';

const _recoveryDevice = FlowPeripheral(
  id: 'recovery-id',
  name: 'DfuTarg',
  rssi: -55,
  bootloader: true,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory downloads;
  late _RecordingUpdater updater;
  late OpenFlowController controller;
  var disposed = false;

  setUpAll(() {
    // Windows/Linux use the injected platform; macOS uses the plugin channels.
    ReactiveBlePlatform.instance = _SilentBlePlatform();
    for (final name in [
      'flutter_reactive_ble_method',
      'flutter_reactive_ble_status',
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
  });

  setUp(() async {
    downloads = await Directory.systemTemp.createTemp('openflow-saved-test-');
    updater = _RecordingUpdater();
    controller = OpenFlowController(demo: false, firmwareUpdater: updater);
    disposed = false;
  });

  tearDown(() async {
    if (!disposed) controller.dispose();
    await downloads.delete(recursive: true);
  });

  Future<SavedFirmware> save(String name, List<int> bytes) async {
    final file = File('${downloads.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes);
    return SavedFirmware(path: file.path, name: name);
  }

  Future<void> runRecoveryDfu() async {
    await controller.connect(_recoveryDevice);
    await controller.startDfu();
  }

  test('prefill resets old results and DFU uses an independent copy', () async {
    final firmware = await save('download.zip', [0x50, 0x4b, 1, 2, 3]);
    controller.firmwareResult = 'Previous update failed';
    controller.firmwareNeedsRecovery = true;
    controller.dfuProgress = 0.6;

    await controller.useSavedFirmware(firmware);

    expect(controller.firmwareName, 'download.zip');
    expect(controller.firmwareResult, isNull);
    expect(controller.firmwareNeedsRecovery, isFalse);
    expect(controller.dfuProgress, isNull);
    expect(controller.working, isFalse);
    expect(updater.paths, isEmpty, reason: 'Prefilling must not start DFU');

    await File(firmware.path).writeAsBytes([9, 8, 7]);
    await runRecoveryDfu();
    expect(updater.paths.single, isNot(firmware.path));
    expect(updater.bytes.single, [0x50, 0x4b, 1, 2, 3]);

    controller.dispose();
    disposed = true;
    await _expectDeleted(File(updater.paths.single));
    expect(await File(firmware.path).readAsBytes(), [9, 8, 7]);
  });

  test(
    'replacing the selection deletes only the previous staged copy',
    () async {
      final first = await save('first.zip', [1, 2, 3]);
      final second = await save('second.ZIP', [4, 5, 6]);
      await controller.useSavedFirmware(first);
      await runRecoveryDfu();
      final oldStagedFile = File(updater.paths.single);
      expect(await oldStagedFile.exists(), isTrue);

      await controller.useSavedFirmware(second);

      expect(controller.firmwareName, 'second.ZIP');
      expect(controller.firmwareResult, isNull);
      expect(await oldStagedFile.exists(), isFalse);
      expect(await File(first.path).readAsBytes(), [1, 2, 3]);
      expect(await File(second.path).readAsBytes(), [4, 5, 6]);
      await runRecoveryDfu();
      expect(updater.bytes.last, [4, 5, 6]);
      expect(updater.paths.last, isNot(second.path));
      expect(updater.paths.last, isNot(oldStagedFile.path));
    },
  );

  test('bad saved files preserve the previous usable selection', () async {
    final firmware = await save('valid.zip', [1, 2, 3]);
    final empty = await save('empty.zip', []);
    final wrongExtension = await save('firmware.txt', [4, 5, 6]);
    final missing = SavedFirmware(
      path: '${downloads.path}${Platform.pathSeparator}missing.zip',
      name: 'missing.zip',
    );
    await controller.useSavedFirmware(firmware);
    await runRecoveryDfu();
    final stagedPath = updater.paths.single;

    for (final (invalid, matcher) in [
      (missing, isA<FileSystemException>()),
      (empty, isA<FormatException>()),
      (wrongExtension, isA<FormatException>()),
    ]) {
      await expectLater(controller.useSavedFirmware(invalid), throwsA(matcher));
      expect(controller.firmwareName, 'valid.zip');
      expect(controller.working, isFalse);
      await runRecoveryDfu();
      expect(updater.paths.last, stagedPath);
      expect(updater.bytes.last, [1, 2, 3]);
    }
    expect(await File(firmware.path).readAsBytes(), [1, 2, 3]);
  });

  test(
    'prefill cannot overlap another operation or an active update',
    () async {
      final firmware = await save('download.zip', [1, 2, 3]);
      final first = controller.useSavedFirmware(firmware);
      expect(controller.working, isTrue);
      await expectLater(
        controller.useSavedFirmware(firmware),
        throwsStateError,
      );
      await first;

      controller.updating = true;
      await expectLater(
        controller.useSavedFirmware(firmware),
        throwsStateError,
      );
      controller.updating = false;
      expect(controller.firmwareName, 'download.zip');
      expect(updater.paths, isEmpty);
    },
  );

  test('prefill requires Idle for a connected headset', () async {
    final firmware = await save('download.zip', [1, 2, 3]);
    await controller.session.attach(DemoTransport(), deviceId: 'test');
    await controller.session.command(StimStatus.selfDiagnostic);
    expect(controller.session.canDfu, isFalse);

    await expectLater(controller.useSavedFirmware(firmware), throwsStateError);

    expect(controller.firmwareName, isNull);
    expect(controller.working, isFalse);
    expect(await File(firmware.path).exists(), isTrue);
  });

  test(
    'disposing while staging cannot publish or delete the saved file',
    () async {
      final firmware = await save('download.zip', [1, 2, 3]);
      final staging = controller.useSavedFirmware(firmware);
      controller.dispose();
      disposed = true;
      await staging;

      expect(controller.firmwareName, isNull);
      expect(controller.working, isFalse);
      expect(await File(firmware.path).readAsBytes(), [1, 2, 3]);
      await expectLater(
        controller.useSavedFirmware(firmware),
        throwsStateError,
      );
    },
  );

  test('demo mode cannot prefill an update', () async {
    final firmware = await save('download.zip', [1, 2, 3]);
    final demo = OpenFlowController(demo: true);
    try {
      await expectLater(demo.useSavedFirmware(firmware), throwsStateError);
      expect(demo.firmwareName, isNull);
      expect(await File(firmware.path).readAsBytes(), [1, 2, 3]);
    } finally {
      demo.dispose();
    }
  });
}

Future<void> _expectDeleted(File file) async {
  // Controller disposal starts asynchronous cleanup without blocking the UI.
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (await file.exists() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(await file.exists(), isFalse);
}

class _RecordingUpdater implements FirmwareUpdater {
  final paths = <String>[];
  final bytes = <List<int>>[];

  @override
  Future<void> start({
    required String deviceId,
    required String firmwarePath,
    required String deviceName,
    required void Function(double) onProgress,
    required void Function(String) onMessage,
  }) async {
    paths.add(firmwarePath);
    bytes.add(await File(firmwarePath).readAsBytes());
  }

  @override
  Future<void> abort() async {}
}

class _SilentBlePlatform extends ReactiveBlePlatform {
  @override
  Future<void> initialize() async {}

  @override
  Stream<BleStatus> get bleStatusStream => const Stream.empty();
}
