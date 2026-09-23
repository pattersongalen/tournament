require "application_system_test_case"

class PreTripTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
  end

  test "pre-trip page shows all checks and their initial passing state" do
    token = SignInToken.issue!(user: @user)
    visit consume_session_path(token: token.token)
    visit pre_trip_path

    assert_text "Pre-trip check"
    assert_selector "[data-check='session']"
    assert_selector "[data-check='camera']"
    assert_selector "[data-check='gps']"
    assert_selector "[data-check='clock']"
    assert_selector "[data-check='notifications']"
    assert_selector "[data-check='network']"

    # On a fresh load there is no stale cached shell, so the version row
    # settles on the up-to-date state and surfaces the current server build
    # id. This row's fetch can outrun a short wait under parallel load, so it
    # gets a longer one.
    assert_selector "[data-check='version']"
    assert page.has_selector?("[data-pre-trip-target='version']", text: "✓", wait: 10),
      "version row should settle on up to date"
    assert page.has_selector?("[data-pre-trip-target='version']", text: AppVersion.current[0, 7], wait: 10),
      "version row should show the current server build id"

    # The session row can't fail — the page requires sign-in to reach.
    assert_selector "[data-pre-trip-target='session']", text: "✓"
    assert_no_selector "[data-check='session'] [data-pre-trip-hint]"

    assert_selector "[data-pre-trip-target='session'].text-emerald-400"
    assert_selector "[data-pre-trip-target='version'].text-emerald-400"
  end

  test "Re-test reflects new results: clears a stale hint and flags a stale app build" do
    token = SignInToken.issue!(user: @user)
    visit consume_session_path(token: token.token)
    visit pre_trip_path

    # The version row is the last check to settle, so this waits out the
    # entire page-load run. Stubbing before it finishes lets the old run's
    # late callbacks overwrite the stubbed run's rows.
    assert page.has_selector?("[data-pre-trip-target='version']", text: /✓|⚠|ℹ/, wait: 10),
      "version row should settle before stubbing"

    # Force the camera check to fail: stub getUserMedia to reject like a real
    # browser would when the camera errors out, then Re-test to produce a
    # visible hint under the camera row.
    page.execute_script(<<~JS)
      navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException("fail", "NotFoundError"))
    JS
    click_button "Re-test"

    assert page.has_selector?("[data-pre-trip-target='camera']", text: "✗", wait: 5),
      "camera should fail after a rejected getUserMedia"
    assert page.has_selector?("[data-check='camera'] [data-pre-trip-hint]", text: "no rear camera", wait: 5),
      "camera hint should explain the missing camera"

    # Now make the same check pass and Re-test again. The row must flip to ✓
    # AND the hint paragraph left over from the failing run must be cleared —
    # this is the stale-hint-clearing path the initial-state test can't
    # reach, since that test's check (session) never fails in the first
    # place.
    page.execute_script(<<~JS)
      navigator.mediaDevices.getUserMedia = () => Promise.resolve({ getTracks: () => [] })
    JS
    click_button "Re-test"

    assert page.has_selector?("[data-pre-trip-target='camera'].text-emerald-400", text: "✓", wait: 5),
      "camera should recover to green once getUserMedia succeeds again"
    assert page.has_no_selector?("[data-check='camera'] [data-pre-trip-hint]", wait: 5),
      "stale camera hint should be cleared once the check passes"

    # Simulate a phone still showing a page rendered before a deploy: rewrite
    # the build baked into the loaded page, then re-run the checks. The
    # server (via /api/version) still reports the real current build, so the
    # row must flag it.
    page.execute_script("document.documentElement.dataset.appBuild = '0000000'")
    click_button "Re-test"

    assert page.has_selector?("[data-pre-trip-target='version']", text: "⚠ update available", wait: 10),
      "version row should flag an available update"
    assert page.has_selector?("[data-pre-trip-target='version']", text: "0000000", wait: 10),
      "version row should show the stale loaded build id"
    assert page.has_selector?("[data-pre-trip-target='version']", text: AppVersion.current[0, 7], wait: 10),
      "version row should show the current server build id"
    assert page.has_selector?("[data-check='version'] [data-pre-trip-hint]", text: "Update app (clear cache)", wait: 5),
      "version hint should explain how to update"
  end
end

class PreTripNoTournamentTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    # Deliberately no tournament: this is the normal state on most days.
  end

  test "no active tournament renders blue, not amber, and explains itself" do
    token = SignInToken.issue!(user: @user)
    visit consume_session_path(token: token.token)
    visit pre_trip_path

    assert_selector "[data-pre-trip-target='tournaments'].text-blue-300", text: "ℹ no active tournaments today"
    assert_selector "[data-check='tournaments'] [data-pre-trip-hint]", text: "won't score until a tournament is running"
  end
