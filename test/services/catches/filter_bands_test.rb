require "test_helper"

class Catches::FilterBandsTest < ActiveSupport::TestCase
  test "wind direction centres cover all eight cardinals and time-of-day hours cover 0..23 exactly once" do
    assert_equal [0, 45, 90, 135, 180, 225, 270, 315],
                 Catches::FilterBands::WIND_DIR_CENTRES.values
    assert_equal %w[n ne e se s sw w nw],
                 Catches::FilterBands::WIND_DIR_CENTRES.keys

    hours = Catches::FilterBands::TIME_OF_DAY.values.flatten
    assert_equal (0..23).to_a.sort, hours.sort
  end

  test "wind speed, pressure, moon, time-of-day keys are stable and label constants cover their data counterparts" do
    assert_equal %w[calm light mod strong], Catches::FilterBands::WIND_SPEED.keys
    assert_equal %w[low normal high],       Catches::FilterBands::PRESSURE.keys
    assert_equal %w[new q1 full q3],        Catches::FilterBands::MOON.keys
    assert_equal %w[dawn morning noon daylight evening dusk night],
                 Catches::FilterBands::TIME_OF_DAY.keys

    assert_equal Catches::FilterBands::WIND_DIR_CENTRES.keys, Catches::FilterBands::WIND_DIR_LABELS.keys
    assert_equal Catches::FilterBands::WIND_SPEED.keys,       Catches::FilterBands::WIND_SPEED_LABELS.keys
    assert_equal Catches::FilterBands::PRESSURE.keys,         Catches::FilterBands::PRESSURE_LABELS.keys
    assert_equal Catches::FilterBands::MOON.keys,             Catches::FilterBands::MOON_LABELS.keys
    assert_equal Catches::FilterBands::TIME_OF_DAY.keys,      Catches::FilterBands::TIME_OF_DAY_LABELS.keys
  end
end
