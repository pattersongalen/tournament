require "test_helper"

# The /admin scheduler is a twin of the /organizers one, which carries the full
# behavioural suite. This covers the parts that can drift between the two:
# the routes, the path helpers each view and redirect uses, and the view itself.
class Admin::LeagueNightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @walleye = create(:species, name: "Walleye")
    @main = create(:tournament_template, club: @club, name: "League Night - Main", mode: :team,
                   default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00",
                   blind_leaderboard: true)
    @side = create(:tournament_template, club: @club, name: "League Night - Side", mode: :team,
                   default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00")
    @main.update!(paired_template: @side)
    sign_in_as(@organizer)
  end

  test "the screen renders and names both columns" do
    get new_admin_tournament_template_league_night_path(tournament_template_id: @main.id)
    assert_response :success
    assert_match(/League Night - Main/, response.body)
    assert_match(/League Night - Side/, response.body)
    # The date picker is a standalone GET form in this view (not a shared
    # partial), so its action has to be pinned to the admin path helper or a
    # drift to the organizers one would go uncaught.
    assert_select "form[action=?][method=get]",
                  new_admin_tournament_template_league_night_path(tournament_template_id: @main.id)
    assert_select "input[type=date][name='date']"
  end

  # The footer clause and the Stimulus value the leak warning reads are written
  # into both views by hand, so they can drift between the twins.
  test "the footer claims Main is always blind only when its template is" do
    get new_admin_tournament_template_league_night_path(tournament_template_id: @main.id)
    assert_response :success
    assert_match(/League Night - Main always blind/, response.body)
    assert_select "form[data-league-night-main-blind-value='true']", 1

    @main.update!(blind_leaderboard: false)
    get new_admin_tournament_template_league_night_path(tournament_template_id: @main.id)
    assert_response :success
    assert_no_match(/always blind/, response.body)
    assert_select "form[data-league-night-main-blind-value='false']", 1
  end

  # Three states, not two. The old two-way ternary named the Side template
  # whenever Main didn't award points, so a pair where neither does read
  # "season points on <Side>" — a flat falsehood in the one line of the page
  # that claims to report what the templates say.
  test "the footer names every half that awards season points, and says so when none do" do
    get new_admin_tournament_template_league_night_path(tournament_template_id: @main.id)
    assert_response :success
    assert_match(/no season points/, response.body)

    @side.update!(awards_season_points: true)
    get new_admin_tournament_template_league_night_path(tournament_template_id: @main.id)
    assert_response :success
    assert_match(/season points on League Night - Side/, response.body)

    @main.update!(awards_season_points: true)
    get new_admin_tournament_template_league_night_path(tournament_template_id: @main.id)
    assert_response :success
    assert_match(/season points on League Night - Main and League Night - Side/, response.body)
  end

  # Also the only branch of this view that names edit_admin_tournament_template_path.
  test "a pair with no weekday or times says so instead of rendering the form" do
    unscheduled_main = create(:tournament_template, club: @club, name: "Someday - Main", mode: :team)
    unscheduled_side = create(:tournament_template, club: @club, name: "Someday - Side", mode: :team)
    unscheduled_main.update!(paired_template: unscheduled_side)

    get new_admin_tournament_template_league_night_path(tournament_template_id: unscheduled_main.id)
    assert_response :success
    assert_match(/weekday/i, response.body)
    assert_no_match(/Create both/, response.body)
    assert_select "a[href=?]", edit_admin_tournament_template_path(unscheduled_main)
  end

  test "creating a league night makes both tournaments, linked" do
    starts_at, ends_at = @main.next_occurrence_at

    assert_difference "Tournament.count", 2 do
      post admin_tournament_template_league_night_path(tournament_template_id: @main.id),
           params: { league_night: {
             starts_at: starts_at.iso8601, ends_at: ends_at.iso8601,
             main: { format: "standard", species_id: @walleye.id },
             side: { format: "smallest_fish", species_id: @walleye.id, slot_count: 1 }
           } }
    end

    main_t = Tournament.find_by(template_source_id: @main.id)
    side_t = Tournament.find_by(template_source_id: @side.id)
    assert_equal main_t.link_group_id, side_t.link_group_id
    assert_redirected_to edit_admin_tournament_path(main_t)
  end

  # The repair branch is a second full copy of the column loop and the submit
  # button in this view, so it can drift from the organizers one on its own.
  test "a half-scheduled night offers to create the missing half only" do
    starts_at, ends_at = @main.next_occurrence_at
    create(:tournament, club: @club, name: @main.name, mode: :team,
           starts_at: starts_at, ends_at: ends_at, template_source_id: @main.id)

    get new_admin_tournament_template_league_night_path(tournament_template_id: @main.id)
    assert_response :success
    assert_match(/already has .*League Night - Main/i, response.body)
    assert_select "select[name='league_night[side][format]']", 1
    assert_select "select[name='league_night[main][format]']", 0
    assert_select "input[type=submit][value='Create the missing half']"

    assert_difference "Tournament.count", 1 do
      post admin_tournament_template_league_night_path(tournament_template_id: @main.id),
           params: { league_night: {
             starts_at: starts_at.iso8601, ends_at: ends_at.iso8601,
             side: { format: "standard", species_id: @walleye.id, slot_count: 1 }
           } }
    end
    assert_redirected_to edit_admin_tournament_path(Tournament.find_by(template_source_id: @side.id))
  end

  test "a validation failure creates neither and re-renders" do
    starts_at, ends_at = @main.next_occurrence_at

    assert_no_difference "Tournament.count" do
      post admin_tournament_template_league_night_path(tournament_template_id: @main.id),
           params: { league_night: {
             starts_at: starts_at.iso8601, ends_at: ends_at.iso8601,
             main: { format: "progressive_length", species_id: @walleye.id },
             side: { format: "smallest_fish", species_id: "" }
           } }
    end
    assert_response :unprocessable_entity
    # The admin view carries its own copy of the "fall back to what was
    # submitted" logic. The Main template's own format is standard, so this
    # only holds if the re-render reads the submission.
    assert_select "select[name='league_night[main][format]'] option[value=?][selected]", "progressive_length"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
