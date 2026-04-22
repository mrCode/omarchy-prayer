module OmarchyPrayer
  module Methods
    # Parameters used by the offline calculator:
    #   fajr_angle: sun depression below horizon for Fajr (degrees)
    #   isha_angle: sun depression for Isha (degrees, unless isha_interval set)
    #   isha_interval: if set, Isha = Maghrib + N minutes (Umm al-Qura convention)
    #   maghrib_angle: sun depression for Maghrib (unset for most → sunset)
    TABLE = {
      'MWL'          => { fajr_angle: 18.0, isha_angle: 17.0 },
      'ISNA'         => { fajr_angle: 15.0, isha_angle: 15.0 },
      'Egypt'        => { fajr_angle: 19.5, isha_angle: 17.5 },
      'Makkah'       => { fajr_angle: 18.5, isha_interval: 90 },
      'Karachi'      => { fajr_angle: 18.0, isha_angle: 18.0 },
      'Tehran'       => { fajr_angle: 17.7, isha_angle: 14.0, maghrib_angle: 4.5 },
      'Jafari'       => { fajr_angle: 16.0, isha_angle: 14.0, maghrib_angle: 4.0 },
      'Kuwait'       => { fajr_angle: 18.0, isha_angle: 17.5 },
      'Qatar'        => { fajr_angle: 18.0, isha_interval: 90 },
      'Singapore'    => { fajr_angle: 20.0, isha_angle: 18.0 },
      'Turkey'       => { fajr_angle: 18.0, isha_angle: 17.0 },
      'Gulf'         => { fajr_angle: 19.5, isha_interval: 90 },
      'Moonsighting' => { fajr_angle: 18.0, isha_angle: 18.0 },
      'Dubai'        => { fajr_angle: 18.2, isha_angle: 18.2 },
      'France'       => { fajr_angle: 12.0, isha_angle: 12.0 }
    }.freeze

    module_function

    def params(name)
      TABLE.fetch(name) { raise ArgumentError, "unknown method: #{name.inspect}" }
    end
  end
end
