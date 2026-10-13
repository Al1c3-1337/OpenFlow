# OpenFlow

OpenFlow is a shared **Flutter app for Android and iOS** in
[`mobile/`](mobile/). Its Dart code shares the UI, BLE protocol, stimulation-state
guards, startup settings, logging, and firmware-update flow across both platforms.
The original Java Android app and its build files are preserved in Git history;
the Flutter app is the only current application and release target.

The iOS build does **not** require you to supply an Apple signing key: the
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
IPA. This CI workflow does not upload an app to a store, access signing secrets, or
select an Apple development team. Native iOS compilation and runtime behavior
must be verified by a macOS build and physical-device testing; a passing Dart test
suite alone does not validate the native plugins.

See [`mobile/README.md`](mobile/README.md) for simulator installation, device
builds, permissions, source layout, and the hardware verification checklist.

## Releases

Publishing a GitHub release with a tag such as `v0.0.3` runs the
[release workflow](.github/workflows/release.yml). It checks the shared code and
builds the Flutter app for both platforms, then attaches these files to that
release:

| Release asset | Use |
| --- | --- |
| `openflow-<version>-android.apk` | Release APK signed with the repository's existing Android release key. |
| `openflow-<version>-ios-UNSIGNED.zip` | Unsigned release `.app` for iPhone/iPad; signing is still required before installation. |

The version comes from the release tag (`vX.Y.Z`). Android signing uses the
existing `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, and `KEY_PASSWORD`
repository secrets. The iOS build requires no Apple signing secrets. Release
builds omit the simulator demo to save runner time; the ordinary mobile CI
workflow still provides that demo when needed.

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

The shared Android app uses the same package ID, `de.al1c3.openflow`, as the former
Java app. A debug build signed with a different key cannot replace an existing signed
installation; uninstall that installation first if appropriate, or use a separate
test device. Uninstalling removes that app's local data.
