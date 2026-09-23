require "test_helper"

class NotificationSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    @sub = create(:push_subscription, user: @user)
    sign_in_as(@user)
  end

  test "snooze sets muted_until, unmute clears it" do
    post snooze_notification_settings_path, params: { hours: 4 }
    assert_in_delta 4.hours.from_now, @sub.reload.muted_until, 60, "snooze"

    post unmute_notification_settings_path
    assert_nil @sub.reload.muted_until, "unmute"
  end

  test "mute_tournament adds the tournament id, unmute_tournament removes it" do
    t = create(:tournament)

    post mute_tournament_notification_settings_path, params: { tournament_id: t.id }
    assert_includes @sub.reload.muted_tournament_ids, t.id, "mute_tournament"

    post unmute_tournament_notification_settings_path, params: { tournament_id: t.id }
    assert_not_includes @sub.reload.muted_tournament_ids, t.id, "unmute_tournament"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
