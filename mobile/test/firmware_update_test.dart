import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:openflow/src/firmware_updater.dart';

const _methodChannel = MethodChannel('dev.steenbakker.nordic_dfu/method');
const _eventChannel = MethodChannel('dev.steenbakker.nordic_dfu/event');
const _androidAddress = 'AA:BB:CC:DD:EE:FF';
const _iosIdentifier = '1D7610CA-B691-4661-9152-04FC32215F62';
const _firmwarePath = '/staged/firmware.zip';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  late NordicFirmwareUpdater updater;
  late List<MethodCall> calls;
  late Completer<void> nativeStarted;
  late Completer<void> nativeListening;
  late Completer<String?> nativeResult;

  setUp(() {
    updater = NordicFirmwareUpdater();
    calls = [];
    nativeStarted = Completer<void>();
    nativeListening = Completer<void>();
    nativeResult = Completer<String?>();
    messenger.setMockMethodCallHandler(_methodChannel, (call) async {
      calls.add(call);
      if (call.method == 'startDfu') {
        nativeStarted.complete();
        return nativeResult.future;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_eventChannel, (call) async {
      if (call.method == 'listen') nativeListening.complete();
      return null;
    });
  });

  tearDown(() async {
    if (!nativeResult.isCompleted) nativeResult.complete();
    await NordicDfu().dispose();
    messenger.setMockMethodCallHandler(_methodChannel, null);
    messenger.setMockMethodCallHandler(_eventChannel, null);
  });

  Future<void> start({
    String id = _androidAddress,
    void Function(double)? onProgress,
    void Function(String)? onMessage,
  }) => updater.start(
    deviceId: id,
    firmwarePath: _firmwarePath,
    deviceName: 'Flow headset',
    onProgress: onProgress ?? (_) {},
    onMessage: onMessage ?? (_) {},
  );

  Future<void> emit(String name, Object payload) async {
    await nativeListening.future;
    await messenger.handlePlatformMessage(
      _eventChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({name: payload}),
      null,
    );
  }

  for (final (platform, identifier) in [
    ('Android Bluetooth address', _androidAddress),
    ('iOS CoreBluetooth identifier', _iosIdentifier),
  ]) {
    test('DFU preserves old-headset compatibility for $platform', () async {
      final transfer = start(id: identifier);
      await nativeStarted.future;
      final arguments = calls.single.arguments as Map;

      // These are the arguments actually crossing the plugin's native channel.
      expect(calls.single.method, 'startDfu');
      expect(arguments['address'], identifier);
      expect(arguments['name'], 'Flow headset');
      expect(arguments['filePath'], _firmwarePath);
      expect(arguments['fileInAsset'], isFalse);
      expect(
        arguments['enableUnsafeExperimentalButtonlessServiceInSecureDfu'],
        isTrue,
      );
      // Let Nordic discover whether the selected device needs a buttonless
      // transition or already exposes the bootloader after an interruption.
      expect(arguments['forceDfu'], isFalse);
      expect(arguments['numberOfPackets'], 12);
      expect(arguments['packetReceiptNotificationsEnabled'], isTrue);
      expect(arguments['keepBond'], isFalse);
      expect(arguments['currentMtu'], 23);
      expect(arguments['disableMtuRequest'], isTrue);
      expect(arguments['dataDelay'], 400);
      expect(arguments['numberOfRetries'], 3);
      expect(arguments['packetReceiptNotificationParameter'], 12);
      expect(arguments['dataObjectPreparationDelay'], 0.4);
      expect(arguments['disableResume'], isNot(isTrue));

      nativeResult.complete(identifier);
      await transfer;
    });
  }

  test('native multipart progress reaches the firmware update UI', () async {
    final progress = <double>[];
    final transfer = start(onProgress: progress.add);
    await nativeStarted.future;

    for (final (percent, part) in [(25, 1), (50, 2), (100, 2)]) {
      await emit('onProgressChanged', {
        'deviceAddress': _androidAddress,
        'percent': percent,
        'speed': 1.0,
        'avgSpeed': 1.0,
        'currentPart': part,
        'partsTotal': 2,
      });
    }

    expect(progress, [0.125, 0.75, 1.0]);
    nativeResult.complete();
    await transfer;
  });

  test('native callbacks report buttonless entry and completion', () async {
    final messages = <String>[];
    final transfer = start(id: _iosIdentifier, onMessage: messages.add);
    await nativeStarted.future;

    await emit('onDeviceConnecting', _iosIdentifier);
    await emit('onEnablingDfuMode', _iosIdentifier);
    await emit('onFirmwareValidating', _iosIdentifier);
    await emit('onDfuCompleted', _iosIdentifier);

    expect(messages, hasLength(4));
    expect(messages[0], contains('connecting'));
    expect(messages[1], contains('bootloader'));
    expect(messages[2], contains('validating'));
    expect(messages[3], contains('completed'));
    nativeResult.complete();
    await transfer;
  });

  test(
    'native terminal errors reject the update and retain error details',
    () async {
      final messages = <String>[];
      final transfer = start(onMessage: messages.add);
      final assertion = expectLater(
        transfer,
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', '4100')
              .having(
                (error) => error.message,
                'message',
                'DFU FAILED: Connection lost',
              ),
        ),
      );
      await nativeStarted.future;

      await emit('onError', {
        'deviceAddress': _androidAddress,
        'error': 4100,
        'errorType': 2,
        'message': 'Connection lost',
      });
      // Both native implementations report the event and reject the original
      // startDfu method call; terminal errors must never look like completion.
      nativeResult.completeError(
        PlatformException(code: '4100', message: 'DFU FAILED: Connection lost'),
      );
      await assertion;

      expect(messages, hasLength(1));
      expect(messages.single, contains('4100'));
      expect(messages.single, contains('Connection lost'));
      expect(messages.any((message) => message.contains('completed')), isFalse);
    },
  );

  test(
    'native abort rejects the update and retains recovery guidance',
    () async {
      final messages = <String>[];
      final transfer = start(id: _iosIdentifier, onMessage: messages.add);
      final assertion = expectLater(
        transfer,
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', 'DFU_ABORTED')
              .having(
                (error) => error.message,
                'message',
                'DFU aborted by user',
              ),
        ),
      );
      await nativeStarted.future;

      await updater.abort();
      expect(calls.map((call) => call.method), ['startDfu', 'abortDfu']);
      await emit('onDfuAborted', _iosIdentifier);
      nativeResult.completeError(
        PlatformException(code: 'DFU_ABORTED', message: 'DFU aborted by user'),
      );
      await assertion;

      expect(messages, hasLength(1));
      expect(messages.single, contains('aborted'));
      expect(messages.single, contains('DFU recovery'));
      expect(messages.any((message) => message.contains('completed')), isFalse);
    },
  );

  test('native start failures propagate to the controller', () async {
    final transfer = start();
    final assertion = expectLater(
      transfer,
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'DFU_FAILED')
            .having(
              (error) => error.message,
              'message',
              'Invalid firmware ZIP',
            ),
      ),
    );
    await nativeStarted.future;
    nativeResult.completeError(
      PlatformException(code: 'DFU_FAILED', message: 'Invalid firmware ZIP'),
    );
    await assertion;
  });
}
