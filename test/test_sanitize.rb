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

  # The attacker sends the LITERAL characters backslash-u-0-0-1-b; Tomlrb
  # decodes them to a real ESC on load, so by the time we see the value it is
  # a control byte.
  def test_strips_terminal_control_characters
    payload = "Paris\u001b]52;c;cGF5bG9hZA==\u0007\u001b[2JOWNED"
    cleaned = OmarchyPrayer::Sanitize.display(payload)
    refute_includes cleaned, "\u001b", 'ESC must not survive'
    refute_includes cleaned, "\u0007", 'BEL must not survive'
    assert_includes cleaned, 'Paris'
  end

  def test_strips_bidi_format_characters
    refute_includes OmarchyPrayer::Sanitize.display("Riyadh\u202Eevil"), "\u202E"
  end

  def test_caps_length
    assert_equal 64, OmarchyPrayer::Sanitize.display('A' * 500).length
  end

  def test_passes_through_non_strings
    assert_nil OmarchyPrayer::Sanitize.display(nil)
    assert_equal 42, OmarchyPrayer::Sanitize.display(42)
  end
end
