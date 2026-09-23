require "test_helper"

class ClubMembershipTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @user = create(:user)
  end

  test "default role is member, role can be organizer, and show_banner defaults to false" do
    membership = ClubMembership.create!(user: @user, club: @club)
    assert membership.member?
    assert_equal false, membership.show_banner

    organizer = ClubMembership.create!(user: @user, club: create(:club), role: :organizer)
    assert organizer.organizer?
  end

  test "user cannot have two memberships in the same club but can have memberships in different clubs" do
    other_club = create(:club)
    ClubMembership.create!(user: @user, club: @club, role: :member)

    duplicate = ClubMembership.new(user: @user, club: @club, role: :organizer)
    assert_not duplicate.valid?

    second = ClubMembership.new(user: @user, club: other_club, role: :organizer)
    assert second.valid?
  end

  test "active scope excludes deactivated memberships, and deactivated? reflects deactivated_at" do
    active = create(:club_membership, user: @user, club: @club)
    deactivated = create(:club_membership, user: @user, club: create(:club), deactivated_at: Time.current)
    assert_includes ClubMembership.active, active
    assert_not_includes ClubMembership.active, deactivated

    assert_not active.deactivated?
    active.update!(deactivated_at: Time.current)
    assert active.deactivated?
  end
end
