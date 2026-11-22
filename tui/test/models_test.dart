import 'dart:convert';
import 'dart:io';

import 'package:cocoon_tui/backend.dart';
import 'package:cocoon_tui/models.dart';
import 'package:test/test.dart';

const _listJson = '''
[{"name":"WhatsApp","engine":"chrome","url":"https://web.whatsapp.com","desktop":"/home/u/.local/share/applications/WhatsApp.desktop"},
  {"name":"Weird \\"Q\\" App","engine":"custom","url":"(custom exec)","desktop":"/home/u/.local/share/applications/Weird \\"Q\\" App.desktop"}]
''';

const _doctorJson = '''
{"apps":[{"name":"Strafe","engine":"firefox","url":"https://strafe.com","desktop":"/home/u/.local/share/applications/Strafe.desktop","icon":"Strafe","icon_path":"/home/u/.local/share/icons/hicolor/128x128/apps/Strafe.png","startup_wmclass":"Strafe","desktop_valid":true,"profile_dir":"/home/u/.local/share/cocoon/firefox-Strafe","css_version":"v3","kwin_rule":true,"live":false,"log_tail":"","issues":[]},
{"name":"Bad App","engine":"firefox","url":"https://bad.example","desktop":"/home/u/.local/share/applications/Bad App.desktop","icon":"/nonexistent/icon.png","icon_path":"/nonexistent/icon.png","startup_wmclass":"","desktop_valid":null,"profile_dir":"","css_version":"n/a","kwin_rule":false,"live":false,"log_tail":"","issues":["icon missing: /nonexistent/icon.png","no KWin rule"]}],
"orphans":["/home/u/.local/share/cocoon/firefox-Orphaned"],"issue_count":2}
''';

const _browsersJson = '''
[{"id":"vivaldi-stable","engine":"chromium","bin":"vivaldi-stable","name":"Vivaldi","version":"Vivaldi 7.1","source":"path","supported":true},
  {"id":"librewolf","engine":"firefox","bin":"librewolf","name":"LibreWolf","version":"LibreWolf 140","source":"path","supported":true},
  {"id":"flatpak:org.mozilla.firefox","engine":"firefox","bin":"flatpak run org.mozilla.firefox","name":"Firefox (flatpak)","version":"Firefox 140","source":"flatpak","supported":true}]
''';

