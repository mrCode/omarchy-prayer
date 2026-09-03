# Releasing

**No release goes out without passing both gates below.** Not "usually" — always,
including for one-line and test-only changes. This project ships through the AUR
and a plugin marketplace, so a bad release lands on other people's machines, and
an AUR `check()` failure breaks their *install*, not just our CI.

Both gates run **before** the tag is pushed. A tag is public the moment it lands.

---

## Gate 1 — Functional check

Prove the thing works as installed, not as it looks in the source tree.

```bash
# 1. Suite green under BOTH invocations. The bundler-less one is what
#    PKGBUILD check() runs, and it has diverged from `rake` before.
bundle exec rake test
ruby -Ilib -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'

# 2. check() green UNDER CPU LOAD. A build machine is loaded by definition,
#    and a load-sensitive flake here fails users' installs. (See v0.3.4.)
for c in 1 2 3 4; do timeout 300 bash -c 'while :; do :; done' & done
makepkg -f --nodeps          # in ~/.cache/yay/omarchy-prayer
kill %1 %2 %3 %4

# 3. Install, then exercise the ACTUAL feature through PATH — never via
#    `ruby -Ilib`. The widget resolves the installed binary; verifying the
#    working tree has shipped two broken releases (0.2.0, 0.2.1).
sudo pacman -U omarchy-prayer-<ver>-1-any.pkg.tar.zst
bash -lc 'omarchy-prayer status --json'
bash -lc 'omarchy-prayer <the new subcommand or flag>'

# 4. Plugin, if the widget changed
omarchy-plugin-validate share/omarchy-shell-plugin
omarchy-prayer setup                      # refreshes the live copy
omarchy-shell -q io.github.mrcode.prayer-times refresh

# 5. The user's own config must be untouched by all of the above
sha256sum ~/.config/omarchy-prayer/config.toml   # compare before/after
```

Confirm `[audio].enabled = false` unless the user deliberately turned it on, and
that `[location]` matches where they actually are — auto-relocate legitimately
rewrites it when they travel, so do not assume a city.

## Gate 2 — Security check

Run a security review of the release diff:

```bash
git diff <previous-tag>..HEAD -- lib/ bin/ share/
```

**Mandatory when the change touches any of these**, and cheap enough to run
anyway when it does not:

- a **display sink** — the waybar JSON, the QML pill or panel, the TUI, a
  notification body, or anything printed to a terminal
- **third-party data** — `city`, `country` (IP geolocation), `hijri` (Aladhan
  API), or anything else fetched over the network
- **config writing**, **subprocess spawning**, or **file paths**
- any **markup or escape-interpreting** renderer (Pango, Qt rich text, terminal
  escapes)

Review your own change as if someone else wrote it, or have an independent agent
do it. The specific failure to guard against: **sanitising the data a report
names, rather than the class of sink it belongs to.** That is how v0.3.1 shipped
an incomplete fix that was reported again as v0.3.2, and how v0.3.3's own scan
missed three sinks that a whole-branch pass then caught.

Known trust boundaries, all of which have already produced real vulnerabilities:

| Source | Reaches | Guard |
|---|---|---|
| IP geolocation (`city`, `country`) | config.toml, bar, TUI, notifications | HTTPS enforced, fields validated, `Sanitize.display` at every sink |
| Aladhan API (`hijri`) | status JSON, panel, TUI | `Sanitize.display` |
| `config.toml` values | everywhere | parsed, not `eval`d; written through `BarSetting.literal` |

`Sanitize.display` strips `[<>]`, C0/C1 controls and Unicode format characters,
and caps length. It does **not** escape `&`.

---

## Then release

1. Bump `lib/omarchy_prayer/version.rb`.
2. Bump `share/omarchy-shell-plugin/manifest.json` **only if the widget's QML or
   JS actually changed** — pushing to the plugin repo makes the marketplace flag
   "upstream changes detected" against its verified snapshot until a maintainer
   re-verifies, which is not worth spending on a version string that describes no
   change. The widget gates on a minimum CLI version, not an exact match.
3. Commit, tag, `git push --follow-tags`.
4. **Create the GitHub Release**, not just the tag — bare tags left the Releases
   page advertising v0.1.5 as "Latest" for four months while 0.3.x shipped.
5. AUR: bump `pkgver`, `updpkgsums`, regenerate `.SRCINFO`, push.
6. Sync and tag the plugin repo if step 2 applied.
7. Update `docs/superpowers/PROGRESS.md` in the same pass.
