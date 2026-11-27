require "test_helper"

module SeasonPoints
  class PlacementCountsTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
      @species = create(:species)
      @users = 5.times.map { create(:user, club: @club) }
    end

    def night(**attributes)
      tournament = create(:tournament, club: @club, mode: :team, awards_season_points: true,
                          season_tag: "Season", starts_at: 2.days.ago, ends_at: 1.day.ago, **attributes)
      create(:scoring_slot, tournament: tournament, species: @species, slot_count: 2)
      tournament
    end

    def enter(tournament, users, lengths)
      entry = create(:tournament_entry, tournament: tournament)
      Array(users).each { |user| create(:tournament_entry_member, tournament_entry: entry, user: user) }
      lengths.each_with_index do |length, index|
        fish = create(:catch, user: Array(users).first, species: @species,
                       length_inches: length, tag_number: (@species.tagged_walleye? ? "TAG-#{index}" : nil), captured_at_device: tournament.starts_at + 1.hour)
        create(:catch_placement, tournament: tournament, tournament_entry: entry,
                                catch: fish, species: @species, slot_index: index)
      end
      entry
    end

    def counts
      PlacementCounts.call(club: @club, season_tag: "Season")
    end

    test "counts each finish across nights, credits teammates and does not place blank entries" do
      5.times do |index|
        tournament = night
        crew = index.zero? ? [@users[0], @users[4]] : [@users[0]]
        enter(tournament, crew, [30])
        enter(tournament, @users[1], [20])
        enter(tournament, @users[2], [10])
        enter(tournament, @users[3], [])
      end
      result = counts
      assert_equal [5, 0, 0], result[@users[0].id]
      assert_equal [0, 5, 0], result[@users[1].id]
      assert_equal [0, 0, 5], result[@users[2].id]
      assert_equal [1, 0, 0], result[@users[4].id]
      assert_equal [0, 0, 0], result.fetch(@users[3].id, [0, 0, 0])
    end

    test "only completed Main nights in the selected club and season count" do
      enter(night, @users[0], [25])
      enter(night(awards_season_points: false), @users[0], [25])
      enter(night(season_tag: "Other season"), @users[0], [25])
      enter(night(starts_at: 1.hour.ago, ends_at: 1.hour.from_now), @users[0], [25])
      enter(night(starts_at: 1.day.from_now, ends_at: 2.days.from_now), @users[0], [25])
      other = create(:club)
      create(:club_membership, club: other, user: @users[0])
      enter(night(club: other), @users[0], [25])
      assert_equal({ @users[0].id => [1, 0, 0] }, counts)
      assert_equal({}, PlacementCounts.call(club: @club, season_tag: nil))
    end

    test "fish-ranked formats place an entry once and recalculate after scoring catches are removed" do
      tournament = night
      travel_to(tournament.starts_at - 1.hour) { tournament.update!(format: :big_fish_season, mode: :solo) }
      first = enter(tournament, @users[0], [30, 29])
      enter(tournament, @users[1], [20])
      enter(tournament, @users[2], [10])
      assert_equal [0, 1, 0], counts[@users[1].id], "two fish from the winner must not consume second place"
      first.catch_placements.update_all(active: false)
      result = counts
      assert_equal [1, 0, 0], result[@users[1].id]
      assert_equal [0, 1, 0], result[@users[2].id]
      assert_equal [0, 0, 0], result.fetch(@users[0].id, [0, 0, 0])
    end

    test "tagged counts the drawn winner rather than the ticket leader and drops a voided winner" do
      @species = Species.find_by(name: "Tagged Walleye") || create(:species, name: "Tagged Walleye")
      tournament = night
      tournament.scoring_slots.first.update!(slot_count: 1)
      travel_to(tournament.starts_at - 1.hour) { tournament.update!(format: :tagged, mode: :solo) }
      enter(tournament, @users[0], [30, 29])
      winner = enter(tournament, @users[1], [20])
      ticket = winner.catch_placements.first
      tournament.update!(drawn_winning_placement: ticket)
      assert_equal({ @users[1].id => [1, 0, 0] }, counts)
      ticket.update!(active: false)
      assert_equal({}, counts)
    end

    test "hidden length does not count provisional rankings before its target is revealed" do
      tournament = night
      tournament.scoring_slots.first.update!(slot_count: 1)
      travel_to(tournament.starts_at - 1.hour) { tournament.update!(format: :hidden_length) }
      enter(tournament, @users[0], [20])
      assert_equal({}, counts)
    end

    test "standard season query count does not grow with the number of nights" do
      tournament = night
      enter(tournament, @users[0], [25])
      one = count_queries(/./) { counts }
      3.times { enter(night, @users[0], [25]) }
      many = count_queries(/./) { counts }
      assert_operator many, :<=, one + 1, "placement-count queries grew from #{one} to #{many}"
    end
  end
end
