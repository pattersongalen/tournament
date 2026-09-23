require "application_system_test_case"

# Exercises the /offline shell's form. The submit handler enqueues to IndexedDB
# and navigates to "/", where offline/sync.js drains the queue — the same path a
# real offline→online transition takes. We inject the photo via the
# photo-capture:captured event the controller already listens for, so no real
# camera is needed.
#
# Three browser quirks have to be smoothed over to drive this headless, all via a
# single "evaluate on new document" script (runs before any page script):
#
#   1. navigator.onLine is pinned false *only on /offline*. The back-to-live
#      controller no longer redirects on its own (it only updates a hint), but
#      sync.js's load-handler on "/" fires when online is true and drains the
#      queue. Pinning it false on /offline prevents that drain from firing while
#      the form is being driven; "/" still reports online so sync.js runs there.
#   2. geolocation.getCurrentPosition is stubbed to "denied" so catch-form's
#      tryGeolocate() resolves immediately instead of hanging (headless Chrome
#      fires neither callback).
#   3. window.SyncManager is removed so submit() skips its
#      `await navigator.serviceWorker.ready` — there's no registered SW in the
#      test env, so that await never resolves and the post-enqueue navigation to
#      "/" never fires. iOS Safari (the primary target) likewise has no
#      SyncManager, so this matches a real client path rather than faking one.
class OfflineCatchFormTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club, name: "Joe")
    @walleye = create(:species, club: @club, name: "Walleye")
  end

  # WebKit's file-backed-blob bug means a photo can become unreadable AFTER
  # it's queued — and by drain time the fish is released and the photo is
  # unrecoverable (the iOS camera-through-web flow never saves to the camera
  # roll). Reading the bytes at submit time moves the failure to the moment
  # the angler is still holding the fish and can retake the shot — so the
  # retake has to be the whole story: refused first, then accepted and synced.
  test "an unreadable photo is refused at submit time and the retake syncs" do
    count_before = Catch.count
    sign_in_as(@user)

    apply_ios_shims(online: :except_offline_shell, deny_geolocation: true, remove_sync_manager: true)

    visit "/offline"
    assert_selector "h1", text: "Log Catch"

    find("select#catch_species_id").select("Walleye")
    fill_in "catch_length_inches", with: "18"

    # A 0-byte blob stands in for WebKit's unreadable file-backed blob — the
    # same stand-in offline_sync_test uses for the drain-side guard.
    capture_photo("new Blob([], { type: 'image/jpeg' })")
    click_button "Submit"

    assert page.has_text?(/photo couldn.?t be read.*retake/i, wait: 5),
           "unreadable photo: the angler must be told to retake it"
    assert_current_path "/offline"
    assert_equal count_before, Catch.count, "unreadable photo: nothing may reach the server"
    assert_equal 0, idb_pending_count, "an unreadable photo must not be enqueued"

    # The retake: a readable photo on the same form must enqueue and sync.
    capture_photo("new Blob([new Uint8Array([0xff,0xd8,0xff,0xe0,0,0,0,0])], { type: 'image/jpeg' })")
    click_button "Submit"

    catch_record = nil
    Timeout.timeout(15) do
      loop do
        catch_record = Catch.order(:id).last if Catch.count > count_before
        break if catch_record
        sleep 0.2
      end
    end

    assert catch_record, "expected the offline-logged catch to reach the server"
    assert_equal @user.id, catch_record.user_id, "retake: wrong user"
    assert_equal "Walleye", catch_record.species.name, "retake: wrong species"
    assert_equal 18, catch_record.length_inches.to_i, "retake: wrong length"
  end

  # Regression: navigator.onLine only reports that a network interface is up, not
  # that our server is reachable. On a real device the shell is shown precisely
  # when the server is unreachable while onLine stays true (wifi up, no route to
  # host). The controller used to redirect to "/" on onLine alone; the service
  # worker then re-served this shell for that navigation and it redirected again
  # — an infinite flash loop that locked the user out of the form. The shell must
  # stay put and interactive until the angler taps the manual return themselves.
  test "the offline shell never auto-redirects and leaves only on the manual button" do
    sign_in_as(@user)

    apply_ios_shims(online: true, extra_js: <<~JS)
      const realFetch = window.fetch.bind(window);
      window.fetch = (input, init = {}) => {
        const method = (init.method || (input && input.method) || "GET").toUpperCase();
        // Simulate "interface up, server unreachable": the reachability probe
        // (a HEAD request) fails, while every other request still works.
        if (method === "HEAD") return Promise.reject(new TypeError("unreachable"));
        return realFetch(input, init);
      };
    JS

    visit "/offline"
    assert_selector "h1", text: "Log Catch"

    # Give the controller ample time to (mis)fire a redirect to "/".
    sleep 1.5

    assert_current_path "/offline"
    assert_selector "h1", text: "Log Catch"
    # The form is still mounted and interactive — not stuck mid-navigation.
    find("select#catch_species_id").select("Walleye")
    assert page.has_selector?("select#catch_species_id option[selected]", text: "Walleye", visible: :all),
           "unreachable server: the form must stay interactive"
    # Old behavior auto-bounced to "/"; the way out is the angler's own tap.
    assert_button "Back to live app"

    click_button "Back to live app"

    # The live page does not carry the back-to-live controller.
    assert_no_selector "[data-controller='back-to-live']"
    assert_no_current_path "/offline"
  end

  private

  # Injects a photo the way photo-capture would.
  def capture_photo(blob_js)
    page.execute_script <<~JS
      const el = document.querySelector("[data-controller~='catch-form']");
      el.dispatchEvent(new CustomEvent("photo-capture:captured", { detail: { blob: #{blob_js} } }));
    JS
  end

  # sign_in_as, apply_ios_shims, and idb_pending_count come from IosWebQuirks
  # (test/support/ios_web_quirks.rb).
end
