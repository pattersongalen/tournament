require "test_helper"

# The /admin boats screen is a twin of the /organizers one, which carries the
# full behavioural suite (Boats::RenameEntries, Boats::Enter, Boats::NearMatch,
# purge guards). This covers the admin view (all 7 tests that render the index
# page) plus one happy-path smoke per mutating action; the actions themselves
# are the shared OrganizerActions::Boats concern.
class Admin::BoatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @kurtis = create(:user, club: @club, name: "Kurtis Sanguin", role: :member)
    @boat = create(:boat, club: @club, name: "Majestic Red", captain: @kurtis)
    @team = create(:tournament, club: @club, mode: :team,
                   starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    sign_in_as(@organizer)
  end

  # create smoke
  test "a retired boat is not offered as a near-match" do
    @boat.update!(active: false)
    assert_difference "Boat.count", 1 do
      post admin_boats_path, params: {
        tournament_id: @team.id,
        boat: { name: "Team Majestic Red", captain_user_id: @kurtis.id }
      }
    end
    assert_equal "Team Majestic Red", @team.tournament_entries.sole.name
  end

  # update smoke
  test "renaming a boat keeps its captain" do
    patch admin_boat_path(@boat), params: { boat: { name: "Majestic Red II", captain_user_id: @kurtis.id } }
    assert_equal "Majestic Red II", @boat.reload.name
    assert_equal @kurtis, @boat.captain
  end

  # view test: retire (destroy) + the active/Retired split
  test "retiring a boat moves it out of the active list into a Retired section, not deleted" do
    delete admin_boat_path(@boat)
    assert_not @boat.reload.active
    get admin_boats_path
    assert_response :success
    assert_select "form[action=?]", admin_boat_path(@boat), count: 0
    assert_select "form[action=?]", restore_admin_boat_path(@boat), count: 1
    assert_match(/Retired/, response.body)
    assert_match(/Majestic Red/, response.body)
  end

  # view test: restore
  test "restoring a retired boat returns it to the active list" do
    @boat.update!(active: false)
    post restore_admin_boat_path(@boat)
    assert @boat.reload.active
    assert_redirected_to admin_boats_path
    get admin_boats_path
    assert_select "form[action=?]", admin_boat_path(@boat), count: 2
    assert_select "form[action=?]", restore_admin_boat_path(@boat), count: 0
  end

  # view test
  test "index eager-loads captains instead of N+1 per row" do
    # See the organizers namespace's identical test for why this compares
    # query counts at 1 vs 3 boats rather than asserting an absolute cap.
    one_boat_queries = count_queries(/\bfrom\s+"?users"?/i) { get admin_boats_path }

    create(:boat, club: @club, name: "Big Tiller", captain: create(:user, club: @club, name: "Kent Pierce"))
    create(:boat, club: @club, name: "Red Rocket", captain: create(:user, club: @club, name: "Nate Rosengren"))

    three_boat_queries = count_queries(/\bfrom\s+"?users"?/i) { get admin_boats_path }

    assert_equal one_boat_queries, three_boat_queries,
                 "captain lookups should be batched, not scale with the number of boats"
  end

  # enter smoke
  test "entering a boat whose captain is already entered elsewhere redirects with an alert instead of crashing" do
    other_entry = create(:tournament_entry, tournament: @team, name: "Big Tiller")
    create(:tournament_entry_member, tournament_entry: other_entry, user: @kurtis)

    assert_no_difference "TournamentEntry.count" do
      post enter_admin_tournament_boat_path(tournament_id: @team.id, id: @boat.id)
    end
    assert_redirected_to edit_admin_tournament_path(@team)
    assert_match(/already entered/i, flash[:alert])
  end

  # purge smoke
  test "deleting a retired boat removes it permanently" do
    @boat.update!(active: false)

    assert_difference "Boat.count", -1 do
      delete purge_admin_boat_path(@boat)
    end
    assert_redirected_to admin_boats_path
    assert_match(/deleted/i, flash[:notice])
  end

  # The confirm calls these "past entries", so an entry in a tournament that is
  # still to come must not be counted among them.
  test "the Delete confirmation counts only entries in finished tournaments" do
    create(:tournament_entry, tournament: @team, name: "Majestic Red", boat: @boat)
    @boat.update!(active: false)

    get admin_boats_path

    # Positive anchor first: the assert_no_match below must not pass merely
    # because the Retired section failed to render at all.
    assert_select "form[action=?]", purge_admin_boat_path(@boat), count: 1
    assert_no_match(/past entr/, response.body)
  end

  # view test
  test "the Retired section offers Delete alongside Restore, naming how many entries it unlinks" do
    finished = create(:tournament, club: @club, mode: :team,
                      starts_at: 2.days.ago, ends_at: 1.day.ago)
    create(:tournament_entry, tournament: finished, name: "Majestic Red", boat: @boat)
    @boat.update!(active: false)

    get admin_boats_path

    assert_select "form[action=?]", purge_admin_boat_path(@boat), count: 1
    assert_select "form[action=?]", restore_admin_boat_path(@boat), count: 1
    assert_match(/1 past entry/, response.body)
  end

  # view test
  test "the Delete confirmation on a boat with no history does not mention entries" do
    @boat.update!(active: false)

    get admin_boats_path

    assert_select "form[action=?]", purge_admin_boat_path(@boat), count: 1
    assert_no_match(/past entr/, response.body)
  end

  # view test
  test "the retired list counts entries in one query rather than one per boat" do
    # See the captain eager-loading test above for why this compares query
    # counts at 1 vs 3 retired boats rather than asserting an absolute cap.
    @boat.update!(active: false)
    one_boat = count_queries(/\bfrom\s+"?tournament_entries"?/i) { get admin_boats_path }

    create(:boat, club: @club, name: "Old Tiller", active: false)
    create(:boat, club: @club, name: "Old Pearl", active: false)

    three_boats = count_queries(/\bfrom\s+"?tournament_entries"?/i) { get admin_boats_path }

    assert_equal one_boat, three_boats,
                 "entry counts should be batched, not scale with the retired list"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
