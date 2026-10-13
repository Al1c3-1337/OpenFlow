import 'package:nordic_dfu/nordic_dfu.dart';

abstract interface class FirmwareUpdater {
  Future<void> start({
    required String deviceId,
    required String firmwarePath,
    required String deviceName,
    required void Function(double) onProgress,
    required void Function(String) onMessage,
  });

  Future<void> abort();
}

/// The same Nordic entry point supports a running headset (automatic buttonless
/// handoff) and an already-advertising DFU bootloader after an interrupted update.
/// These compatibility settings belong to the headset, not a user preference.
class NordicFirmwareUpdater implements FirmwareUpdater {
  @override
  Future<void> start({
    required String deviceId,
    required String firmwarePath,
    required String deviceName,
    required void Function(double) onProgress,
    required void Function(String) onMessage,
  }) async {
    await NordicDfu().startDfu(
      deviceId,
      firmwarePath,
      name: deviceName,
      enableUnsafeExperimentalButtonlessServiceInSecureDfu: true,
      numberOfPackets: 12,
      androidParameters: const AndroidParameters(
        keepBond: false,
        packetReceiptNotificationsEnabled: true,
        currentMtu: 23,
        disableMtuRequest: true,
        dataDelay: 400,
        numberOfRetries: 3,
      ),
      darwinParameters: const DarwinParameters(
        packetReceiptNotificationParameter: 12,
        dataObjectPreparationDelay: 0.4,
      ),
      dfuEventHandler: DfuEventHandler(
        onDeviceConnecting: (_) => onMessage('DFU: connecting…'),
        onEnablingDfuMode: (_) =>
            onMessage('DFU: entering bootloader automatically…'),
        onFirmwareValidating: (_) => onMessage('DFU: validating firmware…'),
        onProgressChanged: (_, percent, speed, average, part, total) {
          if (total > 0) {
            onProgress((((part - 1) + percent / 100) / total).clamp(0.0, 1.0));
          }
        },
        onDfuCompleted: (_) =>
            onMessage('DFU completed. Find the headset to reconnect.'),
        onDfuAborted: (_) => onMessage(
          'DFU aborted. Use DFU recovery if the headset stays in its bootloader.',
        ),
        onError: (_, code, type, message) =>
            onMessage('DFU error $code: $message'),
      ),
    );
  }

  @override
  Future<void> abort() async {
    await NordicDfu().abortDfu();
  }
}
