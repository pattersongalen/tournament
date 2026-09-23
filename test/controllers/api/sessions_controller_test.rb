require "test_helper"

class Api::SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
  end

  test "returns the signed-in user id and a usable CSRF token" do
    sign_in_as(@user)
    get "/api/session", headers: { "Accept" => "application/json" }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal @user.id, body["user_id"]
    assert body["csrf_token"].present?
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
