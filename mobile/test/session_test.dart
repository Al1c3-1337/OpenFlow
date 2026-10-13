import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openflow/src/protocol.dart';
import 'package:openflow/src/session.dart';

class FakeTransport implements GattTransport {
  StimStatus status = StimStatus.idle;
  int? failSetting;
  bool failStop = false;
  bool delayRampUpState = false;
  Completer<List<int>>? heldRead;
  final List<(String, List<int>)> writes = [];
  final List<String> calls = [];
  int outstanding = 0;
  int maximumOutstanding = 0;

  void _started() {
    outstanding++;
    if (outstanding > maximumOutstanding) maximumOutstanding = outstanding;
  }

  @override
  Future<List<int>> read(String service, String characteristic) async {
    _started();
    calls.add('read:$characteristic');
    try {
      final held = heldRead;
      if (held != null) {
        heldRead = null;
        return await held.future;
      }
      return characteristic == StimUuids.stimulationStatus
          ? [status.code]
          : [0];
    } finally {
      outstanding--;
    }
  }

  @override
  Future<void> write(
    String service,
    String characteristic,
    List<int> value,
  ) async {
    _started();
    calls.add('write:$characteristic');
    writes.add((characteristic, List<int>.of(value)));
    try {
      if (characteristic == StimUuids.settings && value.first == failSetting) {
        throw StateError('Setting rejected');
      }
      if (characteristic == StimUuids.stimulationStatus) {
        final target = StimStatus.fromCode(value.first);
        if (target == StimStatus.rampDown && failStop) {
          throw StateError('Stop rejected');
        }
        if (target != StimStatus.rampUp || !delayRampUpState) status = target;
      }
    } finally {
      outstanding--;
    }
  }

  Iterable<(String, List<int>)> get statusWrites =>
      writes.where((entry) => entry.$1 == StimUuids.stimulationStatus);
}

StimSession _session(FakeAsync time, {bool poll = false}) => StimSession(
  now: () => DateTime.utc(2026).add(time.elapsed),
  pollAutomatically: poll,
);

void _complete(FakeAsync time, Future<void> future, {Matcher? error}) {
  var completed = false;
  Object? failure;
  future.then(
    (_) {
      completed = true;
    },
    onError: (Object value) {
      completed = true;
      failure = value;
    },
  );
  time.flushMicrotasks();
  expect(
    completed,
    isTrue,
    reason: 'Expected operation to finish without advancing time',
  );
  expect(failure, error ?? isNull);
}

void _start(FakeAsync time, StimSession session, FakeTransport transport) {
  transport.status = StimStatus.userDetected;
  _complete(time, session.refresh());
  _complete(time, session.command(StimStatus.rampUp));
  expect(session.remainingSeconds, 1800);
}

