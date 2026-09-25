require "test_helper"

module SeasonPoints
  class CurrentSeasonTagTest < ActiveSupport::TestCase
    setup { @club = create(:club) }

    test "returns nil when no points-eligible tournaments" do
      create(:tournament, club: @club, awards_season_points: false, season_tag: "Wednesday 2026")
      assert_nil CurrentSeasonTag.call(club: @club)
    end

    test "returns nil when points-eligible tournaments lack a season_tag" do
      create(:tournament, club: @club, awards_season_points: true, season_tag: nil)
      assert_nil CurrentSeasonTag.call(club: @club)
    end

    test "returns the season_tag of the most recent points-eligible tournament" do
      create(:tournament, club: @club, awards_season_points: true, season_tag: "Wednesday 2025", starts_at: 2.years.ago)
      create(:tournament, club: @club, awards_season_points: true, season_tag: "Wednesday 2026", starts_at: 1.week.ago)
      assert_equal "Wednesday 2026", CurrentSeasonTag.call(club: @club)
    end

    test "a pre-scheduled next-season night does not displace the season in play" do
      create(:tournament, club: @club, awards_season_points: true, season_tag: "Wednesday 2026", starts_at: 1.week.ago)
      create(:tournament, club: @club, awards_season_points: true, season_tag: "Wednesday 2027",
             starts_at: 8.months.from_now, ends_at: 8.months.from_now + 3.hours)
      assert_equal "Wednesday 2026", CurrentSeasonTag.call(club: @club)
    end

    test "falls back to the soonest upcoming season when nothing has started yet" do
      create(:tournament, club: @club, awards_season_points: true, season_tag: "Wednesday 2027",
             starts_at: 8.months.from_now, ends_at: 8.months.from_now + 3.hours)
      create(:tournament, club: @club, awards_season_points: true, season_tag: "Wednesday 2028",
             starts_at: 20.months.from_now, ends_at: 20.months.from_now + 3.hours)
      assert_equal "Wednesday 2027", CurrentSeasonTag.call(club: @club)
    end

    test "ignores non-points-eligible tournaments even if more recent" do
      create(:tournament, club: @club, awards_season_points: true, season_tag: "Wednesday 2026", starts_at: 1.month.ago)
      create(:tournament, club: @club, awards_season_points: false, season_tag: "Casual", starts_at: 1.day.ago)
      assert_equal "Wednesday 2026", CurrentSeasonTag.call(club: @club)
    end
  end
end
