require "test_helper"
require "ostruct"

class ApplicationHelperTest < ActionView::TestCase
  setup { travel_to Time.zone.local(2026, 6, 15, 12, 0) }
  teardown { travel_back }

  def tournament(starts_at:, ends_at: nil)
    OpenStruct.new(starts_at: starts_at, ends_at: ends_at)
  end

  test "tournament_window formats the start/end moments" do
    {
      "missing starts_at returns nil" => [tournament(starts_at: nil), nil],
      "no ends_at renders the start moment" =>
        [tournament(starts_at: Time.zone.local(2026, 9, 20, 8, 0)), "Sep 20 · 8:00 AM"],
      "same-day window collapses to one date with two times" =>
        [tournament(starts_at: Time.zone.local(2026, 9, 20, 8, 0), ends_at: Time.zone.local(2026, 9, 20, 17, 0)),
         "Sep 20 · 8:00 AM – 5:00 PM"],
      "multi-day window shows both moments separately" =>
        [tournament(starts_at: Time.zone.local(2026, 9, 20, 8, 0), ends_at: Time.zone.local(2026, 9, 22, 17, 0)),
         "Sep 20 · 8:00 AM – Sep 22 · 5:00 PM"],
      "prior year includes the year in the date" =>
        [tournament(starts_at: Time.zone.local(2025, 9, 20, 8, 0)), "Sep 20, 2025 · 8:00 AM"]
    }.each do |label, (t, expected)|
      actual = tournament_window(t)
      expected.nil? ? assert_nil(actual, label) : assert_equal(expected, actual, label)
    end
  end

  # FIX 3 regression: the base_ladder scheme rounds multiplier results to 2
  # dp (e.g. base [3, 2, 1] x multiplier 1.25 = [3.75, 2.5, 1.25]). Formatting
  # at 1 dp truncated 3.75 to "3.8", so a member's nightly values no longer
  # added up to their own season total.
  test "format_season_points renders plain integers, trims trailing zeros, keeps needed decimals" do
    {
      0    => "0",
      6.0  => "6",
      3    => "3",
      3.5  => "3.5",
      0.5  => "0.5",
      3.75 => "3.75",
      2.5  => "2.5"
    }.each do |value, expected|
      assert_equal expected, format_season_points(value), "format_season_points(#{value})"
    end
  end

  test "ordered_species returns species alphabetically and memoizes the load" do
    club = create(:club)
    %w[Zander Bass Walleye].each { |n| create(:species, club: club, name: n) }
    assert_equal %w[Bass Walleye Zander], ordered_species.map(&:name)
    assert_same ordered_species, ordered_species, "should reuse the memoized array"
  end

  test "banner_strip_classes maps style to its color classes, defaulting unknowns to info" do
    {
      "info"  => "bg-yellow-500/20 border-yellow-500/40 text-yellow-200",
      "good"  => "bg-emerald-500/20 border-emerald-500/40 text-emerald-200",
      "alert" => "bg-red-500/20 border-red-500/40 text-red-200",
      nil     => "bg-yellow-500/20 border-yellow-500/40 text-yellow-200"
    }.each do |style, expected|
      assert_equal expected, banner_strip_classes(style), "style=#{style.inspect}"
    end
  end
end
