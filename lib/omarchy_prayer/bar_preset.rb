module OmarchyPrayer
  # Named pill designs. A preset is just a format string; the active preset is
  # recovered by matching the stored format back against this catalogue rather
  # than being persisted, so hand-editing `format` can never leave the picker
  # highlighting a design the bar is not using.
  module BarPreset
    PRESETS = {
      'full'    => '{city} · {prayer} {countdown}',
      'minimal' => '{prayer} {countdown}',
      'icon'    => ''
    }.freeze

    CUSTOM = 'custom'.freeze

    module_function

    def names
      PRESETS.keys
    end

    def format_for(name)
      PRESETS[name.to_s]
    end

    def name_for(format)
      return CUSTOM if format.nil?
      PRESETS.key(format.to_s) || CUSTOM
    end
  end
end