end

class PreTripCameraCauseTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    token = SignInToken.issue!(user: @user)
    visit consume_session_path(token: token.token)
    visit pre_trip_path
    # The version row is the last check to settle, so this waits out the entire
    # page-load run. Stubbing before it finishes lets the old run's late
    # callbacks overwrite the stubbed run's rows.
    assert page.has_selector?("[data-pre-trip-target='version']", text: /✓|⚠|ℹ/, wait: 10),
      "version row should settle before stubbing"
  end

  # Rejects getUserMedia with the named DOMException, then re-runs the checks.
  def rerun_with_media_error(name)
    page.execute_script(<<~JS)
      navigator.mediaDevices.getUserMedia = () =>
        Promise.reject(new DOMException("stubbed", "#{name}"))
    JS
    click_button "Re-test"
  end

  test "camera and microphone errors report their own cause and hint" do
    [
      # [DOMException name, status selector, status text, hint selector, hint text]
      ["NotAllowedError", "[data-pre-trip-target='camera'].text-red-400", "✗ blocked",
        "[data-check='camera'] [data-pre-trip-hint]", "set Camera to Allow"],
      ["NotFoundError", "[data-pre-trip-target='camera']", "✗ no camera found",
        "[data-check='camera'] [data-pre-trip-hint]", "no rear camera"],
      ["NotReadableError", "[data-pre-trip-target='camera']", "✗ camera busy",
        "[data-check='camera'] [data-pre-trip-hint]", "Another app is using the camera"],
      # Same rejected getUserMedia call also fails the microphone row, which
      # reports its own cause and points out that photo catches still work.
      ["NotFoundError", "[data-pre-trip-target='microphone']", "✗ no microphone found",
        "[data-check='microphone'] [data-pre-trip-hint]", "only video catches need one"],
    ].each do |error, status_selector, status_text, hint_selector, hint_text|
      rerun_with_media_error(error)

      assert page.has_selector?(status_selector, text: status_text, wait: 5),
        "#{error} on #{status_selector}: expected status #{status_text.inspect}"
      assert page.has_selector?(hint_selector, text: hint_text, wait: 5),
        "#{error} on #{status_selector}: expected hint #{hint_text.inspect}"
    end
  end
end

class PreTripGpsCauseTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    token = SignInToken.issue!(user: @user)
    visit consume_session_path(token: token.token)
    visit pre_trip_path
    # The version row is the last check to settle, so this waits out the entire
    # page-load run. Stubbing before it finishes lets the old run's late
    # callbacks overwrite the stubbed run's rows.
    assert page.has_selector?("[data-pre-trip-target='version']", text: /✓|⚠|ℹ/, wait: 10),
      "version row should settle before stubbing"
  end

  # Replaces getCurrentPosition with one that succeeds at the given accuracy and
  # timestamp, then re-runs the checks. skew_ms shifts the GPS clock away from
  # the phone's clock.
  def rerun_with_fix(accuracy:, skew_ms: 0)
    page.execute_script(<<~JS)
      Object.defineProperty(navigator, "geolocation", {
        configurable: true,
        value: {
          getCurrentPosition: (ok) => ok({
            coords: { accuracy: #{accuracy} },
            timestamp: Date.now() - #{skew_ms},
          }),
        },
      })
    JS
    click_button "Re-test"
  end

  # Replaces getCurrentPosition with one that fails with the given PositionError
  # code (1 = denied, 2 = unavailable, 3 = timeout).
  def rerun_with_position_error(code)
    page.execute_script(<<~JS)
      Object.defineProperty(navigator, "geolocation", {
        configurable: true,
        value: { getCurrentPosition: (ok, fail) => fail({ code: #{code} }) },
      })
    JS
    click_button "Re-test"
  end

  test "position errors report their own cause, and a failed fix disables the clock check" do
    {
      # PositionError code => { selector => expected text, ... }
      1 => {
        "[data-pre-trip-target='gps'].text-red-400" => "✗ blocked",
        "[data-check='gps'] [data-pre-trip-hint]" => "Allow location in your browser's site settings",
      },
      2 => {
        "[data-pre-trip-target='gps'].text-red-400" => "✗ no fix",
        "[data-check='gps'] [data-pre-trip-hint]" => "Turn Location Services off and back on",
        # A failed fix leaves the clock check with nothing to compare against.
        "[data-pre-trip-target='clock'].text-amber-300" => "⚠ no GPS clock",
        "[data-check='clock'] [data-pre-trip-hint]" => "Fix GPS above",
      },
      3 => {
        "[data-pre-trip-target='gps'].text-red-400" => "✗ no fix (timeout)",
        "[data-check='gps'] [data-pre-trip-hint]" => "No fix within 8 seconds",
      },
    }.each do |code, expectations|
      rerun_with_position_error(code)

      expectations.each do |selector, text|
        assert page.has_selector?(selector, text: text, wait: 5),
          "position error #{code}: expected #{selector} to show #{text.inspect}"
      end
    end
  end

  test "gps fix accuracy and clock skew report status and hints" do
    [
      {
        accuracy: 12, skew_ms: 0,
        present: { "[data-pre-trip-target='gps'].text-emerald-400" => "✓ 12m" },
        absent: [ "[data-check='gps'] [data-pre-trip-hint]" ],
      },
      {
        accuracy: 120, skew_ms: 0,
        present: {
          "[data-pre-trip-target='gps'].text-amber-300" => "⚠ 120m (low)",
          "[data-check='gps'] [data-pre-trip-hint]" => "may be flagged for judge review",
        },
      },
      {
        accuracy: 400, skew_ms: 0,
        present: {
          "[data-pre-trip-target='gps'].text-red-400" => "✗ 400m",
          "[data-check='gps'] [data-pre-trip-hint]" => "Too imprecise to place a catch",
        },
      },
      {
        accuracy: 12, skew_ms: 12 * 60 * 1000,
        present: {
          "[data-pre-trip-target='clock'].text-red-400" => "✗ 12m skew (> 5)",
          "[data-check='clock'] [data-pre-trip-hint]" => "Date & Time",
        },
      },
      {
        accuracy: 12, skew_ms: 2000,
        present: { "[data-pre-trip-target='clock'].text-emerald-400" => "✓" },
        absent: [ "[data-check='clock'] [data-pre-trip-hint]" ],
      },
    ].each do |row|
      rerun_with_fix(accuracy: row[:accuracy], skew_ms: row[:skew_ms])
      label = "accuracy=#{row[:accuracy]} skew_ms=#{row[:skew_ms]}"

      row[:present].each do |selector, text|
        assert page.has_selector?(selector, text: text, wait: 5),
          "#{label}: expected #{selector} to show #{text.inspect}"
      end
      (row[:absent] || []).each do |selector|
        assert page.has_no_selector?(selector, wait: 5),
          "#{label}: expected no #{selector}"
      end
    end
  end

  test "the generation guard drops a stale run's late GPS callback" do
    # Stub a slow, bad fix — a GPS lock can take up to 8s on a real phone — and
    # kick off a Re-test, but don't wait for it to finish. Its checkGps promise
    # is now pending inside the setTimeout below.
    page.execute_script(<<~JS)
      Object.defineProperty(navigator, "geolocation", {
        configurable: true,
        value: {
          getCurrentPosition: (ok) => setTimeout(() => ok({
            coords: { accuracy: 400 },
            timestamp: Date.now(),
          }), 1500),
        },
      })
    JS
    click_button "Re-test"

    # Before that slow callback can fire, re-stub with an instant good fix and
    # Re-test again. This starts a second run (a new generation) while the
    # first run is still awaiting its setTimeout.
    page.execute_script(<<~JS)
      Object.defineProperty(navigator, "geolocation", {
        configurable: true,
        value: {
          getCurrentPosition: (ok) => ok({
            coords: { accuracy: 12 },
            timestamp: Date.now(),
          }),
        },
      })
    JS
    click_button "Re-test"

    assert page.has_selector?("[data-pre-trip-target='gps'].text-emerald-400", text: "✓ 12m", wait: 5),
      "the fast, current run should report the good fix"

    # Wait out the first (stale) run's 1500ms callback. Without the generation
    # guard in set(), this late write isn't dropped — it lands after the
    # second run has already finished and clobbers the gps row with the first
    # run's "✗ 400m" result, even though the fast, current run already
    # reported a good fix. That clobber is exactly what the guard prevents.
    sleep 2

    assert page.has_selector?("[data-pre-trip-target='gps'].text-emerald-400", text: "✓ 12m", wait: 5),
      "the good fix should still be showing after the stale run's late callback"
    assert page.has_no_selector?("[data-pre-trip-target='gps'].text-red-400", wait: 5),
      "the stale run's failing state should never appear"
    assert page.has_no_text?("400m", wait: 5),
      "the stale run's inaccurate reading should never appear"
  end
end
