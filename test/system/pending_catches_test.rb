require "application_system_test_case"

# A logged fish must never be destroyable from the device: an unsynced catch is
# the ONLY copy of its photo. On 2026-07-15 a Dismiss tap would have destroyed
# six real photos that turned out to be perfectly intact.
class PendingCatchesTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club, name: "Joe")
    @walleye = create(:species, club: @club, name: "Walleye")
  end

  # sync.js stores a human-readable reason on every failure but nothing had ever
  # rendered it, so anglers saw a bare "⚠️ 18″" with no idea what went wrong —
  # and the reason is device-supplied text, so it has to be escaped on the way
  # in. The seeded reason below carries both: markup in front of the words the
  # angler needs to read.
  test "a failed catch shows its escaped reason, offers no way to delete it, and survives a refresh" do
    seed_failed_catch(uuid: SecureRandom.uuid,
                      reason: "<img src=x onerror=alert(1)>Photo could not be read from this device")

    visit root_path
    assert page.has_selector?("[data-pending-catches-target='failedList'] li", wait: 5),
           "the failed catch must be listed"
    assert page.has_text?("Photo could not be read from this device", wait: 5),
           "the failure reason must be rendered"
    assert_no_selector "[data-pending-catches-target='failedList'] img"
    assert_selector "button", text: "Retry"
    assert_no_selector "button", text: "Dismiss"

    visit root_path
    assert_selector "[data-pending-catches-target='failedList'] li", wait: 5,
                    count: 1
  end

  # A catch the server 5xx'd is held back by deferRetry for up to 15 minutes.
  # Rendered as a bare 🕐 it was indistinguishable from a healthy in-flight
  # upload, and the Retry button existed only for FAILED records — so an angler
  # watching a fish miss the leaderboard had no way to see why, or to hurry it.
  #
  # The angler's real case is the harder ordering: they are already sitting on
  # the page when the drain 5xx's and parks the catch. deferRetry dispatched no
  # event, and this controller only re-renders on catch-synced/catch-failed, so
  # the row stayed a bare 🕐 for the whole 15-minute backoff — the exact state
  # the notice exists for. Once the server recovers, Retry must get it through
  # without waiting out the timer.
  test "a catch parked while the angler is watching says so in place and can be retried" do
    uuid = SecureRandom.uuid
    sign_in_as(@user)
    visit root_path
    assert_selector "[data-controller='pending-catches']", wait: 5

    page.execute_script <<~JS
      window.__realFetch = window.fetch;
      window.fetch = (url, opts) => {
        if (String(url).includes("/api/catches")) {
          return Promise.resolve(new Response("boom", { status: 500 }));
        }
        return window.__realFetch(url, opts);
      };
    JS

    seed_idb_catch(uuid: uuid, species_id: @walleye.id,
                   trigger_js: "window.dispatchEvent(new Event('bsfamilies:try-sync'))")

    # No revisit: the widget must react to the parking itself.
    assert page.has_text?("Upload didn’t go through", wait: 10),
           "parked in place: the widget must re-render on the parking itself"
    assert page.has_selector?("[data-pending-catches-target='list'] button", text: "Retry", wait: 5),
           "parked in place: a parked row must offer Retry"

    # The outage ends; Retry must not make the angler wait out the 15-minute timer.
    page.execute_script("window.fetch = window.__realFetch;")
    find("[data-pending-catches-target='list'] button", text: "Retry").click
    Timeout.timeout(15) do
      sleep 0.2 until Catch.find_by(client_uuid: uuid)
    end
  end

  private

  def seed_failed_catch(uuid:, reason: "test")
    sign_in_as(@user)
    seed_idb_catch(uuid: uuid, species_id: @walleye.id, trigger_js: "void 0",
                   status: "failed",
                   extra_fields: { reason: reason.to_json, length_unit: '"inches"' })
  end
end
