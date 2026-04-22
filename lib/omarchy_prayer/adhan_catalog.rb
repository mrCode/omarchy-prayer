module OmarchyPrayer
  module AdhanCatalog
    SUNNI = [
      { key: 'makkah',        label: 'Adhan Makkah',          url: 'https://praytimes.org/audio/sunni/Adhan-Makkah.mp3' },
      { key: 'madinah',       label: 'Adhan Madinah',         url: 'https://praytimes.org/audio/sunni/Adhan-Madinah.mp3' },
      { key: 'al-aqsa',       label: 'Adhan Al-Aqsa',         url: 'https://praytimes.org/audio/sunni/Adhan-Alaqsa.mp3' },
      { key: 'egypt',         label: 'Adhan Egypt',           url: 'https://praytimes.org/audio/sunni/Adhan-Egypt.mp3' },
      { key: 'halab',         label: 'Adhan Halab',           url: 'https://praytimes.org/audio/sunni/Adhan-Halab.mp3' },
      { key: 'abdul-basit',   label: 'Abdul Basit',           url: 'https://praytimes.org/audio/sunni/Abdul-Basit.mp3' },
      { key: 'abdul-ghaffar', label: 'Abdul Ghaffar',         url: 'https://praytimes.org/audio/sunni/Abdul-Ghaffar.mp3' },
      { key: 'abdul-hakam',   label: 'Abdul Hakam',           url: 'https://praytimes.org/audio/sunni/Abdul-Hakam.mp3' },
      { key: 'al-hussaini',   label: 'Al-Hussaini',           url: 'https://praytimes.org/audio/sunni/Al-Hussaini.mp3' },
      { key: 'bakir-bash',    label: 'Bakir Bash',            url: 'https://praytimes.org/audio/sunni/Bakir-Bash.mp3' },
      { key: 'hafez',         label: 'Hafez',                 url: 'https://praytimes.org/audio/sunni/Hafez.mp3' },
      { key: 'hafiz-murad',   label: 'Hafiz Murad',           url: 'https://praytimes.org/audio/sunni/Hafiz-Murad.mp3' },
      { key: 'minshawi',      label: 'Minshawi',              url: 'https://praytimes.org/audio/sunni/Minshawi.mp3' },
      { key: 'naghshbandi',   label: 'Naghshbandi',           url: 'https://praytimes.org/audio/sunni/Naghshbandi.mp3' },
      { key: 'saber',         label: 'Saber',                 url: 'https://praytimes.org/audio/sunni/Saber.mp3' },
      { key: 'sharif-doman',  label: 'Sharif Doman',          url: 'https://praytimes.org/audio/sunni/Sharif-Doman.mp3' },
      { key: 'yusuf-islam',   label: 'Yusuf Islam',           url: 'https://praytimes.org/audio/sunni/Yusuf-Islam.mp3' }
    ].freeze

    module_function

    def all
      SUNNI
    end

    def find(key)
      SUNNI.find { |e| e[:key] == key }
    end

    def keys
      SUNNI.map { |e| e[:key] }
    end
  end
end
