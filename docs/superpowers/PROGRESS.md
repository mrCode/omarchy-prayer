# PROGRESS — Omarchy 4 support (v0.2.0 → v0.4.1)

> Living state file. **Read this first** in any new session before acting.
> Update it in the same turn a decision is made or a task completes.

**Last updated:** 2026-09-03
**Branch:** `master` (release commits land directly; no feature branch open)
**Status:** **v0.4.1 SHIPPED.** GitHub tags `v0.2.0`–`v0.4.1` (all with
Releases); AUR `omarchy-prayer 0.4.1-1`; installed locally and verified through PATH; plugin
published on the community plugin marketplace.
Suite: **278 runs, 886–888 assertions, 0 failures, 1 skip** — green under both
`bundle exec rake test` and the bundler-less `ruby -Ilib -Itest` invocation
(assertion count differs by one run to run; not a failure — see task-10 report),
**flake fixed 2026-08-31, see below.**

**FLAKE FIXED 2026-08-31** (`d86a540`), and the suite is green.
`test_audio_spawned_before_blocking_notify_send` compared the order the two
shims APPENDED to the log; `mpv` is spawned detached, so under load the kernel
could schedule it after the foreground `notify-send` had already written. The
log inverted while the spawn order stayed correct — the product code was never
wrong. It mattered because this suite runs in the AUR PKGBUILD's `check()` on
every user who builds the package, and a build machine is loaded by definition.

Now `test_audio_starts_during_the_blocking_notify_send`: `with_shims` takes
`delays:`, which makes `notify-send` block 3s (baked into the generated script,
not an env var, so nothing outlives the test), and the adhan must be audible
within 2s while it is still blocking. Spawn latency is single-digit ms, so that
is a ~40x margin. It also asserts the thread is still alive when the adhan
starts, so it fails loudly rather than passing vacuously if the shim ever stops
blocking. **Verified by mutation** — moving `Audio#play` after `notify-send`
makes it fail with a diagnostic naming the delay; production code restored
byte-identical after. 60 runs under 4-way CPU load: 0 failures, where the old
assertion failed ~1 in 45 under the same load. Suite runtime grows ~3s.

**Lesson, worth generalising:** the old test asserted on a PROXY (log write
order) for the property it cared about (spawn order). The proxy held on an idle
machine and broke under load. Prefer asserting the property itself — here, "the
adhan is audible while the notification is still blocking."

---

## v0.3.4 — ship the notifier test fix (2026-08-31)

Test-only change, released rather than held for the next feature because the
suite runs in the AUR PKGBUILD's `check()` on every user's build machine, so a
flaky assertion there means occasional install failures. `check()` was verified
passing **under 4-way CPU load** before the AUR push, not just on an idle
machine — that is the condition the fix exists for.

**The plugin manifest deliberately STAYS at 0.3.3.** No QML or JS changed.
Bumping it would push a new commit to the listed plugin repo, which the
marketplace would flag as "upstream changes detected" against its verified
snapshot (`2ba0549`) until a maintainer re-verified — churning a
security-reviewed listing for a version string describing no change. The widget
gates on "omarchy-prayer 0.2.1+", not an exact match, so nothing depends on the
two matching. This is a deliberate exception to the 0.3.3 lockstep note; do not
"fix" the mismatch without re-reading this.

**Known gap, NOT addressed:** the CLI repo's GitHub *Releases* page still shows
**v0.1.5 as "Latest"** — every tag from v0.2.0 on was pushed as a bare tag with
no release entry. Tags exist and the AUR is correct, so nothing is broken, but a
visitor sees a version four months stale. Backfilling v0.2.0–v0.3.4 as releases
is a short job whenever the user wants it.

---

## End-to-end pass, 2026-08-31

Run after the flake fix, all through PATH against installed `0.3.3-1`:

- **AUR `check()` under 4-way CPU load** — 278 runs, 0 failures (the condition
  that used to break it).
- **Every CLI surface** — `today`, `next`, `status`, `status --json`, `audio`,
  `bar status`, `bar preset list`, `adhans list`, `--help` exits 0, unknown
  subcommand exits non-zero.
- **Widget JSON contract** — all 12 expected keys present, 5 prayers, qibla
  244 WSW, no control characters in any string. Countdown live (epoch decrements
  in real time).
