require 'test_helper'
require 'omarchy_prayer/bar_preset'

class TestBarPreset < Minitest::Test
  def test_ships_exactly_three_presets
    assert_equal %w[full minimal icon], OmarchyPrayer::BarPreset.names
  end

  def test_format_for_each_preset
    assert_equal '{city} · {prayer} {countdown}',
                 OmarchyPrayer::BarPreset.format_for('full')
    assert_equal '{prayer} {countdown}',
                 OmarchyPrayer::BarPreset.format_for('minimal')
    assert_equal '', OmarchyPrayer::BarPreset.format_for('icon')
  end

  def test_format_for_unknown_name_is_nil
    assert_nil OmarchyPrayer::BarPreset.format_for('nope')
  end

  def test_name_for_round_trips_every_preset
    OmarchyPrayer::BarPreset.names.each do |name|
      format = OmarchyPrayer::BarPreset.format_for(name)
      assert_equal name, OmarchyPrayer::BarPreset.name_for(format),
                   "#{name} did not round-trip"
    end
  end

  def test_name_for_unmatched_format_is_custom
    assert_equal 'custom', OmarchyPrayer::BarPreset.name_for('{prayer} at {time}')
  end

  def test_name_for_nil_is_custom
    assert_equal 'custom', OmarchyPrayer::BarPreset.name_for(nil)
  end
end
