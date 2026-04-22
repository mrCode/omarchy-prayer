require 'date'
require 'omarchy_prayer/methods'

module OmarchyPrayer
  module OfflineCalc
    module_function

    PRAYERS = %i[fajr sunrise dhuhr asr maghrib isha].freeze

    # Returns { prayer => Time (local) }.
    # asr_factor: 1 (Shafi) or 2 (Hanafi).
    def compute(date:, lat:, lon:, method:, tz_offset:, asr_factor: 1)
      jd = julian_day(date)
      decl, eqt = sun_position(jd)

      # Dhuhr (solar noon) in UTC hours.
      dhuhr_utc = 12 - lon / 15.0 - eqt / 60.0

      params = Methods.params(method)

      fajr_utc    = dhuhr_utc - hour_angle_for_angle(params[:fajr_angle], lat, decl) / 15.0
      sunrise_utc = dhuhr_utc - hour_angle_for_altitude(-0.833, lat, decl) / 15.0
      maghrib_utc =
        if params[:maghrib_angle]
          dhuhr_utc + hour_angle_for_angle(params[:maghrib_angle], lat, decl) / 15.0
        else
          dhuhr_utc + hour_angle_for_altitude(-0.833, lat, decl) / 15.0
        end
      asr_utc     = dhuhr_utc + hour_angle_for_asr(asr_factor, lat, decl) / 15.0
      isha_utc =
        if params[:isha_interval]
          maghrib_utc + params[:isha_interval] / 60.0
        else
          dhuhr_utc + hour_angle_for_angle(params[:isha_angle], lat, decl) / 15.0
        end

      times = {
        fajr: fajr_utc, sunrise: sunrise_utc, dhuhr: dhuhr_utc,
        asr: asr_utc, maghrib: maghrib_utc, isha: isha_utc
      }
      times.transform_values { |h_utc| hour_to_time(date, h_utc, tz_offset) }
    end

    def julian_day(date)
      y = date.year; m = date.month; d = date.day
      if m <= 2; y -= 1; m += 12; end
      a = (y / 100).floor
      b = 2 - a + (a / 4).floor
      (365.25 * (y + 4716)).floor + (30.6001 * (m + 1)).floor + d + b - 1524.5
    end

    # Returns [declination_deg, equation_of_time_minutes].
    def sun_position(jd)
      nd = jd - 2451545.0
      g = (357.529 + 0.98560028 * nd) % 360
      q = (280.459 + 0.98564736 * nd) % 360
      l = (q + 1.915 * Math.sin(r(g)) + 0.020 * Math.sin(r(2*g))) % 360
      e = 23.439 - 0.00000036 * nd
      ra_deg = d(Math.atan2(Math.cos(r(e)) * Math.sin(r(l)), Math.cos(r(l)))) / 15.0
      ra_deg = (ra_deg + 24) % 24
      decl = d(Math.asin(Math.sin(r(e)) * Math.sin(r(l))))
      eqt  = (q / 15.0 - ra_deg) * 60
      [decl, eqt]
    end

    def hour_angle_for_angle(angle_deg, lat, decl)
      h = Math.acos(
        (-Math.sin(r(angle_deg)) - Math.sin(r(lat)) * Math.sin(r(decl))) /
        (Math.cos(r(lat)) * Math.cos(r(decl)))
      )
      d(h)
    end

    def hour_angle_for_altitude(alt_deg, lat, decl)
      hour_angle_for_angle(-alt_deg, lat, decl)
    end

    def hour_angle_for_asr(factor, lat, decl)
      alt = d(Math.atan(1.0 / (factor + Math.tan(r((lat - decl).abs)))))
      hour_angle_for_altitude(alt, lat, decl)
    end

    def hour_to_time(date, h_utc, tz_offset)
      h_local = (h_utc + tz_offset / 3600.0) % 24
      # Round to nearest minute (consistent with how Aladhan presents times).
      total_min = (h_local * 60).round
      hh = total_min / 60
      mm = total_min % 60
      Time.new(date.year, date.month, date.day, hh, mm, 0, tz_offset)
    end

    # Local helpers: r = deg->rad, d = rad->deg.
    def r(deg); deg * Math::PI / 180.0; end
    def d(rad); rad * 180.0 / Math::PI; end
  end
end
