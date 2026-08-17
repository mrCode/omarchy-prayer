# Bar pill design presets, Arabic names, and display options

## Motivation

The bar pill has exactly one look: `{city} · {prayer} {countdown}`. Changing it
means hand-editing a format string in `config.toml`, which is undiscoverable —
nothing in the UI hints that the pill is configurable at all.

Users want different amounts of information in a bar that is already crowded.
Some want the city (it catches a wrong auto-detected location immediately);
some want only `Isha 1h 26m`; some want the pill to nearly disappear.

This adds a small set of named designs selectable from the panel, plus three
display options that are orthogonal to the design.

## Decisions

| Question | Decision |
|---|---|
| How the user switches | Panel picker (chip row) **and** a `bar` CLI subcommand |
| Preset model | A fixed named set, not independent toggles |
| Presets shipped | `full`, `minimal`, `icon` |
| Extras shipped | Arabic prayer names, compact countdown, quiet-until-near |
| Dropped | `clock` preset, standalone glyph toggle |
| Arabic scope | Widget only — pill and panel. Notifications and TUI stay English |
| Quiet trigger | Its own `quiet_until_minutes`, default 60 when enabled |
| Picker placement | Chip row, directly above the action buttons |
| Extras in the panel | No — CLI and config only |
| Version | **0.3.0** (additive) |

## Design

### A preset *is* a format string

The key simplification: a preset is not a new rendering mode. It is a named
format string, and the name is recovered by matching the format back against the
catalogue.

| Preset | `format` |
|---|---|
| `full` | `{city} · {prayer} {countdown}` |
| `minimal` | `{prayer} {countdown}` |
| `icon` | `""` (empty — glyph only) |

`omarchy-prayer bar preset minimal` writes only the format:

```toml
[bar]
format = "{prayer} {countdown}"
```

`format` remains the single rendering input, exactly as today, so nothing about
the render path changes and existing configs keep working untouched.

The active preset is **derived** from the format via `BarPreset.name_for`, never
stored. Storing it would go stale the moment someone hand-edited `format`,
leaving the picker highlighting a design the bar is not using. Deriving it is
self-correcting and removes a key. A format matching no preset derives as
`custom`, and the picker highlights nothing.

This also means waybar inherits presets for free — it already renders from
`format`.

### `OmarchyPrayer::BarPreset` (`lib/omarchy_prayer/bar_preset.rb`)

```ruby
BarPreset::PRESETS          # => { 'full' => '...', 'minimal' => '...', 'icon' => '' }
BarPreset.format_for(name)  # => String, or nil when the name is unknown
BarPreset.name_for(format)  # => 'full' | 'minimal' | 'icon' | 'custom'
BarPreset.names             # => %w[full minimal icon]
```

`name_for` compares against the catalogue exactly; anything else is `custom`.

### `OmarchyPrayer::PrayerNames` (`lib/omarchy_prayer/prayer_names.rb`)

```ruby
PrayerNames.pretty(:isha, script: 'arabic')  # => "العشاء"
PrayerNames.pretty(:isha, script: 'latin')   # => "Isha"
```

| Key | Latin | Arabic |
|---|---|---|
| `fajr` | Fajr | الفجر |
| `sunrise` | Sunrise | الشروق |
| `dhuhr` | Dhuhr | الظهر |
| `asr` | Asr | العصر |
| `maghrib` | Maghrib | المغرب |
| `isha` | Isha | العشاء |
| `fajr_tomorrow` | Fajr | الفجر |

An unrecognised script falls back to `latin`. `Status` applies this so every
consumer — pill, panel, waybar tooltip — receives an already-localised `pretty`
and needs no knowledge of scripts.

Only prayer names localise. Panel row tags (`passed`), button labels, and the
qibla/method footer stay English; a full UI translation is out of scope.

**Bidi risk:** `العشاء 1h 26m` mixes an RTL run with LTR digits, and bidi
reordering can produce a surprising visual order. This must be checked on a real
bar during implementation; if it misrenders, wrap the countdown in explicit
direction marks (U+200E LEFT-TO-RIGHT MARK) rather than reordering the format.

### Config

New keys under `[bar]`, all optional. Note there is no `preset` key — the
active preset is derived from `format`:

```toml
[bar]
format                 = "{city} · {prayer} {countdown}"
soon_threshold_minutes = 10
names                  = "latin"     # latin | arabic
compact_countdown      = false
quiet_until_minutes    = 0           # 0 disables; 60 is the suggested value
```

