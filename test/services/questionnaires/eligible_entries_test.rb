require "test_helper"
require_relative "../../support/questionnaire_helpers"

class Questionnaires::EligibleEntriesTest < ActiveSupport::TestCase
  include QuestionnaireHelpers

  setup do
    @club = asking_club
  end

  test "returns the top three boats in rank order with their places" do
    tournament = season_tournament(club: @club)
    third  = add_boat(tournament, length: 18)
    first  = add_boat(tournament, length: 25)
    fourth = add_boat(tournament, length: 12)
    second = add_boat(tournament, length: 20)

    result = Questionnaires::EligibleEntries.call(tournament: tournament)

    assert_equal [[first.id, 1], [second.id, 2], [third.id, 3]],
                 result.map { |r| [r[:entry].id, r[:place]] }
    assert_not_includes result.map { |r| r[:entry].id }, fourth.id
  end

  test "boats with no scoring catch are not eligible, so fewer than three may be asked" do
    tournament = season_tournament(club: @club)
    first = add_boat(tournament, length: 25)
    second = add_boat(tournament, length: 20)
    add_boat(tournament, length: nil)

    result = Questionnaires::EligibleEntries.call(tournament: tournament)

    assert_equal [first.id, second.id], result.map { |r| r[:entry].id }
  end

  test "a tournament that does not ask returns nothing" do
    {
      "season points off"              => -> { season_tournament(club: @club, awards: false) },
      "still running"                  => -> { season_tournament(club: @club, ended: 1.hour.from_now) },
      "ended before the club's start"  => -> {
        t = season_tournament(club: @club)
        @club.update!(questionnaires_start_at: Time.current)
        t
      },
      "club has no start time"         => -> {
        t = season_tournament(club: @club)
        @club.update!(questionnaires_start_at: nil)
        t
      },
      "club has no active questions"   => -> {
        t = season_tournament(club: @club)
        @club.questions.update_all(retired_at: Time.current)
        t
      }
    }.each do |label, build|
      tournament = build.call
      add_boat(tournament, length: 25)

      assert_equal false, Questionnaires::EligibleEntries.asks?(tournament.reload), label
      assert_equal [], Questionnaires::EligibleEntries.call(tournament: tournament), label

      @club.update!(questionnaires_start_at: 30.days.ago)
      @club.questions.update_all(retired_at: nil)
    end
  end

  # Per-catch formats rank one row PER FISH, so one angler's three fish would
  # otherwise take 1st, 2nd and 3rd and the real runners-up would never be asked.
  def per_catch_tournament(format, **attrs)
    # These formats validate "exactly one species" at save, so the slot is
    # built with the tournament rather than added afterwards.
    tournament = build(:tournament, club: @club, name: "Per catch", awards_season_points: true,
                       mode: :solo, format: format, starts_at: 1.day.ago - 4.hours, ends_at: 1.day.ago, **attrs)
    tournament.scoring_slots.build(species: questionnaire_species, slot_count: 1)
    tournament.save!
    tournament
  end

  def solo_angler(tournament, lengths)
    user = create(:user, club: @club)
    entry = create(:tournament_entry, tournament: tournament)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    lengths.each_with_index do |length, index|
      caught = create(:catch, user: user, species: questionnaire_species, length_inches: length,
                      captured_at_device: tournament.ends_at - 1.hour - index.minutes)
      create(:catch_placement, catch: caught, tournament: tournament, tournament_entry: entry,
             species: questionnaire_species, slot_index: index)
    end
    entry
  end

  test "big fish season: a boat holding the three longest fish places once" do
    tournament = per_catch_tournament(:big_fish_season)
    hog = solo_angler(tournament, [30, 29, 28])
    runner_up = solo_angler(tournament, [20])

    result = Questionnaires::EligibleEntries.call(tournament: tournament)

    assert_equal [[hog.id, 1], [runner_up.id, 2]], result.map { |r| [r[:entry].id, r[:place]] }
  end

  test "hidden length: nobody is asked until the target has been rolled" do
    tournament = per_catch_tournament(:hidden_length)
    solo_angler(tournament, [30, 29, 28])
    solo_angler(tournament, [20])
    assert_nil tournament.hidden_length_target

    assert_equal [], Questionnaires::EligibleEntries.call(tournament: tournament)

    Tournaments::RollHiddenLengthTarget.call(tournament: tournament)
    result = Questionnaires::EligibleEntries.call(tournament: tournament.reload)
    assert_equal result.map { |r| r[:entry].id }.uniq, result.map { |r| r[:entry].id }
    assert_equal 2, result.size
  end

  # A Tagged tournament is won by the draw, not by ticket count, so the first
  # three leaderboard rows are not its top three.
  test "tagged: nobody is asked, because the draw decides the winner" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    tournament = build(:tournament, club: @club, name: "Tagged night", awards_season_points: true,
                       mode: :solo, format: :tagged, starts_at: 1.day.ago - 4.hours, ends_at: 1.day.ago)
    tournament.scoring_slots.build(species: tagged, slot_count: 1)
    tournament.save!
    user = create(:user, club: @club)
    entry = create(:tournament_entry, tournament: tournament)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    caught = create(:catch, user: user, species: tagged, length_inches: 20, tag_number: "A0001",
                    captured_at_device: tournament.ends_at - 1.hour)
    create(:catch_placement, catch: caught, tournament: tournament, tournament_entry: entry,
           species: tagged, slot_index: 0)

    assert_equal false, Questionnaires::EligibleEntries.asks?(tournament)
    assert_equal [], Questionnaires::EligibleEntries.call(tournament: tournament)
  end

  test "rows passed in are used instead of building the leaderboard again" do
    tournament = season_tournament(club: @club)
    add_boat(tournament, length: 25)
    rows = Leaderboards::Build.call(tournament: tournament)

    queries = count_queries("catch_placements") do
      Questionnaires::EligibleEntries.call(tournament: tournament, rows: rows)
    end

    assert_equal 0, queries
  end
end
