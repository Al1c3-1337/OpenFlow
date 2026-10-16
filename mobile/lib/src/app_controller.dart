import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_transport.dart';
import 'demo_transport.dart';
import 'firmware_updater.dart';
import 'flow_firmware_service.dart';
import 'protocol.dart';
import 'session.dart';

class FlowPeripheral {
  const FlowPeripheral({
    required this.id,
    required this.name,
    required this.rssi,
    this.bootloader = false,
  });
  final String id;
  final String name;
  final int rssi;
  final bool bootloader;
  String get displayName => name.isEmpty ? 'Unnamed headset' : name;
}

class OpenFlowController extends ChangeNotifier {
  OpenFlowController({
    this.demo = const bool.fromEnvironment('OPENFLOW_DEMO'),
    FirmwareUpdater? firmwareUpdater,
  }) : _firmwareUpdater = firmwareUpdater ?? NordicFirmwareUpdater() {
    if (!demo) {
      _ble = FlutterReactiveBle();
      _adapterSubscription = _ble!.statusStream.listen(
        (status) {
          adapterState = switch (status) {
            BleStatus.ready => 'Bluetooth ready',
            BleStatus.poweredOff => 'Turn on Bluetooth',
            BleStatus.unauthorized => 'Bluetooth permission required',
            BleStatus.unsupported => 'Bluetooth unavailable on this device',
            BleStatus.locationServicesDisabled =>
              'Enable Location services for BLE scanning',
            _ => 'Checking Bluetooth…',
          };
          _notify();
        },
        onError: (Object error) {
          adapterState = 'Bluetooth unavailable: $error';
          _notify();
        },
      );
    } else {
      adapterState = 'Simulator demo • no Bluetooth connection';
    }
  }

  final bool demo;
  final FirmwareUpdater _firmwareUpdater;
  final StimSession session = StimSession();
  final List<FlowPeripheral> _devices = [];
  List<FlowPeripheral> get devices => List.unmodifiable(_devices);
  FlowPeripheral? selected;
  String? firmwareName;
  String? _firmwarePath;
  Directory? _firmwareDirectory;
  bool scanning = false;
  bool recoveryScan = false;
  bool working = false;
  bool updating = false;
  double? dfuProgress;
  String? firmwareResult;
  bool firmwareNeedsRecovery = false;
  String adapterState = 'Checking Bluetooth…';
  FlutterReactiveBle? _ble;
  BleTransport? _transport;
  StreamSubscription<BleStatus>? _adapterSubscription;
  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  Timer? _scanTimer;
  int _generation = 0;
  int _scanGeneration = 0;
  bool _disposed = false;
  bool _background = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _requireAvailable() {
    if (_disposed || working || updating) {
      throw StateError('Another operation is in progress');
    }
  }

