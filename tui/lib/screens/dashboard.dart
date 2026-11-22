/// Dashboard: app list with keyboard navigation + screen shortcuts.
library;

import 'package:nocterm/nocterm.dart';

import '../app.dart' show AppScreen;
import '../backend.dart';
import '../models.dart';

/// Baked at release time: dart compile exe -DAPP_VERSION=$(cat VERSION).
/// Plain `dart run`/`dart test` builds report 'dev'.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

class DashboardScreen extends StatefulComponent {
  final Backend backend;
  final void Function(AppScreen) onOpen;

  const DashboardScreen({
    super.key,
    required this.backend,
    required this.onOpen,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<WebApp>? apps;
  String? error;
  String? notice;
  bool noticeOk = true;
  int selected = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      apps = null;
      error = null;
      notice = null;
    });
    try {
      final loaded = await component.backend.listApps();
      if (!mounted) return;
      setState(() {
        apps = loaded;
        if (selected < 0 || selected >= loaded.length) selected = 0;
      });
    } on BackendException catch (e) {
      if (!mounted) return;
      setState(() => error = e.message);
    }
  }

  Future<void> _openSelected() async {
    final items = apps;
    if (items == null || selected < 0 || selected >= items.length) return;
    final name = items[selected].name;
    try {
      final r = await component.backend.openApp(name);
      if (!mounted) return;
      setState(() {
        noticeOk = r.ok;
        notice = r.ok
            ? (r.output.trim().isEmpty ? 'Opened $name' : r.output.trim())
            : (r.output.trim().isEmpty
                  ? 'Could not open $name'
                  : r.output.trim());
      });
    } on BackendException catch (e) {
      if (!mounted) return;
      setState(() {
        noticeOk = false;
        notice = e.message;
      });
    }
  }

  bool _onKey(KeyboardEvent event) {
    final items = apps ?? const <WebApp>[];
    if (event.logicalKey == LogicalKey.enter) {
      _openSelected();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      if (items.isNotEmpty) {
        setState(() => selected = (selected + 1) % items.length);
      }
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowUp) {
      if (items.isNotEmpty) {
        setState(() => selected = (selected - 1 + items.length) % items.length);
      }
      return true;
    }
    final ch = event.character;
    if (ch == 'j') {
      if (items.isNotEmpty) {
        setState(() => selected = (selected + 1) % items.length);
      }
      return true;
    }
    if (ch == 'k') {
      if (items.isNotEmpty) {
        setState(() => selected = (selected - 1 + items.length) % items.length);
      }
      return true;
    }
    switch (ch) {
      case 'c':
        component.onOpen(AppScreen.create);
        return true;
      case 'x':
        component.onOpen(AppScreen.remove);
        return true;
      case 'd':
        component.onOpen(AppScreen.doctor);
        return true;
      case 'p':
        component.onOpen(AppScreen.probe);
        return true;
      case '?':
        component.onOpen(AppScreen.help);
        return true;
      case 'r':
        _load();
        return true;
      case 'q':
        shutdownApp();
        return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final items = apps;
    final err = error;
    return Focusable(
      focused: true,
      onKeyEvent: (event) => _onKey(event),
      child: Container(
        padding: const EdgeInsets.all(1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Cocoon $appVersion — isolated webapps',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.yellow,
              ),
            ),
            const SizedBox(height: 1),
            if (err != null)
              Text(
                'Error: $err\nPress r to retry, q to quit.',
                style: const TextStyle(color: Colors.brightRed),
              )
            else if (items == null)
              const Text('Loading…')
            else if (items.isEmpty)
              const Text(
                'No webapps installed.\nPress c to create one, ? for help.',
              )
            else
              Expanded(
                child: ListView(
                  keyboardScrollable: false,
                  children: [
                    for (var i = 0; i < items.length; i++)
                      _row(items[i], i == selected),
                  ],
                ),
              ),
            if (notice != null)
              Text(
                notice!,
                style: TextStyle(
                  color: noticeOk ? Colors.green : Colors.brightRed,
                ),
              ),
            const SizedBox(height: 1),
            const Text(
              'Enter open · c create · x remove · d doctor · p probe · '
              '? help · r refresh · q quit',
              style: TextStyle(color: Colors.brightBlack),
            ),
          ],
        ),
      ),
    );
  }

  Component _row(WebApp app, bool isSelected) {
    final line =
        '${app.name.padRight(22)} [${app.engine.padRight(7)}] ${app.url}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: isSelected
          ? BoxDecoration(color: Color.fromRGB(30, 40, 50))
          : null,
      child: Text(
        '${isSelected ? '>' : ' '} $line',
        style: TextStyle(color: isSelected ? Colors.brightWhite : Colors.white),
      ),
    );
  }
}
