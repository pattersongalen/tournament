require "application_system_test_case"

# /recover re-materializes a stuck IndexedDB photo blob and re-submits it.
# See docs/superpowers/specs/2026-07-16-ios-blob-sync-fix-design.md.
class RecoverTest < ApplicationSystemTestCase
  setup do
    @club = create(:club, recovery_tool_enabled: true)
    @user = create(:user, club: @club, name: "Joe")
    @walleye = create(:species, club: @club, name: "Walleye")
  end

  # iOS restores /recover from the bfcache with whatever CSRF meta token the
  # page was first rendered with; re-submitting with it fails on every tap
  # until a hard reload — on the tool of last resort. resubmit() therefore
  # preflights GET /api/session (same pattern as offline/sync.js) for a fresh
  # token. The stale-token 422 itself can't be reproduced here (test env
  # disables forgery protection, and with it the csrf meta tag), so this locks
  # in the preflight behaviorally: a dead session must halt with a sign-in
  # message BEFORE any photo-body POST is attempted — and once the session is
  # back, the same button must push the stuck photo through for real.
  test "re-submit halts on a dead session and re-submits the stuck catch once signed in" do
    uuid = SecureRandom.uuid
    sign_in_as(@user)
    seed_catch(uuid: uuid)
    visit "/recover"

    assert_selector "li img", wait: 5           # thumbnail => blob re-materialized

    page.execute_script <<~JS
      window.__realFetch = window.fetch.bind(window);
      window.__catchPosts = 0;
      window.fetch = (input, init = {}) => {
        const url = String(input.url || input);
        if (url.includes("/api/session")) {
          return Promise.resolve(new Response("{}", { status: 401, headers: { "Content-Type": "application/json" } }));
        }
        if (url.includes("/api/catches")) window.__catchPosts++;
        return window.__realFetch(input, init);
      };
    JS
    click_button "Re-submit"

    assert page.has_text?(/signed out.*sign in/i, wait: 5),
           "dead session: the angler must be told to sign in"
    assert_equal 0, page.evaluate_script("window.__catchPosts"),
                 "a dead session must halt resubmit before the photo-body POST"
    assert_nil Catch.find_by(client_uuid: uuid), "dead session: nothing may be persisted"
    assert page.has_selector?("button", text: "Retry", wait: 5),
           "dead session: the row must stay retryable"

    # Signed back in: the preflight now succeeds and the same button re-submits.
    page.execute_script("window.fetch = window.__realFetch;")
    click_button "Retry"

    catch_record = nil
    Timeout.timeout(15) do
      loop do
        catch_record = Catch.find_by(client_uuid: uuid)
        break if catch_record
        sleep 0.2
      end
    end
    assert catch_record, "expected /recover to re-submit the stuck catch"
    assert_equal @user.id, catch_record.user_id, "re-submit: wrong user"
    assert_equal 18, catch_record.length_inches.to_i, "re-submit: wrong length"
    assert_selector "button", text: "Recovered", wait: 5
  end

  # Turbo Drive caches the DOM snapshot of a page when you navigate away from
  # it, and restores that snapshot verbatim (including whatever the JS had
  # already rendered into it) on a back-navigation. connect() then runs again
  # on top of the restored rows. Capybara's `visit` is a full browser
  # navigation, not a Turbo visit, and does not populate Turbo's snapshot
  # cache — so getting a real restore requires leaving via a Turbo-driven
  # link (the bottom-nav Home icon) and then going back.
  test "a Turbo restore visit does not duplicate rows" do
    uuid = SecureRandom.uuid
    sign_in_as(@user)
    seed_catch(uuid: uuid)
    visit "/recover"
    assert_selector "li", count: 1, wait: 5

    find("a[aria-label='Home']").click
    assert_text "Hello, #{@user.name}", wait: 5

    page.go_back
    # NOTE: connect() re-renders rows asynchronously (each row awaits
    # rematerialize() before appending its <li>). A plain
    # `assert_selector "li", count: 1, wait: 5` is NOT safe here — Capybara's
    # polling matcher returns as soon as it FIRST observes the target count,
    # so it can (and did, before this helper) pass by sampling the DOM before
    # the duplicate row has finished appending. We instead wait for the <li>
    # count to stop changing, then assert on the settled value.
    assert_equal 1, stable_li_count
  end

  # The home link is offered for a catch that is genuinely stuck — failed, or
  # pending for long enough that it is not simply mid-upload. Offering
  # "Recover these with photos" for the second or two drain() takes trains
  # anglers to reach for the recovery tool during perfectly healthy operation,
  # so the age check is what separates the two pending cases below. Each step
  # re-seeds the SAME client_uuid, so the queue holds exactly one row and every
  # assertion is about that row's own state.
  test "the home link appears only for a genuinely stuck catch" do
    uuid = SecureRandom.uuid
    sign_in_as(@user)
    visit root_path
    assert_no_selector "[data-pending-catches-target='recoverLink']", visible: true

    # Merely mid-upload: queued a moment ago, so it is just syncing.
    seed_catch(uuid: uuid, status: "pending", queued_ago_ms: 0, held_for_ms: 60_000)
    # Re-render the widget without firing drain() (which would upload the record
    # and empty the pending bucket). The controller refreshes on this event.
    page.execute_script("window.dispatchEvent(new CustomEvent('bsfamilies:catch-failed', { detail: {} }))")
    # Wait for the pending row to prove the render happened, so the link
    # assertion isn't just winning a race.
    assert page.has_selector?("[data-pending-catches-target='list'] li", wait: 5),
           "mid-upload: the pending row must render"
    assert page.has_no_selector?("[data-pending-catches-target='recoverLink']", visible: true),
           "mid-upload: no recover link for a catch that is merely syncing"

    # Queued long enough ago to be stuck rather than in-flight. The age is what
    # makes this the pending-STUCK case: seeded at Date.now() it would be
    # indistinguishable from a catch that is simply mid-upload.
    seed_catch(uuid: uuid, status: "pending", queued_ago_ms: 10 * 60 * 1000,
               held_for_ms: 60_000)
    page.execute_script("window.dispatchEvent(new CustomEvent('bsfamilies:catch-failed', { detail: {} }))")
    assert page.has_selector?("[data-pending-catches-target='recoverLink']", visible: true, wait: 5),
           "pending-stuck: a long-queued pending catch must offer the recover link"

    # And the plain failed case, rendered by connect() on a fresh page load.
    seed_catch(uuid: uuid)
    visit root_path
    assert page.has_selector?("[data-pending-catches-target='recoverLink']", visible: true, wait: 5),
           "failed: a failed catch must offer the recover link"
  end

  private

  # Waits until the <li> count under data-recover-target=list hasn't changed
  # for `settle` seconds, then returns it. connect() renders rows one at a
  # time (each awaiting an async rematerialize), so a single-sample count can
  # catch the DOM mid-render; this waits it out instead.
  def stable_li_count(settle: 1.0, timeout: 6)
    last = page.all("li", minimum: 0).size
    stable_since = Time.now
    Timeout.timeout(timeout) do
      loop do
        current = page.all("li", minimum: 0).size
        if current != last
          last = current
          stable_since = Time.now
        end
        break if Time.now - stable_since >= settle
        sleep 0.1
      end
    end
    last
  end

  # held_for_ms sets hold_until, which is what submit() uses while it waits for
  # a GPS fix: drainOnce skips the record entirely, and the widget still
  # renders it as a plain pending row (the amber "retrying" variant keys off
  # next_attempt_at, not hold_until, and the recover link keys off queued_at).
  #
  # Any test that seeds a PENDING record and then asserts on it needs this.
  # drain() fires from eight triggers, several of them during page and module
  # init, and Capybara's visit can return before the last of them lands. A
  # drain arriving after the seed uploads the fish and empties the pending
  # bucket — and because the widget only re-renders on an event, that empty
  # render is final and the assertion's wait polls a DOM that will never
  # change again.
  def seed_catch(uuid:, status: "failed", queued_ago_ms: 0, held_for_ms: nil)
    extra = { reason: '"test"', length_unit: '"inches"' }
    extra[:hold_until] = "Date.now() + #{Integer(held_for_ms)}" if held_for_ms
    seed_idb_catch(uuid: uuid, species_id: @walleye.id, trigger_js: "void 0",
                   status: status, queued_ago_ms: queued_ago_ms,
                   extra_fields: extra)
  end
end
