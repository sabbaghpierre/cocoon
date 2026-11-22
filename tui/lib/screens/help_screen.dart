/// Static help overlay for the Cocoon TUI.
library;

import 'package:nocterm/nocterm.dart';

import '../branding.dart';

class HelpScreen extends StatelessComponent {
  final VoidCallback onBack;

  const HelpScreen({super.key, required this.onBack});

  @override
  Component build(BuildContext context) {
    const lines = [
      ...cocoonBannerLines,
      '',
      'Cocoon help',
      '',
      'Dashboard keys:',
      '  up/down or j/k .. move selection',
      '  Enter ................ launch highlighted webapp',
      '  c .................... create a webapp',
      '  x .................... remove webapp(s)',
      '  d .................... doctor (health check)',
      '  p .................... probe live window identity',
      '  r .................... refresh list',
      '  q .................... quit',
      '',
      'Each webapp is isolated: own Chrome data dir or Firefox',
      'profile (log in once inside the webapp window).',
      '',
      'Create: pick a detected browser, or a custom binary path',
      '(paths with spaces OK). Custom paths send an explicit engine;',
      'the CLI needs --engine unless it detects the browser itself.',
      '',
      'CLI equivalents: cocoon list, cocoon create, cocoon remove,',
      'cocoon open, cocoon doctor [--probe NAME], cocoon browsers.',
      '',
      'Press Esc to go back.',
    ];
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape) {
          onBack();
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final line in lines) Text(line)],
        ),
      ),
    );
  }
}
