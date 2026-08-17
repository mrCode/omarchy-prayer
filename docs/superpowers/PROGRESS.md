# PROGRESS — Omarchy 4 support (v0.2.0 / v0.2.1)

> Living state file. **Read this first** in any new session before acting.
> Update it in the same turn a decision is made or a task completes.

**Last updated:** 2026-08-17
**Branch:** `master` (feature branch merged and released)
**Status:** SHIPPED and fully verified on hardware. Latest **v0.2.1**.
GitHub tags `v0.2.0` / `v0.2.1`; AUR `omarchy-prayer 0.2.1-1`; installed locally.
Suite: **184 runs, 524 assertions, 0 failures** — green under both `bundle exec
rake test` and the bundler-less `check()` invocation.

**Nothing is outstanding.** The work that opened this effort is complete; only
the unscheduled follow-ups at the bottom remain, and none are committed to.

**Current machine state:** `[audio].enabled = false` (user turned the adhan off
after testing) — notifications fire, audio does not. This is also the shipped
default; see [[project-adhan-muted-default]].

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
- Plugin IDs are not validated; ours is `prayer.times` (avoids the `omarchy.*` namespace).
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

## Possible follow-ups (not scheduled)

- Panel has no keyboard navigation beyond close/tab; rows are not focusable.
- `Model.js` is pure but untested — a node harness could cover countdown
  formatting and placeholder substitution if it ever earns it.
- Vertical-bar layout shows the glyph only; the countdown is not rendered.
