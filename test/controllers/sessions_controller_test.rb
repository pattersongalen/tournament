require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  # Clubless user so each test stages memberships explicitly.
  setup { @user = create(:user, email: "joe@example.com", club: nil) }

  test "POST /session emails a token for a known address and stays silent for an unknown one" do
    {
      "known email" => -> (label) {
        assert_difference "SignInToken.count", 2, label do
          assert_emails 1 do
            post session_path, params: { email: "joe@example.com" }
          end
        end
      },
      # No enumeration: an unknown address must not create a token or send mail.
      "unknown email" => -> (label) {
        assert_no_difference "SignInToken.count", label do
          assert_no_emails do
            post session_path, params: { email: "nobody@example.com" }
          end
        end
      }
    }.each do |label, block|
      block.call(label)
      assert_redirected_to "/session/check_email", label
    end
  end

  # The email form is public — a magic-link request (from the member, or from
  # anyone at all who knows the address) must not kill a code an organizer
  # just read out to the member.
  test "a magic-link request does not invalidate an organizer-issued code" do
    organizer_code = SignInToken.issue_code!(user: @user)
    post session_path, params: { email: "joe@example.com" }
    post code_session_path, params: { email: "joe@example.com", code: organizer_code.token }
    assert_redirected_to root_path
    assert_equal @user.id, session[:user_id]
  end

  test "GET consume signs the user in for a valid token" do
    token = SignInToken.issue!(user: @user)
    get consume_session_path(token: token.token)
    assert_redirected_to root_path
    assert_equal @user.id, session[:user_id]
  end

  test "GET consume rejects an expired token or a deactivated user" do
    {
      "expired token" => -> {
        token = SignInToken.issue!(user: @user)
        token.update!(expires_at: 1.minute.ago)
        token
      },
      "deactivated user" => -> {
        token = SignInToken.issue!(user: @user)
        @user.update!(deactivated_at: Time.current)
        token
      }
    }.each do |label, setup|
      token = setup.call
      get consume_session_path(token: token.token)
      assert_redirected_to new_session_path, label
      assert_nil session[:user_id], label
    end
  end

  test "POST /session/code signs in with a matching email and code" do
    code = SignInToken.issue_code!(user: @user)
    post code_session_path, params: { email: @user.email, code: code.token }
    assert_redirected_to root_path
    assert_equal @user.id, session[:user_id]
  end

  test "POST /session/code rejects a bad code or a deactivated user" do
    {
      "bad code" => -> {
        SignInToken.issue_code!(user: @user)
        "00000000"
      },
      "deactivated user" => -> {
        code = SignInToken.issue_code!(user: @user)
        @user.update!(deactivated_at: Time.current)
        code.token
      }
    }.each do |label, setup|
      token = setup.call
      post code_session_path, params: { email: @user.email, code: token }
      assert_response :unprocessable_entity, label
      assert_nil session[:user_id], label
    end
  end

  test "consume rotates the session id to defeat fixation" do
    get new_session_path
    fixed_id = session.id&.to_s
    token = SignInToken.issue!(user: @user)
    get consume_session_path(token: token.token)
    assert_equal @user.id, session[:user_id]
    rotated_id = session.id&.to_s
    assert rotated_id.present?
    assert_not_equal fixed_id, rotated_id
  end

  test "consume and submit_code resolve session[:current_club_id] to a club the user belongs to" do
    {
      "consume: token names the member's club" => -> {
        club = create(:club)
        user = create(:user, club: nil)
        create(:club_membership, user: user, club: club, role: :member)
        token = SignInToken.issue!(user: user, club: club)
        get consume_session_path(token: token.token)
        club
      },
      "consume: token has no club, falls back to first active membership" => -> {
        club = create(:club)
        user = create(:user, club: nil)
        create(:club_membership, user: user, club: club, role: :member)
        token = SignInToken.issue!(user: user)
        token.update!(club_id: nil)
        get consume_session_path(token: token.token)
        club
      },
      "code: submit_code sets current_club_id from the code's club" => -> {
        club = create(:club)
        user = create(:user, club: nil)
        create(:club_membership, user: user, club: club, role: :member)
        code = SignInToken.issue_code!(user: user, club: club)
        post code_session_path, params: { email: user.email, code: code.token }
        club
      }
    }.each do |label, block|
      reset!
      expected_club = block.call
      assert_equal expected_club.id, session[:current_club_id], label
    end
  end

  test "consume falls back safely when the token's club can't be honored" do
    reset!
    user = create(:user, club: nil)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
    assert_equal user.id, session[:user_id], "no memberships: still signs in"
    assert_nil session[:current_club_id], "no memberships: current_club_id stays nil"

    reset!
    other_club = create(:club)
    own_club = create(:club)
    user2 = create(:user, club: nil)
    create(:club_membership, user: user2, club: own_club, role: :member)
    foreign_token = SignInToken.issue!(user: user2, club: other_club)
    get consume_session_path(token: foreign_token.token)
    assert_equal own_club.id, session[:current_club_id], "token names a club the user isn't a member of: falls back to their own club"
  end

  # --- UserEvent capture ---

  test "successful sign-in records a sign_in_succeeded event, by magic link or by code" do
    {
      "magic link" => -> {
        token = SignInToken.issue!(user: @user)
        assert_difference -> { @user.user_events.sign_in_succeeded.count }, 1, "magic link" do
          get consume_session_path(token: token.token)
        end
      },
      "code" => -> {
        code = SignInToken.issue_code!(user: @user)
        assert_difference -> { @user.user_events.sign_in_succeeded.count }, 1, "code" do
          post code_session_path, params: { email: @user.email, code: code.token }
        end
      }
    }.each { |_label, block| block.call }
  end

  test "failed code sign-in records a sign_in_failed event for a known email and nothing for an unknown one" do
    assert_difference -> { @user.user_events.sign_in_failed.count }, 1, "known email" do
      post code_session_path, params: { email: @user.email, code: "00000000" }
    end

    assert_no_difference -> { UserEvent.count }, "unknown email" do
      post code_session_path, params: { email: "nobody@example.com", code: "00000000" }
    end
  end
end
