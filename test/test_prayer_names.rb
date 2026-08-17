require 'test_helper'
require 'omarchy_prayer/prayer_names'

class TestPrayerNames < Minitest::Test
  KEYS = %i[fajr sunrise dhuhr asr maghrib isha fajr_tomorrow].freeze

  def test_latin_names
    assert_equal 'Fajr',    OmarchyPrayer::PrayerNames.pretty(:fajr, script: 'latin')
    assert_equal 'Maghrib', OmarchyPrayer::PrayerNames.pretty(:maghrib, script: 'latin')
    assert_equal 'Fajr',    OmarchyPrayer::PrayerNames.pretty(:fajr_tomorrow, script: 'latin')
  end

  def test_arabic_names
    assert_equal 'الفجر',  OmarchyPrayer::PrayerNames.pretty(:fajr, script: 'arabic')
    assert_equal 'العشاء', OmarchyPrayer::PrayerNames.pretty(:isha, script: 'arabic')
    assert_equal 'الفجر',  OmarchyPrayer::PrayerNames.pretty(:fajr_tomorrow, script: 'arabic')
  end

  def test_every_key_has_both_scripts
    KEYS.each do |key|
      %w[latin arabic].each do |script|
        value = OmarchyPrayer::PrayerNames.pretty(key, script: script)
        refute_nil value, "#{key}/#{script} missing"
        refute_empty value, "#{key}/#{script} empty"
      end
    end
  end

  def test_unknown_script_falls_back_to_latin
    assert_equal 'Isha', OmarchyPrayer::PrayerNames.pretty(:isha, script: 'klingon')
    assert_equal 'Isha', OmarchyPrayer::PrayerNames.pretty(:isha, script: nil)
  end

  def test_scripts_listed
    assert_equal %w[latin arabic], OmarchyPrayer::PrayerNames::SCRIPTS
  end
end
