import 'dart:typed_data';

import 'protocol.dart';

/// In-memory simulator only. No Bluetooth plugin or DFU API is called.
class DemoTransport implements GattTransport {
  int _status = 0;
  DateTime _changed = DateTime.now();

  List<int> _int16(int value) =>
      (ByteData(2)..setInt16(0, value, Endian.little)).buffer.asUint8List();
  List<int> _int32(int value) =>
      (ByteData(4)..setInt32(0, value, Endian.little)).buffer.asUint8List();

  @override
  Future<List<int>> read(String service, String characteristic) async {
    final elapsed = DateTime.now().difference(_changed).inSeconds;
    if (_status == 10 && elapsed >= 2) _status = 3;
    if (_status == 4 && elapsed >= 3) _status = 5;
    if (_status == 6 && elapsed >= 2) _status = 0;
    final code = characteristic.toLowerCase().substring(4, 8);
    return switch (code) {
      '0002' => _int32(12000),
      '0003' => _int16(2000),
      '0004' => _int16(_status == 4 || _status == 5 ? 2000 : 0),
      '0005' => [_status],
      '0006' => [87],
      '0008' => [0],
      _ => [],
    };
  }

  @override
  Future<void> write(
    String service,
    String characteristic,
    List<int> value,
  ) async {
    if (characteristic.toLowerCase().substring(4, 8) == '0005') {
      _status = value.single;
      _changed = DateTime.now();
    }
  }
}
