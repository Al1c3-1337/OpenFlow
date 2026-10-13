import 'dart:async';

import 'package:flutter/foundation.dart';

import 'protocol.dart';

/// Shared connection, protocol, and stimulation lifecycle for Android and iOS.
/// Device-side limits remain authoritative: mobile timers can be suspended.
class StimSession extends ChangeNotifier {
  StimSession({DateTime Function()? now, bool pollAutomatically = true})
    : _now = now ?? _monotonicClock(),
      _pollAutomatically = pollAutomatically;

  static DateTime Function() _monotonicClock() {
    final elapsed = Stopwatch()..start();
    final origin = DateTime.utc(2000);
    return () => origin.add(elapsed.elapsed);
  }

  final DateTime Function() _now;
  final bool _pollAutomatically;
  GattTransport? _transport;
  int _generation = 0;
  int _intent = 0;
  int _busyCount = 0;
  bool _ready = false;
  bool _defaultsApplied = false;
  bool _disposed = false;
  bool _draining = false;
  bool _refreshing = false;
  bool _backgrounded = false;
  bool _stopRequested = false;
  bool _automaticStopAttempted = false;
  bool _pendingRampUp = false;
  String? _deviceId;
  StimStatus _status = StimStatus.unknown;
  DateTime? _deadline;
  Timer? _ticker;
  Timer? _melodyTimer;
  Completer<void>? _melodyDelay;
  final List<_GattJob> _queue = [];
  final List<String> _logs = [];
  final Map<String, String> _telemetry = {};

  bool get connected => _transport != null;
  bool get ready => _ready;
  bool get busy => _busyCount > 0;
  StimStatus get status => _status;
  bool get defaultsApplied => _defaultsApplied;
  Map<String, String> get telemetry => Map.unmodifiable(_telemetry);
  List<String> get logs => List.unmodifiable(_logs);
  bool get canConfigure =>
      connected && !busy && !_pendingRampUp && _configurable(_status);
  bool get canDfu =>
      connected && !busy && !_pendingRampUp && _status == StimStatus.idle;

