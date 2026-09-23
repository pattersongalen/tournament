require "test_helper"

class ServiceWorkerTest < ActionDispatch::IntegrationTest
  IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) " \
              "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

  test "GET /service-worker.js serves the script with a versioned cache key and no-cache headers" do
    get "/service-worker.js", headers: { "HTTP_USER_AGENT" => IPHONE_UA }
    assert_response :success
    assert_match %r{\Atext/javascript}, response.media_type
    # Cache key must be derived from AppVersion (git SHA or fallback) so each
    # deploy invalidates the install-time and runtime caches.
    assert_match(/const CACHE = "shell-#{Regexp.escape(AppVersion.current)}"/, response.body)
    # So browsers re-check the script itself on every visit.
    assert_includes response.headers["Cache-Control"].to_s, "no-cache"
  end

  # The offline shell is inert without its CSS/JS. activate purges the prior
  # deploy's runtime cache, so a cold launch with no signal right after a deploy
  # would otherwise render the form with no controllers wired up. Precaching the
  # shell's assets alongside its HTML makes them install atomically. Cross-origin
  # modules (the leaflet CDN pin) can't be precached: cache.addAll rejects
  # atomically if any entry fails, which would brick the whole install.
  test "service worker precaches the offline shell and its assets, excluding cross-origin modules" do
    get "/service-worker.js", headers: { "HTTP_USER_AGENT" => IPHONE_UA }
    assert_response :success
    assert_match %r{const SHELL = \[[^\]]*"/offline"}, response.body
    assert_match %r{const SHELL = \[[^\]]*"/assets/tailwind-\w+\.css"}, response.body
    assert_match %r{"/assets/application-\w+\.js"}, response.body
    assert_match %r{"/assets/controllers/catch_form_controller-\w+\.js"}, response.body
    assert_no_match %r{ga\.jspm\.io}, response.body
  end

  test "service worker falls back to the offline shell on failed navigation" do
    get "/service-worker.js", headers: { "HTTP_USER_AGENT" => IPHONE_UA }
    assert_match(/request\.mode === "navigate"/, response.body)
    assert_match(%r{caches\.match\("/offline"\)}, response.body)
  end
end