- **systemd** — 6 transient `op-*` timers armed for the remaining prayers plus
  `omarchy-prayer-schedule.timer`; 0 failed units.
- **Shell plugin** — 0.3.3 installed, listed in `shell.json`, `omarchy-shell` up.
- **IPC** — `refresh`, `toggle`, `close` all rc=0.
- **No drift** — `config.toml` sha256 identical before and after; audio still
  off.

**Two "findings" during this pass were MY tooling errors, not product bugs.**
Recorded so they are not re-investigated: (1) transient prayer timers are named
`op-*`, NOT `omarchy-prayer-*` — searching the latter shows none and looks like
notifications are dead; (2) the IPC invocation is
`omarchy-shell -q <target> <method>` (see `bin/omarchy-prayer-schedule:77`), not
`omarchy-shell ipc call ...`, which returns "Target not found."

---

## START HERE next session

**v0.4.1 is shipped. Every repo is clean and pushed, nothing is in flight,
nothing is broken.** Closed work is written up below — do not re-open it. One
item is live, and it is waiting on someone else:

- **`manual-setup` badge on the marketplace listing.** Asked @ryanrhughes what
  criterion lifts it (comment 5407659947). The badge is ACCURATE, not a docs
  gap — the widget fronts an AUR package and cannot work from
  `omarchy plugin add` alone. "It stays for anything depending on a distro
  package" is an acceptable answer. **Do not chase this.**

**A promise that is still owed:** the PR #4 closing comment tells
@ch-arslanahmad they will get a review "in days, not months" if they contribute
again. Honour that if they turn up.

**Machine state — the user is in NEW YORK.** Auto-relocate moved them on
2026-09-03 and handled it end to end: config NYC/US, method auto-resolved
`Makkah` -> `ISNA`, tz `-14400`, cache re-keyed, timers rearmed in EDT. **Do
not "restore" Riyadh, and do not compare the config against
`config.toml.bak.pre-audio-enable` — that backup predates the move.** Bar on the
`full` preset, Latin names, `[audio].enabled = false` per
[[project-adhan-muted-default]].

Two hazards that bit this session, both now in memory — read them before any
verification step that writes or schedules:
[[feedback-no-adhoc-scripts-against-live-home]] and
[[feedback-systemd-ignores-home-isolation]]. The second one mis-scheduled a real
call-to-prayer notification by 75 minutes.

**Version state: CLI 0.4.1, plugin manifest 0.4.0 — deliberately different.**
No QML or JS changed in 0.4.1, so the plugin repo was not touched and the
marketplace's verified snapshot is not churned. The rule is in
[[reference-published-locations]]: bump the manifest only when the widget's code
actually changes. 0.4.0 bumped it (Model.js gained `{icon}`); 0.3.4 and 0.4.1
correctly did not.

**Every release from here goes through `RELEASING.md`** — a functional check and
a security check, both before the tag is pushed, no exceptions. v0.4.0 is the
case study for why: see the v0.4.1 section.

---

## v0.3.3 — geolocation trust boundary (2026-08-21)

A full-codebase security scan (user-requested) returned three findings, all
confirmed by parallel false-positive filters. One root cause: the geolocation
HTTP response is a **trust root** — persisted to `config.toml`, replayed on
every run, printed to terminals and painted on the bar — but was handled as if
it were our own data.

