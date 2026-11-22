/// Subprocess bridge to the unified `cocoon` CLI.
/// The TUI never reimplements CLI logic: every read goes through --json,
/// every mutation through the CLI's non-interactive subcommands.
/// The command runner is injectable so tests can fake the CLI.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Injectable command runner (defaults to [Process.run]).
typedef RunFn = Future<ProcessResult> Function(String exe, List<String> args);

/// Injectable probe starter (defaults to spawning the real CLI).
typedef ProbeStarter = Future<ProbeSession> Function(String? name);

Future<ProcessResult> _defaultRun(String exe, List<String> args) =>
    Process.run(exe, args, stdoutEncoding: utf8, stderrEncoding: utf8);

class BackendException implements Exception {
  final String message;
  const BackendException(this.message);

  @override
  String toString() => 'BackendException: $message';
}

class CommandResult {
  final bool ok;
  final String output;
  const CommandResult({required this.ok, required this.output});
}

class Backend {
  /// The single unified executable; features are selected by subcommand.
  static const exe = 'cocoon';

  final RunFn run;
  final ProbeStarter probeStarter;

  Backend({RunFn? run, ProbeStarter? probeStarter})
    : run = run ?? _defaultRun,
      probeStarter = probeStarter ?? _defaultProbeStarter;

  /// Run a CLI command, mapping "binary missing" to a helpful error.
  Future<ProcessResult> _guarded(List<String> args) async {
    try {
      return await run(exe, args);
    } on ProcessException catch (e) {
      throw BackendException(
        '$exe not found on PATH. Install Cocoon first:\n'
        '  curl -fsSL https://raw.githubusercontent.com/sabbaghpierre/cocoon/main/install.sh | bash\n'
        '($e)',
      );
    }
  }

  static String _text(ProcessResult r) => '${r.stdout ?? ''}${r.stderr ?? ''}';

  /// JSON output is always UTF-8; never assume [ProcessResult.stdout] is a
  /// String (injectable fakes and unencoded runs may hand back bytes).
  static String _stdout(ProcessResult r) {
    final out = r.stdout;
    if (out is String) return out;
    if (out is List<int>) return utf8.decode(out);
    return out?.toString() ?? '';
  }

  Future<List<WebApp>> listApps() async {
    final r = await _guarded(const ['list', '--json']);
    if (r.exitCode != 0) {
      throw BackendException('cocoon list failed:\n${_text(r)}');
    }
    try {
      return parseAppList(_stdout(r));
    } on FormatException catch (e) {
      throw BackendException('could not parse cocoon list output: $e');
    }
  }

  Future<CommandResult> createApp({
    required String name,
    required String url,
    required String engine,
    String? browser,
    String? icon,
    String? browserBin,
  }) async {
    final args = ['create', '--name', name, '--url', url, '--engine', engine];
    if (browser != null && browser.trim().isNotEmpty) {
      args.addAll(['--browser', browser.trim()]);
    }
    if (browserBin != null && browserBin.trim().isNotEmpty) {
      args.addAll(['--browser-bin', browserBin.trim()]);
    }
    if (icon != null && icon.trim().isNotEmpty) {
      args.addAll(['--icon', icon.trim()]);
    }
    final r = await _guarded(args);
    return CommandResult(ok: r.exitCode == 0, output: _text(r));
  }

  /// Detected browsers (`cocoon browsers --json`), natively-installable
  /// first. Throws [BackendException] when the CLI is too old (no
  /// `browsers` subcommand) or the output is unparseable.
  Future<List<Browser>> listBrowsers() async {
    final r = await _guarded(const ['browsers', '--json']);
    if (r.exitCode != 0) {
      throw BackendException('cocoon browsers failed:\n${_text(r)}');
    }
    try {
      return parseBrowserList(_stdout(r));
    } on FormatException catch (e) {
      throw BackendException('could not parse cocoon browsers output: $e');
    }
  }

