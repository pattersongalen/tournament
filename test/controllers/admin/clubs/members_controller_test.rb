require "test_helper"

class Admin::Clubs::MembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin_home_club = create(:club, name: "BS Phishing Family")
    @target_club = create(:club, name: "Northtown Anglers")
    @admin = create(:user, club: @admin_home_club, admin: true)
    @organizer = create(:user, club: @admin_home_club, role: :organizer)
    @member = create(:user, club: @admin_home_club, role: :member)

    @foreign_club = @target_club
    @foreign_member = create(:user, club: @foreign_club, name: "Northtown Nancy", role: :member)
  end

  test "signed-out cannot access" do
    get new_admin_club_member_path(@target_club)
    assert_redirected_to new_session_path
  end

  test "organizer without admin flag is forbidden" do
    sign_in_as(@organizer)
    get new_admin_club_member_path(@target_club)
    assert_response :forbidden
  end

  test "admin sees the form" do
    sign_in_as(@admin)
    get new_admin_club_member_path(@target_club)
    assert_response :success
    assert_includes response.body, "Northtown Anglers"
  end

  test "admin invites a member into a different club" do
    sign_in_as(@admin)
    assert_difference -> { User.count } => 1,
                      -> { ClubMembership.count } => 1,
                      -> { SignInToken.count } => 1 do
      assert_emails 1 do
        post admin_club_members_path(@target_club), params: {
          user: { name: "First Org", email: "first@northtown.example", role: "organizer" }
        }
      end
    end
    assert_redirected_to admin_clubs_path
    new_user = User.find_by(email: "first@northtown.example")
    membership = new_user.club_memberships.first
    assert_equal @target_club, membership.club
    assert membership.organizer?
    # Token's club is the target club, not the admin's home club.
    assert_equal @target_club, SignInToken.last.club
    assert_equal @admin, SignInToken.last.issued_by_user
  end

  test "admin can invite as plain member too" do
    sign_in_as(@admin)
    post admin_club_members_path(@target_club), params: {
      user: { name: "Plain Member", email: "plain@northtown.example", role: "member" }
    }
    new_user = User.find_by(email: "plain@northtown.example")
    assert new_user.club_memberships.first.member?
  end

  test "blank email re-renders new with 422 and no rows created" do
    sign_in_as(@admin)
    assert_no_difference -> { User.count } do
      assert_no_difference -> { ClubMembership.count } do
        post admin_club_members_path(@target_club), params: {
          user: { name: "Bad", email: "", role: "member" }
        }
      end
    end
    assert_response :unprocessable_entity
  end

  test "admin sees the foreign club's members" do
    sign_in_as(@admin)
    get admin_club_members_path(@foreign_club)
    assert_response :success
    assert_includes response.body, "Northtown Nancy"
  end

  test "members index links to the invite form" do
    sign_in_as(@admin)
    get admin_club_members_path(@foreign_club)
    assert_response :success
    assert_select "a[href=?]", new_admin_club_member_path(@foreign_club), text: /Invite Member/
  end

  test "admin does NOT see host-club members in foreign list" do
    sign_in_as(@admin)
    get admin_club_members_path(@foreign_club)
    refute_includes response.body, @member.name
    refute_includes response.body, @organizer.name
  end

  test "admin can issue a sign-in code for a foreign club's member" do
    sign_in_as(@admin)
    assert_difference "SignInToken.count", 1 do
      post issue_code_admin_club_member_path(@foreign_club, @foreign_member)
    end
    token = SignInToken.order(:id).last
    assert_equal @foreign_member, token.user
    assert_equal @foreign_club, token.club
    assert_equal @admin, token.issued_by_user
    assert_redirected_to code_admin_club_member_path(@foreign_club, @foreign_member)
  end

  test "issue_code 404s for a member not in the foreign club" do
    sign_in_as(@admin)
    post issue_code_admin_club_member_path(@foreign_club, @member)
    assert_response :not_found
  end

  test "issue_code 404s for a deactivated member" do
    @foreign_member.update!(deactivated_at: Time.current)
    sign_in_as(@admin)
    post issue_code_admin_club_member_path(@foreign_club, @foreign_member)
    assert_response :not_found
  end

  test "code page renders the flashed code" do
    sign_in_as(@admin)
    post issue_code_admin_club_member_path(@foreign_club, @foreign_member)
    follow_redirect!
    assert_response :success
    code = SignInToken.order(:id).last.token
    assert_includes response.body, code
    assert_includes response.body, @foreign_member.name
  end

  test "code page without a flashed code redirects back to the members index" do
    sign_in_as(@admin)
    get code_admin_club_member_path(@foreign_club, @foreign_member)
    assert_redirected_to admin_club_members_path(@foreign_club)
  end

  test "code page 404s for a deactivated member" do
    @foreign_member.update!(deactivated_at: Time.current)
    sign_in_as(@admin)
    get code_admin_club_member_path(@foreign_club, @foreign_member)
    assert_response :not_found
  end

  test "admin can GET edit on a cross-club member" do
    sign_in_as(@admin)
    get edit_admin_club_member_path(@foreign_club, @foreign_member)
    assert_response :success
    assert_select "form"
    assert_select "input[name='user[name]'][value=?]", @foreign_member.name
    assert_select "input[name='user[email]'][value=?]", @foreign_member.email
    assert_includes response.body, @foreign_club.name
  end

  test "admin can PATCH update a cross-club member" do
    sign_in_as(@admin)
    patch admin_club_member_path(@foreign_club, @foreign_member), params: {
      user: { name: "Renamed Nancy", email: "Nancy@Northtown.example" }
    }
    assert_redirected_to admin_club_members_path(@foreign_club)
    @foreign_member.reload
    assert_equal "Renamed Nancy", @foreign_member.name
    assert_equal "nancy@northtown.example", @foreign_member.email
  end

  test "update on a cross-club member drops admin and role from strong params" do
    sign_in_as(@admin)
    assert_not @foreign_member.admin?
    assert_not @foreign_member.organizer_in?(@foreign_club)
    patch admin_club_member_path(@foreign_club, @foreign_member), params: {
      user: { name: "Renamed", email: "renamed@northtown.example", admin: true, role: "organizer" }
    }
    assert_redirected_to admin_club_members_path(@foreign_club)
    @foreign_member.reload
    assert_equal "Renamed", @foreign_member.name
    assert_not @foreign_member.admin?
    assert_not @foreign_member.organizer_in?(@foreign_club)
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
