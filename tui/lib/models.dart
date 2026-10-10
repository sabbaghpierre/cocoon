/// Data models parsed from the webapp-* CLI `--json` output.
/// Pure functions only — no I/O, fully unit-testable.
library;

import 'dart:convert';

/// One installed webapp (from `webapp-list --json`).
class WebApp {
  final String name;
  final String engine;
  final String url;
  final String desktop;

  const WebApp({
    required this.name,
    required this.engine,
    required this.url,
    required this.desktop,
  });

  factory WebApp.fromJson(Map<String, dynamic> json) => WebApp(
        name: (json['name'] ?? '').toString(),
        engine: (json['engine'] ?? 'custom').toString(),
        url: (json['url'] ?? '').toString(),
        desktop: (json['desktop'] ?? '').toString(),
      );

  @override
  String toString() => 'WebApp($name, $engine, $url)';
}

/// Parse `webapp-list --json` (a top-level JSON array).
List<WebApp> parseAppList(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! List) {
    throw FormatException('expected JSON array, got: $text');
  }
  return decoded
      .whereType<Map<String, dynamic>>()
      .map(WebApp.fromJson)
      .toList();
}

/// One app entry inside `webapp-doctor --json`.
class DoctorApp {
  final String name;
  final String engine;
  final String url;
  final String cssVersion;
  final bool live;
  final bool kwinRule;
  final List<String> issues;

  const DoctorApp({
    required this.name,
    required this.engine,
    required this.url,
    required this.cssVersion,
    required this.live,
    required this.kwinRule,
    required this.issues,
  });

  factory DoctorApp.fromJson(Map<String, dynamic> json) => DoctorApp(
        name: (json['name'] ?? '').toString(),
        engine: (json['engine'] ?? 'custom').toString(),
        url: (json['url'] ?? '').toString(),
        cssVersion: (json['css_version'] ?? 'n/a').toString(),
        live: json['live'] == true,
        kwinRule: json['kwin_rule'] == true,
        issues: ((json['issues'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
      );

  bool get healthy => issues.isEmpty;
}

/// Full `webapp-doctor --json` report.
class DoctorReport {
  final List<DoctorApp> apps;
  final List<String> orphans;
  final int issueCount;

  const DoctorReport({
    required this.apps,
    required this.orphans,
    required this.issueCount,
  });

  factory DoctorReport.fromJson(Map<String, dynamic> json) {
    final appsJson = json['apps'];
    final orphansJson = json['orphans'];
    return DoctorReport(
      apps: appsJson is List
          ? appsJson
              .whereType<Map<String, dynamic>>()
              .map(DoctorApp.fromJson)
              .toList()
          : const [],
      orphans: orphansJson is List
          ? orphansJson.map((e) => e.toString()).toList()
          : const [],
      issueCount: (json['issue_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Parse `webapp-doctor --json` (a top-level JSON object).
DoctorReport parseDoctorReport(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('expected JSON object, got: $text');
  }
  return DoctorReport.fromJson(decoded);
}

/// One installed browser (from `webapp-browsers --json`).
class Browser {
  final String id;
  final String engine;
  final String name;
  final String version;
  final bool supported;

  const Browser({
    required this.id,
    required this.engine,
    required this.name,
    required this.version,
    required this.supported,
  });

  factory Browser.fromJson(Map<String, dynamic> json) => Browser(
        id: (json['id'] ?? json['bin'] ?? '').toString(),
        engine: (json['engine'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        version: (json['version'] ?? '').toString(),
        supported: json['supported'] != false,
      );

  /// Label for picker rows, e.g. "Vivaldi (vivaldi-stable) [chromium] 7.1".
  String get label {
    final v = version.trim().isEmpty ? '' : ' $version'.trimRight();
    return '$name ($id) [$engine]$v';
  }

  @override
  String toString() => 'Browser($id, $engine)';
}

/// Parse `webapp-browsers --json` (a top-level JSON array).
/// Flatpak list-only rows (supported=false) are kept — callers filter.
List<Browser> parseBrowserList(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! List) {
    throw FormatException('expected JSON array, got: $text');
  }
  return decoded
      .whereType<Map<String, dynamic>>()
      .map(Browser.fromJson)
      .toList();
}

/// Only browsers that can actually back a webapp (native installs).
List<Browser> supportedBrowsers(List<Browser> browsers) =>
    browsers.where((b) => b.supported && b.id.isNotEmpty).toList();

/// Mirror of the bash slugify() in webapp-* (spaces to dashes, keep
/// alnum/dash/underscore/dot, collapse + trim dashes). Used for probe
/// MATCH highlighting only.
String slugifyApp(String name) {
  var s = name.replaceAll(' ', '-');
  s = s.replaceAll(RegExp(r'[^A-Za-z0-9\-_.]'), '-');
  s = s.replaceAll(RegExp(r'-{2,}'), '-');
  s = s.replaceAll(RegExp(r'^[-.]+'), '').replaceAll(RegExp(r'[-.]+$'), '');
  return s.isEmpty ? 'webapp' : s;
}

/// One streamed probe line (`webapp-doctor --probe` output).
class ProbeSample {
  /// Window identity (Wayland app_id / WM class), if parseable.
  final String? klass;

  /// Desktop file the compositor matched, if reported (KWin only).
  final String? desktop;
  final String? pid;
  final String? title;

  /// Original line (also used when the line carries no fields).
  final String raw;

  const ProbeSample({
    this.klass,
    this.desktop,
    this.pid,
    this.title,
    required this.raw,
  });
}

/// Parse one probe output line. Never throws; unparseable lines come back
/// as raw-only samples.
ProbeSample parseProbeLine(String line) {
  // KWin: [ 1s] class=Strafe desktop=Strafe pid=12480 caption=Strafe ... |
  var m = RegExp(r'class=(\S+)\s+desktop=(\S+)\s+pid=(\S+)\s+caption=(.*)$')
      .firstMatch(line);
  if (m != null) {
    return ProbeSample(
      klass: m.group(1),
      desktop: m.group(2),
      pid: m.group(3),
      title: m.group(4),
      raw: line,
    );
  }
  // niri/hyprland/sway: class=X [pid=Y] title=Z
  m = RegExp(r'class=(\S+)\s+(?:pid=(\S+)\s+)?title=(.*)$').firstMatch(line);
  if (m != null) {
    return ProbeSample(
      klass: m.group(1),
      pid: m.group(2),
      title: m.group(3),
      raw: line,
    );
  }
  return ProbeSample(raw: line);
}
