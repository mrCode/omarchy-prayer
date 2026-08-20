require 'test_helper'
require 'omarchy_prayer/sanitize'

class TestSanitize < Minitest::Test
  def test_strips_angle_brackets
    assert_equal 'img src=x', OmarchyPrayer::Sanitize.display('<img src=x>')
  end

  def test_neutralises_a_remote_image_payload
    payload = '<img src="http://attacker.invalid/beacon.png">Riyadh'
    cleaned = OmarchyPrayer::Sanitize.display(payload)
    refute_includes cleaned, '<'
    refute_includes cleaned, '>'
    assert_includes cleaned, 'Riyadh'
  end

  def test_leaves_ordinary_place_names_untouched
    ['Riyadh', 'SA', "Coeur d'Alene", 'São Paulo', 'Al Khubar', ''].each do |name|
      assert_equal name, OmarchyPrayer::Sanitize.display(name)
    end
  end

  def test_passes_through_non_strings
    assert_nil OmarchyPrayer::Sanitize.display(nil)
    assert_equal 42, OmarchyPrayer::Sanitize.display(42)
  end
end
