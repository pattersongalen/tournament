require "test_helper"

module Tournaments
  class SeasonPointsAwardedTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
      @walleye = create(:species, club: @club)
    end

    # Helper: builds a finished, points-eligible tournament with N solo anglers.
    # `lengths_by_index` maps angler index → array of catch lengths.
    # Returns [tournament, anglers].
    def build_finished_solo(n_anglers, lengths_by_index = {})
      tournament = create(
        :tournament,
        club: @club,
        mode: :solo,
        awards_season_points: true,
        starts_at: 2.days.ago,
        ends_at:   1.day.ago
      )
      create(:scoring_slot, tournament: tournament, species: @walleye, slot_count: 2)
      anglers = n_anglers.times.map do |i|
        u = create(:user, club: @club)
        e = create(:tournament_entry, tournament: tournament)
        create(:tournament_entry_member, tournament_entry: e, user: u)
        Array(lengths_by_index[i]).each do |len|
          Catches::PlaceInSlots.call(catch: create(:catch, user: u, species: @walleye, length_inches: len, captured_at_device: 1.5.days.ago))
        end
        u
      end
      [tournament, anglers]
    end

    test "returns {} when not points-eligible, not yet ended, or ends_at is nil" do
      not_eligible = create(:tournament, club: @club, awards_season_points: false, starts_at: 3.hours.ago, ends_at: 1.hour.ago)
      assert_equal({}, SeasonPointsAwarded.call(tournament: not_eligible), "not points-eligible")

      not_ended = create(:tournament, club: @club, awards_season_points: true, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      assert_equal({}, SeasonPointsAwarded.call(tournament: not_ended), "tournament has not ended")

      # Legacy NULL-ends_at row: bypass the now-required ends_at validation.
      nil_ends_at = build(:tournament, club: @club, awards_season_points: true, starts_at: 1.hour.ago, ends_at: nil)
      nil_ends_at.save!(validate: false)
      assert_equal({}, SeasonPointsAwarded.call(tournament: nil_ends_at), "ends_at is nil")
    end

    test "fewer than 3 solo entries awards only the 0.5 attendance bonus" do
      tournament, anglers = build_finished_solo(2, { 0 => [20], 1 => [15] })
      result = SeasonPointsAwarded.call(tournament: tournament)
      assert_equal({ anglers[0].id => 0.5, anglers[1].id => 0.5 }, result)
    end

    test "awards [3,2,1] placement plus 0.5 attendance bonus for 3 anglers in solo mode" do
      tournament, anglers = build_finished_solo(3, { 0 => [20], 1 => [15], 2 => [10] })
      result = SeasonPointsAwarded.call(tournament: tournament)
      assert_equal({ anglers[0].id => 3.5, anglers[1].id => 2.5, anglers[2].id => 1.5 }, result)
    end

    test "awards [6,4,2] placement plus 0.5 attendance bonus for 10 anglers" do
      lengths = (0...10).each_with_object({}) { |i, h| h[i] = [20 - i] }
      tournament, anglers = build_finished_solo(10, lengths)
      result = SeasonPointsAwarded.call(tournament: tournament)
      assert_equal 6.5, result[anglers[0].id]
      assert_equal 4.5, result[anglers[1].id]
      assert_equal 2.5, result[anglers[2].id]
      (3..9).each { |i| assert_equal 0.5, result[anglers[i].id] }
    end

    test "awards [9,6,3] placement plus 0.5 attendance bonus for 20 anglers" do
      lengths = (0...20).each_with_object({}) { |i, h| h[i] = [25 - i] }
      tournament, anglers = build_finished_solo(20, lengths)
      result = SeasonPointsAwarded.call(tournament: tournament)
      assert_equal 9.5, result[anglers[0].id]
      assert_equal 6.5, result[anglers[1].id]
      assert_equal 3.5, result[anglers[2].id]
      (3..19).each { |i| assert_equal 0.5, result[anglers[i].id] }
    end

    test "skunked entrants still get the 0.5 attendance bonus when only 1st and 2nd have catches" do
      tournament, anglers = build_finished_solo(5, { 0 => [20], 1 => [15] })  # angler 2,3,4 skunked
      result = SeasonPointsAwarded.call(tournament: tournament)
      assert_equal 3.5, result[anglers[0].id]
      assert_equal 2.5, result[anglers[1].id]
      assert_equal 0.5, result[anglers[2].id]
      assert_equal 0.5, result[anglers[3].id]
      assert_equal 0.5, result[anglers[4].id]
    end

    test "team mode: every member of a placing entry gets the points" do
      tournament = create(
        :tournament,
        club: @club,
        mode: :team,
        awards_season_points: true,
        starts_at: 2.days.ago,
        ends_at: 1.day.ago
      )
      create(:scoring_slot, tournament: tournament, species: @walleye, slot_count: 2)

      # Team 1 (3 anglers): biggest fish → wins (25")
      team1_users = 3.times.map { create(:user, club: @club) }
      team1 = create(:tournament_entry, tournament: tournament)
      team1_users.each { |u| create(:tournament_entry_member, tournament_entry: team1, user: u) }
      Catches::PlaceInSlots.call(catch: create(:catch, user: team1_users.first, species: @walleye, length_inches: 25, captured_at_device: 1.5.days.ago))

      # Team 2 (2 anglers): second (18")
      team2_users = 2.times.map { create(:user, club: @club) }
      team2 = create(:tournament_entry, tournament: tournament)
      team2_users.each { |u| create(:tournament_entry_member, tournament_entry: team2, user: u) }
      Catches::PlaceInSlots.call(catch: create(:catch, user: team2_users.first, species: @walleye, length_inches: 18, captured_at_device: 1.5.days.ago))

      # Team 3 (3 anglers): third (12")
      team3_users = 3.times.map { create(:user, club: @club) }
      team3 = create(:tournament_entry, tournament: tournament)
      team3_users.each { |u| create(:tournament_entry_member, tournament_entry: team3, user: u) }
      Catches::PlaceInSlots.call(catch: create(:catch, user: team3_users.first, species: @walleye, length_inches: 12, captured_at_device: 1.5.days.ago))

      # 8 anglers total → [3,2,1] scale
      result = SeasonPointsAwarded.call(tournament: tournament)
      team1_users.each { |u| assert_equal 3.5, result[u.id], "team1 member #{u.id} should get 3.5" }
      team2_users.each { |u| assert_equal 2.5, result[u.id], "team2 member #{u.id} should get 2.5" }
      team3_users.each { |u| assert_equal 1.5, result[u.id], "team3 member #{u.id} should get 1.5" }
    end

    # Builds a finished team-mode tournament. `team_sizes` is an array of member
    # counts; team i's first member logs one catch of length (25 - i) inches, so
    # teams place in index order. Returns array-of-arrays of users per team.
    def build_finished_teams(team_sizes)
      @team_tournament = create(
        :tournament,
        club: @club,
        mode: :team,
        awards_season_points: true,
        starts_at: 2.days.ago,
        ends_at: 1.day.ago
      )
      create(:scoring_slot, tournament: @team_tournament, species: @walleye, slot_count: 2)
      team_sizes.each_with_index.map do |size, i|
        users = size.times.map { create(:user, club: @club) }
        entry = create(:tournament_entry, tournament: @team_tournament)
        users.each { |u| create(:tournament_entry_member, tournament_entry: entry, user: u) }
        Catches::PlaceInSlots.call(catch: create(:catch, user: users.first, species: @walleye, length_inches: 25 - i, captured_at_device: 1.5.days.ago))
        users
      end
    end

    test "team mode: 2 teams awards only attendance bonuses regardless of angler count, and a memberless entry doesn't count toward the cutoff" do
      teams = build_finished_teams([5, 5])
      # A leftover entry whose last member was removed (or that was created
      # before anyone was added) is not a competing team.
      create(:tournament_entry, tournament: @team_tournament)

      # 10 anglers would satisfy PointsScale, but 2 competing entries is below the cutoff.
      result = SeasonPointsAwarded.call(tournament: @team_tournament)
      assert_equal 10, result.size
      teams.flatten.each { |u| assert_equal 0.5, result[u.id], "member #{u.id} should get only the attendance bonus" }
    end

    test "team mode: 3 teams with 10 anglers uses the 3-entry [3,2,1] tier" do
      # Field size counts entries (boats/teams), not anglers: 3 teams lands in
      # the 1-9 band even though 10 people fished.
      tournament = create(
        :tournament, club: @club, mode: :team, awards_season_points: true,
        starts_at: 2.days.ago, ends_at: 1.day.ago
      )
      create(:scoring_slot, tournament: tournament, species: @walleye, slot_count: 2)

      teams = [[4, 20], [3, 15], [3, 10]].map do |size, length|
        entry = create(:tournament_entry, tournament: tournament)
        members = size.times.map do
          u = create(:user, club: @club)
          create(:tournament_entry_member, tournament_entry: entry, user: u)
          u
        end
        Catches::PlaceInSlots.call(catch: create(:catch, user: members.first, species: @walleye,
                                                  length_inches: length, captured_at_device: 1.5.days.ago))
        members
      end

      result = SeasonPointsAwarded.call(tournament: tournament)
      assert_equal 3.5, result[teams[0][0].id]   # 3 placement + 0.5 attendance
      assert_equal 2.5, result[teams[1][0].id]
      assert_equal 1.5, result[teams[2][0].id]
      assert_equal 3.5, result[teams[0][3].id]   # every teammate gets the same as the skipper
    end

    test "full_field pays every scoring entry, ladder sized by the entries that fished" do
      @club.update!(season_points_scheme: :full_field)
      # 8 solo entries, only the first 5 catch anything.
      tournament, anglers = build_finished_solo(
        8, { 0 => [30], 1 => [25], 2 => [20], 3 => [15], 4 => [10] }
      )

      result = SeasonPointsAwarded.call(tournament: tournament)

      assert_equal 8.5, result[anglers[0].id]   # 8 placement + 0.5 attendance
      assert_equal 7.5, result[anglers[1].id]
      assert_equal 6.5, result[anglers[2].id]
      assert_equal 5.5, result[anglers[3].id]
      assert_equal 4.5, result[anglers[4].id]
      # Rungs 3, 2 and 1 go unclaimed — the blanked boats get attendance only.
      assert_equal 0.5, result[anglers[5].id]
      assert_equal 0.5, result[anglers[6].id]
      assert_equal 0.5, result[anglers[7].id]
    end

    test "a customised attendance value replaces the 0.5 default" do
      @club.update!(season_points_attendance: 2)
      tournament, anglers = build_finished_solo(3, { 0 => [20], 1 => [15], 2 => [10] })

      result = SeasonPointsAwarded.call(tournament: tournament)

      assert_equal 5, result[anglers[0].id]   # 3 placement + 2 attendance
      assert_equal 4, result[anglers[1].id]
      assert_equal 3, result[anglers[2].id]
    end

    test "zero attendance points means non-placers earn nothing" do
      @club.update!(season_points_attendance: 0)
      tournament, anglers = build_finished_solo(4, { 0 => [20], 1 => [15], 2 => [10], 3 => [] })

      result = SeasonPointsAwarded.call(tournament: tournament)

      assert_equal 3, result[anglers[0].id]
      assert_equal 0, result[anglers[3].id]
    end

    test "a customised minimum entry count gates placement points" do
      @club.update!(season_points_min_entries: 5)
      tournament, anglers = build_finished_solo(4, { 0 => [20], 1 => [15], 2 => [10] })

      result = SeasonPointsAwarded.call(tournament: tournament)

      assert_equal({ anglers[0].id => 0.5, anglers[1].id => 0.5,
                     anglers[2].id => 0.5, anglers[3].id => 0.5 }, result)
    end

    test "a batch caller can inject the scale so it is not recomputed per tournament" do
      tournament, anglers = build_finished_solo(3, { 0 => [20], 1 => [18], 2 => [16] })
      awards = SeasonPointsAwarded.call(tournament: tournament, scale: [10, 5, 1])
      assert_equal 10.5, awards[anglers[0].id], "injected rung 1 + 0.5 attendance"
      assert_equal 5.5,  awards[anglers[1].id]
      assert_equal 1.5,  awards[anglers[2].id]
    end
  end
end
