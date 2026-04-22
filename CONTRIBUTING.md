# Contributing to omarchy-prayer

Thanks for your interest. This project is a Muslim prayer-time notifier for Omarchy (Hyprland / mako / waybar). Contributions — bug fixes, calculation-method additions, new adhan catalog entries, alternate notification backends — are welcome.

## Development setup

```bash
git clone https://github.com/baljedai/omarchy-prayer.git
cd omarchy-prayer
bundle install
bundle exec rake test
```

All tests should pass (currently 66 runs, 178 assertions).

## Workflow

1. Open an issue describing the bug or feature before starting significant work — it avoids duplicated effort and lets us align on approach.
2. Fork and branch off `master`. Name branches by intent: `fix/stop-race`, `feat/shia-catalog`, `docs/readme-typo`.
3. Write tests first where the code is pure logic (parsing, calculation, state). Integration is tested via the end-to-end smoke in `test/test_smoke.rb`.
4. Keep commits focused and messages descriptive. `git log --oneline` reads like a changelog — match that style.
5. Open a PR against `master`. CI runs `rake test` on every push.

## Code conventions

- Ruby ≥ 3.0, 2-space indent, no shebang guards.
- Library lives in `lib/omarchy_prayer/`. Each file has one clear responsibility and a small public surface.
- Entry scripts in `bin/` are thin — they wire modules together, do not contain business logic.
- Tests in `test/`, named `test_<module>.rb`. Use the `TestHelper` mixin (`with_isolated_home`, `with_shims`) — never touch real home state.
- External commands (mpv, notify-send, systemd-run, makoctl) must be invocable via shims for tests. Never hard-code `/usr/bin/...`.

## Adding a new adhan to the catalog

Open `lib/omarchy_prayer/adhan_catalog.rb` and add a new entry:

```ruby
{ key: 'slug-name', label: 'Human Label', url: 'https://...mp3' }
```

Constraints:
- `key` must be lowercase kebab-case, unique, and safe as a filename.
- Prefer directly-linkable MP3s from stable hosts. If unsure about licensing, say so in the PR.
- Update tests in `test/test_adhan_catalog.rb` — the `test_has_17_sunni_entries` count should bump.

## Adding a new calculation method

Two files touched:

1. `lib/omarchy_prayer/methods.rb` — add the new entry to `TABLE` with `fajr_angle` / `isha_angle` / `isha_interval` / `maghrib_angle` as appropriate.
2. `lib/omarchy_prayer/aladhan_client.rb` — add the Aladhan method ID to `METHOD_IDS` if the API supports it.

If the method has a canonical country mapping (e.g. a national authority), add it to `lib/omarchy_prayer/country_methods.rb` too.

Verify offline-calc accuracy against live Aladhan for at least one reference city within ±2 minutes — add a fixture to `test/test_offline_calc.rb`.

## Running locally without installing

```bash
export XDG_CONFIG_HOME=/tmp/opcfg
export XDG_STATE_HOME=/tmp/opstate
mkdir -p $XDG_CONFIG_HOME/omarchy-prayer
# ... seed config.toml ...
ruby -Ilib bin/omarchy-prayer today
```

## Reporting issues

Include:
- Omarchy / Arch / distro version.
- `omarchy-prayer status` output.
- Relevant journalctl: `journalctl --user -u omarchy-prayer-schedule.service -n 50`.
- Steps to reproduce.

## Licensing

By contributing you agree your work is licensed under the MIT License (see `LICENSE`).
