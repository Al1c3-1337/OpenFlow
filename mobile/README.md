# OpenFlow for Android and iOS

This directory is the Flutter port of OpenFlow. Android and iOS share the Dart UI,
Bluetooth protocol, state guards, and firmware-update flow. The Java Android app
in `../app` remains available and has its own unchanged Gradle build.

Use Flutter **3.47.7** / Dart **3.13.5** with the committed `pubspec.lock`.
Android requires API 26 or newer, JDK 17, and Android SDK 37 (AGP 9.2.1 /
Gradle 9.5.1). iOS requires iOS 15
or newer; compiling and running it requires macOS, Xcode, and CocoaPods.

## Run and check

Run commands in this `mobile` directory:

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test

# Simulated headset; works without Bluetooth hardware or permission:
flutter run --dart-define=OPENFLOW_DEMO=true

# Physical device with real Bluetooth transport (default):
flutter run

# Android debug APK:
flutter build apk --debug
```

`OPENFLOW_DEMO=true` is a compile-time switch. Rebuild without it to communicate
with a physical headset. A simulator demo validates the UI and shared behavior;
it does not test BLE or actually flash firmware.

The Android APK is produced at `build/app/outputs/flutter-apk/app-debug.apk` and
uses a local debug signing key. Release signing is intentionally not configured
for this new app. Its package ID matches the original app, so differently signed
installations cannot replace each other in place.

## iOS without a signing key

No Apple account, certificate, provisioning profile, or development team is needed
to compile the unsigned artifacts in CI. The workflow uses a macOS runner because
Apple's iOS build tools run on macOS.

### Simulator demo

On a Mac with Xcode and an installed simulator runtime:

```sh
flutter pub get --enforce-lockfile
flutter build ios --simulator --debug --no-codesign --dart-define=OPENFLOW_DEMO=true
```

Start an iOS simulator from Xcode, then install and launch the app:

```sh
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted de.al1c3.openflow
```

You can also select the booted simulator directly with
`flutter run -d <simulator-id> --dart-define=OPENFLOW_DEMO=true`. Use
`flutter devices` to obtain its ID. A downloaded CI simulator ZIP contains
`Runner.app`; extract it and pass that path to `simctl install`. The simulator and
Mac must support the architecture and SDK used to build that artifact. Rebuild
locally if the CI binary is incompatible with your Mac.

### Unsigned device build

```sh
flutter build ios --release --no-codesign --dart-define=OPENFLOW_DEMO=false
```

This compiles `build/ios/iphoneos/Runner.app`. It is an **unsigned build artifact
and cannot be installed or launched on a physical iPhone or iPad**. Renaming a ZIP
to `.ipa` does not supply the missing signature or provisioning. The CI artifact
is named `openflow-ios-device-UNSIGNED-not-installable` to make this distinction
visible at download time.

If physical iPhone testing becomes possible later, run `flutter pub get`, then
`pod install` inside `ios`, and open `ios/Runner.xcworkspace` in Xcode. Arrange a
signing team and a unique bundle identifier as required by that account. Xcode can
create a certificate for personal testing using a free Apple account / Personal
Team; that route still signs the app and has Apple's provisioning limits. Store
or TestFlight distribution requires the appropriate developer membership. See the
[Flutter iOS setup documentation](https://docs.flutter.dev/platform-integration/ios/setup)
and [Apple's device setup documentation](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).

The checked-in Xcode project has no `DEVELOPMENT_TEAM` or provisioning profile.
`--no-codesign` disables signing for the unsigned build without hard-coding a
signing prohibition into the project, so a future developer can configure their
own team locally.

## Native integration

### Firmware update and interrupted-update recovery

The **Firmware update & recovery** card offers both paths:

1. **Normal / buttonless:** use **Find headset to update**, select the headset,
   and wait for **Idle**. Choose the vendor firmware ZIP, then **Install firmware**
   and confirm. The app automatically uses the older experimental buttonless
   handoff; no manual bootloader command or compatibility toggle is needed.
2. **Already in DFU mode:** use **Recover interrupted update** (or **Find bootloader**),
   select the advertised DFU device, choose the ZIP, and **Install firmware**.
   This path does not require the normal headset service, telemetry, startup
   settings, or an Idle status. It works with a headset that starts directly in
   its bootloader after an interrupted update.

An unfinished update displays recovery instructions and keeps the selected ZIP
for another attempt within the app session. Recovery scans look for the Nordic
Secure DFU service (`0xFE59`) and use the identifier actually discovered on that
platform. Restarting a transfer is handled by the Nordic library and bootloader.

Stimulation current is fixed in code at **0.002 A (2 mA)**. The UI contains no
current slider, input, or other adjustment. Current telemetry is read-only.

### Source and platform integration

Shared source is organized as follows:

- `lib/main.dart` selects the real or demo transport and starts the app.
- `lib/src/home.dart` contains the shared interface.
- `lib/src/app_controller.dart` coordinates connections, telemetry, and DFU.
- `lib/src/firmware_updater.dart` keeps the native Nordic compatibility settings
  shared by buttonless updates and recovery.
- `lib/src/protocol.dart` encodes packets and decodes known telemetry formats.
- `lib/src/session.dart` manages guarded stimulation commands and the stop timer.
- `lib/src/ble_transport.dart` and `demo_transport.dart` provide physical and
  simulated Bluetooth behavior.
- `test/` checks protocol bytes, state guards, connection lifecycle, and the UI.

| Area | Android | iOS |
| --- | --- | --- |
| BLE transport | `flutter_reactive_ble` | `flutter_reactive_ble` / Core Bluetooth |
| Device identifiers | Android Bluetooth device ID | Core Bluetooth peripheral UUID; never assume a MAC address |
| Firmware update | `nordic_dfu` / Nordic Android DFU | `nordic_dfu` / Nordic iOS DFU |
| Firmware selection | System file picker | System document picker |
| Permission | Location for scanning through Android 11; Nearby Devices from Android 12 | Bluetooth usage description and system consent |
| Background support | Nordic DFU foreground service with `connectedDevice` type | `bluetooth-central` background mode |

The Android manifest declares legacy Bluetooth and location permissions with
`maxSdkVersion=30`, plus `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, foreground-service,
connected-device foreground-service, and notification permissions. Scanning is
declared `neverForLocation`. Android 11 and earlier may also require the system
Location switch to be enabled. Nordic's plugin supplies its own foreground-service
declarations; notification permission supports showing DFU progress on Android 13+.

