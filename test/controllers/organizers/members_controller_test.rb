require "test_helper"

class Organizers::MembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    sign_in_as(@organizer)
  end

  test "creating a member sends an invitation email containing a magic link" do
    assert_difference -> { User.count } => 1,
                      -> { SignInToken.count } => 1,
                      -> { ClubMembership.count } => 1 do
      assert_emails 1 do
        post organizers_members_path, params: {
          user: { name: "New Guy", email: "new@example.com", role: "member" }
        }
      end
    end
    assert_match SignInToken.last.token, ActionMailer::Base.deliveries.last.body.encoded
    new_user = User.find_by(email: "new@example.com")
    membership = new_user.club_memberships.first
    assert_equal @club, membership.club
    assert membership.member?
    assert_equal @club, SignInToken.last.club
    assert_equal @organizer, SignInToken.last.issued_by_user
  end

  test "creating an organizer-role member creates an organizer ClubMembership" do
    post organizers_members_path, params: {
      user: { name: "New Org", email: "neworg@example.com", role: "organizer" }
    }
    new_user = User.find_by(email: "neworg@example.com")
    assert new_user.club_memberships.first.organizer?
  end

  test "issue_code stamps the club on the token" do
    member = create(:user, club: @club, role: :member)
    post issue_code_organizers_member_path(member)
    assert_equal @club, SignInToken.where(user: member, kind: "code").last.club
  end

  test "issue_code records the organizer as issuer" do
    member = create(:user, club: @club, role: :member)
    post issue_code_organizers_member_path(member)
    assert_equal @organizer, SignInToken.where(user: member, kind: "code").last.issued_by_user
  end

  test "destroy deactivates the member without removing the record" do
    member = create(:user, club: @club, role: :member)
    assert_no_difference -> { User.count } do
      delete organizers_member_path(member)
    end
    assert member.reload.deactivated?
  end

  test "destroy refuses to deactivate the current organizer" do
    delete organizers_member_path(@organizer)
    assert_not @organizer.reload.deactivated?
    assert_equal "You can't deactivate yourself.", flash[:alert]
  end

  test "reactivate clears the deactivated_at timestamp" do
    member = create(:user, club: @club, role: :member, deactivated_at: 1.day.ago)
    post reactivate_organizers_member_path(member)
    assert_not member.reload.deactivated?
  end

  test "issue_code creates a code-kind token and renders it on a dedicated page" do
    member = create(:user, club: @club, role: :member)
    assert_difference -> { SignInToken.where(kind: "code").count } => 1 do
      post issue_code_organizers_member_path(member)
    end
    code = SignInToken.where(user: member, kind: "code").last
    assert_redirected_to code_organizers_member_path(member)
    follow_redirect!
    assert_response :success
    assert_match code.token, response.body
    assert_no_match(/#{code.token}/, flash[:notice].to_s)
    assert_no_match(/#{code.token}/, flash[:alert].to_s)
  end

  test "issue_code refuses deactivated members" do
    member = create(:user, club: @club, role: :member, deactivated_at: Time.current)
    assert_no_difference -> { SignInToken.count } do
      post issue_code_organizers_member_path(member)
    end
    assert_response :not_found
  end

  test "destroy is scoped to the current club" do
    other_club_member = create(:user, club: create(:club), role: :member)
    delete organizers_member_path(other_club_member)
    assert_response :not_found
    assert_not other_club_member.reload.deactivated?
  end

  test "create rolls back the User INSERT when ClubMembership.create! raises" do
    # Prove the rescue does not silently commit an orphan user. Override
    # ClubMembership.create! to fail; both User and ClubMembership counts
    # must be unchanged.
    original = ClubMembership.method(:create!)
    ClubMembership.define_singleton_method(:create!) do |*|
      raise ActiveRecord::RecordInvalid.new(ClubMembership.new)
    end
    begin
      assert_no_difference -> { User.count } do
        assert_no_difference -> { ClubMembership.count } do
          post organizers_members_path, params: {
            user: { name: "Orphan", email: "orphan@example.com", role: "member" }
          }
        end
      end
      assert_response :unprocessable_entity
      # The form would otherwise render blank if ClubMembership raised after
      # User.save! — generic base error makes sure something is shown.
      assert_includes response.body, "Couldn&#39;t send the invite"
    ensure
      ClubMembership.define_singleton_method(:create!, original)
    end
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  test "index shows each member's league-night Main count for the current season" do
    member = create(:user, club: @club, role: :member, name: "Regular Ralph")
    night = create(:tournament, club: @club, mode: :team, awards_season_points: true, season_tag: "Wed 2026",
                                starts_at: 1.week.ago, ends_at: 1.week.ago + 3.hours)
    entry = create(:tournament_entry, tournament: night)
    create(:tournament_entry_member, tournament_entry: entry, user: member)

    get organizers_members_path
    assert_response :success
    assert_select "li", text: /Regular Ralph/ do
      assert_select "[data-role='main-nights']", text: /1 league night/
    end
  end
end
