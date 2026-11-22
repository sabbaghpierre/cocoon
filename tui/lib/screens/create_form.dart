/// Create wizard: sequential single-field steps (gum-style).
/// One focused TextField per input step (its onKeyEvent handles Esc);
/// selection steps use a local Focusable (no competing focus).
library;

import 'package:nocterm/nocterm.dart';

import '../backend.dart';
import '../models.dart';

enum _Step { name, url, engine, customBin, icon, confirm, working, done }

class CreateScreen extends StatefulComponent {
  final Backend backend;
  final VoidCallback onBack;

  const CreateScreen({super.key, required this.backend, required this.onBack});

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  _Step step = _Step.name;
  final nameCtrl = TextEditingController();
  final urlCtrl = TextEditingController();
  final iconCtrl = TextEditingController();
  final customBinCtrl = TextEditingController();
  // Browser picker (from `cocoon browsers --json`). Falls back to the
  // legacy chrome/firefox toggle when detection is unavailable or empty.
  List<Browser> browsers = const [];
  int browserIndex = 0;
  bool browsersLoading = true;
  bool engineIsChrome = true;
  String? error;
  String? result;
  bool resultOk = false;

  @override
  void initState() {
    super.initState();
    _loadBrowsers();
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    urlCtrl.dispose();
    iconCtrl.dispose();
    customBinCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBrowsers() async {
    try {
      final all = await component.backend.listBrowsers();
      if (!mounted) return;
      final usable = supportedBrowsers(all);
      setState(() {
        browsers = usable;
        browserIndex = 0;
        browsersLoading = false;
      });
    } on BackendException {
      // Detection unavailable (e.g. old CLI): fall back to the legacy
      // engine toggle. Genuine defects must surface, so nothing else is
      // swallowed here.
      if (!mounted) return;
      setState(() => browsersLoading = false);
    }
  }

  bool get _useBrowserList => browsers.isNotEmpty;

  int get _safeBrowserIndex =>
      browsers.isEmpty ? 0 : browserIndex.clamp(0, browsers.length - 1).toInt();

  // Browser/engine choices: detected browsers (or the legacy 2-way toggle),
  // plus two explicit custom-binary choices (chrome / firefox engine).
  int get _baseOptionCount => _useBrowserList ? browsers.length : 2;
  int get _optionCount => _baseOptionCount + 2;
  int get _safeOptionIndex => browserIndex.clamp(0, _optionCount - 1).toInt();
  bool get _customChosen => _safeOptionIndex >= _baseOptionCount;
  bool get _customIsChrome => _safeOptionIndex == _baseOptionCount;

  String get _engine {
    if (_customChosen) return _customIsChrome ? 'chrome' : 'firefox';
    return _useBrowserList
        ? _pickedEngine
        : (engineIsChrome ? 'chrome' : 'firefox');
  }

  String get _pickedEngine {
    if (!_useBrowserList) return engineIsChrome ? 'chrome' : 'firefox';
    final engine = browsers[_safeBrowserIndex].engine;
    switch (engine) {
      case 'chromium':
      case 'chrome':
        return 'chrome';
      case 'firefox':
      case 'ff':
        return 'firefox';
      default:
        // Never silently map an unknown engine to firefox.
        return engine;
    }
  }

  String? get _pickedBrowser =>
      _useBrowserList && !_customChosen ? browsers[_safeBrowserIndex].id : null;

  String? get _pickedBrowserBin {
    if (!_customChosen) return null;
    final path = customBinCtrl.text.trim();
    return path.isEmpty ? null : path;
  }

  static const _baseOrder = [_Step.name, _Step.url, _Step.engine];
  List<_Step> get _order => _customChosen
      ? const [..._baseOrder, _Step.customBin, _Step.icon]
      : const [..._baseOrder, _Step.icon];
  List<_Step> get _flow => [
    ..._order,
    _Step.confirm,
    _Step.working,
    _Step.done,
  ];

  void _next() {
    if (step == _Step.name && nameCtrl.text.trim().isEmpty) {
      setState(() => error = 'Name is required.');
      return;
    }
    if (step == _Step.url && urlCtrl.text.trim().isEmpty) {
      setState(() => error = 'URL is required.');
      return;
    }
    if (step == _Step.customBin && customBinCtrl.text.trim().isEmpty) {
      setState(() => error = 'Binary path is required.');
      return;
    }
    final i = _flow.indexOf(step);
    if (i < 0 || i + 1 >= _flow.length) return;
    setState(() {
      error = null;
      step = _flow[i + 1];
    });
  }

  void _back() {
    final i = _order.indexOf(step);
    if (i <= 0) {
      component.onBack();
    } else {
      setState(() {
        error = null;
        step = _order[i - 1];
      });
    }
  }

  /// Field-level key interceptor: Esc goes back, everything else types.
  bool _fieldKeys(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      _back();
      return true;
    }
    return false;
  }

  Future<void> _submit() async {
    setState(() {
      step = _Step.working;
      error = null;
    });
    try {
      final r = await component.backend.createApp(
        name: nameCtrl.text.trim(),
        url: urlCtrl.text.trim(),
        engine: _engine,
        browser: _pickedBrowser,
        icon: iconCtrl.text.trim().isEmpty ? null : iconCtrl.text.trim(),
        browserBin: _pickedBrowserBin,
      );
      if (!mounted) return;
      setState(() {
        result = r.output.trim().isEmpty
            ? (r.ok ? 'Created.' : 'Failed with no output.')
            : r.output.trim();
        resultOk = r.ok;
        step = _Step.done;
      });
    } on BackendException catch (e) {
      if (!mounted) return;
      setState(() {
        result = e.message;
        resultOk = false;
        step = _Step.done;
      });
    }
  }

