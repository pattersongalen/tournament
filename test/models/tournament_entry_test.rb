require "test_helper"

class TournamentEntryTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @solo_t = create(:tournament, club: @club, mode: :solo)
    @team_t = create(:tournament, club: @club, mode: :team)
    @users = Array.new(3) { create(:user, club: @club) }
  end

  test "solo mode: exactly 1 member required" do
    entry = TournamentEntry.create!(tournament: @solo_t)
    entry.tournament_entry_members.create!(user: @users[0])
    assert entry.valid?

    too_many = entry.tournament_entry_members.build(user: @users[1])
    assert_not too_many.valid?
  end

  test "team mode: respects MAX_TEAM_MEMBERS cap" do
    cap = TournamentEntryMember::MAX_TEAM_MEMBERS
    users = Array.new(cap + 1) { create(:user, club: @club) }
    entry = TournamentEntry.create!(tournament: @team_t, name: "Big Boat")

    cap.times do |i|
      entry.tournament_entry_members.create!(user: users[i])
    end
    assert entry.valid?

    one_too_many = entry.tournament_entry_members.build(user: users[cap])
    assert_not one_too_many.valid?
    assert_includes one_too_many.errors[:base], "team is at capacity (#{cap} anglers max)"
  end

  test "an angler cannot be on two entries in the same tournament" do
    entry_a = TournamentEntry.create!(tournament: @team_t, name: "Boat A")
    entry_a.tournament_entry_members.create!(user: @users[0])

    entry_b = TournamentEntry.create!(tournament: @team_t, name: "Boat B")
    duplicate = entry_b.tournament_entry_members.build(user: @users[0])
    assert_not duplicate.valid?
  end

  test "display_name consumes eager-loaded users without re-querying" do
    entry = TournamentEntry.create!(tournament: @team_t, name: nil)
    entry.tournament_entry_members.create!(user: @users[0])
    entry.tournament_entry_members.create!(user: @users[1])

    loaded = TournamentEntry.where(id: entry.id).includes(:users).to_a
    user_queries = count_queries(/\bfrom\s+"?users"?/i) do
      loaded.each(&:display_name)
    end
    assert_equal 0, user_queries,
                 "display_name should read the preloaded :users association, not re-query"
  end

  test "an entry can carry the boat it was created from" do
    club = create(:club)
    tournament = create(:tournament, club: club, mode: :team)
    boat = create(:boat, club: club, name: "Team Loos")
    entry = create(:tournament_entry, tournament: tournament, name: "Team Loos", boat: boat)
    assert_equal boat, entry.reload.boat
    assert_equal [entry], boat.tournament_entries
  end

  test "a boat can't have two live entries in the same tournament (DB-level guard)" do
    boat = create(:boat, club: @club)
    create(:tournament_entry, tournament: @team_t, boat: boat)
    assert_raises(ActiveRecord::RecordNotUnique) do
      TournamentEntry.create!(tournament: @team_t, boat: boat)
    end
  end

  test "the same boat can have one entry each in two different tournaments" do
    boat = create(:boat, club: @club)
    create(:tournament_entry, tournament: @solo_t, boat: boat)
    assert_nothing_raised do
      TournamentEntry.create!(tournament: @team_t, boat: boat)
    end
  end

  test "multiple boat-less entries in the same tournament don't collide on the partial index" do
    assert_nothing_raised do
      2.times { TournamentEntry.create!(tournament: @team_t) }
    end
  end
end
