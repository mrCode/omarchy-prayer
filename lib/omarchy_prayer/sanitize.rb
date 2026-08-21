module OmarchyPrayer
  # Cleans strings that originate outside our control before they reach any
  # display surface - a terminal, a QML Text, or a notification body.
  #
  # `city` and `country` come from a geolocation HTTP response and are
  # persisted into config.toml, so they are attacker-influenced data replayed
  # on every run. Two distinct hazards, both handled here:
  #
  #   1. MARKUP. QML's `Text` defaults to `Text.AutoText`, which renders
  #      markup-shaped input as RICH text; Qt rich text honours <img src=...>
  #      and loads local and remote resources.
  #
  #   2. TERMINAL CONTROL CHARACTERS. The TUI and `omarchy-prayer status`
  #      print these values straight to the terminal. An attacker never needs
  #      to send a raw ESC byte - that would break TOML parsing. They send the
  #      literal six characters backslash-u-0-0-1-b, which contain no markup,
  #      survive naive filtering, and are written into config.toml as a valid
  #      basic string. Tomlrb then DECODES them back into a real ESC on load.
  #      The classic payload is OSC 52, which writes the user's clipboard, so
  #      their next paste into a shell runs attacker-chosen text.
  #
  # Stripping is safe because none of these characters legitimately appear in
  # a place name or country code. The length cap bounds a hostile value that
  # would otherwise wrap the bar or the TUI.
  module Sanitize
    MARKUP_CHARS = /[<>]/.freeze

    # C0/C1 controls (ESC, BEL, CR, ...) plus Unicode format characters, which
    # include the bidi overrides used to disguise text.
    CONTROL_CHARS = /[\p{Cc}\p{Cf}]/.freeze

    MAX_LENGTH = 64

    module_function

    # Returns a display-safe copy. Non-strings pass through untouched so
    # callers can hand us nil or a number safely.
    def display(value)
      return value unless value.is_a?(String)
      value.gsub(MARKUP_CHARS, '')
           .gsub(CONTROL_CHARS, '')
           .slice(0, MAX_LENGTH)
    end
  end
end
