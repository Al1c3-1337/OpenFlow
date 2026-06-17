# OpenFlow

Build with the help of AI (not AI alone!)

Android app (package `de.al1c3.openflow`, label **OpenFlow**) for the Flow tDCS
headset. Same protocol layer as the Linux/BlueZ version, different transport: `AndroidBleTransport`
drives `android.bluetooth.BluetoothGatt` instead of blessed-bluez. The app scans, connects, dumps the
GATT table, runs a read-only inventory, applies the original startup default settings, then
offers guarded stimulation controls and Nordic Secure DFU firmware update.

## Project layout

```
OpenFlow/
├── settings.gradle            rootProject.name = "OpenFlow", repos
├── build.gradle               AGP 8.7.2 (applied in app/)
├── gradle.properties          useAndroidX=true, nonTransitiveRClass=true
├── gradlew / gradlew.bat      Gradle wrapper scripts
├── gradle/wrapper/            gradle-wrapper.jar + .properties (Gradle 8.9)
└── app/
    ├── build.gradle           namespace/applicationId de.al1c3.openflow, SDK levels, DFU dep
    └── src/main/
        ├── AndroidManifest.xml
        ├── java/de/al1c3/openflow/
        │   ├── BleTransport.java        AndroidBleTransport.java   DfuService.java
        │   ├── StimDevice.java          StimUuids.java             Setting.java
        │   ├── StimulationStatus.java   MainActivity.java
        └── res/
            ├── layout/activity_main.xml
            └── values/strings.xml        app_name = "OpenFlow"
```

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

## Verify against the real device

- **`PRIMARY_SERVICE` = `4C5B0001-…` is confirmed** and is now used as the BLE scan filter, so
  discovery only lists devices advertising it. Caveat: a service-UUID scan filter only matches if the
  device puts that UUID in its *advertising* data. If the list stays empty, switch to the commented
  unfiltered `startScan(null, …)` line in `MainActivity.startScan()`.
- **`getSetting` read path is inferred** (write 1-byte selector, then read). Not exercised by the
  read-only inventory; verify before relying on it.
- **Telemetry decode types are assumptions** (resistance/currents = float32 LE, battery/error = u8).
  Confirm against the printed values.
- **Transition guards are best-effort.** `transitionAllowed()` encodes the state machine
  (Idle → WaitForElectrodes → ElectrodesDetected → WaitForUser → UserDetected → RampUp → CurrentHold
  → RampDown); the firm rule is "no RampUp unless UserDetected". Confirm the exact legal transitions
  against the device and adjust if needed.
- **`RAMP_UP_TIME_S` = 120 s** is the original app's `GetRampUpTime()` value (there is no RampUpTime
  setting to read, so it lives as an app-side constant). It only affects
  `CurrentRampUpRate = TargetCurrent / RampUpTime` = 0.002 / 120 ≈ 1.67e-5 A/s.

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