  Future<CommandResult> removeApps(
    List<String> names, {
    bool purge = false,
  }) async {
    final args = <String>['remove', if (purge) '--purge', ...names];
    final r = await _guarded(args);
    return CommandResult(ok: r.exitCode == 0, output: _text(r));
  }

  /// Launch an installed webapp by name (`cocoon open NAME`).
  Future<CommandResult> openApp(String name) async {
    final r = await _guarded(['open', name]);
    return CommandResult(ok: r.exitCode == 0, output: _text(r));
  }

  /// Edit an installed webapp (`cocoon edit ...`). No TUI screen yet.
  Future<CommandResult> editApp(
    String name, {
    Map<String, String>? fields,
  }) async {
    final args = <String>['edit', name];
    fields?.forEach((key, value) => args.addAll(['--$key', value]));
    final r = await _guarded(args);
    return CommandResult(ok: r.exitCode == 0, output: _text(r));
  }

  /// Change an installed webapp's icon (`cocoon icon ...`). No TUI screen yet.
  Future<CommandResult> setIcon(String name, String icon) async {
    final r = await _guarded(['icon', name, icon]);
    return CommandResult(ok: r.exitCode == 0, output: _text(r));
  }

  /// doctor exit code 1 on warnings is NORMAL — parse stdout regardless.
  Future<DoctorReport> doctor([String? name]) async {
    final r = await _guarded(['doctor', '--json', if (name != null) name]);
    try {
      return parseDoctorReport(_stdout(r));
    } on FormatException {
      throw BackendException(
        'could not parse cocoon doctor output:\n${_text(r)}',
      );
    }
  }

  /// Start a streaming probe (`cocoon doctor --probe`). Lines arrive on the
  /// returned subscription; caller must cancel + kill (see [ProbeSession.stop]).
  Future<ProbeSession> startProbe(String? name) => probeStarter(name);
}

/// Default probe starter: spawns the real CLI.
Future<ProbeSession> _defaultProbeStarter(String? name) async {
  Process proc;
  try {
    proc = await Process.start(Backend.exe, [
      'doctor',
      '--probe',
      if (name != null) name,
    ]);
  } on ProcessException catch (e) {
    throw BackendException('could not start probe: $e');
  }
  return ProbeSession.fromProcess(proc);
}

/// A live `cocoon doctor --probe` process with line-streamed stdout + stderr.
class ProbeSession {
  final Stream<List<int>> _out;
  final Stream<List<int>> _err;
  final Future<int> _exitCode;
  final Future<void> Function() _onStop;
  bool _stopped = false;

  ProbeSession({
    required Stream<List<int>> stdout,
    required Future<int> exitCode,
    required Future<void> Function() onStop,
    Stream<List<int>>? stderr,
  }) : _out = stdout,
       _err = stderr ?? Stream<List<int>>.empty(),
       _exitCode = exitCode,
       _onStop = onStop;

  factory ProbeSession.fromProcess(Process proc) => ProbeSession(
    stdout: proc.stdout,
    stderr: proc.stderr,
    exitCode: proc.exitCode,
    onStop: () async {
      proc.kill(ProcessSignal.sigterm);
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        proc.kill(ProcessSignal.sigkill);
      }
    },
  );

  /// Merge stdout and stderr so compositor diagnostics are not lost, then
  /// decode both through one UTF-8/line splitter pipeline.
  Stream<ProbeSample> get lines {
    final merged = StreamController<List<int>>();
    final subs = <StreamSubscription<List<int>>>[];
    var pending = 2;

    void onDone() {
      pending--;
      if (pending == 0 && !merged.isClosed) merged.close();
    }

    void pump(Stream<List<int>> source) {
      subs.add(
        source.listen(
          merged.add,
          onError: merged.addError,
          onDone: onDone,
          cancelOnError: false,
        ),
      );
    }

    merged.onCancel = () async {
      for (final sub in subs) {
        await sub.cancel();
      }
    };

    pump(_out);
    pump(_err);
    return merged.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(parseProbeLine);
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _onStop();
    try {
      await _exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
