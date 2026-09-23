require "test_helper"

# The /admin deputies screen is a twin of the /organizers one, which carries
# the full behavioural suite. This covers the add smoke and the
# require_permanent_organizer! gate (a live deputy can't grant another
# deputy); the actions themselves are the shared
# OrganizerActions::TournamentDeputies concern.
class Admin::TournamentDeputiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club      = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @member    = create(:user, club: @club, role: :member, name: "Mike")
    @upcoming  = create(:tournament, club: @club, starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
  end

  # add smoke
  test "an organizer adds a deputy" do
    sign_in_as(@organizer)
    assert_difference "TournamentDeputy.count", 1 do
      post admin_tournament_tournament_deputies_path(tournament_id: @upcoming.id),
           params: { tournament_deputy: { user_id: @member.id } }
    end
    assert_redirected_to edit_admin_tournament_path(@upcoming)
  end

  # require_permanent_organizer! gate: granting is privilege-granting, so a
  # deputy (widened organizer_in? but not permanent_organizer_in?) is refused.
  test "a live deputy cannot deputize anyone else" do
    create(:tournament_deputy, tournament: @upcoming, user: @member, granted_by_user: @organizer)
    victim = create(:user, club: @club, role: :member)
    sign_in_as(@member)
    post admin_tournament_tournament_deputies_path(tournament_id: @upcoming.id),
         params: { tournament_deputy: { user_id: victim.id } }
    assert_response :forbidden
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