  /// Selection-step keys (engine/confirm/done): no TextField mounted here.
  bool _selectKeys(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      if (step == _Step.confirm || step == _Step.done) {
        component.onBack();
      } else {
        _back();
      }
      return true;
    }
    if (step == _Step.engine) {
      if (event.logicalKey == LogicalKey.arrowUp) {
        setState(() {
          final i = (_safeOptionIndex - 1 + _optionCount) % _optionCount;
          browserIndex = i;
          if (!_useBrowserList && i < 2) engineIsChrome = i == 0;
        });
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        setState(() {
          final i = (_safeOptionIndex + 1) % _optionCount;
          browserIndex = i;
          if (!_useBrowserList && i < 2) engineIsChrome = i == 0;
        });
        return true;
      }
      if (event.logicalKey == LogicalKey.enter) {
        _next();
        return true;
      }
      if (event.character == 'e' && !_useBrowserList && !_customChosen) {
        setState(() => engineIsChrome = !engineIsChrome);
        return true;
      }
      return false;
    }
    if (step == _Step.confirm) {
      final ch = event.character;
      if (ch == 'y' || event.logicalKey == LogicalKey.enter) {
        _submit();
        return true;
      }
      if (ch == 'n') {
        setState(() {
          error = null;
          step = _Step.icon;
        });
        return true;
      }
      return false;
    }
    if (step == _Step.done) {
      component.onBack();
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Create webapp (Enter: next · Esc: back)',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.yellow),
        ),
        const SizedBox(height: 1),
        _stepBody(),
        if (error != null) ...[
          const SizedBox(height: 1),
          Text(
            'Error: $error',
            style: const TextStyle(color: Colors.brightRed),
          ),
        ],
      ],
    );
    // Selection steps own a Focusable (no fields mounted); input steps
    // render bare so the focused TextField receives keys exclusively.
    if (step == _Step.engine || step == _Step.confirm || step == _Step.done) {
      return Focusable(
        focused: true,
        onKeyEvent: (event) => _selectKeys(event),
        child: Container(padding: const EdgeInsets.all(1), child: body),
      );
    }
    if (step == _Step.working) {
      return Container(padding: const EdgeInsets.all(1), child: body);
    }
    return Container(padding: const EdgeInsets.all(1), child: body);
  }

  Component _stepBody() {
    switch (step) {
      case _Step.name:
        return TextField(
          key: const ValueKey('create-name'),
          controller: nameCtrl,
          focused: true,
          placeholder: 'Name — My favorite web app',
          onKeyEvent: (event) => _fieldKeys(event),
          onSubmitted: (_) => _next(),
        );
      case _Step.url:
        return TextField(
          key: const ValueKey('create-url'),
          controller: urlCtrl,
          focused: true,
          placeholder: 'URL — https://example.com',
          onKeyEvent: (event) => _fieldKeys(event),
          onSubmitted: (_) => _next(),
        );
      case _Step.engine:
        if (browsersLoading) {
          return const Text('Detecting installed browsers…');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_useBrowserList)
              for (var i = 0; i < browsers.length; i++)
                _engineRow(browsers[i].label, i == _safeOptionIndex)
            else ...[
              _engineRow(
                'chrome  (--app SSB window)',
                !_customChosen && _safeOptionIndex == 0,
              ),
              _engineRow(
                'firefox (minimal-UI profile)',
                !_customChosen && _safeOptionIndex == 1,
              ),
            ],
            const SizedBox(height: 1),
            _engineRow(
              'custom binary path (chrome engine)',
              _customChosen && _customIsChrome,
            ),
            _engineRow(
              'custom binary path (firefox engine)',
              _customChosen && !_customIsChrome,
            ),
            const SizedBox(height: 1),
            const Text(
              'up/down: select · Enter: confirm · custom paths send an explicit engine',
              style: TextStyle(color: Colors.brightBlack),
            ),
          ],
        );
      case _Step.customBin:
        return TextField(
          key: const ValueKey('create-browser-bin'),
          controller: customBinCtrl,
          focused: true,
          placeholder: 'Binary path — /path/to/browser (spaces OK)',
          onKeyEvent: (event) => _fieldKeys(event),
          onSubmitted: (_) => _next(),
        );
      case _Step.icon:
        return TextField(
          key: const ValueKey('create-icon'),
          controller: iconCtrl,
          focused: true,
          placeholder: 'Icon URL or file (empty: auto-fetch favicon)',
          onKeyEvent: (event) => _fieldKeys(event),
          onSubmitted: (_) => _next(),
        );
      case _Step.confirm:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Create "${nameCtrl.text.trim()}"?'),
            Text(
              '  ${_pickedBrowser ?? _pickedBrowserBin ?? _engine} · ${urlCtrl.text.trim()}${iconCtrl.text.trim().isEmpty ? '' : ' · custom icon'}',
            ),
            const SizedBox(height: 1),
            const Text('y/Enter: create · n: back to icon · Esc: exit'),
          ],
        );
      case _Step.working:
        return const Text('Creating…');
      case _Step.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              result ?? '',
              style: TextStyle(
                color: resultOk ? Colors.green : Colors.brightRed,
              ),
            ),
            const SizedBox(height: 1),
            const Text('Press any key for dashboard.'),
          ],
        );
    }
  }

  Component _engineRow(String label, bool highlighted) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: highlighted
          ? BoxDecoration(color: Color.fromRGB(30, 40, 50))
          : null,
      child: Text(
        '${highlighted ? '>' : ' '} $label',
        style: TextStyle(
          color: highlighted ? Colors.brightWhite : Colors.white,
        ),
      ),
    );
  }
}
