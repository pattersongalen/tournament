require "application_system_test_case"

# In standalone iOS the only back-navigation is the edge swipe, which Turbo
# services as a *restoration* visit: the cached snapshot renders with no server
# round trip, and any Turbo Stream broadcasts missed while on the other page
# are never replayed. stream_refresh_controller must detect the restore in
# connect() and re-render from the server.
class StreamRefreshTest < ApplicationSystemTestCase
  # Every test starts from the same place: a signed-in entrant looking at a
  # live leaderboard that reads "Zebra Boat".
  setup do
    club = create(:club)
    walleye = create(:species, club: club)
    @angler = create(:user, club: club, name: "Angler A")

    @tournament = create(:tournament, club: club, name: "League Night",
                         starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: @tournament, species: walleye, slot_count: 1)
    @entry = create(:tournament_entry, tournament: @tournament, name: "Zebra Boat")
    create(:tournament_entry_member, tournament_entry: @entry, user: @angler)

    sign_in_as(@angler)
    visit tournament_path(@tournament)
    assert_text "Zebra Boat"
  end

  # The reachability probe must not fetch the leaderboard page itself. Rack::Head
  # sits at the END of the stack, so a HEAD there runs the whole controller and
  # view — a full Leaderboards::Build and ERB render — before the body is thrown
  # away, and the Turbo.visit that follows then renders it a SECOND time. Every
  # foreground, bfcache restore and edge-swipe paid double on the one VM.
  test "a Turbo restore visit re-renders from the server, and only once" do
    # Leave via a Turbo-driven link so the page enters Turbo's snapshot cache
    # (Capybara's visit is a full navigation and would not), then mutate state
    # server-side — standing in for a broadcast missed while away.
    find("a[aria-label='Home']").click
    assert_text "Hello, #{@angler.name}", wait: 5

    # Record every request the restore makes. Installed on the home page; the
    # JS context survives the Turbo restore, so it sees the probe too.
    page.execute_script(<<~JS)
      window.__probes = [];
      const realFetch = window.fetch;
      window.fetch = (url, opts) => {
        window.__probes.push(((opts && opts.method) || "GET") + " " + String(url));
        return realFetch(url, opts);
      };
    JS
    @entry.update!(name: "Renamed Boat")

    page.go_back

    # The restored snapshot alone would still read "Zebra Boat"; only a
    # server re-render shows the new name.
    assert page.has_text?("Renamed Boat", wait: 5),
           "restore visit: the leaderboard must re-render from the server"

    probes = page.evaluate_script("window.__probes")
    assert probes.any? { |p| p.include?("/api/session") },
           "expected the cheap session probe, saw: #{probes.inspect}"
    assert probes.none? { |p| p.start_with?("HEAD") },
           "the probe HEADs a page, which costs a full render: #{probes.inspect}"
  end

  # Two ways a restore's probe can come back not-ok, and neither may cost the
  # angler the leaderboard they can still read:
  #
  #   - Offline on the water, the service worker answers fetches with a bare 503
  #     ("offline"); an unguarded replace-visit would render that over a
  #     stale-but-readable leaderboard — strictly worse than doing nothing.
  #   - A session that expired while the PWA was backgrounded would otherwise
  #     follow require_sign_in!'s 302 to the sign-in page's 200, and the
  #     replace-visit would swap the leaderboard (and its history entry) for the
  #     sign-in screen. redirect: "manual" makes the 302 come back not-ok.
  test "a restore visit whose probe fails keeps the readable leaderboard" do
    find("a[aria-label='Home']").click
    assert_text "Hello, #{@angler.name}", wait: 5

    # Simulate network loss the way the SW presents it: every fetch resolves
    # to a 503 "offline" response. Both the reachability probe and Turbo's
    # visit fetch see this.
    page.execute_script(<<~JS)
      window.fetch = () => Promise.resolve(
        new Response("offline", { status: 503, headers: { "Content-Type": "text/html" } })
      )
    JS

    page.go_back

    # The restored snapshot must survive. Before the guard, Turbo rendered the
    # 503 body and the leaderboard was wiped.
    sleep 1
    assert page.has_text?("Zebra Boat", wait: 5),
           "offline restore: the stale-but-readable leaderboard must survive"

    # Now the expired-session case. A full browser navigation (not a Turbo
    # visit) starts it from a clean JS context, so the offline stub above —
    # and any replace-visit it may still have in flight — is gone.
    visit tournament_path(@tournament)
    assert_text "Zebra Boat"
    find("a[aria-label='Home']").click
    assert_text "Hello, #{@angler.name}", wait: 5

    # The backgrounded session dying is, to the browser, the cookie vanishing.
    page.driver.browser.cookies.clear

    page.go_back

    sleep 1
    assert page.has_text?("Zebra Boat", wait: 5),
           "expired session: the leaderboard must not be swapped for the sign-in screen"
  end

  # One iOS foreground fires BOTH of this controller's triggers: visibilitychange
  # (visible, with a stale hiddenAt) and then pageshow with persisted=true from
  # the bfcache restore. Neither knew about the other, so a single foreground ran
  # two probes and two replace-visits — the server building and rendering the
  # leaderboard twice, which is exactly the doubled cost the cheap /api/session
  # probe was adopted to remove.
  test "one foreground firing both triggers refreshes only once" do
    @entry.update!(name: "Renamed Boat")
    page.execute_script(<<~JS)
      window.__probes = [];
      const realFetch = window.fetch;
      window.fetch = (url, opts) => {
        window.__probes.push(String(url));
        return realFetch(url, opts);
      };

      // Background the page, then foreground it 20s later (past STALE_AFTER_MS)
      // and fire both signals an iOS bfcache restore emits, back to back.
      let visibility = "hidden";
      Object.defineProperty(document, "visibilityState", {
        configurable: true, get: () => visibility
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const realNow = Date.now;
      Date.now = () => realNow.call(Date) + 20000;

      visibility = "visible";
      document.dispatchEvent(new Event("visibilitychange"));
      window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }));
    JS

    # The refresh must still happen — this guard coalesces, it does not suppress.
    assert_text "Renamed Boat", wait: 5
    sleep 1

    probes = page.evaluate_script("window.__probes").select { |p| p.include?("/api/session") }
    assert_equal 1, probes.size,
                 "one foreground must cost one probe and one re-render, saw: #{probes.inspect}"
  end
end
