require 'test_helper'
require 'omarchy_prayer/country_methods'

class TestCountryMethods < Minitest::Test
  def test_saudi_arabia_to_makkah
    assert_equal 'Makkah', OmarchyPrayer::CountryMethods.resolve('SA')
  end

  def test_egypt_to_egypt
    assert_equal 'Egypt', OmarchyPrayer::CountryMethods.resolve('EG')
  end

  def test_pakistan_to_karachi
    assert_equal 'Karachi', OmarchyPrayer::CountryMethods.resolve('PK')
  end

  def test_united_states_to_isna
    assert_equal 'ISNA', OmarchyPrayer::CountryMethods.resolve('US')
  end

  def test_iran_to_tehran
    assert_equal 'Tehran', OmarchyPrayer::CountryMethods.resolve('IR')
  end

  def test_turkey_to_turkey
    assert_equal 'Turkey', OmarchyPrayer::CountryMethods.resolve('TR')
  end

  def test_unknown_falls_back_to_mwl
    assert_equal 'MWL', OmarchyPrayer::CountryMethods.resolve('ZZ')
    assert_equal 'MWL', OmarchyPrayer::CountryMethods.resolve(nil)
    assert_equal 'MWL', OmarchyPrayer::CountryMethods.resolve('')
  end

  def test_lowercase_accepted
    assert_equal 'Makkah', OmarchyPrayer::CountryMethods.resolve('sa')
  end
end
