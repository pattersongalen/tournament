require "test_helper"

class Api::PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    sign_in_as(@user)
  end

  test "POST creates a new subscription or upserts an existing one by endpoint" do
    {
      "new endpoint creates a subscription" => -> {
        assert_difference "PushSubscription.count", 1, "new endpoint creates a subscription" do
          post "/api/push_subscriptions", params: {
            subscription: { endpoint: "https://e/1", keys: { p256dh: "p", auth: "a" } }
          }, headers: { "Accept" => "application/json" }
        end
        assert_response :created
      },
      "existing endpoint upserts idempotently" => -> {
        create(:push_subscription, user: @user, endpoint: "https://e/2")
        assert_no_difference "PushSubscription.count", "existing endpoint upserts idempotently" do
          post "/api/push_subscriptions", params: {
            subscription: { endpoint: "https://e/2", keys: { p256dh: "p2", auth: "a2" } }
          }, headers: { "Accept" => "application/json" }
        end
        assert_equal "p2", PushSubscription.find_by(endpoint: "https://e/2").p256dh,
                     "existing endpoint upserts idempotently"
      }
    }.each { |_label, block| block.call }
  end

  test "DELETE removes a subscription and records push_unsubscribed" do
    user = create(:user)
    sign_in_as(user)
    sub = user.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/abc", p256dh: "k", auth: "a")

    assert_difference -> { user.user_events.push_unsubscribed.count }, 1 do
      delete "/api/push_subscriptions", params: { endpoint: sub.endpoint }, headers: { "Accept" => "application/json" }
    end
    assert_response :no_content
    assert_nil PushSubscription.find_by(endpoint: sub.endpoint)
  end

  test "POST records push_subscribed once per new endpoint, not on an idempotent re-save" do
    user = create(:user)
    sign_in_as(user)

    assert_difference -> { user.user_events.push_subscribed.count }, 1, "first save records the event" do
      post "/api/push_subscriptions", params: {
        subscription: { endpoint: "https://fcm.googleapis.com/abc", keys: { p256dh: "k", auth: "a" } }
      }, headers: { "Accept" => "application/json" }
    end
    assert_equal "fcm.googleapis.com", user.user_events.push_subscribed.last.metadata["endpoint_host"]

    assert_no_difference -> { user.user_events.push_subscribed.count }, "idempotent re-save doesn't re-record" do
      post "/api/push_subscriptions", params: {
        subscription: { endpoint: "https://fcm.googleapis.com/abc", keys: { p256dh: "k2", auth: "a2" } }
      }, headers: { "Accept" => "application/json" }
    end
  end

  test "re-registering an endpoint that belonged to another user reassigns it" do
    other = create(:user)
    stale = PushSubscription.create!(user: other, endpoint: "https://push.example/shared-ep",
                                     p256dh: "oldkey", auth: "oldauth")
    post "/api/push_subscriptions", params: {
      subscription: { endpoint: "https://push.example/shared-ep",
                      keys: { p256dh: "newkey", auth: "newauth" } }
    }, as: :json
    assert_response :created
    stale.reload
    assert_equal @user.id, stale.user_id
    assert_equal "newkey", stale.p256dh
  end

  test "a passive resync still registers and converges the user's own rows" do
    create(:push_subscription, user: @user, endpoint: "https://e/mine", p256dh: "stale", auth: "a")
    post "/api/push_subscriptions", params: {
      resync: true,
      subscription: { endpoint: "https://e/mine", keys: { p256dh: "fresh", auth: "a" } }
    }, as: :json
    assert_response :created
    assert_equal "fresh", PushSubscription.find_by(endpoint: "https://e/mine").p256dh

    assert_difference "PushSubscription.count", 1 do
      post "/api/push_subscriptions", params: {
        resync: true,
        subscription: { endpoint: "https://e/unregistered", keys: { p256dh: "p", auth: "a" } }
      }, as: :json
    end
    assert_equal @user.id, PushSubscription.find_by(endpoint: "https://e/unregistered").user_id
  end

  # POST /api/push_subscriptions/refresh — the service worker's
  # pushsubscriptionchange self-heal. APNs/FCM rotate endpoints behind our
  # back; the SW re-subscribes and swaps the stored row so alerts keep
  # arriving instead of dying silently on ExpiredSubscription.

  test "refresh rotates an existing subscription to the new endpoint and keys" do
    create(:push_subscription, user: @user, endpoint: "https://e/old", p256dh: "p", auth: "a")
    assert_no_difference "PushSubscription.count" do
      post "/api/push_subscriptions/refresh", params: {
        old_endpoint: "https://e/old",
        subscription: { endpoint: "https://e/new", keys: { p256dh: "p2", auth: "a2" } }
      }, as: :json
    end
    assert_response :no_content
    assert_nil PushSubscription.find_by(endpoint: "https://e/old")
    sub = PushSubscription.find_by(endpoint: "https://e/new")
    assert_equal @user.id, sub.user_id
    assert_equal "p2", sub.p256dh
  end

  # Possession of a previously-registered endpoint is one ownership proof
  # (endpoints are unguessable capability URLs). Without a matching row AND
  # without a CSRF token the request proves nothing and must not create
  # anything.
  test "refresh with an unknown old endpoint and no CSRF token is a 404 no-op" do
    with_forgery_protection do
      assert_no_difference "PushSubscription.count" do
        post "/api/push_subscriptions/refresh", params: {
          old_endpoint: "https://e/never-registered",
          subscription: { endpoint: "https://e/new", keys: { p256dh: "p", auth: "a" } }
        }, as: :json
      end
      assert_response :not_found
    end
  end

  # The rotation case the self-heal exists for: delivery already destroyed the
  # row on ExpiredSubscription (or the browser fired pushsubscriptionchange
  # with no oldSubscription, so old_endpoint arrives nil), so possession can't
  # be proven by a matching row. The SW fetches a CSRF token from
  # /api/session — the same same-origin proof create relies on — and the new
  # subscription must be stored, not 404'd away, either way.
  test "refresh with no matching old-endpoint row but a valid CSRF token stores the new subscription" do
    {
      "already-destroyed old endpoint" => { old_endpoint: "https://e/already-destroyed", new_endpoint: "https://e/rotated" },
      "null old endpoint" => { old_endpoint: nil, new_endpoint: "https://e/rotated2" }
    }.each do |label, row|
      with_forgery_protection do
        assert_difference "PushSubscription.count", 1, label do
          post "/api/push_subscriptions/refresh", params: {
            old_endpoint: row[:old_endpoint],
            subscription: { endpoint: row[:new_endpoint], keys: { p256dh: "p2", auth: "a2" } }
          }, headers: { "X-CSRF-Token" => api_session_csrf_token }, as: :json
        end
        assert_response :no_content, label
        sub = PushSubscription.find_by(endpoint: row[:new_endpoint])
        assert_equal @user.id, sub.user_id, label
        assert_equal "p2", sub.p256dh, label
      end
    end
  end

  # A service worker has no page, no csrf meta tag, no token. refresh must be
  # exempt from CSRF verification (while create stays protected — its
  # null_session turns a tokenless POST into a 401).
  test "refresh works without a CSRF token while create stays protected" do
    with_forgery_protection do
      create(:push_subscription, user: @user, endpoint: "https://e/old")

      post "/api/push_subscriptions/refresh", params: {
        old_endpoint: "https://e/old",
        subscription: { endpoint: "https://e/new", keys: { p256dh: "p", auth: "a" } }
      }, as: :json
      assert_response :no_content

      post "/api/push_subscriptions", params: {
        subscription: { endpoint: "https://e/other", keys: { p256dh: "p", auth: "a" } }
      }, as: :json
      assert_response :unauthorized
    end
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  def with_forgery_protection
    old_setting = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = old_setting
  end

  # The token the same way the service worker gets it: from the drain-preflight
  # session endpoint.
  def api_session_csrf_token
    get "/api/session", headers: { "Accept" => "application/json" }
    JSON.parse(response.body).fetch("csrf_token")
  end
end
