<p align="center">
  <img src="assets/cocoon-128.png" alt="Cocoon" width="96">
</p>

# Cocoon

Isolated webapps for any Linux distro and desktop: turn any website into a native-feeling app with its own icon, window, and isolated browser profile — no browser tabs, no shared logins. Cocoon is the successor to `webapp-kit`; everything is driven by a single `cocoon` command.

Two engines per app, your choice at creation time:

- **chrome** — Chromium `--app` SSB window in an isolated `--user-data-dir`
- **firefox** — self-contained profile (ice-ssb style), tab strip removed, only minimize/maximize/close remain

## Requirements

Hard: `bash`, `curl`, `setsid` (util-linux) plus one browser (`firefox`, or a Chromium-family build for the chrome engine). Everything else degrades gracefully. Run `cocoon doctor --deps` after installing for a full check with install commands for your distro.

## Install

Fresh machine, one line:

```sh
curl -fsSL https://raw.githubusercontent.com/sabbaghpierre/cocoon/main/install.sh | bash
```

Options:

```sh
curl -fsSL https://raw.githubusercontent.com/sabbaghpierre/cocoon/main/install.sh | bash -s -- --prefix ~/.local/share/cocoon
COCOON_REF=v0.1.0 curl -fsSL https://raw.githubusercontent.com/sabbaghpierre/cocoon/main/install.sh | bash
COCOON_REPO=your-fork/cocoon curl -fsSL https://raw.githubusercontent.com/sabbaghpierre/cocoon/main/install.sh | bash
./install.sh --no-path        # skip shell PATH wiring (from a clone)
./install.sh --uninstall      # remove Cocoon code, keep your profiles and data
```

The installer never uses `sudo`. Re-running it upgrades in place: code is refreshed, apps/profiles/logins are untouched. It tries a local clone first, then branch/tag tarballs, a shallow `git clone`, and finally per-file raw fetches. Errors from every tier are printed if all fail. The prebuilt terminal UI (`cocoon-tui`) is fetched from GitHub releases as a best-effort step; shell commands work without it.

## Usage

```sh
cocoon create "Strafe" https://strafe.com firefox    # interactive if args omitted
cocoon create "ChatGPT" https://chatgpt.com chrome
cocoon create "YT" https://youtube.com --browser vivaldi-stable
cocoon create "Custom" https://example.com --engine chrome --browser-bin "/opt/my browser/chrome" --no-icon
                                                       # custom binary/wrapper path
cocoon create "YT" https://youtube.com --browser flatpak:org.chromium.Chromium
                                                       # Flatpak browser (see below)

cocoon list                                           # installed apps
cocoon open "ChatGPT"                                 # launch an existing app
cocoon edit "ChatGPT" --url https://chatgpt.com/c/new # change URL/icon/browser in place (profile kept)
cocoon icon "ChatGPT" [url|file]                      # refresh/change an app icon
cocoon config                                         # inspect global configuration
cocoon browsers                                       # browsers you can pin per app
cocoon doctor Strafe                                  # health check (icon, profile, CSS, rules…)
cocoon doctor --probe Strafe                          # live window identity (icon debugging)
cocoon probe Strafe                                   # alias for doctor --probe
cocoon remove --purge Strafe                          # delete app (+ isolated data)
cocoon update --check                                 # is a newer version out?
cocoon update                                         # upgrade in place (data untouched)
cocoon uninstall                                      # remove toolkit, KEEP all app data
cocoon uninstall --purge                              # remove toolkit AND every webapp
cocoon help                                           # full overview
```

`cocoon launch chrome|firefox` and `cocoon open-external` are internal entry points used by generated `.desktop` files and the browser native-messaging host; you rarely invoke them by hand.

Apps appear in any freedesktop app launcher (Kickoff/KRunner, fuzzel, wofi, …) with the site's favicon.

## How it works