  Future<void> _permissions() async {
    if (demo || !Platform.isAndroid) return;
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    final permissions = sdk >= 31
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.locationWhenInUse];
    final results = await permissions.request();
    if (results.values.any((status) => !status.isGranted)) {
      throw StateError(
        'Bluetooth permissions are required. Allow them in system settings and retry.',
      );
    }
  }

  Future<void> scan({bool bootloader = false}) async {
    _requireAvailable();
    if (session.connected) {
      throw StateError('Disconnect before scanning for another headset');
    }
    working = true;
    _notify();
    try {
      await stopScan();
      final generation = _scanGeneration;
      await _permissions();
      if (_disposed || _background || generation != _scanGeneration) return;
      _devices.clear();
      selected = null;
      recoveryScan = bootloader;
      scanning = true;
      if (demo) {
        if (!bootloader) {
          _devices.add(
            const FlowPeripheral(
              id: 'demo',
              name: 'Flow • simulated headset',
              rssi: -42,
            ),
          );
        }
        session.addLog(
          bootloader
              ? 'Firmware updating is disabled in demo mode.'
              : 'Found a simulated headset.',
        );
      } else {
        await _ble!.initialize();
        // CoreBluetooth presents the iOS permission prompt on initialization.
        final status = _ble!.status == BleStatus.unknown
            ? await _ble!.statusStream
                  .firstWhere((s) => s != BleStatus.unknown)
                  .timeout(const Duration(seconds: 15))
            : _ble!.status;
        if (_disposed || _background || generation != _scanGeneration) return;
        if (status != BleStatus.ready) throw StateError(adapterState);
        _scanSubscription = _ble!
            .scanForDevices(
              withServices: [
                Uuid.parse(
                  bootloader ? StimUuids.dfuService : StimUuids.primaryService,
                ),
              ],
              scanMode: ScanMode.lowLatency,
            )
            .listen(
              (device) {
                if (_disposed || generation != _scanGeneration) return;
                final peripheral = FlowPeripheral(
                  id: device.id,
                  name: device.name,
                  rssi: device.rssi,
                  bootloader: bootloader,
                );
                final index = _devices.indexWhere((d) => d.id == device.id);
                if (index < 0) {
                  _devices.add(peripheral);
                } else {
                  _devices[index] = peripheral;
                }
                _notify();
              },
              onError: (Object error) {
                if (generation != _scanGeneration || _disposed) return;
                session.addLog('Scan failed: $error');
                unawaited(stopScan());
              },
            );
      }
      _scanTimer = Timer(
        const Duration(seconds: 12),
        () => unawaited(stopScan()),
      );
    } catch (_) {
      await stopScan();
      rethrow;
    } finally {
      working = false;
      _notify();
    }
  }

  Future<void> stopScan() async {
    ++_scanGeneration;
    _scanTimer?.cancel();
    _scanTimer = null;
    final subscription = _scanSubscription;
    _scanSubscription = null;
    scanning = false;
    await subscription?.cancel();
    _notify();
  }

  Future<void> connect(FlowPeripheral device) async {
    _requireAvailable();
    if (session.connected) {
      throw StateError('Disconnect the current headset first');
    }
    working = true;
    _notify();
    final generation = ++_generation;
    try {
      await stopScan();
      await _transport?.close();
      if (_disposed || generation != _generation) return;
      selected = device;
      if (device.bootloader) {
        session.addLog(
          'Bootloader selected: ${device.displayName} (${device.id}).',
        );
        return;
      }
      if (demo) {
        await session.attach(DemoTransport(), deviceId: device.id);
        session.addLog(
          'Demo: Self diagnostic simulates user detection after two seconds.',
        );
      } else {
        final transport = BleTransport(_ble!, device.id, (reason) {
          if (_disposed || generation != _generation) return;
          session.detach();
          selected = null;
          session.addLog(
            '$reason The headset handles link loss with quick ramp-down.',
          );
          _notify();
        });
        _transport = transport;
        await transport.open();
        if (_disposed || generation != _generation) {
          await transport.close();
          return;
        }
        session.addLog(await transport.inventory());
        await session.attach(transport, deviceId: device.id);
      }
    } catch (_) {
      // Initialization may fail while the link is usable. Keep STOP accessible.
      if (!session.connected) {
        await _transport?.close();
        selected = null;
      }
      rethrow;
    } finally {
      working = false;
      _notify();
    }
  }

  Future<void> disconnect() async {
    _requireAvailable();
    working = true;
    _notify();
    try {
      if (session.connected) {
        await session.prepareDisconnect();
        if (session.status.isDelivering ||
            session.status == StimStatus.unknown ||
            session.status == StimStatus.fault) {
          // Give the commanded gentle ramp-down time to finish before link loss.
          final elapsed = Stopwatch()..start();
          while (session.connected &&
              (session.status.isDelivering ||
                  session.status == StimStatus.unknown ||
                  session.status == StimStatus.fault)) {
            if (elapsed.elapsed > const Duration(seconds: 25)) {
              throw StateError(
                'Ramp-down is not confirmed complete. Connection kept open; retry after the status settles.',
              );
            }
            await Future<void>.delayed(const Duration(seconds: 1));
            await session.readFreshStatus();
          }
        }
      }
      ++_generation;
      session.detach();
      await _transport?.close();
      _transport = null;
      selected = null;
      session.addLog('Disconnected.');
    } finally {
      working = false;
      _notify();
    }
  }

  Future<void> chooseFirmware() async {
    _requireAvailable();
    if (demo) throw StateError('Firmware updating is disabled in demo mode');
    if (session.connected && !session.canDfu) {
      throw StateError('Return the headset to Idle first');
    }
    working = true;
    _notify();
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (file == null) return;
      // Copy a stream: Android document providers may give content:// URLs and
      // iOS document access must not outlive the picker's security scope.
      await _stageFirmware(file.readAsByteStream(), file.name);
    } finally {
      working = false;
      _notify();
    }
  }

  /// Stage a separate copy so replacing a saved download cannot change the ZIP
  /// used by Nordic DFU. Controller cleanup only removes this temporary copy.
  Future<void> useSavedFirmware(SavedFirmware firmware) async {
    _requireAvailable();
    if (demo) throw StateError('Firmware updating is disabled in demo mode');
    if (session.connected && !session.canDfu) {
      throw StateError('Return the headset to Idle first');
    }
    working = true;
    _notify();
    try {
      await _stageFirmware(File(firmware.path).openRead(), firmware.name);
    } finally {
      working = false;
      _notify();
    }
  }

  Future<void> _stageFirmware(Stream<List<int>> bytes, String name) async {
    if (!name.toLowerCase().endsWith('.zip')) {
      throw FormatException('Select a Nordic distribution .zip');
    }
    Directory? pendingDirectory;
    try {
      pendingDirectory = await Directory.systemTemp.createTemp(
        'openflow-firmware-',
      );
      final destination = File(
        '${pendingDirectory.path}${Platform.pathSeparator}firmware.zip',
      );
      final sink = destination.openWrite();
      try {
        await sink.addStream(bytes);
      } finally {
        await sink.close();
      }
      if (await destination.length() == 0) {
        throw FormatException('Firmware file is empty');
      }
      if (_disposed) return;
      if (session.connected && !session.canDfu) {
        throw StateError('Return the headset to Idle first');
      }
      final previousDirectory = _firmwareDirectory;
      _firmwareDirectory = pendingDirectory;
      pendingDirectory = null;
      firmwareName = name;
      _firmwarePath = destination.path;
      firmwareResult = null;
      firmwareNeedsRecovery = false;
      dfuProgress = null;
      if (previousDirectory != null) {
        await previousDirectory
            .delete(recursive: true)
            .catchError((Object _) => previousDirectory);
      }
      session.addLog('Firmware selected: $name');
    } finally {
      if (pendingDirectory != null) {
        await pendingDirectory.delete(recursive: true);
      }
    }
  }

  Future<void> startDfu() async {
    _requireAvailable();
    if (demo) throw StateError('Firmware updating is disabled in demo mode');
    final device = selected;
    final path = _firmwarePath;
    if (device == null || path == null) {
      throw StateError('Select a headset and firmware ZIP first');
    }
    working = true;
    _notify();
    var transferredToDfu = false;
    try {
      if (!device.bootloader) {
        if (!session.connected) {
          throw StateError('Reconnect and verify the headset before updating');
        }
      }
      if (Platform.isAndroid &&
          (await DeviceInfoPlugin().androidInfo).version.sdkInt >= 33) {
        await Permission.notification.request();
      }
      if (_disposed) return;
      // Permission dialogs can suspend the app. Validate after they return.
      if (_background) {
        throw StateError('Return to the app before starting a firmware update');
      }
      if (!device.bootloader) await session.prepareDfu();
      await stopScan();
      if (_disposed) return;
      // Releasing the app's GATT client lets Nordic own the whole DFU connection.
      ++_generation;
      transferredToDfu = true;
      session.detach();
      await _transport?.close();
      _transport = null;
      if (_disposed) return;
      updating = true;
      dfuProgress = null;
      firmwareResult = null;
      firmwareNeedsRecovery = false;
      _notify();
      await _firmwareUpdater.start(
        deviceId: device.id,
        firmwarePath: path,
        deviceName: device.name,
        onMessage: session.addLog,
        onProgress: (progress) {
          if (_disposed) return;
          dfuProgress = progress;
          _notify();
        },
      );
      firmwareResult =
          'Firmware update completed. Find the headset to reconnect.';
    } catch (_) {
      if (transferredToDfu) {
        firmwareNeedsRecovery = true;
        firmwareResult =
            'Update did not finish. If the headset starts in DFU mode, '
            'choose Recover interrupted update, select it, and install the ZIP again. '
            'Your selected firmware file is kept for the retry.';
      }
      rethrow;
    } finally {
      updating = false;
      working = false;
      if (transferredToDfu) selected = null;
      _notify();
    }
  }

  Future<void> abortDfu() async {
    if (!updating || demo) return;
    await _firmwareUpdater.abort();
  }

  Future<void> onBackground() async {
    if (_background || _disposed) return;
    _background = true;
    await stopScan();
    if (_disposed || !_background) return;
    await session.onBackground();
  }

  Future<void> onResume() async {
    _background = false;
    if (!_disposed) await session.onResume();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    ++_scanGeneration;
    _scanTimer?.cancel();
    unawaited(_scanSubscription?.cancel());
    unawaited(_adapterSubscription?.cancel());
    unawaited(_transport?.close());
    session.dispose();
    // Keep the staged ZIP while native DFU could still be reading it. Otherwise
    // only delete the unique temporary directory created by this controller.
    if (!updating && _firmwareDirectory != null) {
      unawaited(
        _firmwareDirectory!
            .delete(recursive: true)
            .catchError((Object _) => _firmwareDirectory!),
      );
    }
    super.dispose();
  }
}
