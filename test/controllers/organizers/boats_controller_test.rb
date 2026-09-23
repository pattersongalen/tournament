require "test_helper"

class Organizers::BoatsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @kurtis = create(:user, club: @club, name: "Kurtis Sanguin", role: :member)
    @boat = create(:boat, club: @club, name: "Majestic Red", captain: @kurtis)
    @team = create(:tournament, club: @club, mode: :team,
                   starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    sign_in_as(@organizer)
  end

  test "entering a boat creates the entry with the captain aboard" do
    assert_difference "TournamentEntry.count", 1 do
      post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    end
    entry = @team.tournament_entries.sole
    assert_equal "Majestic Red", entry.name
    assert_equal [@kurtis], entry.users
    assert_equal "Majestic Red entered.", flash[:notice]
  end

  test "entering the same boat twice is a no-op" do
    post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    assert_no_difference "TournamentEntry.count" do
      post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    end
  end

  # The picker is built from the club's ACTIVE members. Without the current
  # captain forced into the list, a deactivated captain matches no option,
  # nothing is marked selected, and the browser preselects the first member
  # alphabetically — so saving a typo fix silently hands the boat to them.
  test "the captain picker keeps a deactivated captain as the selected option" do
    create(:user, club: @club, name: "Aaron Aardvark", role: :member)
    @kurtis.update!(deactivated_at: 1.day.ago)

    get organizers_boats_path

    assert_response :success
    assert_select "select[name='boat[captain_user_id]'] option[selected][value=?]", @kurtis.id.to_s
  end

  test "a boat whose captain has left the club can still be renamed" do
    @kurtis.update!(deactivated_at: 1.day.ago)

    patch organizers_boat_path(@boat),
          params: { boat: { name: "Majestic Red II", captain_user_id: @kurtis.id } }

    assert_equal "Boat updated.", flash[:notice]
    assert_equal "Majestic Red II", @boat.reload.name
    assert_equal @kurtis.id, @boat.captain_user_id
  end

  test "a solo tournament refuses a boat" do
    solo = create(:tournament, club: @club, mode: :solo,
                  starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    assert_no_difference "TournamentEntry.count" do
      post enter_organizers_tournament_boat_path(tournament_id: solo.id, id: @boat.id)
    end
    assert_equal "Boats are for team tournaments.", flash[:alert]
  end

  test "creating a new boat enters it in the same submit" do
    assert_difference ["Boat.count", "TournamentEntry.count"], 1 do
      post organizers_boats_path, params: {
        tournament_id: @team.id,
        boat: { name: "Red Rocket", captain_user_id: @kurtis.id }
      }
    end
    assert_equal "Red Rocket", @team.tournament_entries.sole.name
  end

  test "a near-match name is refused with a suggestion rather than duplicated" do
    assert_no_difference "Boat.count" do
      post organizers_boats_path, params: {
        tournament_id: @team.id,
        boat: { name: "  majestic   RED  ", captain_user_id: @kurtis.id }
      }
    end
    assert_match(/Did you mean Majestic Red\?/, flash[:alert])
  end

  test "creating a boat in a solo tournament is refused" do
    solo = create(:tournament, club: @club, mode: :solo,
                  starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    assert_no_difference ["Boat.count", "TournamentEntry.count"] do
      post organizers_boats_path, params: {
        tournament_id: solo.id,
        boat: { name: "Red Rocket", captain_user_id: @kurtis.id }
      }
    end
    assert_equal "Boats are for team tournaments.", flash[:alert]
  end

  test "a retired boat is not offered as a near-match" do
    @boat.update!(active: false)
    assert_difference "Boat.count", 1 do
      post organizers_boats_path, params: {
        tournament_id: @team.id,
        boat: { name: "Team Majestic Red", captain_user_id: @kurtis.id }
      }
    end
    assert_equal "Team Majestic Red", @team.tournament_entries.sole.name
  end

  test "a near-match already entered in this tournament says so instead of pointing at an absent row" do
    post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    assert_no_difference "Boat.count" do
      post organizers_boats_path, params: {
        tournament_id: @team.id,
        boat: { name: "Team Majestic Red", captain_user_id: @kurtis.id }
      }
    end
    assert_equal "Majestic Red is already entered.", flash[:alert]
  end

  test "members are forbidden" do
    sign_in_as(@kurtis)
    post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    assert_response :forbidden
  end

  test "index lists the club's boats alphabetically with their captains" do
    create(:boat, club: @club, name: "Big Tiller", captain: create(:user, club: @club, name: "Kent Pierce"))
    get organizers_boats_path
    assert_response :success
    assert_match(/Big Tiller/, response.body)
    assert_match(/Kent Pierce/, response.body)
    assert_operator response.body.index("Big Tiller"), :<, response.body.index("Majestic Red")
  end

  test "renaming a boat keeps its captain" do
    patch organizers_boat_path(@boat), params: { boat: { name: "Majestic Red II", captain_user_id: @kurtis.id } }
    assert_equal "Majestic Red II", @boat.reload.name
    assert_equal @kurtis, @boat.captain
  end

  test "renaming a boat cascades the new name to its entries, including a finished tournament" do
    finished = create(:tournament, club: @club, mode: :team,
                       starts_at: 2.days.ago, ends_at: 1.day.ago)
    finished_entry = create(:tournament_entry, tournament: finished, name: "Majestic Red", boat: @boat)
    live_entry = create(:tournament_entry, tournament: @team, name: "Majestic Red", boat: @boat)

    patch organizers_boat_path(@boat), params: { boat: { name: "Majestic Red II", captain_user_id: @kurtis.id } }

    assert_equal "Majestic Red II", finished_entry.reload.name
    assert_equal "Majestic Red II", live_entry.reload.name
  end

  test "renaming a boat does not touch an entry whose name was deliberately edited away from it" do
    entry = create(:tournament_entry, tournament: @team, name: "Majestic Red - DQ'd", boat: @boat)

    patch organizers_boat_path(@boat), params: { boat: { name: "Majestic Red II", captain_user_id: @kurtis.id } }

    assert_equal "Majestic Red - DQ'd", entry.reload.name
  end

  test "changing only the captain does not touch entries" do
    other_captain = create(:user, club: @club, name: "Other Captain")
    entry = create(:tournament_entry, tournament: @team, name: "Majestic Red", boat: @boat)

    patch organizers_boat_path(@boat), params: { boat: { name: "Majestic Red", captain_user_id: other_captain.id } }

    assert_equal "Majestic Red", entry.reload.name
    assert_equal other_captain, @boat.reload.captain
  end

  test "renaming a boat re-broadcasts the leaderboard for every affected tournament" do
    finished = create(:tournament, club: @club, mode: :team,
                       starts_at: 2.days.ago, ends_at: 1.day.ago)
    create(:tournament_entry, tournament: finished, name: "Majestic Red", boat: @boat)
    create(:tournament_entry, tournament: @team, name: "Majestic Red", boat: @boat)

    tournament_ids = with_broadcast_spy do
      perform_enqueued_jobs do
        patch organizers_boat_path(@boat), params: { boat: { name: "Majestic Red II", captain_user_id: @kurtis.id } }
      end
    end

    assert_equal [finished.id, @team.id].sort, tournament_ids.sort
  end

  test "renaming a boat enqueues the redraw rather than broadcasting inline in the request" do
    create(:tournament_entry, tournament: @team, name: "Majestic Red", boat: @boat)

    assert_enqueued_with(job: BroadcastBoatRenameJob) do
      patch organizers_boat_path(@boat), params: { boat: { name: "Majestic Red II", captain_user_id: @kurtis.id } }
    end
  end

  test "retiring a boat moves it out of the active list into a Retired section, not deleted" do
    delete organizers_boat_path(@boat)
    assert_not @boat.reload.active
    get organizers_boats_path
    assert_response :success
    # The active-list edit/retire forms both post to organizers_boat_path;
    # once retired, the boat is only rendered in the Retired section, whose
    # only form is the Restore action at a different path.
    assert_select "form[action=?]", organizers_boat_path(@boat), count: 0
    assert_select "form[action=?]", restore_organizers_boat_path(@boat), count: 1
    assert_match(/Retired/, response.body)
    assert_match(/Majestic Red/, response.body)
  end

  test "restoring a retired boat returns it to the active list" do
    @boat.update!(active: false)
    post restore_organizers_boat_path(@boat)
    assert @boat.reload.active
    assert_redirected_to organizers_boats_path
    get organizers_boats_path
    assert_select "form[action=?]", organizers_boat_path(@boat), count: 2 # edit form + retire form
    assert_select "form[action=?]", restore_organizers_boat_path(@boat), count: 0
  end

  test "a mis-tapped retire can be undone via Restore, without console access" do
    delete organizers_boat_path(@boat)
    assert_not @boat.reload.active

    post restore_organizers_boat_path(@boat)
    assert @boat.reload.active
    assert_equal "Majestic Red", @boat.name

    # Restored means pickable again, not just flagged active in the DB.
    get edit_organizers_tournament_path(@team)
    assert_select "form[action=?]",
                  enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id), count: 1
  end

  test "index eager-loads captains instead of N+1 per row" do
    # Total "users" queries per request also include the signed-in
    # current_user lookup and the per-row member-picker <select> (a separate,
    # pre-existing, out-of-scope N+1 that the request-level query cache
    # collapses to one real query since it's byte-identical every iteration).
    # Neither of those scales with the number of boats, so comparing the
    # query count at 1 boat vs 3 boats isolates just the captain load and is
    # robust to those constants: N+1 on captain shows up as a difference.
    one_boat_queries = count_queries(/\bfrom\s+"?users"?/i) { get organizers_boats_path }

    create(:boat, club: @club, name: "Big Tiller", captain: create(:user, club: @club, name: "Kent Pierce"))
    create(:boat, club: @club, name: "Red Rocket", captain: create(:user, club: @club, name: "Nate Rosengren"))

    three_boat_queries = count_queries(/\bfrom\s+"?users"?/i) { get organizers_boats_path }

    assert_equal one_boat_queries, three_boat_queries,
                 "captain lookups should be batched, not scale with the number of boats"
  end

  test "entering a boat whose captain is already entered elsewhere redirects with an alert instead of crashing" do
    other_entry = create(:tournament_entry, tournament: @team, name: "Big Tiller")
    create(:tournament_entry_member, tournament_entry: other_entry, user: @kurtis)

    assert_no_difference "TournamentEntry.count" do
      post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/already entered/i, flash[:alert])
  end

  test "creating a new boat whose captain is already entered elsewhere redirects with an alert instead of crashing" do
    other_entry = create(:tournament_entry, tournament: @team, name: "Big Tiller")
    create(:tournament_entry_member, tournament_entry: other_entry, user: @kurtis)

    assert_difference "Boat.count", 1 do
      assert_no_difference "TournamentEntry.count" do
        post organizers_boats_path, params: {
          tournament_id: @team.id,
          boat: { name: "Red Rocket", captain_user_id: @kurtis.id }
        }
      end
    end
    assert_match(/already entered/i, flash[:alert])
  end

  test "a leading 'The' triggers a near-match against the existing boat" do
    create(:boat, club: @club, name: "Pearl", captain: @kurtis)
    assert_no_difference "Boat.count" do
      post organizers_boats_path, params: {
        tournament_id: @team.id,
        boat: { name: "The Pearl", captain_user_id: @kurtis.id }
      }
    end
    assert_match(/Did you mean Pearl\?/, flash[:alert])
  end

  test "an already-entered boat does not appear in the add-a-boat picker" do
    post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    get edit_organizers_tournament_path(@team)
    assert_response :success
    assert_select "form[action=?]",
                  enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id), count: 0
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
  # Name uniqueness spans retired boats, but the picker and NearMatch cover
  # only active ones — so retyping a retired boat's own name hits the index
  # and, without this branch, reports "is already a boat in this club" for a
  # boat that is nowhere on screen, with no hint that Restore is the fix.
  test "retyping a retired boat's exact name points at Restore" do
    @boat.update!(active: false)

    assert_no_difference "Boat.count" do
      post organizers_boats_path, params: {
        tournament_id: @team.id,
        boat: { name: "majestic red", captain_user_id: @kurtis.id }
      }
    end

    assert_redirected_to organizers_boats_path
    assert_match(/retired/i, flash[:alert])
    assert_match(/Restore/, flash[:alert])
  end

  # The picker lists active boats only, but the page is a snapshot: one
  # organizer can retire a boat while another still has the row on screen.
  # Tapping it then went around the Restore flow entirely.
  test "entering a retired boat points at Restore instead of entering it" do
    @boat.update!(active: false)

    assert_no_difference "TournamentEntry.count" do
      post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    end

    assert_redirected_to organizers_boats_path
    assert_match(/retired/i, flash[:alert])
    assert_match(/Restore/, flash[:alert])
  end

  # A boat keeps its captain after they leave the club (see Boat), so it stays
  # in the picker — but the tap must not seat a departed angler, which is what
  # the per-member controls on the same screen already refuse.
  test "entering a boat whose captain has left the club is refused" do
    @kurtis.update!(deactivated_at: 1.day.ago)

    assert_no_difference "TournamentEntry.count" do
      post enter_organizers_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    end

    assert_match(/Kurtis Sanguin has left the club/, flash[:alert])
    assert_match(/Reassign/, flash[:alert])
  end

  # Creating refuses a near-match; renaming has to as well, or the rename
  # recreates the exact Majestic Red / Magestic Red split the guard prevents.
  test "renaming a boat onto another boat's near-match is refused" do
    other = create(:boat, club: @club, name: "Magestic Red", captain: @organizer)

    patch organizers_boat_path(other),
          params: { boat: { name: "Team Majestic Red", captain_user_id: @organizer.id } }

    assert_equal "Magestic Red", other.reload.name
    assert_match(/Majestic Red is already a boat/, flash[:alert])
  end

  test "renaming a boat to a variant of its own name is still allowed" do
    patch organizers_boat_path(@boat),
          params: { boat: { name: "Team Majestic Red", captain_user_id: @kurtis.id } }

    assert_equal "Team Majestic Red", @boat.reload.name
  end

  # Retire is reversible and keeps history attached. Delete is the escape hatch
  # for a boat that should never have existed — a duplicate spelling, a typo, a
  # seed proposal that came out wrong — and is gated behind Retire so a boat
  # still in the picker can't be destroyed by one stray tap.
  test "deleting a retired boat removes it permanently" do
    @boat.update!(active: false)

    assert_difference "Boat.count", -1 do
      delete purge_organizers_boat_path(@boat)
    end
    assert_redirected_to organizers_boats_path
    assert_match(/deleted/i, flash[:notice])
  end

  # The property that makes Delete safe to offer at all: boat_id is read by the
  # picker, the rename cascade and "same as last week", never by
  # Leaderboards::Build, which ranks off the entry and its own name column.
  test "deleting a retired boat leaves its entries and their names standing, only unlinked" do
    finished = create(:tournament, club: @club, mode: :team,
                      starts_at: 2.days.ago, ends_at: 1.day.ago)
    entry = create(:tournament_entry, tournament: finished, name: "Majestic Red", boat: @boat)
    @boat.update!(active: false)

    assert_no_difference "TournamentEntry.count" do
      delete purge_organizers_boat_path(@boat)
    end

    assert_nil entry.reload.boat_id
    assert_equal "Majestic Red", entry.name
  end

  # The Delete button renders only in the Retired section, but the page is a
  # snapshot — another organizer can restore a boat while this one still has
  # the row on screen, the same race #enter guards against.
  test "deleting a boat that is still active is refused" do
    assert_no_difference "Boat.count" do
      delete purge_organizers_boat_path(@boat)
    end
    assert_match(/retire/i, flash[:alert])
  end

  # Retire does not touch entries, so a boat can be retired while it is still
  # entered in tonight's league night. Delete nullifies boat_id, which drops
  # that entry out of every single-entry guard at once -- Boats::Enter's
  # find_by(boat_id:), the partial unique index, and the picker's filter -- so
  # re-creating the freed name and tapping it makes a second entry for the same
  # crew in the same live tournament.
  test "deleting a retired boat still entered in a tournament that has not ended is refused" do
    live = create(:tournament, club: @club, mode: :team,
                  starts_at: 1.hour.ago, ends_at: 3.hours.from_now)
    create(:tournament_entry, tournament: live, name: "Majestic Red", boat: @boat)
    @boat.update!(active: false)

    assert_no_difference "Boat.count" do
      delete purge_organizers_boat_path(@boat)
    end
    assert_match(/still entered/i, flash[:alert])
  end

  test "deleting a retired boat entered only in finished tournaments is allowed" do
    finished = create(:tournament, club: @club, mode: :team,
                      starts_at: 2.days.ago, ends_at: 1.day.ago)
    create(:tournament_entry, tournament: finished, name: "Majestic Red", boat: @boat)
    @boat.update!(active: false)

    assert_difference "Boat.count", -1 do
      delete purge_organizers_boat_path(@boat)
    end
    assert_match(/deleted/i, flash[:notice])
  end

  # The confirm calls these "past entries", so an entry in a tournament that is
  # still to come must not be counted among them.
  test "the Delete confirmation counts only entries in finished tournaments" do
    create(:tournament_entry, tournament: @team, name: "Majestic Red", boat: @boat)
    @boat.update!(active: false)

    get organizers_boats_path

    # Positive anchor first: the assert_no_match below must not pass merely
    # because the Retired section failed to render at all.
    assert_select "form[action=?]", purge_organizers_boat_path(@boat), count: 1
    assert_no_match(/past entr/, response.body)
  end

  test "deleting a boat in another club is out of reach" do
    other = create(:boat, club: create(:club), name: "Someone Else's Boat", active: false)

    assert_no_difference "Boat.count" do
      delete purge_organizers_boat_path(other)
    end
    assert_response :not_found
  end

  test "the Retired section offers Delete alongside Restore, naming how many entries it unlinks" do
    finished = create(:tournament, club: @club, mode: :team,
                      starts_at: 2.days.ago, ends_at: 1.day.ago)
    create(:tournament_entry, tournament: finished, name: "Majestic Red", boat: @boat)
    @boat.update!(active: false)

    get organizers_boats_path

    assert_select "form[action=?]", purge_organizers_boat_path(@boat), count: 1
    assert_select "form[action=?]", restore_organizers_boat_path(@boat), count: 1
    assert_match(/1 past entry/, response.body)
  end

  test "the Delete confirmation on a boat with no history does not mention entries" do
    @boat.update!(active: false)

    get organizers_boats_path

    assert_select "form[action=?]", purge_organizers_boat_path(@boat), count: 1
    assert_no_match(/past entr/, response.body)
  end

  # See the captain eager-loading test above for why this compares query counts
  # at 1 vs 3 retired boats rather than asserting an absolute cap.
  test "the retired list counts entries in one query rather than one per boat" do
    @boat.update!(active: false)
    one_boat = count_queries(/\bfrom\s+"?tournament_entries"?/i) { get organizers_boats_path }

    create(:boat, club: @club, name: "Old Tiller", active: false)
    create(:boat, club: @club, name: "Old Pearl", active: false)

    three_boats = count_queries(/\bfrom\s+"?tournament_entries"?/i) { get organizers_boats_path }

    assert_equal one_boat, three_boats,
                 "entry counts should be batched, not scale with the retired list"
  end

end
