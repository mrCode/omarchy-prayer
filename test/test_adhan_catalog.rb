require 'test_helper'
require 'omarchy_prayer/adhan_catalog'

class TestAdhanCatalog < Minitest::Test
  def test_has_17_sunni_entries
    assert_equal 17, OmarchyPrayer::AdhanCatalog.all.size
  end

  def test_find_by_key
    makkah = OmarchyPrayer::AdhanCatalog.find('makkah')
    refute_nil makkah
    assert_equal 'Adhan Makkah', makkah[:label]
    assert_match %r{praytimes\.org.+Adhan-Makkah\.mp3}, makkah[:url]
  end

  def test_find_returns_nil_for_unknown_key
    assert_nil OmarchyPrayer::AdhanCatalog.find('nonexistent')
  end

  def test_keys_lists_all_slugs
    keys = OmarchyPrayer::AdhanCatalog.keys
    assert_equal 17, keys.size
    assert_includes keys, 'makkah'
    assert_includes keys, 'minshawi'
    assert keys.all? { |k| k.match?(/\A[a-z0-9-]+\z/) }, 'keys must be lowercase-kebab'
  end
end
