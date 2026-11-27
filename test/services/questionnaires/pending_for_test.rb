require "test_helper"
require_relative "../../support/questionnaire_helpers"

class Questionnaires::PendingForTest < ActiveSupport::TestCase
  include QuestionnaireHelpers

  # Builds a tournament where `mine` finishes in `place` among scoring boats,
  # and returns [tournament, my entry, me].
  def finish_in(place, club:, ended: 1.day.ago, awards: true, scoring_rivals: 3, my_length: :auto)
    tournament = season_tournament(club: club, ended: ended, awards: awards)
    rival_lengths = [30, 28, 26, 24, 22].first(scoring_rivals)
    length = my_length == :auto ? { 1 => 40, 2 => 29, 3 => 27, 4 => 25 }.fetch(place) : my_length
    rival_lengths.each { |l| add_boat(tournament, length: l) }
    mine = add_boat(tournament, length: length, members: 2, name: "My Boat")
    [tournament, mine, mine.users.order(:id).first]
  end

  # The spec's state table. Each row arranges one case and states whether the
  # member should have a pending card.
  test "state table: who gets the home page card" do
    rows = {
      "1 boat is 1st" => [true, -> (club) { finish_in(1, club: club) }],
      "2 boat is 3rd" => [true, -> (club) { finish_in(3, club: club) }],
      "3 boat is 4th" => [false, -> (club) { finish_in(4, club: club) }],
      "4 no scoring catch, only 2 others scored" => [false, -> (club) {
        finish_in(3, club: club, scoring_rivals: 2, my_length: nil)
      }],
      "5 only 2 boats scored and this boat is 2nd" => [true, -> (club) {
        finish_in(2, club: club, scoring_rivals: 1)
      }],
      "6 season points off" => [false, -> (club) { finish_in(1, club: club, awards: false) }],
      "7 still running" => [false, -> (club) { finish_in(1, club: club, ended: 1.hour.from_now) }],
      "8 ended 15 days ago" => [false, -> (club) { finish_in(1, club: club, ended: 15.days.ago) }],
      "9 ended before questionnaires_start_at" => [false, -> (club) {
        result = finish_in(1, club: club)
        club.update!(questionnaires_start_at: 1.hour.ago)
        result
      }],
      "10 boat already has a questionnaire" => [false, -> (club) {
        tournament, mine, me = finish_in(1, club: club)
        create(:entry_questionnaire, tournament: tournament, tournament_entry: mine)
        [tournament, mine, me]
      }],
      "11 this member dismissed it" => [false, -> (club) {
        tournament, mine, me = finish_in(1, club: club)
        create(:entry_questionnaire_dismissal, tournament_entry: mine, user: me)
        [tournament, mine, me]
      }],
      "12 a teammate dismissed it" => [true, -> (club) {
        tournament, mine, me = finish_in(1, club: club)
        teammate = mine.users.where.not(id: me.id).first
        create(:entry_questionnaire_dismissal, tournament_entry: mine, user: teammate)
        [tournament, mine, me]
      }],
      "13 was 3rd, a disqualification of this boat's fish drops it out" => [false, -> (club) {
        tournament, mine, me = finish_in(3, club: club)
        disqualify(mine)
        [tournament, mine, me]
      }],
      "14 was 4th, a rival's disqualification raises it to 3rd" => [true, -> (club) {
        tournament, mine, me = finish_in(4, club: club)
        rival = tournament.tournament_entries.where.not(id: mine.id).first
        disqualify(rival)
        [tournament, mine, me]
      }],
      "15 member is deactivated" => [false, -> (club) {
        tournament, mine, me = finish_in(1, club: club)
        me.update!(deactivated_at: Time.current)
        [tournament, mine, me]
      }]
    }

    rows.each do |label, (expected, arrange)|
      club = asking_club
      tournament, mine, me = arrange.call(club)

      pending = Questionnaires::PendingFor.call(user: me.reload, club: club.reload)

      assert_equal expected, pending.any? { |p| p[:entry].id == mine.id }, "row #{label}"
      if expected
        item = pending.find { |p| p[:entry].id == mine.id }
        assert_equal tournament.id, item[:tournament].id, "row #{label}: tournament"
      end
    end
  end

  test "state table row 16: a tournament in another club is not pending for this club" do
    club = asking_club
    other_club = asking_club
    _tournament, _mine, me = finish_in(1, club: other_club)

    assert_empty Questionnaires::PendingFor.call(user: me, club: club)
  end

  test "the place reported is the boat's current place" do
    club = asking_club
    _tournament, mine, me = finish_in(2, club: club)

    item = Questionnaires::PendingFor.call(user: me, club: club).first

    assert_equal mine.id, item[:entry].id
    assert_equal 2, item[:place]
  end

  test "the window is inclusive of day 14 and excludes anything older" do
    club = asking_club
    freeze_time do
      _t, mine, me = finish_in(1, club: club, ended: 14.days.ago)
      assert Questionnaires::PendingFor.call(user: me, club: club).any? { |p| p[:entry].id == mine.id },
             "ended exactly 14 days ago: still pending"

      _t2, mine2, me2 = finish_in(1, club: club, ended: 14.days.ago - 1.second)
      assert_empty Questionnaires::PendingFor.call(user: me2, club: club).select { |p| p[:entry].id == mine2.id }
    end
  end

  test "several pending items come back newest tournament first" do
    club = asking_club
    me = create(:user, club: club)
    older = season_tournament(club: club, ended: 5.days.ago, name: "Older")
    newer = season_tournament(club: club, ended: 1.day.ago, name: "Newer")
    [older, newer].each do |tournament|
      entry = add_boat(tournament, length: 30)
      entry.tournament_entry_members.delete_all
      create(:tournament_entry_member, tournament_entry: entry, user: me)
    end

    names = Questionnaires::PendingFor.call(user: me, club: club).map { |p| p[:tournament].name }

    assert_equal ["Newer", "Older"], names
  end

  # The home page holds the Log Catch button. A leaderboard that fails to
  # build must cost the member a card, never the page.
  test "a leaderboard that raises for one tournament is skipped, and the others still show" do
    club = asking_club
    me = create(:user, club: club)
    broken = season_tournament(club: club, ended: 1.day.ago, name: "Broken")
    fine = season_tournament(club: club, ended: 2.days.ago, name: "Fine")
    [broken, fine].each do |tournament|
      entry = add_boat(tournament, length: 30)
      entry.tournament_entry_members.delete_all
      create(:tournament_entry_member, tournament_entry: entry, user: me)
    end

    original = Leaderboards::Build.method(:call)
    exploding = ->(tournament:, **rest) {
      raise "boom" if tournament.id == broken.id
      original.call(tournament: tournament, **rest)
    }

    pending = nil
    with_class_method_stub(Leaderboards::Build, :call, exploding) do
      assert_nothing_raised { pending = Questionnaires::PendingFor.call(user: me, club: club) }
    end

    assert_equal ["Fine"], pending.map { |p| p[:tournament].name }
  end

  # The test environment runs a null store; these two need a real one.
  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  # Most members finish outside the top three, get no card to dismiss, and
  # would otherwise rebuild every recent leaderboard on each home page load.
  test "a tournament's top three is built once, then read from the cache" do
    club = asking_club
    _tournament, mine, me = finish_in(4, club: club)

    # Counts builds, not queries: the query cache answers a repeated SELECT
    # inside a test, which would hide a second build.
    builds = 0
    original = Leaderboards::Build.method(:call)
    counting = ->(**args) { builds += 1; original.call(**args) }

    with_memory_cache do
      with_class_method_stub(Leaderboards::Build, :call, counting) do
        2.times do
          assert_empty Questionnaires::PendingFor.call(user: me, club: club).select { |p| p[:entry].id == mine.id }
        end
      end
    end

    assert_equal 1, builds
  end

  test "a change in the standings reaches the card once the cached top three expires" do
    club = asking_club
    tournament, mine, me = finish_in(4, club: club)

    with_memory_cache do
      assert_empty Questionnaires::PendingFor.call(user: me, club: club)
      disqualify(tournament.tournament_entries.where.not(id: mine.id).first)

      travel Questionnaires::PendingFor::CACHE_FOR + 1.second do
        item = Questionnaires::PendingFor.call(user: me, club: club).first
        assert_equal [mine.id, 3], [item[:entry].id, item[:place]]
      end
    end
  end

  test "a nil user or nil club returns nothing" do
    club = asking_club
    assert_empty Questionnaires::PendingFor.call(user: nil, club: club)
    assert_empty Questionnaires::PendingFor.call(user: create(:user, club: club), club: nil)
  end

  test "a member with no candidate tournaments costs one query and builds no leaderboard" do
    club = asking_club
    me = create(:user, club: club)
    busy = season_tournament(club: club)
    add_boat(busy, length: 30)

    all_queries = count_queries(/./) { Questionnaires::PendingFor.call(user: me, club: club) }
    placement_queries = count_queries("catch_placements") do
      Questionnaires::PendingFor.call(user: me, club: club)
    end

    assert_equal 1, all_queries
    assert_equal 0, placement_queries
  end
end
