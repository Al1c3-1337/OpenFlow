import 'dart:typed_data';

/// Platforms provide a connection with discovered GATT services. The controller
/// serializes requests; writes must wait for the peripheral's acknowledgement.
abstract class GattTransport {
  Future<List<int>> read(String service, String characteristic);
  Future<void> write(String service, String characteristic, List<int> value);
}

abstract final class StimUuids {
  static const primaryService = '4c5b0001-c40b-49ee-9427-6e7cc8c388f3';
  static const resistance = '4c5b0002-c40b-49ee-9427-6e7cc8c388f3';
  static const targetCurrent = '4c5b0003-c40b-49ee-9427-6e7cc8c388f3';
  static const measuredCurrent = '4c5b0004-c40b-49ee-9427-6e7cc8c388f3';
  static const stimulationStatus = '4c5b0005-c40b-49ee-9427-6e7cc8c388f3';
  static const batteryLevel = '4c5b0006-c40b-49ee-9427-6e7cc8c388f3';
  static const ticket = '4c5b0007-c40b-49ee-9427-6e7cc8c388f3';
  static const errorCode = '4c5b0008-c40b-49ee-9427-6e7cc8c388f3';
  static const sound = '4c5b0009-c40b-49ee-9427-6e7cc8c388f3';
  static const settings = '4c5b000a-c40b-49ee-9427-6e7cc8c388f3';
  static const dfuService = '0000fe59-0000-1000-8000-00805f9b34fb';
  static const buttonlessDfu = '8e400001-f315-4f60-9fb8-838830daea50';
}

enum StimStatus {
  idle(0, 'Idle'),
  fault(1, 'Fault'),
  waitForUser(2, 'Wait for user'),
  userDetected(3, 'User detected'),
  rampUp(4, 'Ramp up'),
  currentHold(5, 'Current hold'),
  rampDown(6, 'Ramp down'),
  quickRampDown(7, 'Quick ramp down'),
  waitForElectrodes(8, 'Wait for electrodes'),
  electrodesDetected(9, 'Electrodes detected'),
  selfDiagnostic(10, 'Self diagnostic'),
  panelSelfDiagnostic(11, 'Panel self diagnostic'),
  unknown(255, 'Unknown');

  const StimStatus(this.code, this.label);
  final int code;
  final String label;

  bool get isActive => this == rampUp || this == currentHold;
  bool get isDelivering =>
      isActive || this == rampDown || this == quickRampDown;

  static StimStatus fromCode(int code) {
    for (final status in values) {
      if (status.code == (code & 0xff)) return status;
    }
    return unknown;
  }

  static StimStatus decode(List<int> bytes) =>
      bytes.isEmpty ? unknown : fromCode(bytes.first);
}

/// Explicit values preserve the original companion application's wire codes.
enum StimSetting {
  userDetectedThresholdResistance(0),
  currentRampUpRate(1),
  currentRampDownRate(2),
  currentQuickRampDown(3),
  targetCurrent(4),
  minTicketTime(5),
  timeout(6),
  batteryLowerProtectionLimit(7),
  allowStimulationDuringChargerConnected(8),
  buttonHasBeenPressed(9),
  forceLedOn(10),
  assertFileNameFirst4Char(11),
  assertLineNumber(12),
  assertErrorCode(13),
  skipElectrodeDetection(14),
  overResistanceThresholdVoltageOnPadA(15),
  faultThresholdVoltageOnPadA(16),
  disableTickets(17),
  maxStimulationTime(18),
  disconnectFromPhone(19);

  const StimSetting(this.code);
  final int code;
}

class StimDefault {
  const StimDefault(this.setting, this.value);
  final StimSetting setting;
  final double value;
}

abstract final class StimProtocol {
  static const targetAmps = 0.002;
  static const maxStimulationSeconds = 1900;
  static const autoRampDownSeconds = 1800;