1. **HIGH — cleartext transport.** `DEFAULT_URL` was `http://ip-api.com/json/`
   and auto-relocate fires on every NetworkManager connection-up. The existing
   timezone cross-check does NOT close this: it only catches *cross-country*
   spoofing and is skipped entirely when `TzLocation.detect` returns nil, so a
   co-located hostile-WiFi attacker was unaffected by it. Now `https://ipwho.is/`
   (ip-api's free tier is HTTP-only) plus `require_secure_transport!`, which
   refuses any non-HTTPS endpoint except loopback. Payload fields are validated:
   coordinates numeric and in range, country code two letters.

2. **HIGH — terminal control-character injection.** The attacker never sends a
   raw ESC byte (that would break TOML); they send the literal six characters
   `backslash-u-0-0-1-b`, which carry no markup and are a valid TOML basic
   string. **Tomlrb 2.0.4 decodes them back into a real ESC on load** —
   empirically confirmed. The payload is OSC 52, which writes the clipboard, and
   Omarchy's shipped Alacritty config sets `osc52 = "CopyPaste"`, so the user's
   next paste into a shell runs attacker-chosen text. `Sanitize.display` now
   strips C0/C1 controls and Unicode format characters (covering bidi overrides
   too) and caps length at 64.

3. **LOW/MEDIUM — TOML injection.** `city`/`country` were spliced in unescaped;
   a quote closed the literal early and the rest parsed as TOML — enough to flip
   `auto_update` back on for a user who pinned their location. Escalation to code
   execution via `[audio].player` is **not** reachable: tomlrb rejects duplicate
   table headers. `first_run` and `relocate` now write through
   `BarSetting.literal`, whose `escape` also drops control characters (TOML
   forbids them raw in a basic string; a newline in `city` would otherwise write
   a config nothing can parse).

**Sanitisation is applied at every sink, not at ingress alone** — the poisoned
values may already be on disk in existing installs, so ingress filtering cannot
protect someone hit before this release. Sinks covered: `Status.build`,
`TUI#render_header`, `TUI#relocate_here`, `bin/omarchy-prayer status`,
`Notifier#compose`, `AutoRelocate#maybe_update`, and the QML pill/panel (0.3.2).

**A second commit fixed three sinks the scan's own scope missed** — the
notification body, `Status`'s `hijri` (an Aladhan API string, same trust class
as city), and the auto-relocate stderr line. Found by the whole-branch pass, not
by the scan. Same failure mode as v0.3.1: sanitising the *data a report names*
rather than the *class of sink* it belongs to. See
[[feedback-whole-branch-review]].

Regression tests: `test/test_injection_hardening.rb` (10 tests). It first
asserts the decoded ESC really reaches the config — if tomlrb ever stops
decoding, that guard fails loudly rather than letting the sink tests silently
pass on inert input.

**Incident during this work:** an ad-hoc `ruby -e` verification script set
`ENV["HOME"]` too late and ran `FirstRun.ensure_config!` against the REAL
config, overwriting it with the injection fixture (location → Paris, adhan
paths → template defaults). Restored from
`config.toml.bak.pre-audio-enable`; the corrupted file was kept as
`config.toml.corrupted-by-test.<epoch>`. **Never run destructive verification
through `ruby -e` against a live HOME — write it as a test using
`with_isolated_home`.** See [[feedback-no-adhoc-scripts-against-live-home]].

---

## User-reported issues and outside contributions

Checked 2026-09-04: **no issues open anywhere.** Zero have ever been filed on
`mrCode/omarchy-prayer-plugin`; the CLI repo's only issue,
[#1](https://github.com/mrCode/omarchy-prayer/issues/1) (`tomlrb` LoadError under
a user-managed Ruby), was fixed in AUR `0.1.1-2` the same day it was reported in
April, sat open for four months because nobody closed it behind the fix, and was
closed 2026-08-25 after re-verifying against the CURRENT `0.3.4` package on a
machine that reproduces the original condition (mise Ruby ahead of
`/usr/bin/ruby` on PATH).

