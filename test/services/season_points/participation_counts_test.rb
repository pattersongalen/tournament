require "test_helper"

module SeasonPoints
  class ParticipationCountsTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
      @user = create(:user, club: @club)
    end

    def enter(user, tournament)
      entry = create(:tournament_entry, tournament: tournament)
      create(:tournament_entry_member, tournament_entry: entry, user: user)
      entry
    end

    def main(club: @club, season_tag: "Wed 2026", starts_at: 1.week.ago, **attrs)
      create(:tournament, club: club, awards_season_points: true, season_tag: season_tag,
                          starts_at: starts_at, ends_at: starts_at + 3.hours, mode: :team, **attrs)
    end

    test "counts one per season-points tournament the member entered" do
      enter(@user, main)
      enter(@user, main(starts_at: 2.weeks.ago))
      counts = ParticipationCounts.call(club: @club, season_tag: "Wed 2026")
      assert_equal({ @user.id => 2 }, counts)
    end

    test "ignores side tournaments, other seasons, other clubs, and unstarted nights" do
      enter(@user, main)
      enter(@user, create(:tournament, club: @club, awards_season_points: false, season_tag: "Wed 2026",
                                       mode: :team, starts_at: 1.week.ago, ends_at: 1.week.ago + 3.hours))
      enter(@user, main(season_tag: "Wed 2025"))
      enter(@user, main(club: create(:club)))
      enter(@user, main(starts_at: 1.week.from_now))
      counts = ParticipationCounts.call(club: @club, season_tag: "Wed 2026")
      assert_equal({ @user.id => 1 }, counts)
    end

    test "a member in two entries of one night counts that night once" do
      night = main
      enter(@user, night)
      # The model forbids a second entry in one tournament, so mirror a stray
      # duplicate row directly.
      second = create(:tournament_entry, tournament: night)
      TournamentEntryMember.insert!({ tournament_entry_id: second.id, user_id: @user.id,
                                      created_at: Time.current, updated_at: Time.current })
      assert_equal({ @user.id => 1 }, ParticipationCounts.call(club: @club, season_tag: "Wed 2026"))
    end

    test "returns an empty hash when there is no season" do
      enter(@user, main)
      assert_equal({}, ParticipationCounts.call(club: @club, season_tag: nil))
    end
  end
end