  int? get remainingSeconds {
    if (_deadline == null) return null;
    final ms = _deadline!.difference(_now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  }

  static bool _configurable(StimStatus status) => switch (status) {
    StimStatus.idle ||
    StimStatus.waitForUser ||
    StimStatus.userDetected ||
    StimStatus.waitForElectrodes ||
    StimStatus.electrodesDetected => true,
    _ => false,
  };

  bool canCommand(StimStatus target) =>
      connected &&
      _ready &&
      !busy &&
      !_backgrounded &&
      _allowed(_status, target);

  bool _allowed(StimStatus current, StimStatus target) => switch (target) {
    StimStatus.rampUp =>
      current == StimStatus.userDetected &&
          _defaultsApplied &&
          !_stopRequested &&
          !_pendingRampUp,
    StimStatus.rampDown => current.isActive,
    StimStatus.selfDiagnostic => current == StimStatus.idle,
    StimStatus.idle => _configurable(current),
    _ => false,
  };

  void addLog(String message) {
    _logs.add(message);
    if (_logs.length > 250) _logs.removeAt(0);
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> attach(GattTransport transport, {String? deviceId}) async {
    if (_disposed) throw StateError('Session has been disposed');
    detach();
    if (deviceId != null && deviceId != _deviceId) {
      _deadline = null;
      _pendingRampUp = false;
      _stopRequested = false;
    }
    _deviceId = deviceId;
    _transport = transport;
    final generation = _generation;
    _telemetry.clear();
    _automaticStopAttempted = false;
    addLog('Connected. Reading device status before changing settings.');
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_current(generation)) return;
      _checkDeadline();
      if (_pollAutomatically && !_backgrounded && timer.tick.isEven) {
        _quiet(refresh());
      }
      _changed();
    });
    await _perform('Initialize', generation, () async {
      final initial = await _readStatus(generation);
      if (_configurable(initial)) {
        await _applyDefaults(generation, _intent);
      } else if (initial.isDelivering) {
        addLog('Existing stimulation detected; retaining the device settings.');
      } else {
        addLog('Settings unchanged: device status is ${initial.label}.');
      }
      _checkCurrent(generation);
      _ready = true;
    });
    _checkDeadline();
    await refresh();
  }

  /// Retain any session deadline until a later device read confirms inactivity.
  /// Old operations and callbacks cannot update the replacement connection.
  void detach() {
    _generation++;
    _intent++;
    _transport = null;
    _ready = false;
    _defaultsApplied = false;
    _status = StimStatus.unknown;
    _pendingRampUp = false;
    _busyCount = 0;
    _refreshing = false;
    _ticker?.cancel();
    _ticker = null;
    _cancelMelodyDelay();
    final pending = List<_GattJob>.of(_queue);
    _queue.clear();
    for (final job in pending) {
      job.cancel(StateError('Connection changed'));
    }
    _changed();
  }

  Future<void> applyDefaults() {
    final generation = _generation;
    final intent = _intent;
    return _perform('Apply defaults', generation, () async {
      await _applyDefaults(generation, intent);
      _ready = true;
    });
  }

  Future<void> _applyDefaults(int generation, int intent) async {
    _defaultsApplied = false;
    final current = await _readStatus(generation);
    _checkIntent(generation, intent);
    if (!_configurable(current) || _pendingRampUp) {
      throw StateError('Defaults require a confirmed inactive device');
    }
    _ready = false;
    for (final entry in StimProtocol.startupDefaults) {
      _checkIntent(generation, intent);
      await _write(
        generation,
        StimUuids.settings,
        StimProtocol.setting(entry.setting, entry.value),
        intent: intent,
      );
    }
    _checkIntent(generation, intent);
    _defaultsApplied = true;
    addLog(
      'All startup settings acknowledged: 2 mA target, 1900 s device limit.',
    );
  }

  Future<void> refresh() async {
    if (!connected || _refreshing) return;
    final generation = _generation;
    _refreshing = true;
    try {
      await _readStatus(generation);
      for (final entry in {
        'Resistance': StimUuids.resistance,
        'Target current': StimUuids.targetCurrent,
        'Measured current': StimUuids.measuredCurrent,
        'Battery': StimUuids.batteryLevel,
        'Error code': StimUuids.errorCode,
      }.entries) {
        try {
          final value = await _read(generation, entry.value);
          _checkCurrent(generation);
          _telemetry[entry.key] = StimProtocol.describeCharacteristic(
            entry.value,
            value,
          );
        } catch (error) {
          _checkCurrent(generation);
          _telemetry[entry.key] = 'Read failed: $error';
        }
      }
    } catch (error) {
      if (_current(generation)) {
        _status = StimStatus.unknown;
        addLog('Status refresh failed: $error');
      }
    } finally {
      if (_current(generation)) {
        _refreshing = false;
        _changed();
        _checkDeadline();
      }
    }
  }

  /// Unlike telemetry refresh, this always queues its own read and propagates
  /// failures. Lifecycle decisions must not rely on a coalesced refresh.
  Future<StimStatus> readFreshStatus() => _readStatus(_generation);

  /// Cancel queued ordinary actions before inspecting the link. A delayed
  /// RampUp status must still receive a gentle stop before intentional close.
  Future<void> prepareDisconnect() async {
    _intent++;
    _cancelMelodyDelay();
    final current = await _readStatus(_generation);
    if (current.isDelivering ||
        current == StimStatus.unknown ||
        current == StimStatus.fault ||
        _pendingRampUp ||
        _deadline != null) {
      await stop();
    }
  }

  /// Validate immediately before transferring the connection to Nordic DFU.
  Future<void> prepareDfu() {
    if (busy) {
      return Future.error(StateError('Wait for the current action before DFU'));
    }
    final generation = _generation;
    final intent = _intent;
    return _perform('Prepare firmware update', generation, () async {
      await _requireDfuIdle(generation, intent);
    });
  }

  Future<void> _requireDfuIdle(int generation, int intent) async {
    final current = await _readStatus(generation);
    _checkIntent(generation, intent);
    if (current != StimStatus.idle || _pendingRampUp || _backgrounded) {
      throw StateError(
        'Firmware update requires a freshly confirmed Idle state in the foreground',
      );
    }
  }

  Future<void> command(StimStatus target) {
    if (target == StimStatus.rampDown) return stop();
    final generation = _generation;
    final intent = _intent;
    return _perform('Set ${target.label}', generation, () async {
      if (!_ready || _backgrounded) throw StateError('Device is not ready');
      final current = await _readStatus(generation);
      _checkIntent(generation, intent);
      if (!_allowed(current, target)) {
        throw StateError('${current.label} → ${target.label} is not allowed');
      }
      if (target == StimStatus.rampUp) {
        // Keep the original deadline even if acknowledgement/readback fails.
        _deadline = _now().add(
          const Duration(seconds: StimProtocol.autoRampDownSeconds),
        );
        _automaticStopAttempted = false;
        _stopRequested = false;
        _pendingRampUp = true;
      }
      await _write(
        generation,
        StimUuids.stimulationStatus,
        StimProtocol.status(target),
        intent: intent,
      );
      _checkIntent(generation, intent);
      addLog('Requested ${target.label}.');
      await _readStatus(generation);
    });
  }

  /// This write is the next GATT operation after any current operation finishes.
  /// It remains available even if initialization/defaults failed.
  Future<void> stop() {
    final generation = _generation;
    _intent++;
    _stopRequested = true;
    _cancelMelodyDelay();
    return _perform('Ramp down', generation, () async {
      await _write(generation, StimUuids.stimulationStatus, [
        StimStatus.rampDown.code,
      ], priority: true);
      addLog('Ramp down acknowledged; waiting for inactive device status.');
      await _readStatus(generation, priority: true);
    }, allowWhileBusy: true);
  }

  Future<void> beep() {
    final generation = _generation;
    final intent = _intent;
    return _perform('Beep', generation, () async {
      await _write(
        generation,
        StimUuids.sound,
        StimProtocol.sound(1000, 150),
        intent: intent,
      );
    });
  }

  Future<void> playMelody() {
    final generation = _generation;
    final intent = _intent;
    return _perform('Melody', generation, () async {
      for (final note in const [
        [392, 312],
        [440, 312],
        [466, 1875],
        [392, 312],
        [440, 312],
        [466, 1562],
        [440, 312],
        [392, 312],
        [294, 312],
        [349, 1250],
        [392, 1250],
      ]) {
        _checkIntent(generation, intent);
        await _write(
          generation,
          StimUuids.sound,
          StimProtocol.sound(note[0], note[1]),
          intent: intent,
        );
        _checkIntent(generation, intent);
        _melodyDelay = Completer<void>();
        _melodyTimer = Timer(
          Duration(milliseconds: note[1] + 60),
          _cancelMelodyDelay,
        );
        await _melodyDelay!.future;
      }
    });
  }

  void _cancelMelodyDelay() {
    _melodyTimer?.cancel();
    _melodyTimer = null;
    final delay = _melodyDelay;
    _melodyDelay = null;
    if (delay != null && !delay.isCompleted) delay.complete();
  }

  Future<void> enterBootloader() {
    if (busy) {
      return Future.error(StateError('Wait for the current action before DFU'));
    }
    final generation = _generation;
    final intent = _intent;
    return _perform('Enter bootloader', generation, () async {
      await _requireDfuIdle(generation, intent);
      await _write(
        generation,
        StimUuids.buttonlessDfu,
        [1],
        service: StimUuids.dfuService,
        intent: intent,
      );
      _ready = false;
      addLog('Bootloader requested; reconnect through the DFU workflow.');
    });
  }

  Future<void> onBackground() async {
    _backgrounded = true;
    _intent++;
    _cancelMelodyDelay();
    if (connected &&
        (_status.isDelivering ||
            _status == StimStatus.unknown ||
            _status == StimStatus.fault ||
            _deadline != null)) {
      addLog('App leaving the foreground; requesting ramp down.');
      await stop();
    }
    _changed();
  }

  Future<void> onResume() async {
    _backgrounded = false;
    await refresh();
    _checkDeadline();
    _changed();
  }

  void _checkDeadline() {
    if (!connected ||
        _deadline == null ||
        remainingSeconds != 0 ||
        _automaticStopAttempted) {
      return;
    }
    _automaticStopAttempted = true;
    addLog('Session deadline reached; requesting ramp down.');
    _quiet(stop());
  }

  void _observe(StimStatus value) {
    _status = value;
    if (value.isActive) {
      _pendingRampUp = false;
      if (_deadline == null) {
        // A session started elsewhere has no trustworthy local start time.
        _deadline = _now();
        addLog(
          'Active session has no known start time; ramp down is required.',
        );
      }
    } else if (_configurable(value) && (!_pendingRampUp || _stopRequested)) {
      _deadline = null;
      _pendingRampUp = false;
      _stopRequested = false;
      _automaticStopAttempted = false;
    }
    _changed();
  }

  Future<StimStatus> _readStatus(
    int generation, {
    bool priority = false,
  }) async {
    final bytes = await _read(
      generation,
      StimUuids.stimulationStatus,
      priority: priority,
    );
    _checkCurrent(generation);
    final value = StimStatus.decode(bytes);
    _observe(value);
    return value;
  }

  Future<List<int>> _read(
    int generation,
    String characteristic, {
    bool priority = false,
  }) => _enqueue(
    generation,
    (transport) => transport.read(StimUuids.primaryService, characteristic),
    priority: priority,
  );

  Future<void> _write(
    int generation,
    String characteristic,
    List<int> value, {
    String service = StimUuids.primaryService,
    bool priority = false,
    int? intent,
  }) => _enqueue(generation, (transport) {
    if (intent != null) _checkIntent(generation, intent);
    return transport.write(service, characteristic, value);
  }, priority: priority);

  Future<T> _enqueue<T>(
    int generation,
    Future<T> Function(GattTransport) operation, {
    bool priority = false,
  }) {
    _checkCurrent(generation);
    final transport = _transport!;
    final job = _TypedGattJob<T>(() async {
      _checkCurrent(generation);
      try {
        final value = await operation(
          transport,
        ).timeout(const Duration(seconds: 10));
        _checkCurrent(generation);
        return value;
      } on TimeoutException {
        if (_current(generation)) {
          addLog(
            'GATT operation timed out. Reconnect before further commands.',
          );
          detach();
        }
        rethrow;
      }
    });
    if (priority) {
      _queue.insert(0, job);
    } else {
      _queue.add(job);
    }
    if (!_draining) unawaited(_drain());
    return job.future;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        await _queue.removeAt(0).run();
      }
    } finally {
      _draining = false;
    }
  }

  bool _current(int generation) =>
      !_disposed && generation == _generation && connected;
  void _checkCurrent(int generation) {
    if (!_current(generation)) {
      throw StateError('Connection changed or disconnected');
    }
  }

  void _checkIntent(int generation, int intent) {
    _checkCurrent(generation);
    if (intent != _intent) {
      throw StateError('Action interrupted by ramp down or lifecycle change');
    }
  }

  Future<void> _perform(
    String action,
    int generation,
    Future<void> Function() body, {
    bool allowWhileBusy = false,
  }) async {
    _checkCurrent(generation);
    if (busy && !allowWhileBusy) {
      throw StateError('Wait for the current action before $action');
    }
    _busyCount++;
    _changed();
    try {
      await body();
    } catch (error) {
      if (_current(generation)) addLog('$action failed: $error');
      rethrow;
    } finally {
      if (_current(generation)) {
        _busyCount--;
        _changed();
      }
    }
  }

  void _quiet(Future<void> action) {
    unawaited(
      action.catchError((Object error) {
        // Public actions already log failures. Preserve failed-stop deadline.
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    detach();
    super.dispose();
  }
}

abstract class _GattJob {
  Future<void> run();
  void cancel(Object error);
}

class _TypedGattJob<T> implements _GattJob {
  _TypedGattJob(this.operation);
  final Future<T> Function() operation;
  final Completer<T> completer = Completer<T>();
  Future<T> get future => completer.future;

  @override
  Future<void> run() async {
    try {
      final value = await operation();
      if (!completer.isCompleted) completer.complete(value);
    } catch (error, stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    }
  }

  @override
  void cancel(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }
}
