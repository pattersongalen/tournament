require "test_helper"

class Admin::Clubs::CatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host_club    = create(:club, name: "Host Anglers")
    @foreign_club = create(:club, name: "Northtown Anglers")
    @admin     = create(:user, club: @host_club, admin: true, role: :organizer)
    @organizer = create(:user, club: @host_club, role: :organizer)
    @member    = create(:user, club: @host_club, role: :member)

    @foreign_member = create(:user, club: @foreign_club, name: "Northtown Nancy", role: :member)
    @host_catch    = create(:catch, user: @member, length_inches: 22.5)
    @foreign_catch = create(:catch, user: @foreign_member, length_inches: 19.0)
  end

  # Shares Admin::Clubs::BaseController with Members/Tournaments, which carry the
  # full signed-out + non-admin gate coverage; this is a smoke that the same
  # class-level before_actions apply here too.
  test "non-admin organizer is forbidden" do
    sign_in_as(@organizer)
    get admin_club_catches_path(@foreign_club)
    assert_response :forbidden
  end

  test "admin sees the foreign club's catches" do
    sign_in_as(@admin)
    get admin_club_catches_path(@foreign_club)
    assert_response :success
    assert_includes response.body, "Northtown Nancy"
  end

  test "admin does NOT see host-club catches in the foreign list" do
    sign_in_as(@admin)
    get admin_club_catches_path(@foreign_club)
    refute_includes response.body, @member.name
  end

  test "user_id filter scopes the catch list to the selected user" do
    other_foreign = create(:user, club: @foreign_club, name: "Other Foreign", role: :member)
    create(:catch, user: other_foreign, length_inches: 14.0)
    sign_in_as(@admin)
    get admin_club_catches_path(@foreign_club), params: { user_id: @foreign_member.id }

    # Scope assertions to the catch-card list (the <ul> that contains each catch <li>),
    # not the whole body — "Other Foreign" is still legitimately present in the filter
    # dropdown options. assert_select narrows to the catch grid.
    assert_select "ul.grid li", minimum: 1 do
      assert_select "*", text: /Northtown Nancy/
    end
    assert_select "ul.grid li *", text: /Other Foreign/, count: 0
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