  // Java computes these divisions with the already-rounded float32 setpoint.
  static final double _javaTarget = _float32(targetAmps);
  static final List<StimDefault> startupDefaults = List.unmodifiable([
    StimDefault(StimSetting.currentRampUpRate, _javaTarget / 120),
    StimDefault(StimSetting.currentRampDownRate, _javaTarget / 15),
    StimDefault(StimSetting.currentQuickRampDown, _javaTarget / 6),
    const StimDefault(StimSetting.userDetectedThresholdResistance, 4000000),
    const StimDefault(StimSetting.skipElectrodeDetection, 0),
    const StimDefault(StimSetting.batteryLowerProtectionLimit, 0.25),
    const StimDefault(StimSetting.disableTickets, 1),
    const StimDefault(StimSetting.minTicketTime, 1),
    const StimDefault(StimSetting.maxStimulationTime, 1900),
    const StimDefault(StimSetting.targetCurrent, targetAmps),
  ]);

  static double _float32(double value) {
    final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
    return bytes.getFloat32(0, Endian.little);
  }

  static Uint8List setting(StimSetting setting, double value) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'Must be finite');
    }
    final bytes = ByteData(5)
      ..setUint8(0, setting.code)
      ..setFloat32(1, value, Endian.little);
    if (!bytes.getFloat32(1, Endian.little).isFinite) {
      throw ArgumentError.value(value, 'value', 'Outside float32 range');
    }
    return bytes.buffer.asUint8List();
  }

  static List<int> status(StimStatus status) => [status.code];

  static Uint8List sound(int pitch, int duration) {
    RangeError.checkValueInInterval(pitch, 0, 32767, 'pitch');
    RangeError.checkValueInInterval(duration, 0, 32767, 'duration');
    return (ByteData(4)
          ..setInt16(0, pitch, Endian.little)
          ..setInt16(2, duration, Endian.little))
        .buffer
        .asUint8List();
  }

  /// Field types recovered from the original companion DLL's characteristic
  /// size table and conversion methods. Resistance notifications use Int32;
  /// its read wrapper inconsistently uses Int16, so reject mismatched lengths
  /// instead of silently truncating. Current scaling is inferred from the DLL's
  /// measuredCurrent / (targetAmps * 1e6) ratio, not firmware verification.
  static String describeCharacteristic(String characteristic, List<int> value) {
    final uuid = characteristic.toLowerCase();
    final int expected;
    final String format;
    switch (uuid) {
      case StimUuids.resistance:
        expected = 4;
        format = 'int32 LE resistance';
      case StimUuids.targetCurrent || StimUuids.measuredCurrent:
        expected = 2;
        format = 'int16 LE current';
      case StimUuids.batteryLevel || StimUuids.errorCode:
        expected = 1;
        format = 'uint8';
      default:
        return describeTelemetry(value);
    }
    final raw = _rawBytes(value);
    if (value.length != expected) {
      return '$raw · format mismatch: expected $expected bytes for $format';
    }
    final bytes = ByteData.sublistView(Uint8List.fromList(value));
    if (uuid == StimUuids.resistance) {
      return '${bytes.getInt32(0, Endian.little)} Ω · $raw';
    }
    if (uuid == StimUuids.targetCurrent || uuid == StimUuids.measuredCurrent) {
      final current = bytes.getInt16(0, Endian.little);
      return '$current µA (${current / 1000} mA; scale inferred) · $raw';
    }
    if (uuid == StimUuids.batteryLevel) return '${value.first}% · $raw';
    return '${value.first} · $raw';
  }

  static String _rawBytes(List<int> value) {
    if (value.isEmpty) return '(empty)';
    final hex = value
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    return '${value.length} bytes [$hex]';
  }

  /// Preserve generic candidate interpretations for unknown characteristics.
  static String describeTelemetry(List<int> value) {
    if (value.isEmpty) return '(empty)';
    final data = ByteData.sublistView(Uint8List.fromList(value));
    var result = _rawBytes(value);
    if (value.length == 1) {
      result += ' · candidate uint8=${value.first}';
    } else if (value.length == 2) {
      result += ' · candidate uint16 LE=${data.getUint16(0, Endian.little)}';
    } else if (value.length == 4) {
      result +=
          ' · candidate int32 LE=${data.getInt32(0, Endian.little)}'
          ' / float32 LE=${data.getFloat32(0, Endian.little)}';
    }
    return result;
  }
}
