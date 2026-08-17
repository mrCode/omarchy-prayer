module OmarchyPrayer
  # Prayer names per script. Applied in Status so every consumer — pill, panel,
  # waybar tooltip — receives an already-localised name and needs no knowledge
  # of scripts. Only names localise; the rest of the UI stays English.
  module PrayerNames
    SCRIPTS = %w[latin arabic].freeze
    DEFAULT_SCRIPT = 'latin'.freeze

    NAMES = {
      'latin' => {
        fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr', asr: 'Asr',
        maghrib: 'Maghrib', isha: 'Isha', fajr_tomorrow: 'Fajr'
      }.freeze,
      'arabic' => {
        fajr: 'الفجر', sunrise: 'الشروق', dhuhr: 'الظهر', asr: 'العصر',
        maghrib: 'المغرب', isha: 'العشاء', fajr_tomorrow: 'الفجر'
      }.freeze
    }.freeze

    module_function

    def pretty(key, script: DEFAULT_SCRIPT)
      table = NAMES[script.to_s] || NAMES[DEFAULT_SCRIPT]
      table.fetch(key.to_sym) { NAMES[DEFAULT_SCRIPT].fetch(key.to_sym) }
    end
  end
end
