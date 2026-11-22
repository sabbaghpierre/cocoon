/// End-to-end tests: real Backend against a single stub `cocoon` script.
/// The stub lives in a temp dir injected into the child-process PATH only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cocoon_tui/app.dart';
import 'package:cocoon_tui/backend.dart';
import 'package:cocoon_tui/screens/probe_screen.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

const _stubListJson =
    '[{"name":"E2EApp","engine":"firefox","url":"https://e2e.example","desktop":"/tmp/E2EApp.desktop"}]';

const _stubHead = r"""#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  list)
    if [[ "$1" == "--json" ]]; then printf '%s' '""";
const _stubTail = r"""'; else echo "E2EApp firefox https://e2e.example"; fi
    ;;
  create)
    echo "create $*" >> "$STUB_CALLS"
    echo Created
    ;;
  remove)
    echo "remove $*" >> "$STUB_CALLS"
    echo Removed
    ;;
  doctor)
    if [[ "$1" == "--json" ]]; then echo '{"apps":[],"orphans":[],"issue_count":0}'; exit 0; fi
    if [[ "$1" == "--probe" ]]; then shift; echo "  class=E2EApp desktop=E2EApp pid=1 caption=X"; sleep 0.2; echo "probe: done"; fi
    ;;
  browsers)
    echo '[]'
    ;;
  open)
    echo "open $*" >> "$STUB_CALLS"
    echo Opened
    ;;
esac
""";

late final Directory stubDir;
late final String stubPath;

/// Real Process.run with stub dir prepended to the CHILD's PATH only.
RunFn stubbedRun() {
  return (exe, args) => Process.run(
    exe,
    args,
    environment: {
      ...Platform.environment,
      'PATH': '$stubPath:${Platform.environment['PATH']}',
    },
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
}

Backend backendWithCalls(String logPath) => Backend(
  run: (exe, args) {
    return Process.run(
      exe,
      args,
      environment: {
        ...Platform.environment,
        'PATH': '$stubPath:${Platform.environment['PATH']}',
        'STUB_CALLS': logPath,
      },
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  },
);

KeyboardEvent charKey(String ch, LogicalKey logical) =>
    KeyboardEvent(logicalKey: logical, character: ch);

/// Real subprocesses need wall-clock time: poll a few rounds.
Future<void> settleReal(NoctermTester t) async {
  for (var i = 0; i < 10; i++) {
    await Future.delayed(const Duration(milliseconds: 200));
    await t.pump();
  }
}

File freshCallsLog() => File(
  '${Directory.systemTemp.path}/cocoon-e2e-calls-${DateTime.now().microsecondsSinceEpoch}.log',
);

void main() {
  setUpAll(() {
    stubDir = Directory.systemTemp.createTempSync('cocoon-stubs');
    stubPath = stubDir.path;
    File('$stubPath/cocoon')
        .writeAsStringSync(_stubHead + _stubListJson + _stubTail);
    Process.runSync('chmod', ['+x', '$stubPath/cocoon']);
  });

  tearDownAll(() {
    try {
      stubDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('e2e vs unified cocoon CLI', () {
    test('dashboard renders stub apps via real backend', () async {
      await testNocterm('e2e dashboard', (tester) async {
        await tester.pumpComponent(
          CocoonTui(backend: Backend(run: stubbedRun())),
        );
        await settleReal(tester);
        expect(tester.terminalState, containsText('E2EApp'));
      });
    });

    test('create submits through real backend to stub', () async {
      final calls = freshCallsLog();
      await testNocterm('e2e create', (tester) async {
        await tester.pumpComponent(
          CocoonTui(backend: backendWithCalls(calls.path)),
        );
        await tester.pump();
        await tester.sendKeyEvent(charKey('c', LogicalKey.keyC));
        await tester.pump();
        await tester.enterText('E2EMade');
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();
        await tester.enterText('https://made.example');
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();
        await tester.sendEnter();
        await settleReal(tester);
      });
      expect(
        calls.readAsStringSync(),
        contains(
          'create --name E2EMade --url https://made.example --engine chrome',
        ),
      );
      calls.deleteSync();
    });

    test('custom binary path reaches the stub CLI', () async {
      final calls = freshCallsLog();
      await testNocterm('e2e custom binary create', (tester) async {
        await tester.pumpComponent(
          CocoonTui(backend: backendWithCalls(calls.path)),
        );
        await tester.pump();
        await tester.sendKeyEvent(charKey('c', LogicalKey.keyC));
        await tester.pump();
        await tester.enterText('E2ECustom');
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();
        await tester.enterText('https://custom.example');
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();
        // No detected browsers: chrome/firefox rows, then 2 custom rows.
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendEnter();
        await tester.pump();
        await tester.enterText('/tmp/My Browser/firefox');
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();
        await tester.sendEnter();
        await tester.pump();
        await tester.sendEnter();
        await settleReal(tester);
      });
      expect(
        calls.readAsStringSync(),
        contains(
          'create --name E2ECustom --url https://custom.example --engine firefox --browser-bin /tmp/My Browser/firefox',
        ),
      );
      calls.deleteSync();
    });

    test('Enter launches app through cocoon open', () async {
      final calls = freshCallsLog();
      await testNocterm('e2e open', (tester) async {
        await tester.pumpComponent(
          CocoonTui(backend: backendWithCalls(calls.path)),
        );
        await settleReal(tester);
        await tester.sendEnter();
        await settleReal(tester);
      });
      expect(calls.readAsStringSync(), contains('open E2EApp'));
      calls.deleteSync();
    });

    test('probe streams stub output via real backend', () async {
      await testNocterm('e2e probe', (tester) async {
        final backend = Backend(
          run: stubbedRun(),
          probeStarter: (name) async {
            final proc = await Process.start(
              'cocoon',
              ['doctor', '--probe', if (name != null) name],
              environment: {
                ...Platform.environment,
                'PATH': '$stubPath:${Platform.environment['PATH']}',
              },
            );
            return ProbeSession.fromProcess(proc);
          },
        );
        await tester.pumpComponent(
          ProbeScreen(backend: backend, onBack: () {}),
        );
        await tester.pump();
        await tester.enterText('E2EApp');
        await tester.pump();
        await tester.sendEnter();
        await settleReal(tester);
        expect(tester.terminalState, containsText('class=E2EApp'));
      });
    });
  });
}