The iOS `Info.plist` supplies `NSBluetoothAlwaysUsageDescription` and
`UIBackgroundModes = bluetooth-central`. CocoaPods is selected per project in
`pubspec.yaml`; `ios/Podfile` enables only the Bluetooth permission-handler macro.
Neither a location usage string nor location permission is required for iOS BLE.
The iOS minimum stays at the Flutter 3.47.7 scaffold's iOS 15 deployment target.

Both DFU implementations use the platform's native Nordic library. Select an
appropriate vendor-signed Secure DFU ZIP. Firmware signature enforcement belongs
to the device bootloader and is unchanged. Demo mode disables firmware updates;
it does not verify firmware compatibility, bootloader discovery, or transfer reliability.

The port preserves the device-specific SDK-12 experimental buttonless handoff via
`enableUnsafeExperimentalButtonlessServiceInSecureDfu: true`. This enables that
Nordic transport variant; it does not disable Secure DFU's firmware-signature
check. The configured transfer parameters are:

- Common: `numberOfPackets: 12`.
- Android: `keepBond: false`, `packetReceiptNotificationsEnabled: true`,
  `currentMtu: 23`, `disableMtuRequest: true`, `dataDelay: 400`, and
  `numberOfRetries: 3`.
- iOS: `packetReceiptNotificationParameter: 12` and
  `dataObjectPreparationDelay: 0.4`.

## Scope and validation

The shared application ports the GATT UUIDs, settings encoding, status transitions,
startup defaults, sound commands, stop/ramp-down behavior, and Nordic DFU flow from
the Java app. Raw telemetry remains available for comparison; values whose units
or meaning are not established by the original implementation must not be treated
as calibrated readings.

The phone schedules a best-effort auto ramp-down after 1800 seconds. The device
maximum stimulation time remains 1900 seconds, intentionally chosen by the headset
owner to leave a buffer for the gentle stop. Background Bluetooth declarations
do **not** ensure that Dart timers execute while iOS suspends the application or
Android stops its process. The headset owner reports a device-side quick ramp-down
on connection loss, which can feel unsettling. Prefer a gentle stop before an
intentional disconnect or backgrounding. The phone timer is not a guaranteed
background stop mechanism.

