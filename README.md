# OpenFlow

OpenFlow now includes a shared **Flutter app for Android and iOS** in
[`mobile/`](mobile/). Its Dart code shares the UI, BLE protocol, stimulation-state
guards, startup settings, logging, and firmware-update flow across both platforms.
The original Java Android app remains in [`app/`](app/) for comparison and continued
use; its build and release workflow are unchanged.

The iOS build does **not** require you to supply an Apple signing key: the new
[mobile CI workflow](.github/workflows/mobile.yml) builds a simulator demo and an
unsigned device application on a macOS runner. **An unsigned device app cannot be
installed or run on a physical iPhone.** Running on an iPhone still requires signing
and provisioning arranged separately. For personal testing, Xcode can create a
development certificate with a free Apple account / Personal Team; App Store and
TestFlight distribution require the appropriate Apple Developer membership. See
[Flutter's iOS setup guide](https://docs.flutter.dev/platform-integration/ios/setup)
and [Apple's device setup guide](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).

## Shared Android / iOS app

Use **Flutter 3.47.7** (Dart 3.13.5). The native targets are Android 8.0+ (API 26)
and iOS 15+. Install Android SDK 37 and JDK 17 for Android. Building or running
iOS requires **macOS and Xcode 26.1 or newer**, plus CocoaPods for the native plugins.
CI pins Xcode 26.6 on macOS 26; the app still supports iOS 15 and newer. Windows
can run the shared checks and Android builds; GitHub Actions can compile the iOS
targets on your behalf without Apple credentials.

```sh
cd mobile
flutter pub get --enforce-lockfile
flutter analyze
flutter test

# Interactive demo, including in an Android emulator or iOS simulator:
flutter run --dart-define=OPENFLOW_DEMO=true

# Android debug APK, using the real Bluetooth transport:
flutter build apk --debug
```

On a Mac, build the iOS simulator demo without an Apple signing identity:

```sh
cd mobile
flutter pub get --enforce-lockfile
flutter build ios --simulator --debug --no-codesign --dart-define=OPENFLOW_DEMO=true
```

The generated simulator bundle is `mobile/build/ios/iphonesimulator/Runner.app`.
The demo uses simulated data and sends no Bluetooth commands; real headset BLE
and firmware updates require a physical phone.

The **Flutter Android and unsigned iOS** workflow runs on relevant pushes, pull
requests, and manual dispatch. Successful runs expose these downloadable artifacts:

| Artifact | Use |
| --- | --- |
| `openflow-android-debug` | Debug APK for an Android phone; no release key required. |
| `openflow-ios-simulator-demo` | Zipped `.app` for the iOS simulator on a compatible Mac. |
| `openflow-ios-device-UNSIGNED-not-installable` | Zipped release `.app` compiled for iPhone/iPad, awaiting separately arranged signing. |

The unsigned device artifact is deliberately a `.app` archive, not an installable
IPA. The workflow does not upload an app to a store, access signing secrets, or
select an Apple development team. Native iOS compilation and runtime behavior
must be verified by a macOS build and physical-device testing; a passing Dart test
suite alone does not validate the native plugins.

See [`mobile/README.md`](mobile/README.md) for simulator installation, device
builds, permissions, source layout, and the hardware verification checklist.

## Port status and device behavior

The shared app carries over device discovery, GATT inventory, characteristic
reads and status polling, guarded stimulation commands, startup defaults, stop/ramp-down,
sound commands, and Nordic DFU using a selected firmware ZIP. The protocol values
are ported from the Java implementation. Unknown telemetry is retained as raw
bytes rather than assigned guessed units or clinical meaning. The port still
needs validation with the actual headset on Android and iOS, including telemetry
payloads, reconnection, and the complete bootloader handoff during DFU.

The phone's 1800-second auto ramp-down is **best effort while the app is executing
and connected**. iOS background Bluetooth support does not guarantee that Dart
timers run while the app is suspended, and Android may also suspend or terminate
the app. The device-side maximum stimulation time remains 1900 seconds, an
intentional buffer selected by the headset owner for the app's gentle stop at
1800 seconds. The headset owner reports that losing the Bluetooth
connection triggers the device's own quick ramp-down, which can feel unsettling.
Prefer the app's gentle ramp-down before intentional disconnect or backgrounding;
do not treat its timer as a guaranteed background stop mechanism.

Inspection of the supplied companion DLL confirms that its original maximum-time
setting was 1805 seconds and that known telemetry uses integer fields, while
settings use 32-bit floats. The DLL's 0.0021 A literal was the owner's test
modification; the intended target and this port's target are 0.002 A (2 mA).
The intentional 1900-second buffer is preserved. See the
[encoding evidence](mobile/README.md#telemetry-encoding-evidence).

The shared Android app uses the same package ID, `de.al1c3.openflow`, as the Java
app. A debug build signed with a different key cannot replace an existing signed
installation; uninstall that installation first if appropriate, or use a separate
test device. Uninstalling removes that app's local data.

## Original Java Android app

Build with the help of AI (not AI alone!)

Android app (package `de.al1c3.openflow`, label **OpenFlow**) for the Flow tDCS
headset.

## Build / run

One external dependency: Nordic's DFU library (`no.nordicsemi.android:dfu`, from Maven Central; it
pulls a few AndroidX transitive deps). The Gradle wrapper is included, so no extra setup is needed.

1. In Android Studio: **File → Open** and select this `OpenFlow/` folder. Let it sync (it downloads
   Gradle 8.9, AGP 8.7.2, and the SDK components).
2. Build & run on a **physical device** (BLE does not work on the emulator).

CLI alternative (the wrapper is bundled, so `gradle` need not be installed):
```
# macOS/Linux: the exec bit may be lost in transit, so set it once:
chmod +x gradlew
export ANDROID_HOME=/path/to/Android/sdk     # or create local.properties with sdk.dir=...
./gradlew assembleDebug
./gradlew installDebug                        # device attached via adb
# Windows: use gradlew.bat instead of ./gradlew
```

`local.properties` (the SDK path) is intentionally not included — Android Studio generates it on
import, or create it yourself with `sdk.dir=/path/to/Android/sdk`.

Targets: `compileSdk` 35, `targetSdk` 34, `minSdk` 26. AGP 8.7.2 / Gradle 8.9 are pinned in
`build.gradle` and `gradle/wrapper/gradle-wrapper.properties` — Android Studio's AGP Upgrade
Assistant will offer to bump them if your installed version is newer.

## Firmware update (DFU)

Uses Nordic's [Android-DFU-Library](https://github.com/NordicSemiconductor/Android-DFU-Library)
(`no.nordicsemi.android:dfu:2.11.0`) — the same library the companion app's `Laerdal.Dfu` binding
wraps. Flow: scan → tap the device (runs the inventory and captures its address) → **Select firmware
(.zip)** → **Flash firmware (DFU)** → confirm. The library handles the buttonless app→bootloader
switch automatically and shows progress in a foreground-service notification; progress is also echoed
to the in-app log.

Things to know:
- **Secure DFU is signature-enforced.** The `0000fe59` bootloader verifies the package against the
  vendor's public key and rejects anything not signed with it. This is the standard signed-update
  transport; it is not a way to load unsigned/tampered firmware.
- **Package format:** a `.zip` built with [nRF Util](https://github.com/NordicSemiconductor/pc-nrfutil).
  Raw `.bin`/`.hex` are not accepted by Secure DFU.
- **This library is for nRF5 SDK bootloaders** (Secure ≥ SDK 12, or Legacy 4.3–11), which matches the
  `fe59` service. It does **not** work for nRF Connect SDK / MCUboot devices (those use the SMP
  service and the nRF Connect Device Manager library instead) — worth confirming for this device.
- **SDK-12 experimental buttonless service:** if the bootloader jump fails, uncomment
  `setUnsafeExperimentalButtonlessServiceInSecureDfuEnabled(true)` in `MainActivity.startDfu()`.
- **Permissions:** `BLUETOOTH_SCAN` (already requested) covers the rescan after the MAC-incremented
  bootloader re-advertises on Android 12+; `POST_NOTIFICATIONS` (API 33+) is requested so the
  progress notification shows — the update still runs if it is denied.

Unlike the GATT write controls, this flow is wired live (you asked for firmware upgrading), but it is
still a deliberate three-step action with a confirmation dialog, and Secure DFU's signing check is
the backstop. If you'd rather it be commented out, that's a small change.

The device can also be put into the bootloader manually with **Enter DFU bootloader** (writes 0x01 to
the buttonless characteristic over GATT); the flash flow does this automatically.

## Stimulation control & safety

On connect the app applies the startup defaults (ramp rates derived from the fixed
2 mA target, `UserDetectedThresholdResistance` 4 MΩ, `SkipElectrodeDetection` 0 = detection ON,
battery protection 0.25, `MaxStimulationTime` 1900 s, `TargetCurrent` 0.002). Re-apply any time with
**Apply defaults**.

Controls and their guards:
- **Status dropdown + Apply** commands a stimulation state, but only if the transition is legal from
  the current state — in particular **no RampUp until the device reports UserDetected**.
- **RAMP DOWN (STOP)** is the stop sequence (sets status `RampDown`); it is always available while
  connected and bypasses the dropdown guard.
- **Auto ramp-down at 1800 s.** Once stimulation is active the app arms a gentle `RampDown` ~100 s
  before the device's 1900 s `MaxStimulationTime`, so the device never falls back to the abrupt
  `QuickRampDown`. It disarms if stimulation stops first.
- **Beep / Play melody** exercise the sound characteristic.

Deliberately **not** exposed in the UI: `TargetCurrent` and `MaxStimulationTime` (kept as code
constants), and the dangerous interlocks (`SkipElectrodeDetection`, compliance/fault voltage limits,
…) — those are only written, with safe values, in the defaults block. Nothing in the protocol layer
clamps a written value before it reaches firmware that drives current through a person.