void main() {
  group('parseAppList', () {
    test('parses apps incl. quoted names', () {
      final apps = parseAppList(_listJson);
      expect(apps, hasLength(2));
      expect(apps[0].name, 'WhatsApp');
      expect(apps[0].engine, 'chrome');
      expect(apps[1].name, 'Weird "Q" App');
    });

    test('empty array', () {
      expect(parseAppList('[]'), isEmpty);
    });

    test('invalid json throws', () {
      expect(() => parseAppList('nope'), throwsFormatException);
      expect(() => parseAppList('{}'), throwsFormatException);
    });
  });

  group('parseDoctorReport', () {
    test('apps, issues, orphans', () {
      final report = parseDoctorReport(_doctorJson);
      expect(report.apps, hasLength(2));
      expect(report.apps[0].healthy, isTrue);
      expect(report.apps[0].cssVersion, 'v3');
      expect(report.apps[1].healthy, isFalse);
      expect(report.apps[1].issues, hasLength(2));
      expect(report.orphans, ['/home/u/.local/share/cocoon/firefox-Orphaned']);
      expect(report.issueCount, 2);
    });

    test('tolerates missing keys', () {
      final report = parseDoctorReport('{"apps":[{}],"orphans":[]}');
      expect(report.apps.single.name, '');
      expect(report.apps.single.healthy, isTrue);
    });

    test('invalid json throws', () {
      expect(() => parseDoctorReport('[]'), throwsFormatException);
      expect(() => parseDoctorReport('garbage'), throwsFormatException);
    });
  });

  group('parseBrowserList', () {
    test('parses browsers incl. launchable flatpak rows', () {
      final browsers = parseBrowserList(_browsersJson);
      expect(browsers, hasLength(3));
      expect(browsers[0].id, 'vivaldi-stable');
      expect(browsers[0].engine, 'chromium');
      expect(browsers[0].label, contains('[chromium]'));
      expect(browsers[0].source, 'path');
      expect(browsers[2].id, 'flatpak:org.mozilla.firefox');
      expect(browsers[2].source, 'flatpak');
      expect(browsers[2].supported, isTrue);
    });

    test(
      'supportedBrowsers keeps flatpak but drops unsupported and empty ids',
      () {
        final browsers = parseBrowserList(_browsersJson);
        final withEmpty = [
          ...browsers,
          const Browser(
            id: '',
            engine: 'chrome',
            name: '',
            version: '',
            supported: true,
          ),
        ];
        expect(supportedBrowsers(withEmpty).map((b) => b.id), [
          'vivaldi-stable',
          'librewolf',
          'flatpak:org.mozilla.firefox',
        ]);
        final unsupported = parseBrowserList(
          '[{"id":"vivaldi-stable","engine":"chromium","name":"V","version":"","supported":false}]',
        );
        expect(supportedBrowsers(unsupported), isEmpty);
      },
    );

    test('Browser.source defaults to path', () {
      final b = Browser.fromJson({'id': 'firefox', 'engine': 'firefox'});
      expect(b.source, 'path');
    });

    test('empty array', () {
      expect(parseBrowserList('[]'), isEmpty);
    });

    test('invalid json throws', () {
      expect(() => parseBrowserList('nope'), throwsFormatException);
      expect(() => parseBrowserList('{}'), throwsFormatException);
    });
  });

  group('parseProbeLine', () {
    test('kwin sample', () {
      final s = parseProbeLine(
        '  [ 1s] class=Strafe                 desktop=Strafe                 pid=12480    caption=Strafe Esports | Watch |',
      );
      expect(s.klass, 'Strafe');
      expect(s.desktop, 'Strafe');
      expect(s.pid, '12480');
      expect(s.title, contains('Esports'));
    });

    test('niri/hypr sample without desktop', () {
      final s = parseProbeLine(
        '  class=firefox                pid=111      title=Mozilla Firefox',
      );
      expect(s.klass, 'firefox');
      expect(s.desktop, isNull);
      expect(s.title, 'Mozilla Firefox');
    });

    test('MATCH and prompt lines pass through raw', () {
      final s = parseProbeLine("probe: MATCH — window reports class 'Strafe'");
      expect(s.klass, isNull);
      expect(s.raw, contains('MATCH'));
    });
  });

  group('Backend', () {
    Future<ProcessResult> fakeRun(String exe, List<String> args) async {
      expect(exe, 'cocoon');
      final sub = args.isEmpty ? '' : args.first;
      switch (sub) {
        case 'list':
          return ProcessResult(0, 0, _listJson, '');
        case 'create':
          return ProcessResult(0, 0, 'Created X', '');
        case 'remove':
          return ProcessResult(0, 1, '', 'boom');
        case 'doctor':
          return ProcessResult(0, 1, _doctorJson, '');
        case 'browsers':
          return ProcessResult(0, 0, _browsersJson, '');
        case 'open':
          return ProcessResult(0, 0, 'Opened', '');
        default:
          throw UnimplementedError('$exe $args');
      }
    }

    test('listApps maps json via cocoon list', () async {
      final apps = await Backend(run: fakeRun).listApps();
      expect(apps.map((a) => a.name), ['WhatsApp', 'Weird "Q" App']);
    });

    test('listApps decodes byte stdout', () async {
      final b = Backend(
        run: (exe, args) async =>
            ProcessResult(0, 0, utf8.encode(_listJson), ''),
      );
      final apps = await b.listApps();
      expect(apps.first.name, 'WhatsApp');
    });

    test('createApp passes flags, ok on exit 0', () async {
      String? seenExe;
      List<String>? seenArgs;
      final b = Backend(
        run: (exe, args) async {
          seenExe = exe;
          seenArgs = args;
          return ProcessResult(0, 0, 'ok', '');
        },
      );
      final r = await b.createApp(
        name: 'N',
        url: 'https://e.com',
        engine: 'firefox',
        icon: '',
      );
      expect(seenExe, 'cocoon');
      expect(seenArgs, [
        'create',
        '--name',
        'N',
        '--url',
        'https://e.com',
        '--engine',
        'firefox',
      ]);
      expect(r.ok, isTrue);
    });

    test('createApp with icon appends --icon', () async {
      List<String>? seenArgs;
      final b = Backend(
        run: (exe, args) async {
          seenArgs = args;
          return ProcessResult(0, 0, '', '');
        },
      );
      await b.createApp(
        name: 'N',
        url: 'https://e.com',
        engine: 'chrome',
        icon: '/tmp/i.png',
      );
      expect(seenArgs!.last, '/tmp/i.png');
      expect(seenArgs, contains('--icon'));
    });

    test('createApp with browser passes --browser after --engine', () async {
      List<String>? seenArgs;
      final b = Backend(
        run: (exe, args) async {
          seenArgs = args;
          return ProcessResult(0, 0, '', '');
        },
      );
      await b.createApp(
        name: 'N',
        url: 'https://e.com',
        engine: 'chrome',
        browser: 'vivaldi-stable',
      );
      expect(seenArgs, [
        'create',
        '--name',
        'N',
        '--url',
        'https://e.com',
        '--engine',
        'chrome',
        '--browser',
        'vivaldi-stable',
      ]);
    });

    test(
      'createApp with browserBin appends --browser-bin (no --browser)',
      () async {
        List<String>? seenArgs;
        final b = Backend(
          run: (exe, args) async {
            seenArgs = args;
            return ProcessResult(0, 0, '', '');
          },
        );
        await b.createApp(
          name: 'N',
          url: 'https://e.com',
          engine: 'chrome',
          browserBin: ' /opt/My Browser/chrome ',
        );
        expect(seenArgs, [
          'create',
          '--name',
          'N',
          '--url',
          'https://e.com',
          '--engine',
          'chrome',
          '--browser-bin',
          '/opt/My Browser/chrome',
        ]);
      },
    );

    test('createApp with browser and browserBin sends both in order', () async {
      List<String>? seenArgs;
      final b = Backend(
        run: (exe, args) async {
          seenArgs = args;
          return ProcessResult(0, 0, '', '');
        },
      );
      await b.createApp(
        name: 'N',
        url: 'https://e.com',
        engine: 'firefox',
        browser: 'firefox',
        browserBin: '/opt/custom',
        icon: '/tmp/i.png',
      );
      expect(seenArgs, [
        'create',
        '--name',
        'N',
        '--url',
        'https://e.com',
        '--engine',
        'firefox',
        '--browser',
        'firefox',
        '--browser-bin',
        '/opt/custom',
        '--icon',
        '/tmp/i.png',
      ]);
    });

    test('listBrowsers maps json incl. flatpak ids', () async {
      final browsers = await Backend(run: fakeRun).listBrowsers();
      expect(browsers.map((b) => b.id), [
        'vivaldi-stable',
        'librewolf',
        'flatpak:org.mozilla.firefox',
      ]);
    });

    test('removeApps ok reflects exit code and passes names', () async {
      List<String>? seenArgs;
      final b = Backend(
        run: (exe, args) async {
          seenArgs = args;
          return ProcessResult(0, 1, '', 'boom');
        },
      );
      expect((await b.removeApps(['A'], purge: true)).ok, isFalse);
      expect(seenArgs, ['remove', '--purge', 'A']);
    });

    test('openApp invokes cocoon open NAME', () async {
      String? seenExe;
      List<String>? seenArgs;
      final b = Backend(
        run: (exe, args) async {
          seenExe = exe;
          seenArgs = args;
          return ProcessResult(0, 0, 'Opened', '');
        },
      );
      final r = await b.openApp('My App');
      expect(seenExe, 'cocoon');
      expect(seenArgs, ['open', 'My App']);
      expect(r.ok, isTrue);
    });

    test('doctor parses despite exit 1', () async {
      List<String>? seenArgs;
      final b = Backend(
        run: (exe, args) async {
          seenArgs = args;
          return ProcessResult(0, 1, _doctorJson, '');
        },
      );
      final report = await b.doctor('Strafe');
      expect(seenArgs, ['doctor', '--json', 'Strafe']);
      expect(report.apps, hasLength(2));
      expect(report.issueCount, 2);
    });

    test('missing binary becomes BackendException', () async {
      final b = Backend(
        run: (exe, args) async {
          throw const ProcessException('cocoon', []);
        },
      );
      expect(() => b.listApps(), throwsA(isA<BackendException>()));
    });
  });

  group('ProbeSession', () {
    Future<List<ProbeSample>> collect(ProbeSession s) async =>
        await s.lines.toList();

    test('merges stderr into the line stream', () async {
      final session = ProbeSession(
        stdout: Stream.fromIterable([utf8.encode('class=Alpha title=A\n')]),
        stderr: Stream.fromIterable([
          utf8.encode('no supported compositor detected\n'),
        ]),
        exitCode: Future.value(0),
        onStop: () async {},
      );
      final lines = await collect(session);
      expect(
        lines.map((s) => s.raw),
        contains('no supported compositor detected'),
      );
      expect(lines.map((s) => s.raw), contains('class=Alpha title=A'));
    });
  });
}
