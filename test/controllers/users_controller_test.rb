require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    sign_in_as(@user)
  end

  test "PATCH /me updates length_unit, or rejects an invalid one" do
    {
      "valid value" => [ "centimeters", "centimeters" ],
      "invalid value" => [ "feet", "inches" ]
    }.each do |label, (value, expected)|
      @user.update!(length_unit: "inches")
      patch me_path, params: { user: { length_unit: value } }
      assert_equal expected, @user.reload.length_unit, label
    end
  end

  test "PATCH /me as JSON updates length_unit and returns 204, or rejects an invalid one with 422" do
    {
      "valid value" => [ "centimeters", "centimeters", :no_content ],
      "invalid value" => [ "feet", "inches", :unprocessable_entity ]
    }.each do |label, (value, expected, expected_status)|
      @user.update!(length_unit: "inches")
      patch me_path, params: { user: { length_unit: value } }, as: :json
      assert_response expected_status, label
      assert_equal expected, @user.reload.length_unit, label
      assert_includes JSON.parse(response.body)["errors"].join(" "), "Length unit", label if expected_status == :unprocessable_entity
    end
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
