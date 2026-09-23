require "test_helper"

module SeasonPoints
  class StandingsTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
      @walleye = create(:species, club: @club)
    end

    # Returns [tournament, in_window_timestamp]. The in_window timestamp is
    # safe to pass as captured_at_device for catches in this tournament.
    def build_finished(season_tag:, ends_at: 1.day.ago, awards: true)
      starts_at = ends_at - 4.hours
      tournament = create(
        :tournament,
        club: @club,
        mode: :solo,
        awards_season_points: awards,
        season_tag: season_tag,
        starts_at: starts_at,
        ends_at: ends_at
      )
      create(:scoring_slot, tournament: tournament, species: @walleye, slot_count: 2)
      [tournament, ends_at - 1.hour]
    end

    def add_solo(tournament:, in_window:, name:, lengths:)
      user = ::User.find_by(name: name) ||
             create(:user, club: @club, name: name)
      entry = create(:tournament_entry, tournament: tournament)
      create(:tournament_entry_member, tournament_entry: entry, user: user)
      lengths.each do |len|
        Catches::PlaceInSlots.call(
          catch: create(:catch, user: user, species: @walleye, length_inches: len, captured_at_device: in_window)
        )
      end
      user
    end

    # Seeds a fresh club with `tournaments` finished, points-eligible events in
    # one season, each with three solo anglers. Returns the club.
    def seed_season(tournaments:)
      club = create(:club)
      walleye = create(:species, club: club)
      tournaments.times do |i|
        ends_at = (i + 1).weeks.ago
        t = create(:tournament, club: club, mode: :solo, awards_season_points: true,
                                season_tag: "S", starts_at: ends_at - 4.hours, ends_at: ends_at)
        create(:scoring_slot, tournament: t, species: walleye, slot_count: 2)
        in_window = ends_at - 1.hour
        %w[Alpha Bravo Charlie].each_with_index do |nm, j|
          name = "#{nm}-#{club.id}"
          user = ::User.find_by(name: name) || create(:user, club: club, name: name)
          entry = create(:tournament_entry, tournament: t)
          create(:tournament_entry_member, tournament_entry: entry, user: user)
          Catches::PlaceInSlots.call(catch: create(:catch, user: user, species: walleye,
                                                           length_inches: 25 - (j * 5), captured_at_device: in_window))
        end
      end
      club
    end

    test "query count does not grow per tournament (no N+1 across the season)" do
      one = seed_season(tournaments: 1)
      many = seed_season(tournaments: 4)

      q1 = count_queries(/./) { Standings.call(club: one, season_tag: "S") }
      q4 = count_queries(/./) { Standings.call(club: many, season_tag: "S") }

      assert_operator q4, :<=, q1 + 1,
                      "standings query count grew with tournament count (#{q1} -> #{q4}): N+1 over tournaments"
    end

    test "full_field standings pay the whole scoring field, ladder sized by entries" do
      @club.update!(season_points_scheme: :full_field)
      t, in_window = build_finished(season_tag: "FF")
      a = add_solo(tournament: t, in_window: in_window, name: "FF-A", lengths: [25])
      b = add_solo(tournament: t, in_window: in_window, name: "FF-B", lengths: [20])
      c = add_solo(tournament: t, in_window: in_window, name: "FF-C", lengths: [15])
      d = add_solo(tournament: t, in_window: in_window, name: "FF-D", lengths: [10])
      e = add_solo(tournament: t, in_window: in_window, name: "FF-E", lengths: [])

      by_id = Standings.call(club: @club, season_tag: "FF").index_by { |r| r[:user].id }

      # 5 entries → ladder [5,4,3,2,1]; only 4 boats scored, so rung 1 is unclaimed.
      assert_equal 5.5, by_id[a.id][:points]
      assert_equal 4.5, by_id[b.id][:points]
      assert_equal 3.5, by_id[c.id][:points]
      assert_equal 2.5, by_id[d.id][:points]
      assert_equal 0.5, by_id[e.id][:points]
    end

    test "returns [] for nil season_tag" do
      assert_equal [], Standings.call(club: @club, season_tag: nil)
    end

    test "sums points across multiple tournaments per user" do
      t1, w1 = build_finished(season_tag: "Wednesday 2026", ends_at: 2.weeks.ago)
      t2, w2 = build_finished(season_tag: "Wednesday 2026", ends_at: 1.week.ago)

      [[t1, w1], [t2, w2]].each do |t, w|
        add_solo(tournament: t, in_window: w, name: "Alpha",   lengths: [25])
        add_solo(tournament: t, in_window: w, name: "Bravo",   lengths: [20])
        add_solo(tournament: t, in_window: w, name: "Charlie", lengths: [15])
      end

      result = Standings.call(club: @club, season_tag: "Wednesday 2026")
      points_by_name = result.to_h { |r| [r[:user].name, r[:points]] }
      assert_equal 7.0, points_by_name["Alpha"]    # (3 + 0.5) * 2
      assert_equal 5.0, points_by_name["Bravo"]    # (2 + 0.5) * 2
      assert_equal 3.0, points_by_name["Charlie"]  # (1 + 0.5) * 2
    end

    test "skunked but entered anglers show up with the 0.5 attendance bonus only" do
      t, w = build_finished(season_tag: "Wednesday 2026")
      add_solo(tournament: t, in_window: w, name: "Alpha",   lengths: [25])
      add_solo(tournament: t, in_window: w, name: "Bravo",   lengths: [20])
      add_solo(tournament: t, in_window: w, name: "Charlie", lengths: [15])
      add_solo(tournament: t, in_window: w, name: "Skunked", lengths: [])

      result = Standings.call(club: @club, season_tag: "Wednesday 2026")
      skunked = result.find { |r| r[:user].name == "Skunked" }
      assert_not_nil skunked, "Skunked angler should appear in standings via attendance bonus"
      assert_equal 0.5, skunked[:points]
    end

    test "team tournament below the 3-team cutoff contributes only attendance bonuses" do
      ends_at = 1.day.ago
      t = create(:tournament, club: @club, mode: :team, awards_season_points: true,
                 season_tag: "Wednesday 2026", starts_at: ends_at - 4.hours, ends_at: ends_at)
      create(:scoring_slot, tournament: t, species: @walleye, slot_count: 2)

      # 2 teams x 2 anglers = 4 anglers: enough for PointsScale, but only 2 entries.
      %w[TeamA TeamB].each_with_index do |prefix, i|
        entry = create(:tournament_entry, tournament: t)
        users = 2.times.map { |j| create(:user, club: @club, name: "#{prefix}-#{j}") }
        users.each { |u| create(:tournament_entry_member, tournament_entry: entry, user: u) }
        Catches::PlaceInSlots.call(catch: create(:catch, user: users.first, species: @walleye,
                                                 length_inches: 25 - i, captured_at_device: ends_at - 1.hour))
      end

      result = Standings.call(club: @club, season_tag: "Wednesday 2026")
      assert_equal 4, result.size
      result.each do |row|
        assert_equal 0.5, row[:points], "#{row[:user].name} should have only the attendance bonus"
      end
    end

    test "a member-less entry doesn't lift a 2-team tournament over the cutoff" do
      ends_at = 1.day.ago
      t = create(:tournament, club: @club, mode: :team, awards_season_points: true,
                 season_tag: "Wednesday 2026", starts_at: ends_at - 4.hours, ends_at: ends_at)
      create(:scoring_slot, tournament: t, species: @walleye, slot_count: 2)

      %w[TeamA TeamB].each_with_index do |prefix, i|
        entry = create(:tournament_entry, tournament: t)
        users = 2.times.map { |j| create(:user, club: @club, name: "#{prefix}-#{j}") }
        users.each { |u| create(:tournament_entry_member, tournament_entry: entry, user: u) }
        Catches::PlaceInSlots.call(catch: create(:catch, user: users.first, species: @walleye,
                                                 length_inches: 25 - i, captured_at_device: ends_at - 1.hour))
      end
      create(:tournament_entry, tournament: t)

      result = Standings.call(club: @club, season_tag: "Wednesday 2026")
      assert_equal 4, result.size
      result.each do |row|
        assert_equal 0.5, row[:points], "#{row[:user].name} should have only the attendance bonus"
      end
    end

    test "excludes in-progress tournaments" do
      future_end = 1.hour.from_now
      starts_at = future_end - 4.hours
      tournament = create(:tournament, club: @club, mode: :solo, awards_season_points: true,
                          season_tag: "Wednesday 2026", starts_at: starts_at, ends_at: future_end)
      create(:scoring_slot, tournament: tournament, species: @walleye, slot_count: 2)
      add_solo(tournament: tournament, in_window: starts_at + 1.hour, name: "Alpha",   lengths: [25])
      add_solo(tournament: tournament, in_window: starts_at + 1.hour, name: "Bravo",   lengths: [20])
      add_solo(tournament: tournament, in_window: starts_at + 1.hour, name: "Charlie", lengths: [15])

      assert_equal [], Standings.call(club: @club, season_tag: "Wednesday 2026")
    end

    test "excludes non-points-eligible tournaments with same season_tag" do
      t, w = build_finished(season_tag: "Wednesday 2026", awards: false)
      add_solo(tournament: t, in_window: w, name: "Alpha",   lengths: [25])
      add_solo(tournament: t, in_window: w, name: "Bravo",   lengths: [20])
      add_solo(tournament: t, in_window: w, name: "Charlie", lengths: [15])
      assert_equal [], Standings.call(club: @club, season_tag: "Wednesday 2026")
    end

    test "tied total sorts alphabetically by name" do
      t1, w1 = build_finished(season_tag: "Wednesday 2026", ends_at: 2.weeks.ago)
      t2, w2 = build_finished(season_tag: "Wednesday 2026", ends_at: 1.week.ago)

      # Bravo wins t1, Charlie+Delta finish 2/3
      add_solo(tournament: t1, in_window: w1, name: "Bravo",   lengths: [25])
      add_solo(tournament: t1, in_window: w1, name: "Charlie", lengths: [20])
      add_solo(tournament: t1, in_window: w1, name: "Delta",   lengths: [15])

      # Alpha wins t2, Charlie+Delta again finish 2/3
      add_solo(tournament: t2, in_window: w2, name: "Alpha",   lengths: [25])
      add_solo(tournament: t2, in_window: w2, name: "Charlie", lengths: [20])
      add_solo(tournament: t2, in_window: w2, name: "Delta",   lengths: [15])

      result = Standings.call(club: @club, season_tag: "Wednesday 2026")

      # With the 0.5 attendance bonus per-tournament:
      #   Alpha   in t2 only     → 3 + 0.5         = 3.5
      #   Bravo   in t1 only     → 3 + 0.5         = 3.5
      #   Charlie in both        → 2 + 2 + 0.5*2   = 5.0
      #   Delta   in both        → 1 + 1 + 0.5*2   = 3.0
      # Alpha and Bravo tied at 3.5 — Alpha first by alphabetical
      # Charlie still highest overall, Delta lowest
      assert_equal "Charlie", result.first[:user].name
      tied_at_3_5 = result.select { |r| r[:points] == 3.5 }.map { |r| r[:user].name }
      assert_equal ["Alpha", "Bravo"], tied_at_3_5
    end

    test "bingo tournament awards season points without crashing" do
      create_bingo_species!
      ends_at = 1.day.ago
      starts_at = ends_at - 4.hours
      t = create(:tournament, club: @club, mode: :solo, format: :bingo,
                 awards_season_points: true, season_tag: "Bingo 2026",
                 starts_at: starts_at, ends_at: ends_at)

      user = create(:user, club: @club, name: "Bingo Angler")
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: user)
      create(:catch, user: user, species: @walleye, length_inches: 15,
                     captured_at_device: ends_at - 1.hour)

      # Placement points need >= 3 entries; these two make it 3 solo entries but
      # never progress past the free square (0.5 attendance bonus only).
      %w[Skunked1 Skunked2].each do |name|
        u = create(:user, club: @club, name: name)
        e = create(:tournament_entry, tournament: t)
        create(:tournament_entry_member, tournament_entry: e, user: u)
      end

      result = Standings.call(club: @club, season_tag: "Bingo 2026")

      angler = result.find { |r| r[:user].name == "Bingo Angler" }
      assert_not_nil angler, "bingo angler with a qualifying square should appear in standings"
      assert_operator angler[:points], :>, 0
      skunked = result.find { |r| r[:user].name == "Skunked1" }
      assert_equal 0.5, skunked[:points], "entrant with only the free square should still get the attendance bonus"
    end

    test "row includes per-tournament breakdown" do
      t, w = build_finished(season_tag: "Wednesday 2026", ends_at: 1.week.ago)
      add_solo(tournament: t, in_window: w, name: "Alpha",   lengths: [25])
      add_solo(tournament: t, in_window: w, name: "Bravo",   lengths: [20])
      add_solo(tournament: t, in_window: w, name: "Charlie", lengths: [15])

      result = Standings.call(club: @club, season_tag: "Wednesday 2026")
      alpha = result.find { |r| r[:user].name == "Alpha" }
      assert_equal 1, alpha[:breakdown].size
      assert_equal t.id, alpha[:breakdown].first[:tournament_id]
      assert_equal 3.5,  alpha[:breakdown].first[:points]
    end
  end
end
