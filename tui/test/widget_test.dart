import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cocoon_tui/app.dart';
import 'package:cocoon_tui/backend.dart';
import 'package:cocoon_tui/screens/create_form.dart';
import 'package:cocoon_tui/screens/dashboard.dart';
import 'package:cocoon_tui/screens/doctor_screen.dart';
import 'package:cocoon_tui/screens/probe_screen.dart';
import 'package:cocoon_tui/screens/remove_screen.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

const _apps = [
  {
    'name': 'Alpha',
    'engine': 'chrome',
    'url': 'https://a.example',
    'desktop': '/tmp/Alpha.desktop',
  },
  {
    'name': 'Beta',
    'engine': 'firefox',
    'url': 'https://b.example',
    'desktop': '/tmp/Beta.desktop',
  },
];

const _report = {
  'apps': [
    {
      'name': 'Alpha',
      'engine': 'chrome',
      'url': 'https://a.example',
      'css_version': 'n/a',
      'live': false,
      'kwin_rule': true,
      'issues': [],
    },
    {
      'name': 'Bad',
      'engine': 'firefox',
      'url': 'https://bad.example',
      'css_version': 'v1/v2',
      'live': false,
      'kwin_rule': false,
      'issues': [
        'userChrome.css is v1/v2 (hides titlebar); relaunch to migrate',
      ],
    },
  ],
  'orphans': <String>[],
  'issue_count': 1,
};

Backend fakeBackend({
  List<String>? seenCreate,
  List<String>? seenRemove,
  List<String>? seenOpen,
}) {
  Future<ProcessResult> run(String exe, List<String> args) async {
    final sub = args.isEmpty ? '' : args.first;
    switch (sub) {
      case 'list':
        return ProcessResult(0, 0, jsonEncode(_apps), '');
      case 'create':
        seenCreate?.addAll(args);
        return ProcessResult(0, 0, 'Created via stub', '');
      case 'remove':
        seenRemove?.addAll(args);
        return ProcessResult(0, 0, 'Removed via stub', '');
      case 'doctor':
        return ProcessResult(0, 1, jsonEncode(_report), '');
      case 'open':
        if (args.length > 1) seenOpen?.add(args[1]);
        return ProcessResult(0, 0, '', '');
      case 'browsers':
        return ProcessResult(0, 0, '[]', '');
      default:
        throw UnimplementedError('$exe $args');
    }
  }

  return Backend(run: run);
}

KeyboardEvent charKey(String ch, LogicalKey logical) =>
    KeyboardEvent(logicalKey: logical, character: ch);

