# PROGRESS — Omarchy 4 support (v0.2.0 → v0.3.3)

> Living state file. **Read this first** in any new session before acting.
> Update it in the same turn a decision is made or a task completes.

**Last updated:** 2026-08-21
**Branch:** merged to `master` (`fix/geolocation-trust-hardening`, `--no-ff`)
**Status:** **v0.3.3 SHIPPED.** GitHub tags `v0.2.0`–`v0.3.3`; AUR
`omarchy-prayer 0.3.3-1`; installed locally and verified through PATH; plugin
repo synced and pushed. Also listed for the community plugin marketplace.
Suite: **278 runs, 884–885 assertions, 0 failures, 1 skip** — green under both
`bundle exec rake test` and the bundler-less `ruby -Ilib -Itest` invocation
(assertion count differs by one run to run; not a failure — see task-10 report).

**Outstanding:** nothing on the code. The design-picker chips were the last
unverified path and a real human click closed that on 2026-08-21 (see START
HERE), and the marketplace listing published on 2026-08-21. Nothing is
outstanding. The only thing in flight is a question asked of @ryanrhughes about
the `manual-setup` badge, which needs no action unless he replies.

**Current machine state:** `[audio].enabled = false` (user turned the adhan off
after testing) — notifications fire, audio does not. This is also the shipped
default; see [[project-adhan-muted-default]].

---

## START HERE next session

Everything is shipped and every repo is clean and pushed. There is no work in
flight. Three items are open, none urgent:

1. ~~Click the design-picker chips.~~ **CLOSED 2026-08-21 — verified by a real
   human click.** The user clicked Minimal in the panel while an `inotifywait`
   watcher sat on `config.toml`; it caught `full` -> `minimal` within a second,
   and three consecutive `status --json` reads then agreed with disk. The whole
   path is exercised for real: click -> `setPreset()` -> `bar.run` -> CLI
   rewrite -> widget re-read. The silent-`bar.run`-failure mode this item
   existed to rule out is ruled out. Method worth reusing for any future
   QML-click verification: watch the FILE, not the pill — the chip could update
   its own selected state without the CLI call landing, so only the config write
   is honest evidence.
2. ~~Marketplace listing.~~ **PUBLISHED 2026-08-21.** Live at
   https://omarchyplugins.com/plugin.html?id=io.github.mrcode.prayer-times —
   manifest v0.3.3, verified snapshot `2ba0549`, compatibility PASSED.
   @ryanrhughes added `approved-and-verified` at 15:07, ~2.5h after the security
   follow-up went up, and the bot listed and closed #456 two minutes later.
   `security-review-required` is still attached but sits alongside
   `approved-and-verified`, so it records that the review happened rather than
   blocking. Getting `validated` needed the issue BODY to carry all six
   `SUBMISSION.md` headings — comments do NOT update metadata.

   **Open question, asked 2026-08-25:** the listing carries a `manual-setup`
   badge ("Standard install cannot produce a functioning plugin"), added by
   @ryanrhughes at the moment of approval. It is ACCURATE and not a docs gap —
   the README already leads with the `yay -S omarchy-prayer` block; the widget
   is a front-end for a system package and cannot work from `omarchy plugin add`
   alone. Asked him what criterion lifts it, if any (comment 5407659947). A
   reply of "it stays for anything depending on a distro package" is an
   acceptable outcome — do not chase it.

   The plugin repo now has tag AND GitHub release `v0.3.3` on `2ba0549`, which
   fills the listing's previously empty "Repository release" field.
3. **@ryanrhughes / issue #456 have been told** about the 0.3.2 and 0.3.3
   fixes (comment 5369851004, posted 2026-08-21 with the user's approval). It
   states plainly that the v0.3.1 "fixed" report was wrong, walks all three
   v0.3.3 findings, and offers to hold the listing pending review. Nothing to do
   but wait for a reply.

Machine state: Location Riyadh, SA. Bar back on the **`full`** preset, Latin
names — the user cycled through the chips during the verification and returned
to `full`. `[audio].enabled = false`, notifications on: the panel's Adhan toggle
got caught alongside the design chips, the user was told rather than having it
changed for them, and they asked for it off at 18:2x on 2026-08-21. This is the
standing state per [[project-adhan-muted-default]].

**Plugin state (all three copies agree at 0.3.3):** the marketplace-listed repo
`mrCode/omarchy-prayer-plugin` (HEAD `2ba0549`, pushed), `share/omarchy-shell-plugin/`
here, and the live copy at `~/.config/omarchy/plugins/io.github.mrcode.prayer-times/`,
which `omarchy-prayer setup` refreshed and which diffs byte-identical to the repo.
**0.3.3 changed the plugin's `manifest.json` version and nothing else — no QML
or JS changed, so the running shell needed no reload.** The QML fix was 0.3.2;
all of 0.3.3's fixes are CLI-side. The version is bumped anyway so the two can
never disagree about what a user has installed.

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

## User-reported issues

Checked 2026-08-25: **none open anywhere.** Zero issues have ever been filed on
`mrCode/omarchy-prayer-plugin`; the CLI repo's only issue,
[#1](https://github.com/mrCode/omarchy-prayer/issues/1) (`tomlrb` LoadError
under a user-managed Ruby, filed 2026-04-22 by @ecleel), was closed as completed
on 2026-08-25.

That fix — shebang pinned to `/usr/bin/ruby` instead of `/usr/bin/env ruby`,
plus `ruby-racc` added to `depends` — shipped in AUR `0.1.1-2` the same day it
was reported, but the issue was never closed behind it and sat open for four
months. Before closing, the fix was re-verified against the CURRENT `0.3.3-1`
package rather than the changelog, on a machine that reproduces the original
condition: this one has a `mise`-managed Ruby ahead of `/usr/bin/ruby` on
`PATH`, which is exactly what broke for the reporter.

**Standing habit worth keeping:** when a fix ships in response to a report,
close the report in the same pass. And when closing something stale, re-verify
against the current build — a changelog entry is not evidence that a fix
survived twelve releases.

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