- `cocoon create` fetches the favicon, installs it into the hicolor icon theme, and writes `~/.local/share/applications/<Name>.desktop` with an absolute `Exec=` (immune to session-PATH issues), a matching `StartupWMClass`, and — on Plasma — a KWin window rule forcing the association.
- Each app is pinned to the browser you picked (`--browser "…"` in the `Exec=` line, chosen from `cocoon browsers`: Chrome, Vivaldi, Ungoogled Chromium, Brave, Edge, Firefox, LibreWolf, Zen, Floorp, …). Older apps without a pin use the first-found binary of their engine.
- **Custom binaries:** pass `--browser-bin <path>` to pin any executable wrapper, including paths with spaces (relative paths work too). Custom paths require `--engine chrome|firefox` unless the engine can be detected from the binary's brand/name; a confident mismatch is rejected. (`--browser-bin` without a `/` is still the legacy alias of `--browser`.) `cocoon browsers --probe <path> [--json]` reports a binary's detected engine; the TUI create wizard offers custom chrome/firefox binary-path rows.
- Chrome-engine apps route every clicked link to your system default browser (link-router extension + `com.cocoon.open_external` native host via `xdg-open`), so e.g. a Chrome-backed WhatsApp app sends links to your default Firefox. Firefox-engine apps keep clicks in-app (Mozilla add-on signing blocks the router there).
- Chrome apps get `--user-data-dir=~/.local/share/cocoon/chrome-<slug>` + `--ozone-platform-hint=auto`.
- Firefox apps get `--profile ~/.local/share/cocoon/firefox-<slug> --no-remote`, native Wayland when `WAYLAND_DISPLAY` is set, `--name` app_id, and a `userChrome.css` that strips everything but window controls.
- **Legacy data is read transparently.** If a profile or log still lives in `~/.local/share/webapps` (e.g. a manual copy or interrupted migration), launchers, `doctor` and `remove` find it there instead of silently creating a fresh empty profile. New data and logs are always written under `~/.local/share/cocoon/`; the legacy root is never used for writes. `cocoon remove --purge` (and `cocoon uninstall --purge`) deletes matching profiles and logs from **both** roots, so old logins cannot survive a purge.

### Link-router caveat (Chrome 137+)

Chrome 137+ ignores command-line loading of unpacked extensions in branded Chrome builds, so the bundled link router may not activate there and clicked links stay inside the app window. The router works in Chromium, Brave, Vivaldi, Edge and other builds that still honor `--load-extension`; alternatively install the extension permanently in Chrome and keep `cocoon open-external` registered. Firefox-engine apps always keep links in-app.

### Flatpak browsers

`cocoon browsers` also reports installed Flatpak browsers as launchable ids in the form `flatpak:<app-id>` (for example `flatpak:org.chromium.Chromium`, `flatpak:com.google.Chrome`, `flatpak:org.mozilla.firefox`). Only apps that are both installed and in Cocoon's known mapping table are offered; free-form `flatpak run ...` strings are rejected. The engine is derived from that table, so no extra `--engine` is needed.

```sh
cocoon browsers --json                                  # source:"flatpak", supported:true rows
cocoon create "YT" https://youtube.com --browser flatpak:org.chromium.Chromium
```

Generated apps launch through `flatpak run --filesystem=<cocoon data dir> <app-id>` with a **per-run** bind of Cocoon's data root — Cocoon never writes a permanent `flatpak override` and never grants `--filesystem=host`. The isolated profile/log still lives under `~/.local/share/cocoon/`.

Sandbox limits:

- **Link-out is disabled** for Flatpak pins: the native-messaging host and unpacked extension live on the host, outside the sandbox. Clicked links stay in-app; `cocoon doctor` reports the app healthy with link-out `unsupported` rather than warning about a broken router.
- **Window identity may differ** under Flatpak (sandboxed app_id / WM class). If the taskbar icon does not match, focus the window and run `cocoon doctor --probe <name>` to inspect what the compositor reports, then adjust the app's icon/rule if needed.
- `flatpak` is a soft dependency unless an app is actually pinned to a Flatpak browser, in which case `cocoon doctor --deps` treats it as hard.

## Portability

No package-manager calls, no hardcoded paths or usernames, no distro-specific assumptions. Icon matching uses `app_id` + `StartupWMClass` everywhere (KWin rule added automatically on Plasma only). `cocoon doctor --probe` auto-detects KWin, niri, Hyprland and Sway (on GNOME it prints Looking-Glass steps). PATH wiring is idempotent for bash, zsh, fish and Plasma sessions and is fenced with Cocoon markers; Plasma's snippet is POSIX `sh`-compatible.

