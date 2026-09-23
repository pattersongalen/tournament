require "test_helper"

class Admin::Clubs::TournamentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host_club    = create(:club, name: "Host Anglers")
    @foreign_club = create(:club, name: "Northtown Anglers")
    @admin     = create(:user, club: @host_club, admin: true, role: :organizer)
    @organizer = create(:user, club: @host_club, role: :organizer)

    @foreign_t = create(:tournament, club: @foreign_club, name: "Northtown Spring Bash")
    @host_t    = create(:tournament, club: @host_club, name: "Host Club Derby")
  end

  # Shares Admin::Clubs::BaseController with Members/Catches, which carry the
  # full signed-out + non-admin gate coverage; this is a smoke that the same
  # class-level before_actions apply here too.
  test "non-admin organizer is forbidden" do
    sign_in_as(@organizer)
    get admin_club_tournaments_path(@foreign_club)
    assert_response :forbidden
  end

  test "admin sees the foreign club's tournament" do
    sign_in_as(@admin)
    get admin_club_tournaments_path(@foreign_club)
    assert_response :success
    assert_includes response.body, "Northtown Spring Bash"
  end

  test "admin does NOT see host club's tournaments in foreign list" do
    sign_in_as(@admin)
    get admin_club_tournaments_path(@foreign_club)
    assert_response :success
    refute_includes response.body, "Host Club Derby"
  end

  test "banner is rendered with the foreign club's name" do
    sign_in_as(@admin)
    get admin_club_tournaments_path(@foreign_club)
    assert_includes response.body, "Viewing Northtown Anglers"
    assert_includes response.body, "read-only"
  end

  test "admin can view a foreign club's tournament detail page" do
    sign_in_as(@admin)
    get admin_club_tournament_path(@foreign_club, @foreign_t)
    assert_response :success
    assert_includes response.body, "Northtown Spring Bash"
    assert_includes response.body, "Viewing Northtown Anglers"
  end

  test "admin foreign tournament show suppresses the member-facing entry CTA" do
    sign_in_as(@admin)
    get admin_club_tournament_path(@foreign_club, @foreign_t)
    assert_response :success
    refute_includes response.body, "You're not entered"
    refute_includes response.body, "Log Catch"
  end

  test "admin cannot reach a tournament that belongs to a different club via this path" do
    sign_in_as(@admin)
    get admin_club_tournament_path(@foreign_club, @host_t)
    assert_response :not_found
  end

  test "banner offers a back-to-hub link on sub-section pages" do
    sign_in_as(@admin)
    get admin_club_tournaments_path(@foreign_club)
    assert_response :success
    assert_select "a[href=?]", admin_club_path(@foreign_club), text: /Back to club/
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
