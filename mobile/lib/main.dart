import 'package:flutter/material.dart';

import 'src/app_controller.dart';
import 'src/home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenFlowApp());
}

class OpenFlowApp extends StatefulWidget {
  const OpenFlowApp({super.key, this.controller});

  /// A caller supplying a controller retains ownership of it.
  final OpenFlowController? controller;

  @override
  State<OpenFlowApp> createState() => _OpenFlowAppState();
}

class _OpenFlowAppState extends State<OpenFlowApp> {
  late final OpenFlowController _controller =
      widget.controller ?? OpenFlowController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff006b68),
        brightness: brightness,
      ),
    );

    return MaterialApp(
      title: 'OpenFlow',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: OpenFlowHome(controller: _controller),
    );
  }
}
