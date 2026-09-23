require "test_helper"

class Catches::ApplyFiltersTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    @walleye = create(:species, club: @club, name: "Walleye")
    @perch   = create(:species, club: @club, name: "Perch")
  end

  def call(params)
    Catches::ApplyFilters.call(scope: Catch.where(user: @user), params: ActionController::Parameters.new(params))
  end

  # Walleye catch with the given condition attrs; used by the band tables below.
  def catch_with(**attrs)
    create(:catch, **{ user: @user, species: @walleye, length_inches: 18, captured_at_device: 1.day.ago }.merge(attrs))
  end

  test "no params returns scope unchanged" do
    c = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: 1.day.ago)
    assert_includes call({}), c
  end

  test "species filter narrows by species_id" do
    a = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: 1.day.ago)
    b = create(:catch, user: @user, species: @perch,   length_inches: 10, captured_at_device: 1.day.ago)
    result = call(species: @walleye.id.to_s)
    assert_includes result, a
    refute_includes result, b
  end

  test "lake param selects the matching catches" do
    dam_catch  = create(:catch, user: @user, species: @walleye, length_inches: 18, lake: "boundary_dam", captured_at_device: 1.day.ago)
    null_catch = create(:catch, user: @user, species: @walleye, length_inches: 18, lake: nil,            captured_at_device: 1.day.ago)

    {
      "boundary_dam" => [dam_catch],
      "other"        => [null_catch],
      "neverland"    => [dam_catch, null_catch] # unknown key is ignored -> all lakes
    }.each do |lake, expected|
      result = call(lake: lake)
      assert_equal expected.sort_by(&:id), result.to_a.sort_by(&:id), "lake=#{lake}"
    end
  end

  test "date range filter: start and end bound captured_at_device" do
    in_range  = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.zone.local(2026, 5, 10, 9))
    too_early = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.zone.local(2026, 5, 1,  9))
    too_late  = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.zone.local(2026, 5, 20, 9))
    result = call(start: "2026-05-05", end: "2026-05-15")
    assert_includes result, in_range
    refute_includes result, too_early
    refute_includes result, too_late
  end

  test "min_length filters by inclusive lower bound, ignoring blank/zero" do
    short = create(:catch, user: @user, species: @walleye, length_inches: 12, captured_at_device: 1.day.ago)
    exact = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: 1.day.ago)
    long  = create(:catch, user: @user, species: @walleye, length_inches: 22, captured_at_device: 1.day.ago)

    {
      "18" => [exact, long],        # boundary inclusive, excludes shorter
      ""   => [short, exact, long], # blank ignored
      "0"  => [short, exact, long]  # zero ignored
    }.each do |min_length, expected|
      result = call(min_length: min_length)
      assert_equal expected.sort_by(&:id), result.to_a.sort_by(&:id), "min_length=#{min_length.inspect}"
    end
  end

  test "month filter matches that month across years and ignores invalid values or a date range" do
    may_2024 = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.zone.local(2024, 5, 10, 9))
    may_2025 = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.zone.local(2025, 5, 10, 9))
    jun_2025 = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.zone.local(2025, 6, 10, 9))

    result = call(month: "5")
    assert_includes result, may_2024, "month=5 matches 2024"
    assert_includes result, may_2025, "month=5 matches 2025"
    refute_includes result, jun_2025, "month=5 excludes June"

    # date range would normally exclude 2024; month overrides it
    assert_includes call(month: "5", start: "2026-01-01", end: "2026-12-31"), may_2024, "month overrides start/end"

    ["0", "13", ""].each do |bad_month|
      assert_includes call(month: bad_month), may_2025, "month=#{bad_month.inspect} out-of-range is ignored"
    end
  end

  test "month filter buckets late-evening catches by local time, not UTC" do
    # 10:30pm local on May 31. In UTC this is June 1 04:30. The correct
    # local month is May, so a `month: 5` filter must include this catch.
    late_may = create(:catch, user: @user, species: @walleye, length_inches: 18,
                              captured_at_device: Time.zone.local(2025, 5, 31, 22, 30))
    result = call(month: "5")
    assert_includes result, late_may
  end

  test "wind_dir bands select catches by compass sector (boundaries half-open, wraps 0/360)" do
    cases = {
      45   => { ne: true,  n: false },  # inside NE
      22.5 => { ne: true,  n: false },  # NE lower bound inclusive
      67.5 => { ne: false, n: false },  # NE upper bound exclusive -> belongs to E
      80   => { ne: false, n: false },
      350  => { ne: false, n: true  },  # N wraps across 0/360
      10   => { ne: false, n: true  },
      100  => { ne: false, n: false },
      nil  => { ne: false, n: false }   # missing direction never matches
    }
    cases.each do |deg, expect|
      c = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: 1.day.ago, wind_direction_deg: deg)
      if expect[:ne]
        assert_includes call(wind_dir: "ne"), c, "#{deg.inspect}deg should be in NE"
      else
        refute_includes call(wind_dir: "ne"), c, "#{deg.inspect}deg should not be in NE"
      end
      if expect[:n]
        assert_includes call(wind_dir: "n"), c, "#{deg.inspect}deg should be in N"
      else
        refute_includes call(wind_dir: "n"), c, "#{deg.inspect}deg should not be in N"
      end
    end
  end

  test "wind_dir: unknown value ignored" do
    c = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: 1.day.ago, wind_direction_deg: 45)
    assert_includes call(wind_dir: "up"), c
  end

  test "wind_speed bands select catches by kph range (boundaries inclusive/exclusive)" do
    bands = {
      "calm"   => { match: [3],        miss: [5] },
      "light"  => { match: [5, 15],    miss: [16] },
      "mod"    => { match: [15.5, 25], miss: [15] },
      "strong" => { match: [30],       miss: [25] }
    }
    bands.each do |band, spec|
      spec[:match].each do |kph|
        c = catch_with(wind_speed_kph: kph)
        assert_includes call(wind_speed: band), c, "#{band}: #{kph} kph should match"
      end
      spec[:miss].each do |kph|
        c = catch_with(wind_speed_kph: kph)
        refute_includes call(wind_speed: band), c, "#{band}: #{kph} kph should not match"
      end
    end
  end

  test "pressure bands select catches by hpa range (boundaries inclusive/exclusive)" do
    bands = {
      "low"    => { match: [1005],       miss: [1010] },
      "normal" => { match: [1010, 1020], miss: [1021] },
      "high"   => { match: [1025],       miss: [1020] }
    }
    bands.each do |band, spec|
      spec[:match].each do |hpa|
        c = catch_with(barometric_pressure_hpa: hpa)
        assert_includes call(pressure: band), c, "#{band}: #{hpa} hpa should match"
      end
      spec[:miss].each do |hpa|
        c = catch_with(barometric_pressure_hpa: hpa)
        refute_includes call(pressure: band), c, "#{band}: #{hpa} hpa should not match"
      end
    end
  end

  test "NULL condition columns are excluded when that filter is active" do
    nilled = create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: 1.day.ago,
                            wind_speed_kph: nil, barometric_pressure_hpa: nil, moon_phase_fraction: nil)
    refute_includes call(wind_speed: "calm"), nilled, "wind_speed"
    refute_includes call(pressure: "low"),    nilled, "pressure"
    refute_includes call(moon: "full"),       nilled, "moon"
  end

  test "moon bands select catches by phase fraction (q1 top-exclusive, new wraps 0/1)" do
    bands = {
      "q1"   => { match: [0.25, 0.125], miss: [0.375] }, # bottom inclusive, top exclusive
      "full" => { match: [0.5],         miss: [] },
      "new"  => { match: [0.05, 0.95],  miss: [0.5] }     # wraps across 0/1
    }
    bands.each do |band, spec|
      spec[:match].each do |frac|
        c = catch_with(moon_phase_fraction: frac)
        assert_includes call(moon: band), c, "#{band}: #{frac} should match"
      end
      spec[:miss].each do |frac|
        c = catch_with(moon_phase_fraction: frac)
        refute_includes call(moon: band), c, "#{band}: #{frac} should not match"
      end
    end
  end

  test "tod bands select catches by hour-of-day range (night wraps midnight)" do
    at = ->(hour, min = 0, day = 10) { Time.zone.local(2025, 5, day, hour, min) }
    bands = {
      "dawn"  => { match: [at.(5, 30)],            miss: [at.(7)] },
      "noon"  => { match: [at.(11), at.(13, 59)],  miss: [at.(14)] },
      "night" => { match: [at.(23, 30), at.(2, 0, 11)], miss: [at.(5)] } # wraps across midnight
    }
    bands.each do |band, spec|
      spec[:match].each do |time|
        c = catch_with(captured_at_device: time)
        assert_includes call(tod: band), c, "#{band}: #{time} should match"
      end
      spec[:miss].each do |time|
        c = catch_with(captured_at_device: time)
        refute_includes call(tod: band), c, "#{band}: #{time} should not match"
      end
    end
  end

  test "active_filter_keys returns only keys with valid values" do
    {
      ActionController::Parameters.new => [],
      ActionController::Parameters.new(month: "13", wind_dir: "up", wind_speed: "hurricane",
                                        pressure: "very_low", moon: "halfmoon", tod: "afternoon") => [],
      ActionController::Parameters.new(month: "5", wind_dir: "ne", moon: "halfmoon", pressure: "low", tod: "noon") =>
        %i[month wind_dir pressure tod]
    }.each do |params, expected|
      assert_equal expected, Catches::ApplyFilters.active_filter_keys(params), "params=#{params.to_unsafe_h}"
    end
  end

  test "parse_date parses ISO dates and returns nil for anything unparseable" do
    {
      nil          => nil,
      ""           => nil,
      "banana"     => nil,
      "2026-05-17" => Date.new(2026, 5, 17)
    }.each do |input, expected|
      actual = Catches::ApplyFilters.parse_date(input)
      expected.nil? ? assert_nil(actual, "input=#{input.inspect}") : assert_equal(expected, actual, "input=#{input.inspect}")
    end
  end

  test "filters AND together: only catches matching every active filter survive" do
    match     = create(:catch, user: @user, species: @walleye, length_inches: 22,
                               captured_at_device: 1.day.ago,
                               wind_direction_deg: 45, moon_phase_fraction: 0.5)
    wrong_dir = create(:catch, user: @user, species: @walleye, length_inches: 22,
                               captured_at_device: 1.day.ago,
                               wind_direction_deg: 225, moon_phase_fraction: 0.5)
    wrong_moon = create(:catch, user: @user, species: @walleye, length_inches: 22,
                                captured_at_device: 1.day.ago,
                                wind_direction_deg: 45, moon_phase_fraction: 0.1)
    too_short = create(:catch, user: @user, species: @walleye, length_inches: 12,
                               captured_at_device: 1.day.ago,
                               wind_direction_deg: 45, moon_phase_fraction: 0.5)
    result = call(wind_dir: "ne", moon: "full", min_length: "18")
    assert_includes result, match
    refute_includes result, wrong_dir
    refute_includes result, wrong_moon
    refute_includes result, too_short
  end
end
