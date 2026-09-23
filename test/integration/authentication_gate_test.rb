require "test_helper"

# Consolidates the "requires sign-in" gate check that used to be repeated, one
# assertion per controller, across season_points, rules, recover, home,
# tournaments/catches, api/version, api/sessions, and push refresh. Every
# controller in this table shares the same gate: ApplicationController's
# require_sign_in! (HTML: redirect to sign-in) or Api::BaseController's
# override (JSON: 401), so one signed-out row per path is sufficient — the
# per-controller tests keep proving what a signed-in request does.
class AuthenticationGateTest < ActionDispatch::IntegrationTest
  test "a signed-out request is redirected to sign-in for HTML paths, or 401 for /api paths" do
    [
      [ :get,  "/",                                 :html ],
      [ :get,  "/rules",                             :html ],
      [ :get,  "/season-points",                     :html ],
      [ :get,  "/recover",                           :html ],
      [ :get,  "/tournaments/1/catches/1",           :html ],
      [ :get,  "/api/version",                       :api ],
      [ :get,  "/api/session",                       :api ],
      [ :post, "/api/push_subscriptions/refresh",    :api ]
    ].each do |verb, path, kind|
      label = "#{verb.upcase} #{path}"
      headers = kind == :api ? { "Accept" => "application/json" } : {}
      send(verb, path, headers: headers)

      case kind
      when :html
        assert_redirected_to new_session_path, label
      when :api
        assert_response :unauthorized, label
      end
    end
  end
end
