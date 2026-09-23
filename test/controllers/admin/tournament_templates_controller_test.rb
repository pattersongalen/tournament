require "test_helper"

# The /admin templates screen is a twin of the /organizers one, which carries
# the full behavioural suite (strong-params permit families, clone). This
# covers the admin view + one smoke per action; the actions themselves are the
# shared OrganizerActions::TournamentTemplates concern.
class Admin::TournamentTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    sign_in_as(@organizer)
  end

  test "create accepts season_tag" do
    assert_difference -> { TournamentTemplate.count }, 1 do
      post admin_tournament_templates_path, params: {
        tournament_template: { name: "Wednesday League", mode: "solo", season_tag: "2026" }
      }
    end
    assert_redirected_to admin_tournament_templates_path
    assert_equal "2026", TournamentTemplate.last.season_tag
  end

  test "POST clone carries the template's season_tag onto the tournament" do
    walleye = create(:species, club: @club)
    template = create(:tournament_template, club: @club, name: "Monthly Walleye", season_tag: "2026")
    template.tournament_template_scoring_slots.create!(species: walleye, slot_count: 1)

    post clone_admin_tournament_template_path(template),
         params: { starts_at: 1.day.from_now, ends_at: 1.day.from_now + 4.hours }

    assert_redirected_to admin_tournaments_path
    assert_equal "2026", Tournament.last.season_tag
  end

  # Twin of the organizers picker: a solo candidate is an offer that can only end
  # in a validation failure, since link groups are team-mode only.
  test "the pairing picker offers team templates only" do
    main = create(:tournament_template, club: @club, name: "Wednesday Main", mode: :team)
    team_candidate = create(:tournament_template, club: @club, name: "Wednesday Side", mode: :team)
    solo_candidate = create(:tournament_template, club: @club, name: "Saturday Solo", mode: :solo)

    get edit_admin_tournament_template_path(main)

    assert_response :success
    assert_select "select#tournament_template_paired_template_id option[value=?]",
                  team_candidate.id.to_s, 1
    assert_select "select#tournament_template_paired_template_id option[value=?]",
                  solo_candidate.id.to_s, 0
  end

  test "a paired template shows once, with a league-night action instead of Schedule next" do
    main = create(:tournament_template, club: @club, name: "League Night - Main", mode: :team,
                  default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00")
    side = create(:tournament_template, club: @club, name: "League Night - Side", mode: :team,
                  default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00")
    main.update!(paired_template: side)

    get admin_tournament_templates_path

    assert_response :success
    assert_select "form[action=?]",
                  new_admin_tournament_template_league_night_path(tournament_template_id: main.id),
                  count: 1 do
      assert_select "button", text: "Schedule next league night", count: 1
    end
    assert_match(/League Night - Main \+ League Night - Side/, response.body)
    assert_select "form[action=?]", clone_admin_tournament_template_path(main), count: 0
    assert_select "form[action=?]", clone_admin_tournament_template_path(side), count: 0
    assert_select "a[href=?]", edit_admin_tournament_template_path(main), count: 1
    assert_select "a[href=?]", edit_admin_tournament_template_path(side), count: 1
    assert_select "form[action=?]", admin_tournament_template_path(main), count: 1
    assert_select "form[action=?]", admin_tournament_template_path(side), count: 1
  end

  test "a paired template with no weekday or times still links to the scheduler" do
    main = create(:tournament_template, club: @club, name: "League Night - Main", mode: :team)
    side = create(:tournament_template, club: @club, name: "League Night - Side", mode: :team)
    main.update!(paired_template: side)

    get admin_tournament_templates_path

    assert_select "form[action=?]",
                  new_admin_tournament_template_league_night_path(tournament_template_id: main.id),
                  count: 1 do
      assert_select "button", text: "Schedule next league night", count: 1
    end
    assert_no_match(/either template/, response.body)
    assert_select "form[action=?]", clone_admin_tournament_template_path(main), count: 0
    assert_select "form[action=?]", clone_admin_tournament_template_path(side), count: 0
  end

  test "an unpaired template keeps its own Schedule next button" do
    solo = create(:tournament_template, club: @club, name: "Saturday LML",
                  default_weekday: 6, default_start_time: "08:00", default_end_time: "16:00")

    get admin_tournament_templates_path

    assert_select "form[action=?]", clone_admin_tournament_template_path(solo), count: 1
    assert_select "form[action=?]",
                  new_admin_tournament_template_league_night_path(tournament_template_id: solo.id),
                  count: 0
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
