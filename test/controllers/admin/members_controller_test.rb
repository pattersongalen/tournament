require "test_helper"

class Admin::MembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club, name: "BS Phishing Family")
    @admin = create(:user, club: @club, admin: true, role: :organizer)
    @organizer = create(:user, club: @club, role: :organizer)
    @member = create(:user, club: @club, role: :member, name: "Old Name", email: "old@example.com")
  end

  test "non-admin organizer cannot GET edit" do
    sign_in_as(@organizer)
    get edit_admin_member_path(@member)
    assert_response :forbidden
  end

  test "admin can GET edit" do
    sign_in_as(@admin)
    get edit_admin_member_path(@member)
    assert_response :success
    assert_select "form"
    assert_select "input[name='user[name]'][value=?]", "Old Name"
    assert_select "input[name='user[email]'][value=?]", "old@example.com"
  end

  test "admin can PATCH update to change name and email" do
    sign_in_as(@admin)
    patch admin_member_path(@member), params: {
      user: { name: "New Name", email: "New@Example.COM" }
    }
    assert_redirected_to admin_members_path
    @member.reload
    assert_equal "New Name", @member.name
    assert_equal "new@example.com", @member.email
  end

  test "non-admin organizer cannot PATCH update" do
    sign_in_as(@organizer)
    patch admin_member_path(@member), params: {
      user: { name: "Hijack", email: "hijack@example.com" }
    }
    assert_response :forbidden
    @member.reload
    assert_equal "Old Name", @member.name
    assert_equal "old@example.com", @member.email
  end

  test "update with invalid email re-renders edit with errors" do
    sign_in_as(@admin)
    other = create(:user, club: @club, role: :member, email: "taken@example.com")
    patch admin_member_path(@member), params: {
      user: { name: "Whoever", email: other.email }
    }
    assert_response :unprocessable_entity
    @member.reload
    assert_equal "old@example.com", @member.email
  end

  test "update drops admin and role from strong params" do
    sign_in_as(@admin)
    assert_not @member.admin?
    assert_not @member.organizer_in?(@club)
    patch admin_member_path(@member), params: {
      user: { name: "Renamed", email: "renamed@example.com", admin: true, role: "organizer" }
    }
    assert_redirected_to admin_members_path
    @member.reload
    assert_equal "Renamed", @member.name
    assert_not @member.admin?
    assert_not @member.organizer_in?(@club)
  end

  test "update is scoped to current club" do
    sign_in_as(@admin)
    other_club_user = create(:user, club: create(:club), role: :member)
    patch admin_member_path(other_club_user), params: {
      user: { name: "Cross", email: "cross@example.com" }
    }
    assert_response :not_found
  end

  test "non-admin organizer cannot destroy" do
    sign_in_as(@organizer)
    delete admin_member_path(@member)
    assert_response :forbidden
    assert_not @member.reload.deactivated?
  end

  test "admin can destroy" do
    sign_in_as(@admin)
    delete admin_member_path(@member)
    assert @member.reload.deactivated?
  end

  test "non-admin organizer cannot reactivate" do
    @member.update!(deactivated_at: 1.day.ago)
    sign_in_as(@organizer)
    post reactivate_admin_member_path(@member)
    assert_response :forbidden
    assert @member.reload.deactivated?
  end

  test "admin can reactivate" do
    @member.update!(deactivated_at: 1.day.ago)
    sign_in_as(@admin)
    post reactivate_admin_member_path(@member)
    assert_not @member.reload.deactivated?
  end

  test "admin can purge a deactivated catch-less member" do
    @member.update!(deactivated_at: 1.day.ago)
    sign_in_as(@admin)
    delete purge_admin_member_path(@member)
    assert_redirected_to admin_members_path
    assert_not User.exists?(@member.id)
  end

  test "non-admin organizer cannot purge" do
    @member.update!(deactivated_at: 1.day.ago)
    sign_in_as(@organizer)
    delete purge_admin_member_path(@member)
    assert_response :forbidden
    assert User.exists?(@member.id)
  end

  test "cannot purge a member who still has catches" do
    @member.update!(deactivated_at: 1.day.ago)
    create(:catch, user: @member)
    sign_in_as(@admin)
    delete purge_admin_member_path(@member)
    assert_redirected_to admin_members_path
    assert User.exists?(@member.id)
  end

  test "cannot purge a member who is not deactivated" do
    sign_in_as(@admin)
    delete purge_admin_member_path(@member)
    assert_redirected_to admin_members_path
    assert User.exists?(@member.id)
  end

  test "admin cannot purge themselves" do
    sign_in_as(@admin)
    delete purge_admin_member_path(@admin)
    assert_redirected_to admin_members_path
    assert User.exists?(@admin.id)
  end

  test "purge is scoped to current club" do
    other_club_user = create(:user, club: create(:club), role: :member)
    other_club_user.update!(deactivated_at: 1.day.ago)
    sign_in_as(@admin)
    delete purge_admin_member_path(other_club_user)
    assert_response :not_found
    assert User.exists?(other_club_user.id)
  end

  test "index shows Delete button for a deactivated catch-less member" do
    @member.update!(deactivated_at: 1.day.ago)
    sign_in_as(@admin)
    get admin_members_path
    assert_response :success
    assert_select "form[action=?]", purge_admin_member_path(@member)
  end

  test "index hides Delete button for a deactivated member with catches" do
    @member.update!(deactivated_at: 1.day.ago)
    create(:catch, user: @member)
    sign_in_as(@admin)
    get admin_members_path
    assert_response :success
    assert_select "form[action=?]", purge_admin_member_path(@member), count: 0
  end

  test "index hides Delete button for a deactivated member who logged catches for a teammate" do
    @member.update!(deactivated_at: 1.day.ago)
    # Catch belongs to @organizer but was logged *by* @member — not in
    # @member.catches, but still an FK that blocks purge.
    create(:catch, user: @organizer, logged_by_user_id: @member.id)
    sign_in_as(@admin)
    get admin_members_path
    assert_response :success
    assert_select "form[action=?]", purge_admin_member_path(@member), count: 0
  end

  test "index hides Delete button from non-admin organizer" do
    @member.update!(deactivated_at: 1.day.ago)
    sign_in_as(@organizer)
    get admin_members_path
    assert_response :success
    assert_select "form[action=?]", purge_admin_member_path(@member), count: 0
  end

  test "authenticated request stamps last_seen_at on current_user" do
    @admin.update_columns(last_seen_at: nil)
    sign_in_as(@admin)
    get admin_members_path
    assert_response :success
    assert_not_nil @admin.reload.last_seen_at
  end

  test "renders Never badge for users with no last_seen_at" do
    create(:user, club: @club, name: "Unclaimed Carl", last_seen_at: nil)
    sign_in_as(@admin)
    get admin_members_path
    assert_response :success
    assert_includes response.body, "Unclaimed Carl"
    assert_match %r{Unclaimed Carl.*Never}m, response.body
  end

  test "renders relative time for users with a last_seen_at" do
    freeze_time do
      create(:user, club: @club, name: "Active Alice", last_seen_at: 3.days.ago)
      sign_in_as(@admin)
      get admin_members_path
      assert_response :success
      assert_match %r{Active Alice.*3 days ago}m, response.body
    end
  end

  test "member edit page renders the diagnostics card" do
    @member.user_events.create!(kind: :device_changed, user_agent:
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1")

    sign_in_as(@admin)
    get edit_admin_member_path(@member)

    assert_response :success
    assert_select "h2", text: /Diagnostics/
    assert_match "Safari", response.body
  end

  test "a plain member cannot change a role" do
    other = create(:user, club: @club, role: :member)
    sign_in_as(other)
    patch role_admin_member_path(@member), params: { club_membership: { role: "organizer" } }
    assert_response :forbidden
  end

  test "an organizer promotes a member to organizer" do
    sign_in_as(@organizer)
    patch role_admin_member_path(@member), params: { club_membership: { role: "organizer" } }
    assert_redirected_to admin_members_path
    assert @member.reload.permanent_organizer_in?(@club)
  end

  test "an organizer demotes another organizer to member" do
    victim = create(:user, club: @club, role: :organizer)
    sign_in_as(@organizer)
    patch role_admin_member_path(victim), params: { club_membership: { role: "member" } }
    assert_redirected_to admin_members_path
    assert_not victim.reload.permanent_organizer_in?(@club)
  end

  test "an organizer cannot demote themselves" do
    sign_in_as(@organizer)
    patch role_admin_member_path(@organizer), params: { club_membership: { role: "member" } }
    assert_redirected_to admin_members_path
    assert_equal "You can't demote yourself.", flash[:alert]
    assert @organizer.reload.permanent_organizer_in?(@club)
  end

  test "an unknown role is rejected" do
    sign_in_as(@organizer)
    patch role_admin_member_path(@member), params: { club_membership: { role: "wizard" } }
    assert_redirected_to admin_members_path
    assert_equal "Unknown role.", flash[:alert]
    assert_not @member.reload.permanent_organizer_in?(@club)
  end

  test "a member of another club cannot be re-roled from this club" do
    outsider = create(:user, club: create(:club), role: :member)
    sign_in_as(@organizer)
    patch role_admin_member_path(outsider), params: { club_membership: { role: "organizer" } }
    assert_redirected_to admin_members_path
    assert_equal "That member isn't in this club.", flash[:alert]
  end

  test "index shows a role toggle to an organizer" do
    sign_in_as(@organizer)
    get admin_members_path
    assert_response :success
    assert_select "form[action=?]", role_admin_member_path(@member)
  end

  test "index hides the role toggle on the current user's own row" do
    sign_in_as(@organizer)
    get admin_members_path
    assert_select "form[action=?]", role_admin_member_path(@organizer), count: 0
  end

  test "a live deputy cannot change roles" do
    upcoming = create(:tournament, club: @club, starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
    deputy   = create(:user, club: @club, role: :member)
    create(:tournament_deputy, tournament: upcoming, user: deputy, granted_by_user: @organizer)

    sign_in_as(deputy)
    # Sanity: the deputy really does reach the admin area.
    get admin_members_path
    assert_response :success

    patch role_admin_member_path(@member), params: { club_membership: { role: "organizer" } }
    assert_response :forbidden
    assert_not @member.reload.permanent_organizer_in?(@club)
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