Before relying on a physical device build, validate these behaviors on each OS:

- Bluetooth permission granted, denied, revoked, and Bluetooth switched off.
- Device discovery, connection, complete GATT inventory, reads, and notification
  payloads against the existing Java app.
- Successful application of every startup setting before stimulation controls
  become available; legal state transitions and stop behavior.
- Connection loss, reconnection, app background/resume, and elapsed-time handling.
- Firmware ZIP selection, confirmation/cancellation, bootloader handoff, transfer,
  completion, and recovery from failure with compatible headset firmware.

CI runs formatting, analyzer checks, shared tests, an Android debug build, a
simulator demo build, and an unsigned iOS release build. Its unsigned iOS outputs
are compilation artifacts; only a successful macOS job validates native iOS
compilation, and real Bluetooth behavior still needs physical hardware.

## Telemetry encoding evidence

The supplied `out/Flow.Forms.dll` was inspected statically to check the ambiguous
numeric values in the original Java prototype. No code from the DLL was executed
or changed. Its identity is:

- Assembly `Flow.Forms`, version `4.0.0.0`, target `.NETStandard,Version=v2.1`.
- SHA-256: `16aa2556e1335df63a79ccc230aa469c4758b2f91d4bf51501aa19f471f1816e`.
- MVID: `3ee80fd4-d6a6-4a83-98ee-7552bbb14cee`.
- REA artifact Evidence: `ev_716c26ef45051e8ee78a2762a6974261167adba052c994f58e100e06b206c894`.
- REA member Evidence: `ev_6066cd10ed894a65adc778b71f4afa5203db0377a39e34295e28b313183c9e08`.

The metadata tokens below are specific to that exact assembly. Method bodies and
their CIL hashes were checked against the input bytes; these are static
observations, not a capture of headset traffic.

| Payload | Observed representation | Evidence |
| --- | --- | --- |
| Settings writes and responses | 5 bytes: setting ID followed by a 32-bit float | `<WriteSetting>d__189.MoveNext`, `0x06002366`, copies `GetBytes(float)` into bytes 1–4; update handler `0x0600235e` requires length 5 and calls `ToSingle(bytes, 1)`. |
| Resistance notification | Signed 32-bit integer, displayed as ohms | Update handler `0x0600235e` calls `ToInt32`; `Headset_ResistanceChanged`, `0x06000e32`, formats `Resistance: {0} Ohm`. |
| Measured current | Signed 16-bit integer | Update handler `0x0600235e` calls `ToInt16`; `GetMeasuredCurrentRatio`, `0x060022e3`, divides it by target current × 1,000,000. |
| Target-current characteristic read | Signed 16-bit integer, distinct from float setting writes | `<ReadTargetCurrent>d__204.MoveNext`, `0x06002384`, reads characteristic 3 through `ReadShortCharacteristicValue`. |
| Battery | One unsigned byte, displayed as percent | `Headset_BatteryLevelChanged`, `0x06000e2f`, formats `Battery: {0}%`. |
| Status and error code | One byte each | Size table in `BaseHeadset..cctor`, `0x0600231d`; error reader `0x0600237c` uses `ReadByteCharacteristicValue`. |

The original calls use `BitConverter` without byte swapping. The port explicitly
uses little endian, matching the Android/iOS hardware on which that code runs.
The current scale in microamps is inferred from the ratio's factor of 1,000,000
and the target-current setting in amps. Resistance and battery units are explicit
in the original UI. Raw bytes remain useful when checking these representations
against actual firmware.

There is one inconsistency in the original DLL: `ReadElectrodeResistance`
(`0x0600237e`) calls the short reader, while the notification decoder, stored
`Resistance` property, and characteristic size table consistently use 32 bits / 4
bytes. The port follows the notification decoder and 4-byte size table.

The supplied DLL's `GetTargetCurrent` (`0x060022e0`) contains 0.0021 A; the headset
owner confirms that this was their test modification. The intended target is
0.002 A (2 mA), which this port uses. `WriteDefaultSettings` (`0x06002354`) confirms
the original maximum-time value of 1805 seconds. The owner intentionally changed
this repository's maximum to 1900 seconds to leave a buffer for the app's gentle
1800-second ramp-down and avoid the unpleasant quick ramp-down fallback. The port
preserves those intended values. Static analysis establishes what the supplied
file contains; the history and intent of these edits come from the owner's
clarification.