## Layout

```
VERSION  install.sh  README.md  LICENSE
bin/     cocoon                      # unified dispatcher — the only thing on PATH
libexec/ cocoon-{create,list,remove,doctor,browsers,launch-chrome,launch-firefox,
                  open-external,update,uninstall,help,edit,icon,config}
         cocoon-env.sh cocoon-kwin.sh    # sourced helpers
ext/     open-external/              # link-router WebExtension for chrome apps
tool/    version.sh                  # single entry point for versioning
         test-paths.sh test-browsers.sh test-flatpak.sh  # bash regression harnesses
tui/     prebuilt Cocoon terminal UI (Dart SDK only needed to build it)
```

Per-user state (never in this repo): `~/.local/share/cocoon/` (profiles, data, run logs; canonical write root), `~/.local/share/applications/*.desktop`, `~/.local/share/icons/hicolor/…`, `~/.config/kwinrulesrc` entries, and `~/.config/<browser>/NativeMessagingHosts/com.cocoon.open_external.json`. Legacy `~/.local/share/webapps` data is read-only fallback and is fully purged on request.

## Upgrading from webapp-kit

Running the Cocoon installer on a machine with a legacy `webapp-kit` install migrates it automatically — **no logins or profiles are lost**:

- `~/.local/share/webapps` is moved to `~/.local/share/cocoon` (profiles and logins are preserved, not re-created). Same-named directories are merged file by file with no overwrites, and the copy containing real browser state (`Preferences`/`prefs.js`) wins. If a profile is still left at the old path (manual copy or interrupted migration), it is found and used transparently and is fully removed by `--purge`.
- `.desktop` entries are rewritten from `webapp-launch-chrome`/`webapp-launch-firefox` (including old absolute paths) to `cocoon launch chrome`/`cocoon launch firefox`.
- Native-host manifests become `com.cocoon.open_external.json`, point at `<prefix>/bin/cocoon` and allow only `chrome-extension://ojjpgedkhjmaochljkpgamkcmfnbhocl/`.
- KWin rule descriptions change from `webapp: ` to `cocoon: `, and old PATH lines plus `webapp-tui` are removed.
- The old `webapp-*` binaries are deleted. Legacy `.desktop` Exec lines are rewritten to the unified CLI, so no compatibility shims are needed.

`./install.sh --uninstall` (or keeping data during `cocoon uninstall`) removes code, PATH entries and native manifests but keeps profiles/data. `cocoon uninstall --purge` removes everything, including every webapp and its isolated data under both the current and legacy data roots.

## Troubleshooting

**Installer fails with `could not fetch Cocoon`.** Every fetch tier reports its own error — read those first. Compare hosts; a common real case is the archive host blocked/slow while everything else works:

```sh
for u in https://raw.githubusercontent.com/sabbaghpierre/cocoon/main/VERSION "https://github.com/sabbaghpierre/cocoon/archive/refs/heads/main.tar.gz"; do
  echo "== $u"; curl -sSL -o /dev/null -w "http=%{http_code} time=%{time_total}s\n" --max-time 30 "$u" || echo "CURL FAILED rc=$?"
done
ls /etc/ssl/certs/ca-certificates.crt || echo "NO CA BUNDLE (install ca-certificates)"
```

Other usual suspects: no network/DNS on a fresh install, a proxy that needs `http_proxy`/`https_proxy`, or an inherited `IFS` without space / `GLOBIGNORE` (which could break downloads silently — current releases sanitize both).

**Apps have a generic icon.** Run `cocoon doctor --probe <name>` to inspect the live window identity, then `cocoon icon <name>` to refresh.

**Links open inside a Chrome app.** Check the Chrome 137+ caveat above, then run `cocoon doctor <name>` — it verifies the manifest in the app's isolated profile (`~/.local/share/cocoon/chrome-<slug>/NativeMessagingHosts/com.cocoon.open_external.json`) rather than just looking for a file in the browser config dir.

**Commands not found in a new terminal.** Open a new shell (or `exec fish`), or re-run `install.sh` to restore the managed PATH block.

## License

MIT — see [LICENSE](LICENSE).