void main() {
  group('dashboard', () {
    test('lists apps and moves highlight', () async {
      await testNocterm('dashboard nav', (tester) async {
        AppScreen? opened;
        await tester.pumpComponent(
          DashboardScreen(backend: fakeBackend(), onOpen: (s) => opened = s),
        );
        await tester.pump();
        expect(tester.terminalState, containsText('Cocoon dev'));
        expect(tester.terminalState, containsText('Alpha'));
        await tester.pump();
        expect(tester.terminalState, containsText('> Alpha'));
        await tester.sendKey(LogicalKey.arrowDown);
        expect(tester.terminalState, containsText('> Beta'));
        await tester.sendKey(LogicalKey.arrowUp);
        expect(tester.terminalState, containsText('> Alpha'));
        expect(opened, isNull);
      });
    });

    test('c opens create, ? opens help', () async {
      await testNocterm('dashboard shortcuts', (tester) async {
        AppScreen? opened;
        await tester.pumpComponent(
          DashboardScreen(backend: fakeBackend(), onOpen: (s) => opened = s),
        );
        await tester.sendKeyEvent(charKey('c', LogicalKey.keyC));
        expect(opened, AppScreen.create);
      });
    });

    test('Enter launches the highlighted app', () async {
      await testNocterm('dashboard open', (tester) async {
        final seenOpen = <String>[];
        await tester.pumpComponent(
          DashboardScreen(
            backend: fakeBackend(seenOpen: seenOpen),
            onOpen: (_) {},
          ),
        );
        await tester.pump();
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendEnter();
        await tester.pump();
        expect(seenOpen, ['Beta']);
      });
    });
  });

  group('create wizard', () {
    test('full flow submits expected flags', () async {
      await testNocterm('create flow', (tester) async {
        final seenCreate = <String>[];
        var backCount = 0;
        await tester.pumpComponent(
          CreateScreen(
            backend: fakeBackend(seenCreate: seenCreate),
            onBack: () => backCount++,
          ),
        );
        await tester.enterText('MyApp');
        await tester.sendEnter();
        expect(tester.terminalState, containsText('https://example.com'));
        await tester.enterText('https://e.com');
        await tester.sendEnter();
        expect(tester.terminalState, containsText('firefox'));
        await tester.sendKeyEvent(charKey('e', LogicalKey.keyE));
        await tester.sendEnter();
        expect(tester.terminalState, containsText('auto-fetch'));
        await tester.sendEnter();
        expect(tester.terminalState, containsText('Create "MyApp"?'));
        await tester.sendKeyEvent(charKey('y', LogicalKey.keyY));
        await tester.pump();
        expect(seenCreate, [
          'create',
          '--name',
          'MyApp',
          '--url',
          'https://e.com',
          '--engine',
          'firefox',
        ]);
        expect(tester.terminalState, containsText('Created via stub'));
        expect(backCount, 0);
      });
    });

    test('browser picker submits pinned browser', () async {
      await testNocterm('create with browsers', (tester) async {
        const browsersJson =
            '[{"id":"vivaldi-stable","engine":"chromium","bin":"vivaldi-stable","name":"Vivaldi","version":"7.1","source":"path","supported":true},{"id":"firefox","engine":"firefox","bin":"firefox","name":"Firefox","version":"155","source":"path","supported":true}]';
        final seenCreate = <String>[];
        Future<ProcessResult> run(String exe, List<String> args) async {
          final sub = args.isEmpty ? '' : args.first;
          if (sub == 'browsers') {
            return ProcessResult(0, 0, browsersJson, '');
          }
          if (sub == 'create') {
            seenCreate.addAll(args);
            return ProcessResult(0, 0, 'Created via stub', '');
          }
          throw UnimplementedError('$exe $args');
        }

        await tester.pumpComponent(
          CreateScreen(
            backend: Backend(run: run),
            onBack: () {},
          ),
        );
        await tester.enterText('MyApp');
        await tester.sendEnter();
        await tester.enterText('https://e.com');
        await tester.sendEnter();
        await tester.pump();
        expect(tester.terminalState, containsText('vivaldi-stable'));
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendEnter();
        await tester.sendEnter();
        expect(tester.terminalState, containsText('firefox'));
        await tester.sendKeyEvent(charKey('y', LogicalKey.keyY));
        await tester.pump();
        expect(seenCreate, [
          'create',
          '--name',
          'MyApp',
          '--url',
          'https://e.com',
          '--engine',
          'firefox',
          '--browser',
          'firefox',
        ]);
      });
    });

    test('browser picker forwards a flatpak browser id', () async {
      await testNocterm('create with flatpak browser', (tester) async {
        const browsersJson =
            '[{"id":"vivaldi-stable","engine":"chromium","bin":"vivaldi-stable","name":"Vivaldi","version":"7.1","source":"path","supported":true},'
            '{"id":"flatpak:org.chromium.Chromium","engine":"chromium","bin":"flatpak run org.chromium.Chromium","name":"Chromium (flatpak)","version":"120","source":"flatpak","supported":true},'
            '{"id":"firefox","engine":"firefox","bin":"firefox","name":"Firefox","version":"155","source":"path","supported":true}]';
        final seenCreate = <String>[];
        Future<ProcessResult> run(String exe, List<String> args) async {
          final sub = args.isEmpty ? '' : args.first;
          if (sub == 'browsers') return ProcessResult(0, 0, browsersJson, '');
          if (sub == 'create') {
            seenCreate.addAll(args);
            return ProcessResult(0, 0, 'Created via stub', '');
          }
          throw UnimplementedError('$exe $args');
        }

        await tester.pumpComponent(
          CreateScreen(
            backend: Backend(run: run),
            onBack: () {},
          ),
        );
        await tester.enterText('MyApp');
        await tester.sendEnter();
        await tester.enterText('https://e.com');
        await tester.sendEnter();
        await tester.pump();
        expect(
          tester.terminalState,
          containsText('flatpak:org.chromium.Chromium'),
        );
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendEnter();
        await tester.sendEnter();
        await tester.sendKeyEvent(charKey('y', LogicalKey.keyY));
        await tester.pump();
        expect(seenCreate, [
          'create',
          '--name',
          'MyApp',
          '--url',
          'https://e.com',
          '--engine',
          'chrome',
          '--browser',
          'flatpak:org.chromium.Chromium',
        ]);
      });
    });

    test('custom binary path submits --browser-bin with explicit engine', () async {
      await testNocterm('create custom binary', (tester) async {
        const browsersJson =
            '[{"id":"vivaldi-stable","engine":"chromium","bin":"vivaldi-stable","name":"Vivaldi","version":"7.1","source":"path","supported":true},{"id":"firefox","engine":"firefox","bin":"firefox","name":"Firefox","version":"155","source":"path","supported":true}]';
        final seenCreate = <String>[];
        Future<ProcessResult> run(String exe, List<String> args) async {
          final sub = args.isEmpty ? '' : args.first;
          if (sub == 'browsers') {
            return ProcessResult(0, 0, browsersJson, '');
          }
          if (sub == 'create') {
            seenCreate.addAll(args);
            return ProcessResult(0, 0, 'Created via stub', '');
          }
          throw UnimplementedError('$exe $args');
        }

        await tester.pumpComponent(
          CreateScreen(
            backend: Backend(run: run),
            onBack: () {},
          ),
        );
        await tester.enterText('MyApp');
        await tester.sendEnter();
        await tester.enterText('https://e.com');
        await tester.sendEnter();
        await tester.pump();
        expect(
          tester.terminalState,
          containsText('custom binary path (chrome engine)'),
        );
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendEnter();
        await tester.pump();
        expect(tester.terminalState, containsText('Binary path'));
        await tester.sendEnter();
        expect(tester.terminalState, containsText('Binary path is required'));
        await tester.enterText('/opt/My Browser/chrome');
        await tester.sendEnter();
        await tester.sendEnter();
        await tester.sendKeyEvent(charKey('y', LogicalKey.keyY));
        await tester.pump();
        expect(seenCreate, [
          'create',
          '--name',
          'MyApp',
          '--url',
          'https://e.com',
          '--engine',
          'chrome',
          '--browser-bin',
          '/opt/My Browser/chrome',
        ]);
      });
    });

    test('unknown browser engine is not silently mapped to firefox', () async {
      await testNocterm('create unknown engine', (tester) async {
        const browsersJson =
            '[{"id":"mystery","engine":"other","bin":"mystery","name":"Mystery","version":"","source":"path","supported":true}]';
        final seenCreate = <String>[];
        Future<ProcessResult> run(String exe, List<String> args) async {
          final sub = args.isEmpty ? '' : args.first;
          if (sub == 'browsers') return ProcessResult(0, 0, browsersJson, '');
          if (sub == 'create') {
            seenCreate.addAll(args);
            return ProcessResult(0, 0, 'Created via stub', '');
          }
          throw UnimplementedError('$exe $args');
        }

        await tester.pumpComponent(
          CreateScreen(
            backend: Backend(run: run),
            onBack: () {},
          ),
        );
        await tester.enterText('MyApp');
        await tester.sendEnter();
        await tester.enterText('https://e.com');
        await tester.sendEnter();
        await tester.sendEnter();
        await tester.sendEnter();
        await tester.sendKeyEvent(charKey('y', LogicalKey.keyY));
        await tester.pump();
        expect(seenCreate, [
          'create',
          '--name',
          'MyApp',
          '--url',
          'https://e.com',
          '--engine',
          'other',
          '--browser',
          'mystery',
        ]);
      });
    });

    test('empty name blocks advance', () async {
      await testNocterm('create validation', (tester) async {
        await tester.pumpComponent(
          CreateScreen(backend: fakeBackend(), onBack: () {}),
        );
        await tester.sendEnter();
        expect(tester.terminalState, containsText('Name is required'));
      });
    });

    test('n at confirm returns to icon and Esc exits', () async {
      await testNocterm('create back navigation', (tester) async {
        var backCount = 0;
        await tester.pumpComponent(
          CreateScreen(backend: fakeBackend(), onBack: () => backCount++),
        );
        await tester.enterText('MyApp');
        await tester.sendEnter();
        await tester.enterText('https://e.com');
        await tester.sendEnter();
        await tester.sendEnter();
        await tester.enterText('/tmp/icon.png');
        await tester.sendEnter();
        expect(tester.terminalState, containsText('Create "MyApp"?'));

        await tester.sendKeyEvent(charKey('n', LogicalKey.keyN));
        expect(tester.terminalState, containsText('/tmp/icon.png'));
        expect(tester.terminalState, isNot(containsText('Create "MyApp"?')));
        expect(backCount, 0);

        await tester.sendEnter();
        expect(tester.terminalState, containsText('Create "MyApp"?'));
        await tester.sendEscape();
        expect(backCount, 1);
      });
    });
  });

  group('remove screen', () {
    test('toggle two apps and delete keeping data', () async {
      await testNocterm('remove flow', (tester) async {
        final seenRemove = <String>[];
        await tester.pumpComponent(
          RemoveScreen(
            backend: fakeBackend(seenRemove: seenRemove),
            onBack: () {},
          ),
        );
        await tester.pump();
        expect(tester.terminalState, containsText('Alpha'));
        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.space, character: ' '),
        );
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.space, character: ' '),
        );
        await tester.sendKeyEvent(charKey('y', LogicalKey.keyY));
        await tester.pump();
        expect(seenRemove, hasLength(0));
        await tester.sendKeyEvent(charKey('y', LogicalKey.keyY));
        await tester.pump();
        expect(seenRemove, ['remove', 'Alpha', 'Beta']);
        expect(tester.terminalState, containsText('Removed via stub'));
      });
    });

    test('confirm prompt follows the purge toggle', () async {
      await testNocterm('remove purge prompt', (tester) async {
        await tester.pumpComponent(
          RemoveScreen(backend: fakeBackend(), onBack: () {}),
        );
        await tester.pump();
        await tester.sendKeyEvent(
          KeyboardEvent(logicalKey: LogicalKey.space, character: ' '),
        );
        await tester.sendKeyEvent(charKey('p', LogicalKey.keyP));
        await tester.sendKeyEvent(charKey('y', LogicalKey.keyY));
        await tester.pump();
        expect(tester.terminalState, containsText('y: PURGE data'));
        expect(tester.terminalState, containsText('P: always PURGE'));
      });
    });
  });

  group('doctor screen', () {
    test('renders ok and warnings', () async {
      await testNocterm('doctor rows', (tester) async {
        await tester.pumpComponent(
          DoctorScreen(backend: fakeBackend(), onBack: () {}),
        );
        await tester.pump();
        expect(tester.terminalState, containsText('ok Alpha'));
        await tester.pump();
        expect(tester.terminalState, containsText('WARN Bad'));
        await tester.pump();
        expect(tester.terminalState, containsText('v1/v2'));
      });
    });
  });

  group('probe screen', () {
    test('streams samples and highlights match', () async {
      await testNocterm('probe stream', (tester) async {
        final backend = Backend(
          run: (exe, args) async => ProcessResult(0, 0, '[]', ''),
          probeStarter: (_) async => ProbeSession(
            stdout: Stream.fromIterable([
              utf8.encode(
                '  [ 1s] class=Beta desktop=Beta pid=42 caption=Hi\n',
              ),
            ]),
            stderr: Stream.fromIterable([
              utf8.encode('no supported compositor detected\n'),
            ]),
            exitCode: Future.value(0),
            onStop: () async {},
          ),
        );
        await tester.pumpComponent(
          ProbeScreen(backend: backend, onBack: () {}),
        );
        await tester.enterText('Beta');
        await tester.sendEnter();
        await tester.pump();
        expect(tester.terminalState, containsText('MATCH'));
        await tester.pump();
        expect(tester.terminalState, containsText('class=Beta'));
        await tester.pump();
        expect(
          tester.terminalState,
          containsText('no supported compositor detected'),
        );
      });
    });
  });
}
