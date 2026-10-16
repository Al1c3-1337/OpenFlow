import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'flow_firmware_service.dart';

/// Downloads a firmware package without starting a headset update.
class FlowFirmwareScreen extends StatefulWidget {
  const FlowFirmwareScreen({super.key, required this.controller, this.service});

  final OpenFlowController controller;

  /// A route-scoped service. This screen closes it, including when injected,
  /// so leaving the route cancels any unfinished authenticated request.
  final FlowFirmwareService? service;

  @override
  State<FlowFirmwareScreen> createState() => _FlowFirmwareScreenState();
}

class _FlowFirmwareScreenState extends State<FlowFirmwareScreen> {
  static const _subscriptionReminder =
      'Please check that you have a valid Flow subscription.';

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  late final FlowFirmwareService _service;
  SavedFirmware? _saved;
  bool _loadingSaved = true;
  bool _downloading = false;
  bool _savingCopy = false;
  bool _selecting = false;
  double? _progress;
  String? _error;
  String? _notice;

  OpenFlowController get controller => widget.controller;
  bool get _busy => _loadingSaved || _downloading || _savingCopy || _selecting;

  String _downloadError(String message) =>
      message.contains(_subscriptionReminder)
      ? message
      : '$message $_subscriptionReminder';

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? FlowFirmwareService();
    unawaited(_loadSaved());
  }

  @override
  void dispose() {
    _service.close();
    _password.clear();
    _password.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    try {
      final saved = await _service.loadSavedFirmware();
      if (mounted) setState(() => _saved = saved);
    } on FlowFirmwareException catch (error) {
      if (mounted) setState(() => _error = _downloadError(error.message));
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = _downloadError(
            'The saved firmware could not be opened. Download it again.',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _loadingSaved = false);
    }
  }

  Future<void> _download() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
      _notice = null;
    });
    try {
      final saved = await _service.loginAndDownload(
        username: _email.text.trim(),
        password: _password.text,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _notice = 'Download verified. The firmware is saved on this device.';
      });
    } on FlowFirmwareException catch (error) {
      if (mounted) setState(() => _error = _downloadError(error.message));
    } catch (_) {
      // Never expose arbitrary network errors, response bodies or credentials.
      if (mounted) {
        setState(() {
          _error = _downloadError(
            'The firmware could not be downloaded. Please try again.',
          );
        });
      }
    } finally {
      if (mounted) {
        _password.clear();
        setState(() => _downloading = false);
      }
    }
  }

  Future<void> _saveCopy() async {
    final saved = _saved;
    if (_busy || saved == null) return;
    setState(() {
      _savingCopy = true;
      _error = null;
      _notice = null;
    });
    try {
      final bytes = await File(saved.path).readAsBytes();
      if (!mounted) return;
      final location = await FilePicker.saveFile(
        fileName: saved.name,
        bytes: bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Save firmware copy',
      );
      if (mounted && location != null) {
        setState(
          () => _notice = 'A firmware copy was saved to your chosen location.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              'The copy could not be saved. The download remains in OpenFlow.';
        });
      }
    } finally {
      if (mounted) setState(() => _savingCopy = false);
    }
  }

  Future<void> _useFirmware() async {
    final saved = _saved;
    if (_busy || saved == null) return;
    setState(() {
      _selecting = true;
      _error = null;
    });
    try {
      await controller.useSavedFirmware(saved);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } on FlowFirmwareException catch (error) {
      if (mounted) setState(() => _error = _downloadError(error.message));
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              'The firmware could not be selected. Wait for device operations '
              'to finish and check that the headset is Idle, then try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Future<void> _stop() async {
    try {
      await controller.session.stop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ramp down could not be confirmed. Try STOP again.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.session]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Download Flow firmware')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Flow account',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sign in to Flow Neuroscience to download the firmware package. '
                    'Your password and login token are used only for this download '
                    'and are not saved by OpenFlow.',
                  ),
                  if (controller.demo) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Demo mode: this download uses a real Flow account and internet '
                      'connection. Firmware installation is disabled in demo mode.',
                    ),
                  ],
                  const SizedBox(height: 20),
                  Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          key: const ValueKey('flow-email'),
                          controller: _email,
                          enabled: !_busy,
                          decoration: const InputDecoration(labelText: 'Email'),
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          enableSuggestions: false,
                          validator: (value) =>
                              RegExp(
                                r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                              ).hasMatch(value?.trim() ?? '')
                              ? null
                              : 'Enter your Flow account email.',
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const ValueKey('flow-password'),
                          controller: _password,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                          ),
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => unawaited(_download()),
                          validator: (value) => value == null || value.isEmpty
                              ? 'Enter your Flow account password.'
                              : null,
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          key: const ValueKey('flow-download'),
                          onPressed: _busy ? null : _download,
                          icon: const Icon(Icons.download),
                          label: const Text('Log in & download'),
                        ),
                      ],
                    ),
                  ),
                  if (_downloading) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _progress,
                      semanticsLabel: 'Firmware download progress',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _progress == null
                          ? 'Signing in and downloading…'
                          : 'Downloading firmware · ${(_progress! * 100).round()}%',
                    ),
                    const Text('Leaving this screen cancels the download.'),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                  if (_notice != null) ...[
                    const SizedBox(height: 16),
                    Semantics(liveRegion: true, child: Text(_notice!)),
                  ],
                  const SizedBox(height: 24),
                  if (_loadingSaved)
                    const LinearProgressIndicator(
                      semanticsLabel: 'Loading saved firmware',
                    ),
                  if (_saved != null) _savedCard(),
                  if (_savingCopy || _selecting) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      semanticsLabel: _savingCopy
                          ? 'Saving firmware copy'
                          : 'Selecting firmware',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: controller.session.connected ? _stopBar() : null,
    ),
  );

  Widget _savedCard() {
    final canUse =
        !_busy &&
        !controller.demo &&
        !controller.working &&
        !controller.updating &&
        (!controller.session.connected || controller.session.canDfu);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Saved firmware',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(_saved!.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Stored in OpenFlow on this device and available after restarting the app.',
            ),
            const SizedBox(height: 8),
            SelectableText(
              _saved!.path,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const ValueKey('flow-use-firmware'),
              onPressed: canUse ? _useFirmware : null,
              icon: const Icon(Icons.system_update_alt),
              label: const Text('Use for firmware update'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('flow-save-copy'),
              onPressed: _busy ? null : _saveCopy,
              icon: const Icon(Icons.save_alt),
              label: const Text('Save a copy…'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Use for firmware update prefills the update screen. '
              'Review the headset and choose Install firmware there to begin.',
            ),
            if (!controller.demo &&
                controller.session.connected &&
                !controller.session.canDfu) ...[
              const SizedBox(height: 8),
              const Text(
                'Return the headset to Idle and wait for device operations to finish before selecting firmware.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stopBar() => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('flow-stop-button'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                  minimumSize: const Size.fromHeight(56),
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: _stop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('STOP · Request ramp down'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
