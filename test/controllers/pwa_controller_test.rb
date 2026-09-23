require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  # catch_form_controller stamps queued_by_user_id from this meta. The offline
  # shell is the flagship offline capture path — without the meta, catches
  # queued there carry a null stamp and bypass the shared-phone wrong-account
  # guards in sync.js and Api::CatchesController (user A's fish drains under
  # user B).
  test "the offline shell carries the signed-in user's id for the queue stamp" do
    user = create(:user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)

    get "/offline"
    assert_response :success
    assert_select "meta[name='current-user-id'][content='#{user.id}']"
  end

  test "the offline shell omits the user meta when signed out" do
    get "/offline"
    assert_response :success
    assert_select "meta[name='current-user-id']", count: 0
  end

  # Downgraded from test/system/pwa_install_test.rb "manifest is linked from the layout".
  test "the layout links the web app manifest" do
    get "/"
    follow_redirect! # unauthenticated -> sign-in page, same layout carries the manifest link

    assert_response :success
    assert_select "link[rel='manifest'][href='/manifest.webmanifest']"
  end

  # iOS rotates PWA push subscriptions (SW updates, OS events). Without a
  # pushsubscriptionchange handler the server hits ExpiredSubscription,
  # deletes the row, and the angler silently stops getting alerts while the
  # home-page toggle still reads "on".
  test "service worker ships the pushsubscriptionchange self-heal" do
    get "/service-worker.js"
    assert_response :success
    assert_includes response.body, "pushsubscriptionchange"
    assert_includes response.body, "/api/push_subscriptions/refresh"
    assert_includes response.body, VAPID[:public_key]
    # The old row may already be destroyed server-side; the CSRF token from
    # /api/session is the fallback proof that lets refresh store the new
    # subscription instead of 404ing it away.
    assert_includes response.body, "/api/session"
    assert_includes response.body, "X-CSRF-Token"
  end
end
