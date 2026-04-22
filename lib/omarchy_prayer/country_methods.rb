module OmarchyPrayer
  module CountryMethods
    TABLE = {
      # Makkah (Umm al-Qura)
      'SA' => 'Makkah', 'YE' => 'Makkah',
      # Egypt (Egyptian General Authority)
      'EG' => 'Egypt', 'SY' => 'Egypt', 'IQ' => 'Egypt', 'JO' => 'Egypt',
      'LB' => 'Egypt', 'PS' => 'Egypt', 'DZ' => 'Egypt', 'TN' => 'Egypt',
      'LY' => 'Egypt', 'MA' => 'Egypt', 'SD' => 'Egypt',
      # Karachi
      'PK' => 'Karachi', 'BD' => 'Karachi', 'AF' => 'Karachi', 'IN' => 'Karachi',
      # Tehran (Shia Ithna-Ashari)
      'IR' => 'Tehran',
      # Turkey Diyanet
      'TR' => 'Turkey',
      # Gulf
      'AE' => 'Gulf', 'OM' => 'Gulf', 'BH' => 'Gulf',
      'QA' => 'Qatar',
      'KW' => 'Kuwait',
      # Singapore (also covers MY/BN/ID)
      'SG' => 'Singapore', 'MY' => 'Singapore', 'BN' => 'Singapore', 'ID' => 'Singapore',
      # ISNA — North America
      'US' => 'ISNA', 'CA' => 'ISNA',
      # France
      'FR' => 'France'
    }.freeze

    DEFAULT = 'MWL'

    module_function

    def resolve(code)
      return DEFAULT if code.nil? || code.to_s.strip.empty?
      TABLE.fetch(code.to_s.upcase, DEFAULT)
    end
  end
end