Absent keys take these defaults, so an existing config behaves exactly as it
does today. No migration is required.

### Status additions

The `pill` object gains four fields:

```json
"pill": {
  "format": "{prayer} {countdown}",
  "soon_threshold_minutes": 10,
  "preset": "minimal",
  "compact_countdown": false,
  "quiet_until_minutes": 0
}
```

`names` does not appear: it is applied server-side to every `pretty` value, so
the widget never sees the setting.

### CLI: `omarchy-prayer bar`

```
omarchy-prayer bar preset <full|minimal|icon>   set the design
omarchy-prayer bar preset list                  list designs, marking the active one
omarchy-prayer bar names <latin|arabic>         prayer-name script
omarchy-prayer bar compact <on|off>             compact countdown
omarchy-prayer bar quiet <minutes>              collapse to icon beyond N minutes (0 = off)
omarchy-prayer bar status                       print all current values
```

Writes are section-aware text rewrites of `config.toml` under `[bar]`,
preserving comments and alignment — the same approach `AudioSetting` uses, and
for the same reason. Invalid input prints the valid values and exits 1.

### Widget

**Pill.** `Model.js` gains two pure helpers:

```javascript
formatCountdown(secs, compact)          // compact: "1:26" at >= 1h, else "26m"
shouldCollapse(secs, quietMinutes)      // true when quietMinutes > 0 && secs > quietMinutes * 60
```

When the format is empty, or `shouldCollapse` is true, the pill renders the
glyph alone. In that state the tooltip carries `"<prayer> <countdown>"` rather
than the generic "Prayer times", so the information stays reachable without a
click.

Glyph, amber "soon" tint, dimmed-when-muted and the muted-speaker indicator all
behave as they do now, in every preset.

**Panel.** A `Design` section directly above the action buttons: three chips
(`Full`, `Minimal`, `Icon`), the active one highlighted from `pill.preset`.
Clicking runs `omarchy-prayer bar preset <name>` and refreshes, the same
mechanism the adhan toggle uses. When `preset` is `custom`, no chip is
highlighted and clicking one still switches normally.

The chip row is hidden when `pill.preset` is absent, so an older CLI hides the
control rather than showing a picker that cannot work — the rule established in
0.2.1 for `audio_enabled`.

### Waybar

`Waybar.render_from_status` honours `compact_countdown` and the preset (both
are just the format string and a countdown format, recomputed each poll).

It deliberately **ignores** `quiet_until_minutes`. Collapsing depends on falling
back to a glyph, and the waybar module has no glyph of its own — collapsing
there would render empty text, making the module silently vanish for most of the
day. Quiet-until-near is a Quickshell-widget feature.

## Error handling

| Case | Behaviour |
|---|---|
| `format` matches no preset | Derives as `custom`; renders the literal format. Never raises |
| `format` absent | Default `full` format |
| Unknown `names` value | Falls back to `latin` |
| Negative or non-numeric `quiet_until_minutes` | Treated as 0 (disabled) |
| Invalid CLI argument | Print valid values, exit 1, config untouched |
| Pre-0.3.0 CLI with a 0.3.0 widget | `pill.preset` absent → chip row hidden |

## Testing

- `BarPreset` — catalogue contents, `format_for` for each name and for unknown, `name_for` round-trip, `custom` for an unmatched format
- `PrayerNames` — both scripts for all keys, unknown script falls back to latin, unknown key raises nothing
- `Status` — the four new `pill` fields; `pretty` localised when `names = "arabic"`; unchanged shape when the keys are absent
- `Config` — defaults for all new keys, back-compat when absent, invalid values coerced per the table above
- `bar` CLI — round-trip each subcommand against a fixture config; comments and alignment preserved; invalid input exits 1 without writing
- `Waybar` — compact countdown formatting; collapsed output when quiet applies; unchanged output when both are off
- Tests must not use `.stub` (unavailable outside bundler) and must restore any mutated env

## Out of scope

- Translating the full UI (row tags, buttons, footer) to Arabic
- A `clock` preset and a standalone glyph toggle — considered and dropped
- Per-monitor designs via `shell.json`
- Exposing Arabic names in notifications or the TUI
- A native Omarchy settings form: `settingsForm` names resolve to forms built
  into the shell, and there is no evidence a third-party plugin can supply one
