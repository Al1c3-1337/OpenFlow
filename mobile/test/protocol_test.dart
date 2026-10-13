import 'package:flutter_test/flutter_test.dart';
import 'package:openflow/src/protocol.dart';

void main() {
  test('current and the two ramp-down timers remain fixed', () {
    expect(StimProtocol.targetAmps, 0.002);
    expect(
      StimProtocol.startupDefaults
          .singleWhere((entry) => entry.setting == StimSetting.targetCurrent)
          .value,
      0.002,
    );
    expect(StimProtocol.autoRampDownSeconds, 1800);
    expect(StimProtocol.maxStimulationSeconds, 1900);
  });

  test(
    'characteristic telemetry follows original DLL types and retains raw evidence',
    () {
      expect(
        StimProtocol.describeCharacteristic(StimUuids.resistance, [
          0xa0,
          0x86,
          1,
          0,
        ]),
        '100000 Ω · 4 bytes [A0 86 01 00]',
      );
      expect(
        StimProtocol.describeCharacteristic(StimUuids.measuredCurrent, [
          0xd0,
          7,
        ]),
        '2000 µA (2.0 mA; scale inferred) · 2 bytes [D0 07]',
      );
      expect(
        StimProtocol.describeCharacteristic(StimUuids.targetCurrent, [
          0xff,
          0xff,
        ]),
        '-1 µA (-0.001 mA; scale inferred) · 2 bytes [FF FF]',
      );
      expect(
        StimProtocol.describeCharacteristic(StimUuids.batteryLevel, [80]),
        '80% · 1 bytes [50]',
      );
      expect(
        StimProtocol.describeCharacteristic(StimUuids.errorCode, [3]),
        '3 · 1 bytes [03]',
      );
    },
  );

  test(
    'known telemetry refuses truncated or oversized payloads without losing raw bytes',
    () {
      for (final value in <List<int>>[
        [],
        [1],
        [1, 2, 3],
        [1, 2, 3, 4, 5],
      ]) {
        expect(
          StimProtocol.describeCharacteristic(StimUuids.resistance, value),
          contains('format mismatch: expected 4 bytes'),
        );
      }
      expect(
        StimProtocol.describeCharacteristic(StimUuids.measuredCurrent, [
          0x6f,
          0x12,
          3,
          0x3b,
        ]),
        contains('[6F 12 03 3B] · format mismatch: expected 2 bytes'),
      );
      expect(
        StimProtocol.describeCharacteristic(StimUuids.batteryLevel, []),
        contains('(empty) · format mismatch'),
      );
    },
  );

  test('known companion-app command vectors are byte compatible', () {
    expect(StimProtocol.setting(StimSetting.targetCurrent, .002), [
      4,
      0x6f,
      0x12,
      3,
      0x3b,
    ]);
    expect(StimProtocol.setting(StimSetting.maxStimulationTime, 1900), [
      18,
      0,
      0x80,
      0xed,
      0x44,
    ]);
    expect(StimProtocol.status(StimStatus.rampDown), [6]);
    expect(StimProtocol.sound(1000, 150), [0xe8, 3, 0x96, 0]);
    final quickRamp = StimProtocol.startupDefaults.singleWhere(
      (value) => value.setting == StimSetting.currentQuickRampDown,
    );
    expect(StimProtocol.setting(quickRamp.setting, quickRamp.value), [
      3,
      0x3f,
      0xc3,
      0xae,
      0x39,
    ]);
  });

  test('startup order includes the original ticket and interlock settings', () {
    expect(StimProtocol.startupDefaults.map((entry) => entry.setting.code), [
      1,
      2,
      3,
      0,
      14,
      7,
      17,
      5,
      18,
      4,
    ]);
    expect(
      StimSetting.values.map((entry) => entry.code),
      List.generate(20, (index) => index),
    );
    expect(StimStatus.values.map((entry) => entry.code), [
      ...List.generate(12, (index) => index),
      255,
    ]);
  });

  test('unknown and truncated status cannot become a permissive state', () {
    expect(StimStatus.decode([]), StimStatus.unknown);
    expect(StimStatus.fromCode(80), StimStatus.unknown);
    expect(StimStatus.fromCode(-1), StimStatus.unknown);
    expect(StimStatus.rampDown.isDelivering, isTrue);
    expect(StimStatus.quickRampDown.isDelivering, isTrue);
    expect(StimStatus.rampDown.isActive, isFalse);
  });

  test(
    'telemetry retains raw bytes and labels unverified candidate decodes',
    () {
      expect(StimProtocol.describeTelemetry([]), '(empty)');
      expect(
        StimProtocol.describeTelemetry([0x6f, 0x12, 3, 0x3b]),
        contains('[6F 12 03 3B]'),
      );
      expect(
        StimProtocol.describeTelemetry([0x6f, 0x12, 3, 0x3b]),
        contains('candidate int32 LE='),
      );
      expect(StimProtocol.describeTelemetry([1, 2, 3]), '3 bytes [01 02 03]');
    },
  );

  test('malformed setting/sound values fail before any BLE write', () {
    for (final value in [double.nan, double.infinity, 1e100]) {
      expect(
        () => StimProtocol.setting(StimSetting.targetCurrent, value),
        throwsArgumentError,
      );
    }
    expect(() => StimProtocol.sound(-1, 150), throwsRangeError);
    expect(() => StimProtocol.sound(1000, 32768), throwsRangeError);
  });
}