**OPEN AND AWAITING A REPLY FROM THE CONTRIBUTOR — [PR #4](https://github.com/mrCode/omarchy-prayer/pull/4).**
@ch-arslanahmad opened it 2026-06-01: waybar icons, 12-hour time, and Pango
time-of-day colours, +72/-8 across 6 files, all defaulting to existing
behaviour, with screenshots. **It sat three months with zero human replies** —
the only review was a Copilot bot that could not finish. Answered 2026-09-04
(comment 5532108848).

It is CONFLICTING and cannot be rebased mechanically: it was written against
pre-v0.2.0 code and every file it touches was rewritten underneath it —
`[waybar]` became `[bar]`, `waybar.rb` now renders from the shared `Status`
structure via `render_from_status`, and v0.3.0 added presets/name
scripts/compact countdown to the same path.

**The substantive technical point, verified against current code:** the colour
feature needs `markup: true` plus Pango `<span>`. `{city}` is
geolocation-derived and flows into that same `text` field
(`lib/omarchy_prayer/waybar.rb:49`); it is sanitised in `Status.build`
(`lib/omarchy_prayer/status.rb:26`), so markup is NOT exploitable today — but
enabling it makes `Sanitize.display` load-bearing for waybar in a way it was
not before. That must be a deliberate, commented decision, not a side effect.

**COMMITMENT MADE ON THE USER'S BEHALF:** the comment says that if the
contributor does not reply, the maintainer will port the three features to the
current renderer, crediting them by name in the commit and release notes. The
user approved the wording. **If PR #4 goes quiet, that port is owed** — do not
let it lapse into another three-month silence.

---

## Context in one paragraph

The user upgraded to Omarchy 4.0.0 ("Quarto"), which replaced waybar with a
Quickshell shell (`omarchy-shell`) and mako with an in-shell notification
daemon. An end-to-end audit of v0.1.7 on that machine found the core healthy
but five integration points broken. v0.2.0 ports the bar integration to a
native Quickshell plugin and fixes the compat breakages.

## Audit results (2026-08-16, Omarchy 4.0.0, machine `mrcode`)

**Healthy — do not re-investigate:**

- Test suite: 133 runs, 397 assertions, 0 failures, 1 skip
- Scheduler: 5 transient timers per day, past ones pruned, daily rebuild active
- Prayer times / cache / offline calc
- `notify-send` delivery — Quickshell owns `org.freedesktop.Notifications`
- TUI rendering, hijri date, qibla
- `omarchy-prayer-waybar` still emits valid JSON

**Broken — the work items:**

| # | Breakage | Detail |
|---|---|---|
| 1 | No bar widget | `~/.config/waybar/` gone; bar is Quickshell |
| 2 | Theme falls back silently | Theme moved to `~/.local/state/omarchy/current/theme/alacritty.toml` |
| 3 | DND ignored | `makoctl mode` fails; use `omarchy-shell notifications isDnd` |
| 4 | `setup` reports work it didn't do | Claims "waybar widget" when none exists |
| 5 | Dead package deps | PKGBUILD depends on `mako` + `waybar` |

## Decisions made (do NOT re-ask)

| Question | Decision |
|---|---|
| Scope | Everything: compat fixes **and** the Quickshell plugin |
| Waybar support | Keep, but `optdepends` only — not a hard dependency |
| Widget richness | Pill **+ native popup panel** (not a faithful tooltip-only port) |
| Panel layout | **Layout B** — rows with status tags, qibla/method footer, action buttons |
| Action buttons | **Keep** — "Mute today" and "Stop adhan" in the panel |
| Pill placement | Bar **right section, index 0** (immediately before the tray) |
| Glyph | **Keep** the glyph on the pill |
| Data source | New `omarchy-prayer status --json`; Ruby owns all math |
| Countdown | **Ticks locally in QML** off `next.epoch`; data refreshes separately |
| Install UX | Auto-install **and** auto-enable, but enable **once only** |
| Version compat | **Runtime detection** of Quickshell vs waybar |
| Config rename | `[waybar]` → `[bar]` **with migration** |
| Version | **0.2.0** |

## Constraints carried in

- **Adhan audio always muted by default** — never flip `[audio].enabled` to true
- **Test isolation** — restore any mutated env vars / module constants in `teardown`
  (this broke the v0.1.5 AUR `check()`)
- Ship via the usual flow: merge → tag → GitHub → PKGBUILD bump → AUR

## Key technical findings

- `PluginRegistry.qml:11` hardcodes `pluginsDir: home + "/.config/omarchy/plugins"`.
  **Pacman cannot own the live plugin files** — setup must copy into `$HOME`.
- **Plugin id is `io.github.mrcode.prayer-times`.** The shell does not validate
  ids, but the marketplace treats them as permanent and globally unique, so the
  original generic `prayer.times` was renamed in v0.2.2 with an automatic
  migration. `ShellPlugin::LEGACY_PLUGIN_ID` still carries the old value — do
  not delete it while anyone may still be on 0.2.0/0.2.1.
- **The shell keys plugins on the manifest id, not the directory name.** If the
  two disagree the widget silently does not render; `warn_on_id_mismatch` now
  reports that case.
- Omarchy ships **no generic command-output widget** — a bar widget must be QML.
- `omarchy-shell shell ping` → `ok` is the liveness probe. **Do not** detect
  Quickshell via `shell.json` existing — that file is optional.
- Ruby producer subprocess cost: ~43 ms.
- **Theme parse needs more than a path fix:** `parse_theme_file` regexes the first
  `black =`, which in the v4 file is `[colors.normal].black` — identical to the
  background, so muted text would render invisible. Parse with `Tomlrb` by section
  and take `[colors.bright].black` for `muted`.
- `with_shims` in `test/test_helper.rb` supports stdout via
  `OP_SHIM_STDOUT_<NAME>` (name uppercased, non-alnum → `_`), e.g.
  `OP_SHIM_STDOUT_OMARCHY_SHELL`.

## Where things live

- Spec: `docs/superpowers/specs/2026-08-16-omarchy4-quickshell-design.md` (committed `d4ec04f`)
- Plan: `docs/superpowers/plans/2026-08-16-omarchy4-quickshell.md`
- Design mockups: `.superpowers/brainstorm/` (gitignored; companion server stopped)

## Implementation notes (discovered while building)

Things that cost time and would cost it again:

- **`data` is QML's default property on `Item`.** Naming the widget's status
  property `data` makes child elements unassignable and breaks the whole
  component. It is called `prayerData`.
- **`Ui/Button` emits `clicked()`**, while `Ui/WidgetButton` emits
  `pressed(int button)`. They are not interchangeable.
- **`Ui/BarIconButton` is icon-only** (fixed slot width). A text pill needs
  `Ui/WidgetButton` directly, as `omarchy.clock` does.
- **Quickshell caches compiled QML.** After a syntax-level fix, `rescanPlugins`
  can keep serving the old version — use `omarchy restart shell` to be sure.
- **The test shim had a concurrent-append race.** It wrote each log line with
  three separate `printf >>` calls, so a detached mpv and a foreground
  notify-send spliced into one corrupted entry. Now a single atomic append;
  verified across 14 seeds.

## Verified live on Omarchy 4.0.0

Confirmed by observation on the real machine, not just by tests:

- Widget renders on the bar, countdown ticks, panel opens, IPC refresh works
- All four pill states seen: normal, amber "soon", dimmed muted, error
- `setup` installs + places the plugin, backs up `shell.json`
- Removing the widget from the bar survives a re-run of `setup`
- `[waybar]` → `[bar]` migration ran against the real config
- DND on → notification suppressed; DND off → notification fires
- Theme resolves the live Everforest palette (`muted` ≠ background)
- `omarchy-prayer-waybar` output unchanged
- **Full daily cycle at Isha 2026-08-16:** pre-notification fired 19:47:00,
  on-time fired 19:57:00, adhan played to completion (~3m21s), and the widget
  rolled over to tomorrow's Fajr and dropped out of amber — all unattended
- Adhan on/off button toggles correctly; mosque and muted-speaker glyphs both
  render in the bar font
- **Plugin id migration ran on the real install:** the bar entry was renamed in
  place, the widget kept index 0 before the tray, the stale directory was
  removed, and `shell.json` was backed up first

## Release notes (v0.2.0, 2026-08-16)

Shipped. One late scare worth remembering: the AUR `check()` runs the suite
**without bundler**, where `minitest/mock` does not exist on Ruby 4.x — the new
`.stub` calls died there while `bundle exec rake test` was green. Fixed by
injecting the plugin source instead of monkeypatching, then the tag was moved
to the fix commit (nothing had consumed it yet) and the checksum recomputed.
See [[feedback-pkgbuild-check-divergence]].

## v0.2.1 (2026-08-17)

Adds `omarchy-prayer audio on|off|toggle|status`, `audio_enabled` in the status
JSON, and an **Adhan on/off** button in the panel plus a muted-speaker glyph on
the pill. Motivated by a real gap: the widget showed the *today-only* mute but
gave no way to see or change the standing `[audio].enabled` setting.

Lesson (second occurrence): `bar.run` executes via `bash -lc` through **PATH**,
so it runs the *installed* CLI, and failures are silent. The button appeared
dead because 0.2.0 had no `audio` subcommand. Verify with
`bash -lc "omarchy-prayer <cmd>"`, never `ruby -Ilib`. New JSON fields are now
gated on presence so an older CLI hides the control instead of misreporting it.
See [[feedback-verify-via-path]].

## v0.2.2 (2026-08-17) — namespaced plugin id

Renamed `prayer.times` → `io.github.mrcode.prayer-times` before the marketplace
listing was approved, since ids there are permanent and a generic one could
collide. `setup` migrates existing installs: it renames the id in place in
`shell.json` (preserving the widget's bar position), removes the stale plugin
directory, and backs `shell.json` up first. A user who had already removed the
widget is left alone.

**Ordering hazard, hit during the release:** `source_dir` prefers the *packaged*
copy at `/usr/share/omarchy-prayer/shell-plugin`, so running `setup` from the
repo while the installed package still had the old manifest copied an old
`manifest.json` into the new directory name — the bar entry and manifest id
disagreed and the widget vanished. For a real upgrade the order is correct
(pacman installs the new manifest, then setup runs). `warn_on_id_mismatch`
now surfaces it rather than failing silently.

Also note: `omarchy-shell -q <target> <method>` returns success even when the
target does not exist. Never use `-q` to *verify* anything — drop it when
checking whether IPC actually works.

## v0.3.0 (2026-08-17) — pill design presets

Three named pill designs, selectable from the panel's chip row or the CLI:

| Preset | Pill reads |
|---|---|
| `full` | `Riyadh · Isha 1h 26m` |
| `minimal` | `Isha 1h 26m` |
| `icon` | mosque glyph alone; times move to the tooltip and panel |

Also: `omarchy-prayer bar preset|names|compact|quiet|status`, Arabic prayer
names (`bar names arabic`, pill/panel only — notifications and TUI stay
English on purpose, so alerts read the same regardless of display setting),
compact countdown (`1:26` instead of `1h 26m`), and quiet-until-near (collapse
to the glyph until the prayer is within N minutes).

**Derived preset, not stored** (`lib/omarchy_prayer/bar_preset.rb`): a preset
is just a `format` string under `[bar]`. `BarPreset.name_for` recovers the
active name by matching the stored format back against the catalogue, rather
than a separate `preset = "minimal"` key being persisted alongside it.
Storing the name redundantly would go stale the moment someone hand-edits
`format` — the picker would keep highlighting a design the bar isn't actually
rendering. Deriving it means a hand-written format can never disagree with
what's on screen: it just falls out as `custom`, chips unhighlighted.

**RTL/bidi finding — real, reproduced on the live bar.** The Arabic preset
feeds an RTL prayer name (e.g. `العشاء`) into a string that also has a
trailing LTR countdown (`1h 26m`). Unicode's bidi algorithm can pull the
countdown's leading digits across the RTL run and visually reorder the pill.
Both renderers anchor the countdown with a leading U+200E (LEFT-TO-RIGHT
MARK) — invisible, no visible character added — to pin its direction. Caught
by testing the Arabic preset on the actual Omarchy 4 bar, not by unit tests
alone: `Model.js#renderPill` got the anchor first, then `tooltipLine` turned
out to bypass it and show unanchored text whenever the pill is collapsed
(icon preset, quiet-until-near) — fixed in `203b8ac`, verified by a
`journalctl` codepoint dump showing U+200E landing immediately before the
countdown digits in the resolved tooltip text.

**The waybar anchor is deliberately conditional, not a mirror of Model.js.**
Round 1 (`5b6049a`) anchored unconditionally in `lib/omarchy_prayer/waybar.rb`,
matching Model.js exactly. Review pushed back (`e2fbcdf`): waybar is a
released, widely-installed code path, and anchoring unconditionally would
change the shipped `text` bytes for 100% of Latin-default installs to fix a
defect that only manifests under the opt-in `names = "arabic"` preset — the
"identical by construction" argument doesn't hold because the Quickshell
widget is new and carries no legacy-compatibility burden that waybar does.
Fix: detect RTL characters (Hebrew/Arabic/Arabic Supplement ranges) in
`next.pretty` and anchor only when the prayer name is actually RTL. Latin
waybar output is now byte-identical to what shipped before either fix; RTL
output still gets the anchor at the same position Model.js applies it.

**Verification done this session (task 10 — version bump, docs, tests only;
publication is out of scope, see task-10-report.md):**

- `bundle exec rake test` and `ruby -Ilib -Itest -e 'Dir["test/test_*.rb"]...'`
  both green: 249 runs, 0 failures, 0 errors, 1 skip (766 vs 767 assertions —
  run-to-run variance, not a defect)
- `omarchy plugin validate share/omarchy-shell-plugin` exits 0
- `./script/sync-plugin-repo` copied + validated + committed locally in
  `../omarchy-prayer-plugin` (commit `1b960c9`, **not pushed**)
- No tag created, nothing pushed to any remote, AUR `PKGBUILD` untouched

## Marketplace listing

- Directory: <https://omarchyplugins.com/> (community, HANCORE-linux/omarchy-plugin-marketplace)
- Standalone plugin repo: <https://github.com/mrCode/omarchy-prayer-plugin>
  — manifest/README/LICENSE plus `preview.png` at the **repo root**, as the
  marketplace requires. This repo stays the source of truth; publish with
  `script/sync-plugin-repo`, which copies, validates, and commits.
- Submission: issue #456, category **Widgets**, tags **Bar** + **Quickshell**.
  Awaiting maintainer review.
- The plugin is *not* self-contained — it fronts the `omarchy-prayer` CLI. That
  dependency is disclosed in the listing and the README, and a 5s watchdog
  reports `omarchy-prayer is not installed` when the binary is missing
  (Quickshell does **not** fire `onExited` in that case).

## v0.3.1 (2026-08-20) — security fix, reported externally

QML `Text` defaults to `Text.AutoText`, which renders markup-shaped input as
RICH text; Qt rich text honours `<img src>` and loads local AND remote
resources. `city`/`country` come from an ip-api.com response, are persisted by
auto-relocate, and reach the pill and panel — so a hostile or intercepted reply
could trigger an unattended fetch from inside the shell process. Reported by
@ryanrhughes on marketplace issue #456.

Fixed in two layers, because the pill's `Text` belongs to Omarchy's
`WidgetButton` and cannot be configured from the plugin:
`textFormat: Text.PlainText` on all nine panel `Text` elements, plus
`OmarchyPrayer::Sanitize` stripping angle brackets at ingress (`Geolocate`) and
egress (`Status`).

**Lesson:** the whole-branch review asked about component interactions and
backward compatibility but never "what if the DATA is hostile?" Untrusted-input
review was not in the rubric. Any field originating from a network response —
`city`, `country` — is attacker-influenced and must be treated as such.

## Known-and-accepted after the v0.3.0 whole-branch review

Deliberately shipped as-is, with rulings — do not "rediscover" these:

- `Waybar.build_tooltip` has no U+200E anchor, so tooltip lines mirror under
  `names = arabic`. Cosmetic, waybar-only, information intact.
- `BarSetting.append_key` can insert a key before a comment block that belongs
  to the next section, mis-annotating it. Non-issue for the shipped template,
  where `[bar]` is last.
- `Model.js` has no automated tests. The final review verified by hand that its
  `formatCountdown` and `Waybar.format_countdown` agree byte-for-byte across 303
  inputs, but nothing enforces that going forward.
- `BarSetting.get` is only called by its own tests; production reads via `Config`.
- `bar quiet` accepts unbounded minutes; `bar names ARABIC` fails safely but the
  usage text does not mention case sensitivity.

**The seam lesson from this branch:** both defects the whole-branch review caught
were the same shape — new code written without knowledge of old code, in a place
no single task's scope contained. `BarSetting` knew `[bar]` but not `[waybar]`
(config corruption); the preset catalogue knew the widget's glyph but not
waybar's lack of one (`icon` renders an empty module). Per-task review cannot
see these. Budget for a whole-branch pass on anything touching legacy paths.

## Possible follow-ups (not scheduled)

- Panel has no keyboard navigation beyond close/tab; rows are not focusable.
- `Model.js` is pure but untested — a node harness could cover countdown
  formatting and placeholder substitution if it ever earns it.
- Vertical-bar layout shows the glyph only; the countdown is not rendered.
