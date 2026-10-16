import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'flow_firmware_screen.dart';
import 'protocol.dart';

class OpenFlowHome extends StatefulWidget {
  const OpenFlowHome({super.key, required this.controller});

  final OpenFlowController controller;

  @override
  State<OpenFlowHome> createState() => _OpenFlowHomeState();
}

class _OpenFlowHomeState extends State<OpenFlowHome>
    with WidgetsBindingObserver {
  final _connectionKey = GlobalKey();
  final _firmwareKey = GlobalKey();
  bool _downloadRouteOpen = false;

  OpenFlowController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_perform(controller.onResume));
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      unawaited(_perform(controller.onBackground));
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().replaceFirst(
        RegExp(r'^Exception: '),
        '',
      );
      controller.session.addLog(message);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _findFirmwareTarget({bool bootloader = false}) async {
    await controller.scan(bootloader: bootloader);
    if (!mounted) return;
    final target = _connectionKey.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
      );
    }
  }

  Future<void> _confirmFirmware() async {
    final target = controller.selected;
    final firmware = controller.firmwareName;
    if (target == null || firmware == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Install firmware?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Device: ${target.displayName}'),
              const SizedBox(height: 8),
              SelectableText(target.id),
              const SizedBox(height: 16),
              Text('Firmware: $firmware'),
              const SizedBox(height: 16),
              Text(
                target.bootloader
                    ? 'DFU recovery: the headset is already in update mode. '
                          'The selected ZIP will be sent directly to its bootloader.'
                    : 'Buttonless update: the app switches the headset into update '
                          'mode automatically. No headset button presses are needed.',
              ),
              const SizedBox(height: 12),
              const Text(
                'The device will restart during the update. Keep this app open '
                'and the device nearby until the transfer finishes.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install firmware'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _perform(() async {
      if (controller.selected?.id != target.id ||
          controller.firmwareName != firmware) {
        throw StateError(
          'The device or firmware changed. Review the update again.',
        );
      }
      await controller.startDfu();
    });
  }

  Future<void> _downloadFirmware() async {
    if (_downloadRouteOpen ||
        controller.working ||
        controller.updating ||
        (controller.session.connected && !controller.session.canDfu) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _downloadRouteOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => FlowFirmwareScreen(controller: controller),
        ),
      );
      if (!mounted) return;
      final target = _firmwareKey.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 250),
        );
      }
    } finally {
      _downloadRouteOpen = false;
    }
  }

  Future<void> _copyLogs() async {
    await Clipboard.setData(
      ClipboardData(text: controller.session.logs.join('\n')),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Logs copied')));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.session]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: _downloadFirmware,
          child: const Text('OpenFlow'),
        ),
        actions: [
          if (controller.demo)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Chip(label: Text('DEMO')),
            ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (controller.demo) ...[
                    _notice(
                      Icons.science_outlined,
                      'Simulated demo · No Bluetooth connection or firmware '
                      'transfer. Values and device actions are simulated.',
                    ),
                    const SizedBox(height: 16),
                  ],
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final left = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          KeyedSubtree(
                            key: _connectionKey,
                            child: _connectionCard(),
                          ),
                          const SizedBox(height: 16),
                          KeyedSubtree(
                            key: _firmwareKey,
                            child: _firmwareCard(),
                          ),
                        ],
                      );
                      final right = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _stimulationCard(),
                          const SizedBox(height: 16),
                          _telemetryCard(),
                        ],
                      );
                      if (constraints.maxWidth < 800) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [left, const SizedBox(height: 16), right],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: left),
                          const SizedBox(width: 16),
                          Expanded(child: right),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  _logsCard(),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: _stopBar(),
    ),
  );

  Widget _connectionCard() {
    final session = controller.session;
    final selected = controller.selected;
    final canScan =
        !controller.working && !controller.updating && !session.connected;
    return _card('Connection', Icons.bluetooth, [
      Semantics(
        liveRegion: true,
        child: Text(
          session.connected
              ? (session.ready ? 'Connected · Ready' : 'Connected · Preparing')
              : (selected?.bootloader == true
                    ? 'DFU recovery device selected · Ready for firmware'
                    : 'Disconnected'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      const SizedBox(height: 8),
      Text('Bluetooth: ${controller.adapterState}'),
      if (selected != null) ...[
        const SizedBox(height: 8),
        Text(selected.displayName),
        SelectableText(
          selected.id,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: canScan && !controller.scanning
                ? () => _perform(() => controller.scan())
                : null,
            icon: const Icon(Icons.search),
            label: const Text('Find headset'),
          ),
          OutlinedButton.icon(
            onPressed: canScan && !controller.scanning
                ? () => _perform(() => controller.scan(bootloader: true))
                : null,
            icon: const Icon(Icons.system_update),
            label: const Text('Find bootloader'),
          ),
          if (controller.scanning)
            OutlinedButton.icon(
              onPressed: () => _perform(controller.stopScan),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop scan'),
            ),
          if (selected != null)
            TextButton(
              onPressed: !controller.working && !controller.updating
                  ? () => _perform(controller.disconnect)
                  : null,
              child: Text(session.connected ? 'Disconnect' : 'Clear selection'),
            ),
        ],
      ),
      if (controller.scanning) ...[
        const SizedBox(height: 16),
        const LinearProgressIndicator(semanticsLabel: 'Scanning for devices'),
        const SizedBox(height: 8),
        Text(
          controller.recoveryScan
              ? 'Searching for a headset already in DFU mode…'
              : 'Searching for nearby headsets…',
        ),
      ],
      if (controller.devices.isNotEmpty) ...[
        const SizedBox(height: 16),
        for (final device in controller.devices)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.all(12),
              ),
              onPressed:
                  !controller.working &&
                      !controller.updating &&
                      !session.connected
                  ? () => _perform(() => controller.connect(device))
                  : null,
              child: Row(
                children: [
                  Icon(
                    device.bootloader ? Icons.system_update : Icons.headphones,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(device.displayName),
                        Text(
                          '${device.bootloader ? 'Bootloader' : 'Headset'} '
                          '· ${device.rssi} dBm',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          device.id,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
      ] else if (!session.connected && !controller.scanning) ...[
        const SizedBox(height: 12),
        Text(
          controller.recoveryScan
              ? 'No DFU device found yet. Keep the headset nearby and powered on, '
                    'then try Recover interrupted update again.'
              : 'Use Find headset for normal use or a buttonless firmware update. '
                    'If an update was interrupted, use Recover interrupted update.',
        ),
      ],
    ]);
  }

  Widget _stimulationCard() {
    final session = controller.session;
    final available = !controller.working && !controller.updating;
    final seconds = session.remainingSeconds;
    return _card('Stimulation', Icons.monitor_heart_outlined, [
      Semantics(
        liveRegion: true,
        child: Text(
          session.connected ? session.status.label : 'No headset connected',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
      if (session.connected) Text('Device status code: ${session.status.code}'),
      const SizedBox(height: 12),
      Text(
        session.defaultsApplied
            ? 'Default settings applied · 2 mA target · 1900 s device limit'
            : 'Default settings have not been confirmed.',
      ),
      const Text(
        'Current is fixed at 0.002 A (2 mA). It cannot be adjusted here.',
      ),
      if (seconds != null) ...[
        const SizedBox(height: 16),
        Text(
          '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
          '${(seconds % 60).toString().padLeft(2, '0')}',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const Text('Until the app requests ramp down'),
      ],
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final status in [
            StimStatus.idle,
            StimStatus.selfDiagnostic,
            StimStatus.rampUp,
            StimStatus.rampDown,
          ])
            OutlinedButton(
              onPressed: available && session.canCommand(status)
                  ? () => _perform(() => session.command(status))
                  : null,
              child: Text(status.label),
            ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        'Ramp up is available after the headset reports User detected. '
        'The app requests ramp down after 30 minutes while it remains active. '
        'Leaving the foreground also requests ramp down. '
        'Phone timers cannot guarantee operation in the background.',
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          TextButton.icon(
            onPressed: available && session.ready && !session.busy
                ? () => _perform(session.refresh)
                : null,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
          TextButton(
            onPressed: available && session.canConfigure
                ? () => _perform(session.applyDefaults)
                : null,
            child: const Text('Apply defaults'),
          ),
          TextButton.icon(
            onPressed: available && session.ready && !session.busy
                ? () => _perform(session.beep)
                : null,
            icon: const Icon(Icons.volume_up_outlined),
            label: const Text('Beep'),
          ),
          TextButton.icon(
            onPressed: available && session.ready && !session.busy
                ? () => _perform(session.playMelody)
                : null,
            icon: const Icon(Icons.music_note_outlined),
            label: const Text('Melody'),
          ),
        ],
      ),
      if (session.busy || controller.working) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(
          semanticsLabel: 'Device operation in progress',
        ),
      ],
    ]);
  }

  Widget _telemetryCard() {
    final telemetry = controller.session.telemetry;
    return _card('Telemetry', Icons.data_usage, [
      const Text(
        'Read-only readings with raw characteristic bytes. Known types follow '
        'the original app; the current scale still needs hardware verification.',
      ),
      const SizedBox(height: 16),
      if (telemetry.isEmpty)
        const Text('Readings appear after connecting to a headset.'),
      if (telemetry.isNotEmpty && !controller.session.connected) ...[
        const Text('Disconnected · Last received readings'),
        const SizedBox(height: 12),
      ],
      for (final entry in telemetry.entries) ...[
        Text(entry.key, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(entry.value),
        const SizedBox(height: 16),
      ],
    ]);
  }

  Widget _firmwareCard() {
    final session = controller.session;
    final selected = controller.selected;
    final available =
        !controller.demo && !controller.working && !controller.updating;
    final canUpdate =
        available &&
        controller.firmwareName != null &&
        selected != null &&
        (selected.bootloader || session.canDfu);
    final progress = controller.dfuProgress;
    final canFind = available && !session.connected && !controller.scanning;
    return _card('Firmware update & recovery', Icons.system_update_outlined, [
      const Text(
        'Normal update: find and connect to the headset, choose the firmware ZIP, '
        'then Install firmware. The app enters update mode automatically.',
      ),
      const SizedBox(height: 8),
      const Text(
        'Interrupted update: if the headset starts in DFU mode, choose '
        'Recover interrupted update and select the device found. '
        'You can install the ZIP directly, even without a normal headset connection.',
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: canFind
                ? () => _perform(() => _findFirmwareTarget())
                : null,
            icon: const Icon(Icons.headphones),
            label: const Text('Find headset to update'),
          ),
          FilledButton.tonalIcon(
            onPressed: canFind
                ? () => _perform(() => _findFirmwareTarget(bootloader: true))
                : null,
            icon: const Icon(Icons.restore),
            label: const Text('Recover interrupted update'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (selected != null) ...[
        Text(
          selected.bootloader ? 'DFU recovery' : 'Buttonless update',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text('Selected device: ${selected.displayName}'),
        const SizedBox(height: 8),
      ],
      Text(controller.firmwareName ?? 'No firmware ZIP selected'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: available
                ? () => _perform(controller.chooseFirmware)
                : null,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose firmware ZIP'),
          ),
          FilledButton.icon(
            onPressed: canUpdate ? _confirmFirmware : null,
            icon: const Icon(Icons.install_mobile),
            label: const Text('Install firmware'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        controller.demo
            ? 'Firmware transfer is unavailable in the simulated demo.'
            : selected?.bootloader == true
            ? 'Ready to install directly in DFU mode. No normal connection is required.'
            : session.connected && !session.canDfu
            ? 'Return the headset to Idle before installing firmware.'
            : 'Compatibility with this headset’s older buttonless update mode '
                  'is enabled automatically.',
      ),
      if (controller.firmwareResult != null) ...[
        const SizedBox(height: 12),
        _notice(
          controller.firmwareNeedsRecovery
              ? Icons.restore
              : Icons.check_circle_outline,
          controller.firmwareResult!,
        ),
      ],
      if (controller.updating || progress != null) ...[
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: progress?.clamp(0, 1),
          semanticsLabel: 'Firmware transfer progress',
          semanticsValue: progress == null
              ? null
              : '${(progress * 100).round()}%',
        ),
        const SizedBox(height: 8),
        Text(
          progress == null
              ? 'Preparing firmware transfer…'
              : controller.updating
              ? 'Firmware transfer: ${(progress * 100).round()}%'
              : 'Last reported transfer: ${(progress * 100).round()}%. '
                    'See logs for the final update result.',
        ),
      ],
      if (controller.updating) ...[
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => _perform(controller.abortDfu),
          child: const Text('Abort firmware transfer'),
        ),
      ],
    ]);
  }

  Widget _logsCard() {
    final logs = controller.session.logs;
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        leading: const Icon(Icons.terminal),
        title: const Text('Connection & device logs'),
        subtitle: Text(
          '${logs.length} entries · Includes discovered GATT details',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: logs.isEmpty ? null : () => _perform(_copyLogs),
              icon: const Icon(Icons.copy),
              label: const Text('Copy logs'),
            ),
          ),
          if (logs.isEmpty)
            const Text('No events yet.')
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: SelectableText(
                  logs.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stopBar() => Material(
    elevation: 8,
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('stop-button'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
                minimumSize: const Size.fromHeight(56),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
              onPressed: controller.session.connected
                  ? () => _perform(controller.session.stop)
                  : null,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('STOP · Request ramp down'),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _notice(IconData icon, String message) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
      ],
    ),
  );

  Widget _card(String title, IconData icon, List<Widget> children) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    ),
  );
}
