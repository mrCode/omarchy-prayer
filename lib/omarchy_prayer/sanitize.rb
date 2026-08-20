module OmarchyPrayer
  # Strips markup-significant characters from strings that reach a display
  # surface.
  #
  # This exists because QML's `Text` defaults to `Text.AutoText`, which sniffs
  # its input and renders anything that looks like markup as RICH text. Qt rich
  # text honours `<img src="...">`, which loads local files and REMOTE URLs from
  # inside the shell process. Our `city` and `country` come from an ip-api.com
  # HTTP response, so without this a hostile or intercepted reply could put
  # `<img src="http://attacker/">` on the user's bar and have it fetched
  # unattended on the next auto-relocate.
  #
  # The widget also sets `textFormat: Text.PlainText` on every Text it owns.
  # This is the second layer, and the only protection for the bar pill, whose
  # Text belongs to Omarchy's WidgetButton and cannot be configured from here.
  #
  # Angle brackets never legitimately appear in a place name or country code,
  # so removing them outright is safe and needs no escaping rules.
  module Sanitize
    MARKUP_CHARS = /[<>]/.freeze

    module_function

    # Returns a copy with markup-significant characters removed. Non-strings
    # pass through untouched so callers can hand us nil or a number safely.
    def display(value)
      return value unless value.is_a?(String)
      value.gsub(MARKUP_CHARS, '')
    end
  end
end
