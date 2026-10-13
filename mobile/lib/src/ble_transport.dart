import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'protocol.dart';

/// One connection owns every callback. IDs stay opaque: CoreBluetooth UUID on
/// iOS, Bluetooth address on Android. Never synthesize a bootloader address.
class BleTransport implements GattTransport {
  BleTransport(this.ble, this.id, this.onDropped);

  final FlutterReactiveBle ble;
  final String id;
  final void Function(String reason) onDropped;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  bool _closed = false;
  bool _connected = false;

  Future<void> open() async {
    final ready = Completer<void>();
    _connection = ble
        .connectToDevice(id: id, connectionTimeout: const Duration(seconds: 15))
        .listen(
          (event) {
            if (_closed) return;
            if (event.connectionState == DeviceConnectionState.connected) {
              _connected = true;
              if (!ready.isCompleted) ready.complete();
            } else if (event.connectionState ==
                DeviceConnectionState.disconnected) {
              final error = StateError(
                'Bluetooth disconnected: ${event.failure ?? id}',
              );
              if (!ready.isCompleted) ready.completeError(error);
              _drop(error.toString());
            }
          },
          onError: (Object error) {
            if (!ready.isCompleted) ready.completeError(error);
            _drop(error.toString());
          },
        );
    try {
      await ready.future.timeout(const Duration(seconds: 18));
      await _operation(() => ble.discoverAllServices(id));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<String> inventory() => _operation(() async {
    final services = await ble.getDiscoveredServices(id);
    return services
        .map((service) {
          final characteristics = service.characteristics.map(
            (c) =>
                '  ${c.id} '
                '[${c.isReadable ? 'R' : ''}${c.isWritableWithResponse ? 'W' : ''}'
                '${c.isWritableWithoutResponse ? 'w' : ''}'
                '${c.isNotifiable ? 'N' : ''}${c.isIndicatable ? 'I' : ''}]',
          );
          return 'Service ${service.id}\n${characteristics.join('\n')}';
        })
        .join('\n');
  });

  QualifiedCharacteristic _characteristic(
    String service,
    String characteristic,
  ) => QualifiedCharacteristic(
    deviceId: id,
    serviceId: Uuid.parse(service),
    characteristicId: Uuid.parse(characteristic),
  );

  @override
  Future<List<int>> read(String service, String characteristic) => _operation(
    () => ble.readCharacteristic(_characteristic(service, characteristic)),
  );

  @override
  Future<void> write(String service, String characteristic, List<int> value) =>
      _operation(
        () => ble.writeCharacteristicWithResponse(
          _characteristic(service, characteristic),
          value: value,
        ),
      );

  // The session serializes operations and gives STOP priority. A timed-out
  // native operation cannot be canceled individually, so retire its connection.
  Future<T> _operation<T>(Future<T> Function() operation) async {
    if (_closed || !_connected) throw StateError('Bluetooth is disconnected');
    try {
      final result = await operation().timeout(const Duration(seconds: 8));
      if (_closed) throw StateError('Connection changed during operation');
      return result;
    } on TimeoutException {
      _drop('Bluetooth operation timed out. Reconnect before continuing.');
      rethrow;
    }
  }

  void _drop(String reason) {
    if (_closed) return;
    unawaited(close().catchError((Object _) {}));
    onDropped(reason);
  }

  Future<void> close() async {
    _closed = true;
    _connected = false;
    final connection = _connection;
    _connection = null;
    await connection?.cancel();
  }
}
