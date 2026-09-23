require "test_helper"

module Tournaments
  class PointsScaleTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
    end

    test "returns nil below the club's minimum entry count" do
      [0, 1, 2].each do |n|
        assert_nil PointsScale.call(club: @club, entry_count: n), "expected nil for #{n} entries"
      end
    end

    test "honours a customised minimum entry count" do
      @club.update!(season_points_min_entries: 5)
      assert_nil PointsScale.call(club: @club, entry_count: 4)
      assert_equal [3, 2, 1], PointsScale.call(club: @club, entry_count: 5)
    end

    test "tiered_ladders returns the ladder for the entry count's band" do
      { 3 => [3, 2, 1], 9 => [3, 2, 1], 10 => [6, 4, 2], 19 => [6, 4, 2],
        20 => [9, 6, 3], 29 => [9, 6, 3], 30 => [9, 6, 3], 75 => [9, 6, 3] }.each do |entries, expected|
        assert_equal expected, PointsScale.call(club: @club, entry_count: entries),
                     "expected #{expected.inspect} for #{entries} entries"
      end
    end

    test "tiered_ladders supports ladders longer than three places" do
      @club.update!(season_points_ladders: [[10, 8, 6, 5, 4], [6, 4, 2], [9, 6, 3], [9, 6, 3]])
      assert_equal [10, 8, 6, 5, 4], PointsScale.call(club: @club, entry_count: 4)
    end

    test "base_ladder multiplies the base by the band's multiplier" do
      @club.update!(season_points_scheme: :base_ladder)
      assert_equal [3, 2, 1], PointsScale.call(club: @club, entry_count: 5)
      assert_equal [6, 4, 2], PointsScale.call(club: @club, entry_count: 12)
      assert_equal [9, 6, 3], PointsScale.call(club: @club, entry_count: 25)
      assert_equal [9, 6, 3], PointsScale.call(club: @club, entry_count: 40)
    end

    test "base_ladder rounds a fractional multiplier to two places" do
      @club.update!(season_points_scheme: :base_ladder,
                    season_points_tier_multipliers: [1, 1.5, 2, 2.5])
      assert_equal [4.5, 3.0, 1.5], PointsScale.call(club: @club, entry_count: 12)
    end

    test "full_field pays every entry, highest rung equal to the entry count" do
      @club.update!(season_points_scheme: :full_field)
      assert_equal [8, 7, 6, 5, 4, 3, 2, 1], PointsScale.call(club: @club, entry_count: 8)
      assert_equal [3, 2, 1], PointsScale.call(club: @club, entry_count: 3)
    end

    test "full_field still respects the minimum entry count" do
      @club.update!(season_points_scheme: :full_field)
      assert_nil PointsScale.call(club: @club, entry_count: 2)
    end

    # FIX 2 regression: jsonb stores whatever is written, so a ladder saved
    # by any path that skips validation (update_column here stands in for a
    # legacy row, a console fix, etc.) can hold Strings. The dispatch point
    # is the last guard before SeasonPointsAwarded sums placement points
    # into an accumulator with `+=`, where a String used to raise TypeError.
    test "tiered_ladders returns numerics even when the stored ladder holds strings" do
      @club.update_column(:season_points_ladders, [["9", "6", "3"], [6, 4, 2], [9, 6, 3], [9, 6, 3]])

      scale = PointsScale.call(club: @club, entry_count: 5)

      assert_equal [9.0, 6.0, 3.0], scale
      assert(scale.all? { |amount| amount.is_a?(Numeric) })
    end
  end
end
