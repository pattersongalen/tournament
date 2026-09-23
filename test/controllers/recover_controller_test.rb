require "test_helper"

class RecoverControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @user = create(:user, club: @club, name: "Joe")
  end

  test "404s when the recovery tool is disabled, renders it when enabled" do
    sign_in_as(@user)

    get "/recover"
    assert_response :not_found, "disabled"

    @club.update!(recovery_tool_enabled: true)
    get "/recover"
    assert_response :success, "enabled"
    assert_select "div[data-controller=?]", "recover"
    assert_select "ul[data-recover-target=?]", "list"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