void main() {
  test(
    'intentional disconnect stops a start whose status has not advanced yet',
    () {
      fakeAsync((time) {
        final transport = FakeTransport()..delayRampUpState = true;
        final session = _session(time);
        _complete(time, session.attach(transport));
        _start(time, session, transport);
        expect(session.status, StimStatus.userDetected);
        _complete(time, session.prepareDisconnect());
        expect(transport.statusWrites.map((entry) => entry.$2.first), [4, 6]);
        session.dispose();
      });
    },
  );

  test(
    'concurrent start commands cannot both pass the same preflight state',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        transport.status = StimStatus.userDetected;
        _complete(time, session.refresh());
        final first = session.command(StimStatus.rampUp);
        Object? failure;
        final second = session.command(StimStatus.rampUp).catchError((
          Object error,
        ) {
          failure = error;
        });
        _complete(time, Future.wait([first, second]).then((_) {}));
        expect(failure, isStateError);
        expect(transport.statusWrites.map((entry) => entry.$2.first), [4]);
        session.dispose();
      });
    },
  );

  test(
    'DFU preparation queues a fresh read even when telemetry polling is in flight',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        final held = Completer<List<int>>();
        transport.heldRead = held;
        final refresh = session.refresh();
        transport.status = StimStatus.currentHold;
        Object? failure;
        final preparation = session.prepareDfu().catchError((Object error) {
          failure = error;
        });
        held.complete([StimStatus.idle.code]);
        _complete(time, Future.wait([refresh, preparation]).then((_) {}));
        expect(failure, isStateError);
        expect(
          transport.writes.where(
            (entry) => entry.$1 == StimUuids.buttonlessDfu,
          ),
          isEmpty,
        );
        session.dispose();
      });
    },
  );

  test(
    'stale work from a replaced connection cannot change the new status',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport, deviceId: 'first'));
        final held = Completer<List<int>>();
        transport.heldRead = held;
        final refresh = session.refresh();
        session.detach();
        final next = FakeTransport()..status = StimStatus.userDetected;
        final attach = session.attach(next, deviceId: 'second');
        held.complete([StimStatus.currentHold.code]);
        _complete(time, Future.wait([refresh, attach]).then((_) {}));
        expect(session.status, StimStatus.userDetected);
        expect(session.remainingSeconds, isNull);
        expect(next.statusWrites, isEmpty);
        session.dispose();
      });
    },
  );

  test(
    'an active attachment with unknown start time preserves defaults and requests stop',
    () {
      fakeAsync((time) {
        final transport = FakeTransport()..status = StimStatus.currentHold;
        final session = _session(time);
        _complete(time, session.attach(transport));
        expect(
          transport.writes.where((entry) => entry.$1 == StimUuids.settings),
          isEmpty,
        );
        expect(transport.statusWrites.single.$2, [6]);
        expect(session.remainingSeconds, 0);
        session.dispose();
      });
    },
  );

  test(
    'initialization is ordered and enables start only after all acknowledgements',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        expect(transport.writes.map((entry) => entry.$2.first), [
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
        expect(session.ready, isTrue);
        expect(session.defaultsApplied, isTrue);
        expect(transport.maximumOutstanding, 1);
        expect(session.canCommand(StimStatus.rampUp), isFalse);
        session.dispose();
      });
    },
  );

  test('a failed startup write fails closed while stop remains available', () {
    fakeAsync((time) {
      final transport = FakeTransport()..failSetting = 3;
      final session = _session(time);
      _complete(time, session.attach(transport), error: isStateError);
      expect(session.connected, isTrue);
      expect(session.ready, isFalse);
      expect(session.defaultsApplied, isFalse);
      expect(transport.writes.map((entry) => entry.$2.first), [1, 2, 3]);
      _complete(time, session.stop());
      expect(transport.statusWrites.single.$2, [6]);
      session.dispose();
    });
  });

  test(
    'command guard re-reads status instead of trusting the visible state',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        transport.status = StimStatus.userDetected;
        _complete(time, session.refresh());
        expect(session.canCommand(StimStatus.rampUp), isTrue);
        transport.status = StimStatus.idle;
        _complete(
          time,
          session.command(StimStatus.rampUp),
          error: isStateError,
        );
        expect(transport.statusWrites, isEmpty);
        session.dispose();
      });
    },
  );

  test(
    'stop preempts queued sounds and polls after the current GATT operation',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        _start(time, session, transport);
        final held = Completer<List<int>>();
        transport.heldRead = held;
        final refresh = session.refresh();
        Object? beepError;
        final beep = session.beep().catchError((Object error) {
          beepError = error;
        });
        final stop = session.stop();
        final before = transport.calls.length;
        held.complete([StimStatus.rampUp.code]);
        _complete(time, Future.wait([refresh, beep, stop]).then((_) {}));
        expect(transport.calls[before], 'write:${StimUuids.stimulationStatus}');
        expect(beepError, isStateError);
        expect(
          transport.writes.where((entry) => entry.$1 == StimUuids.sound),
          isEmpty,
        );
        expect(transport.maximumOutstanding, 1);
        session.dispose();
      });
    },
  );

  test(
    'melody delay never blocks a stop and remaining notes are cancelled',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        Object? melodyError;
        final melody = session.playMelody().catchError((Object error) {
          melodyError = error;
        });
        time.flushMicrotasks();
        expect(
          transport.writes.where((entry) => entry.$1 == StimUuids.sound).length,
          1,
        );
        _complete(time, session.stop());
        _complete(time, melody);
        time.elapse(const Duration(seconds: 30));
        expect(melodyError, isStateError);
        expect(
          transport.writes.where((entry) => entry.$1 == StimUuids.sound).length,
          1,
        );
        session.dispose();
      });
    },
  );

  test(
    'deadline survives hold transition and failed stop without granting another 30 minutes',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        _start(time, session, transport);
        time.elapse(const Duration(seconds: 120));
        transport.status = StimStatus.currentHold;
        _complete(time, session.refresh());
        expect(session.remainingSeconds, 1680);
        transport.failStop = true;
        time.elapse(const Duration(seconds: 1680));
        time.flushMicrotasks();
        expect(session.remainingSeconds, 0);
        expect(
          transport.statusWrites.where((entry) => entry.$2.first == 6).length,
          1,
        );
        _complete(time, session.refresh());
        time.elapse(const Duration(seconds: 1800));
        expect(session.remainingSeconds, 0);
        expect(
          transport.statusWrites.where((entry) => entry.$2.first == 6).length,
          1,
        );
        expect(
          session.logs.any((entry) => entry.contains('Ramp down failed')),
          isTrue,
        );
        session.dispose();
      });
    },
  );

  test('delayed RampUp telemetry does not discard the start deadline', () {
    fakeAsync((time) {
      final transport = FakeTransport()..delayRampUpState = true;
      final session = _session(time);
      _complete(time, session.attach(transport));
      _start(time, session, transport);
      time.elapse(const Duration(seconds: 3));
      transport.status = StimStatus.rampUp;
      _complete(time, session.refresh());
      expect(session.remainingSeconds, 1797);
      expect(transport.statusWrites.length, 1);
      session.dispose();
    });
  });

  test('active reconnect preserves device settings and known deadline', () {
    fakeAsync((time) {
      final transport = FakeTransport();
      final session = _session(time);
      _complete(time, session.attach(transport, deviceId: 'headset-one'));
      _start(time, session, transport);
      time.elapse(const Duration(seconds: 90));
      session.detach();
      final next = FakeTransport()..status = StimStatus.currentHold;
      _complete(time, session.attach(next, deviceId: 'headset-one'));
      expect(next.writes, isEmpty);
      expect(session.defaultsApplied, isFalse);
      expect(session.remainingSeconds, 1710);
      session.dispose();
    });
  });

  test(
    'background requests gentle ramp down and retains the deadline during ramp',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        _start(time, session, transport);
        _complete(time, session.onBackground());
        expect(transport.status, StimStatus.rampDown);
        expect(session.remainingSeconds, 1800);
        expect(session.canCommand(StimStatus.rampUp), isFalse);
        transport.status = StimStatus.idle;
        _complete(time, session.onResume());
        expect(session.remainingSeconds, isNull);
        session.dispose();
      });
    },
  );

  test('slow polling never overlaps or builds an unbounded backlog', () {
    fakeAsync((time) {
      final transport = FakeTransport();
      final session = _session(time, poll: true);
      _complete(time, session.attach(transport));
      final held = Completer<List<int>>();
      transport.heldRead = held;
      final before = transport.calls.length;
      time.elapse(const Duration(seconds: 8));
      expect(transport.calls.length, before + 1);
      held.complete([StimStatus.idle.code]);
      time.flushMicrotasks();
      expect(transport.calls.length, before + 6);
      expect(transport.maximumOutstanding, 1);
      session.dispose();
    });
  });

  test(
    'timeout invalidates the session and late results cannot restore it',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        final held = Completer<List<int>>();
        transport.heldRead = held;
        final refresh = session.refresh();
        time.elapse(const Duration(seconds: 10));
        _complete(time, refresh);
        expect(session.connected, isFalse);
        held.complete([StimStatus.userDetected.code]);
        time.flushMicrotasks();
        expect(session.status, StimStatus.unknown);
        expect(session.ready, isFalse);
        session.dispose();
      });
    },
  );

  test(
    'DFU uses a fresh idle read and rejects a device that began stimulation',
    () {
      fakeAsync((time) {
        final transport = FakeTransport();
        final session = _session(time);
        _complete(time, session.attach(transport));
        expect(session.canDfu, isTrue);
        transport.status = StimStatus.rampUp;
        _complete(time, session.enterBootloader(), error: isStateError);
        expect(
          transport.writes.where(
            (entry) => entry.$1 == StimUuids.buttonlessDfu,
          ),
          isEmpty,
        );
        session.dispose();
      });
    },
  );
}
