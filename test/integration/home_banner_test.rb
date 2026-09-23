require "test_helper"

class HomeBannerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club, name: "Banner Club")
    @member = create(:user, club: @club, role: :member, name: "Banner Bob")
    @membership = @member.club_memberships.find_by!(club: @club)
  end

  test "the home-page banner shows only for a targeted member with a non-blank message" do
    {
      "targeted member sees the banner with the chosen color" => -> (label) {
        @club.update!(banner_message: "Weigh-in moved to 6pm", banner_style: :alert)
        @membership.update!(show_banner: true)

        sign_in_as(@member)
        get root_path

        assert_response :success, label
        assert_select "#club-banner", { text: /Weigh-in moved to 6pm/ }, label
        assert_select "#club-banner.border-red-500\\/40", true, label
      },
      "untargeted member does not see the banner" => -> (label) {
        @club.update!(banner_message: "Weigh-in moved to 6pm", banner_style: :alert)
        @membership.update!(show_banner: false)

        sign_in_as(@member)
        get root_path

        assert_response :success, label
        assert_not_includes response.body, "Weigh-in moved to 6pm", label
      },
      "blank message hides the banner even for a targeted member" => -> (label) {
        @club.update!(banner_message: nil, banner_style: :info)
        @membership.update!(show_banner: true)

        sign_in_as(@member)
        get root_path

        assert_response :success, label
        # Scoped to the club banner: the (hidden) sync-auth notice in the layout
        # legitimately uses the same yellow warning classes on every page.
        assert_select "#club-banner", { count: 0 }, label
      }
    }.each { |label, block| block.call(label) }
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
