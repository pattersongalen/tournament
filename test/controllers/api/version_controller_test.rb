require "test_helper"

class Api::VersionControllerTest < ActionDispatch::IntegrationTest
  test "GET returns the current server build" do
    sign_in_as(create(:user))

    get "/api/version", headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal AppVersion.current, response.parsed_body["build"]
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
