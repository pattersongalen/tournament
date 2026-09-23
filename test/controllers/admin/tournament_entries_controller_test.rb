require "test_helper"

# The /admin tournament entries screen is a twin of the /organizers one, which
# carries the full behavioural suite (linked-tournament mirroring, backfill,
# judging-conflict guards). This covers one happy-path smoke per action; the
# actions themselves are the shared OrganizerActions::TournamentEntries
# concern.
class Admin::TournamentEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @member = create(:user, club: @club, name: "Joe", role: :member)
    @team = create(:tournament, club: @club, mode: :team,
                                starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
    sign_in_as(@organizer)
  end

  # create smoke
  test "organizer creates a team entry" do
    assert_difference "TournamentEntry.count", 1 do
      post admin_tournament_tournament_entries_path(tournament_id: @team.id),
           params: { tournament_entry: { name: "Boat", member_user_ids: [@member.id] } }
    end
    entry = TournamentEntry.last
    assert_equal "Boat", entry.name
    assert_redirected_to edit_admin_tournament_path(@team)
  end

  # update smoke
  test "organizer renames a team entry before tournament starts" do
    entry = create(:tournament_entry, tournament: @team, name: "Old")
    create(:tournament_entry_member, tournament_entry: entry, user: @member)

    patch admin_tournament_tournament_entry_path(tournament_id: @team.id, id: entry.id),
          params: { tournament_entry: { name: "New" } }

    assert_redirected_to edit_admin_tournament_path(@team)
    assert_equal "New", entry.reload.name
  end

  # destroy smoke
  test "destroying an entry mid-tournament cascades placements and broadcasts the leaderboard" do
    walleye = create(:species, club: @club)
    started = create(:tournament, club: @club, mode: :team, starts_at: 30.minutes.ago, ends_at: 30.minutes.from_now)
    create(:scoring_slot, tournament: started, species: walleye, slot_count: 2)
    entry = create(:tournament_entry, tournament: started, name: "Doomed")
    create(:tournament_entry_member, tournament_entry: entry, user: @member)
    fish = create(:catch, user: @member, species: walleye, length_inches: 18, captured_at_device: 5.minutes.ago)
    Catches::PlaceInSlots.call(catch: fish)

    broadcast_calls = with_broadcast_spy do
      assert_difference "TournamentEntry.count", -1 do
        delete admin_tournament_tournament_entry_path(tournament_id: started.id, id: entry.id)
      end
    end
    assert_equal [started.id], broadcast_calls
    assert_equal 0, CatchPlacement.where(catch_id: fish.id).count
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
