require 'json'
require 'omarchy_prayer/today'
require 'omarchy_prayer/prayer_icons'

module OmarchyPrayer
  module Waybar
    PRETTY = {
      fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr',
      asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha',
      fajr_tomorrow: 'Fajr'
    }.freeze

    # Hebrew (U+0590-05FF), Arabic (U+0600-06FF), Arabic Supplement
    # (U+0750-077F). Covers `[bar] names = "arabic"` (the only shipped RTL
    # preset) plus Hebrew "for free" as the same class of problem, without
    # pulling in a full bidi-category library.
    RTL_CHARS = /[\u0590-\u05FF\u0600-\u06FF\u0750-\u077F]/.freeze

    module_function

    # The one renderer. Consumes the same Status structure the Omarchy 4
    # widget does, so the two bars can never drift apart.
    def render_from_status(status, now: Time.now)
      nx   = status['next']
      pill = status['pill']
      secs = nx['epoch'] - now.to_i

      # The countdown substitution is prefixed with U+200E (LEFT-TO-RIGHT
      # MARK) ONLY when {prayer} is an RTL string (e.g. Arabic "العشاء" from
      # `names = "arabic"`). In that case the bidi algorithm can pull the
      # countdown's leading LTR digits across the RTL run, visually
      # reordering "1h 26m" around the prayer name; the LRM anchors the
      # countdown's direction without adding a visible character. This
      # mirrors where Model.js#renderPill in the Quickshell widget (share/
      # omarchy-shell-plugin/Model.js) applies the same anchor -- do not
      # "clean up" this invisible character where it does appear.
      #
      # The condition is deliberate, not an oversight: waybar is a
      # released, widely-installed code path, and anchoring unconditionally
      # (as Model.js does -- the widget carries no legacy-compatibility
      # burden) would silently change the `text` bytes for every
      # Latin-default install to fix a defect that only manifests for the
      # opt-in `names = "arabic"` preset. Scoping the anchor to actual RTL
      # prayer names keeps Latin output byte-identical to what shipped
      # before this fix.
      plain_countdown = format_countdown(secs, pill['compact_countdown'] == true)
      countdown = nx['pretty'].to_s.match?(RTL_CHARS) ? "\u200E#{plain_countdown}" : plain_countdown

      # ONE pass, block form. The chained-gsub version expanded a substituted
      # value again on the next pass (a city containing "{prayer}" rendered a
      # second prayer name), and the string form of gsub treats \0, \&,
      # backtick and \' in the REPLACEMENT as backreferences — the same trap
      # Relocate.sub_string documents and avoids.
      subs = {
        '{city}'      => pango(status['city']),
        '{icon}'      => pango(nx['icon']),
        '{prayer}'    => prayer_label(nx, pill['colored'] == true),
        '{time}'      => pango(nx['time']),
        '{countdown}' => pango(countdown)
      }
      text = pill['format'].to_s.gsub(/\{(?:city|icon|prayer|time|countdown)\}/) { subs[Regexp.last_match(0)] }

      cls = secs / 60 < pill['soon_threshold_minutes'] ? 'prayer-soon' : 'prayer-normal'
      JSON.generate(text: text, class: cls, tooltip: build_tooltip(status))
    end

    # waybar renders this label through Pango markup UNCONDITIONALLY: its
    # documented JSON contract is {text, tooltip, class, percentage} — there is
    # no "markup" key to opt in with — and our module snippet does not set
    # "escape": true. So `Sanitize` stripping angle brackets is load-bearing for
    # EVERY user, not only those who turn colours on. Do not relax it on the
    # belief that markup parsing is opt-in; it is not.
    #
    # `&` is the other character Pango treats specially, and Sanitize does not
    # strip it. Unescaped, a legitimate name like "Tom & Jerry" fails
    # gtk_label_set_markup outright and the module renders BLANK. Escape it on
    # the way in — after this, the only markup in the string is ours.
    def pango(value)
      value.to_s.gsub('&', '&amp;')
    end

    # Pango-coloured prayer name, time-of-day palette from PR #4 by
    # @ch-arslanahmad. Only the NAME is wrapped: the `{icon}` emoji carries its
    # own colour and ignores a Pango foreground, so including it would add a
    # span that changes nothing.
    def prayer_label(nx, colored)
      pretty = pango(nx['pretty'])
      return pretty unless colored
      color = PrayerIcons.color_for(nx['name'])
      return pretty unless color
      "<span color='#{color}'>#{pretty}</span>"
    end

    # Historical signature, kept so callers passing loose args keep working.
    # Builds the minimal Status shape and delegates.
    def render(today, now: Time.now, format:, soon_minutes:, city:)
      name, at = today.next_prayer(now: now)
      status = {
        'city'    => city,
        'prayers' => Today::ORDER.map { |p| { 'pretty' => PRETTY[p], 'time' => today.times[p] } },
        'next'    => { 'pretty' => PRETTY.fetch(name),
                       'time'   => at.strftime('%H:%M'),
                       'epoch'  => at.to_i },
        'pill'    => { 'format' => format, 'soon_threshold_minutes' => soon_minutes }
      }
      render_from_status(status, now: now)
    end

    def format_countdown(secs, compact = false)
      secs = 0 if secs < 0
      h = secs / 3600
      m = (secs % 3600) / 60
      return "#{m}m" unless h.positive?
      compact ? format('%d:%02d', h, m) : "#{h}h #{m}m"
    end

    # Also a markup label (set_tooltip_markup), so it needs the same escaping.
    def build_tooltip(status)
      status['prayers']
        .map { |p| format('%-7s %s', pango(p['pretty']), pango(p['time'])) }
        .join("\n")
    end
  end
end
