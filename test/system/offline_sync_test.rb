require "application_system_test_case"

# Locks in the iOS-friendly drain triggers and failure handling in
# app/javascript/offline/sync.js. A queued catch in IndexedDB must upload when:
#   - visibilitychange fires with the document visible (foregrounding the PWA)
#   - bsfamilies:try-sync fires (manual retry from the pending-catches widget)
#   - pageshow fires with persisted=true (iOS bfcache back-navigation restore)
#   - turbo:load fires (in-app Turbo navigation)
#   - the slow retry interval ticks (no lifecycle event at all)
#
# Background: on 2026-05-13 a tournament called the wrong winner because an
# iOS Safari catch sat stuck-pending until the angler went home and reopened
# his phone — iOS has no Background Sync API, so the page must be alive to
# drain. Losing any of these triggers re-opens that incident.
#
# Shared IndexedDB seeding/inspection and iOS shims: test/support/ios_web_quirks.rb.
class OfflineSyncTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club, name: "Joe")
    @walleye = create(:species, club: @club, name: "Walleye")
  end

  # One drain trigger per assertion, each naming itself: the incident above is
  # re-opened by losing any single trigger, so a failure has to say which one
  # stopped draining.
  test "every drain trigger uploads a pending IndexedDB catch" do
    sign_in_as(@user)

    {
      "visibilitychange (foregrounding the PWA)" =>
        "document.dispatchEvent(new Event('visibilitychange'))",
      "bsfamilies:try-sync (manual retry from the pending widget)" =>
        "window.dispatchEvent(new Event('bsfamilies:try-sync'))",
      # iOS back-navigation restores pages from the bfcache WITHOUT firing load —
      # the drain trigger that covers normal arrivals. pageshow with persisted=true
      # is the only signal those restores emit.
      "pageshow persisted=true (iOS bfcache restore)" =>
        "window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }))",
      # Turbo Drive visits never fire load either — an angler who keeps browsing
      # in-app after signal returns should not need to background the app to sync.
      "turbo:load (in-app Turbo navigation)" =>
        "document.dispatchEvent(new Event('turbo:load'))"
    }.each do |trigger, trigger_js|
      uuid = SecureRandom.uuid
      seed_idb_catch(uuid: uuid, species_id: @walleye.id, trigger_js: trigger_js)
      assert_catch_received(uuid, trigger)
    end

    # WebKit can report navigator.onLine === false on a device that is actually
    # online (stale flag after backgrounding, standalone PWAs). The flag must be
    # a hint at most — a drain trigger firing while onLine is wrongly false must
    # still attempt the upload (the preflight fetch handles the truly-offline
    # case by failing silently). The shim only lands on a fresh document, hence
    # the revisit.
    apply_ios_shims(extra_js: 'Object.defineProperty(navigator, "onLine", { configurable: true, get: () => false });')
    visit root_path
    stale_flag = SecureRandom.uuid
    seed_idb_catch(uuid: stale_flag, species_id: @walleye.id,
                   trigger_js: "document.dispatchEvent(new Event('visibilitychange'))")
    assert_catch_received(stale_flag, "visibilitychange while navigator.onLine wrongly reports false")

    # Safety net: if no lifecycle event ever fires (user sits on one screen with
    # the app foregrounded, e.g. watching the leaderboard), a slow retry tick
    # must eventually drain the queue. The tick period is overridable via
    # window.__syncRetryMs so the test doesn't wait 45 real seconds. This case
    # runs LAST, behind its own revisit: a 300ms tick installed any earlier
    # would drain the rows above and make their trigger assertions vacuous.
    apply_ios_shims(sync_retry_ms: 300)
    visit root_path
    ticked = SecureRandom.uuid
    seed_idb_catch(uuid: ticked, species_id: @walleye.id, trigger_js: "void 0")
    assert_catch_received(ticked, "the retry interval with no user action")
  end

  # Safari evicts ALL script-writable storage (IndexedDB included) after ~7
  # days without interaction unless the origin holds persistent storage. A
  # queued catch must survive that window, so the first enqueue on a page
  # requests persistence. Once per page is enough — repeat calls are no-ops.
  test "enqueueCatch requests persistent storage once" do
    sign_in_as(@user)
    page.execute_script <<~JS
      window.__persistCalls = 0;
      navigator.storage.persist = () => { window.__persistCalls++; return Promise.resolve(true); };
      window.__enqueued = false;
      (async () => {
        const { enqueueCatch } = await import("offline/db");
        const rec = (uuid) => ({
          client_uuid: uuid, species_id: "1", length_inches: "18",
          captured_at_device: new Date().toISOString(),
          photo: { bytes: new Uint8Array([1]).buffer, type: "image/jpeg", name: "p.jpg", size: 1 }
        });
        await enqueueCatch(rec("#{SecureRandom.uuid}"));
        await enqueueCatch(rec("#{SecureRandom.uuid}"));
        window.__enqueued = true;
      })().catch((err) => { window.__enqueueError = String(err); });
    JS

    Timeout.timeout(5) do
      loop do
        break if page.evaluate_script("window.__enqueued === true")
        err = page.evaluate_script("window.__enqueueError || null")
        flunk "enqueue errored: #{err}" if err
        sleep 0.05
      end
    end
    assert_equal 1, page.evaluate_script("window.__persistCalls"),
                 "expected exactly one navigator.storage.persist() call across two enqueues"
  end

  # A drain that hits 401 (expired session — or a CSRF failure, which
  # null_session makes indistinguishable) correctly leaves catches queued, but
  # used to do so in total silence: the exact silent-stranding shape of the
  # 2026-05-13 wrong-winner incident. The angler must be told to sign in.
  test "a 401 drain shows the sign-in-to-sync notice and keeps the catch queued" do
    uuid = SecureRandom.uuid
    visit "/session/new"
    seed_idb_catch(uuid: uuid, species_id: @walleye.id,
                   trigger_js: "window.dispatchEvent(new Event('bsfamilies:try-sync'))")

    assert_selector "[data-controller='sync-auth-notice']:not([hidden])", wait: 5
    assert_text(/sign in/i)
    assert_text(/catch/i)
    assert_nil Catch.find_by(client_uuid: uuid)

    # Still queued — signing back in must be able to resume it.
    assert_equal "pending", idb_status_of(uuid)
  end

  test "a catch whose photo cannot be read is failed on-device and never POSTed" do
    uuid = SecureRandom.uuid
    sign_in_as(@user)
    seed_idb_catch(uuid: uuid, species_id: @walleye.id,
                   photo_js: IosWebQuirks::UNREADABLE_PHOTO_JS, trigger_js: "void 0")
    page.execute_script("window.dispatchEvent(new Event('bsfamilies:try-sync'))")

    # sync.js marks it failed and fires bsfamilies:catch-failed, which the
    # pending-catches widget listens for and re-renders.
    # NOTE: the failure *reason* is asserted below, not here — this test is
    # about the on-device photo-unreadable branch, not the server 4xx branch.
    assert_selector "[data-pending-catches-target='failedList'] li", wait: 5
    assert_nil Catch.find_by(client_uuid: uuid),
               "sync.js must not POST a catch whose photo can't be read"
  end

  # When /api/session breaks with a non-401 (misrouted route, proxy 503 on
  # that path only), sync.js falls back to the page's meta token and can no
  # longer verify who is signed in — so another member's queued catch gets
  # uploaded and the server refuses it with queued_by_mismatch. That record
  # must stay PENDING (drains only pull pending rows; the right member's next
  # sign-in syncs it), never failed behind their back.
  test "a wrong-account catch stays pending when the preflight fallback uploads it" do
    other = create(:user)
    uuid = SecureRandom.uuid
    sign_in_as(@user)
    page.execute_script <<~JS
      // Forgery protection is off in the test env, so csrf_meta_tags renders
      // no meta — but the preflight-unavailable fallback only proceeds when
      // the page has one (offline-shell pages must keep waiting). Inject the
      // meta a production page would have; its value is never validated here.
      if (!document.querySelector("meta[name='csrf-token']")) {
        document.head.insertAdjacentHTML("beforeend", '<meta name="csrf-token" content="test-token">');
      }
      const realFetch = window.fetch;
      window.fetch = (url, opts) => {
        if (String(url).includes("/api/session")) {
          return Promise.resolve(new Response("busy", { status: 503 }));
        }
        return realFetch(url, opts);
      };
    JS
    seed_idb_catch(uuid: uuid, species_id: @walleye.id, queued_by_user_id: other.id,
                   trigger_js: "window.dispatchEvent(new Event('bsfamilies:try-sync'))")

    # deferRetry stamps next_attempt_at after the 422 round-trip — wait on that
    # rather than sleeping, then assert the record was left pending.
    Timeout.timeout(10) do
      sleep 0.1 until idb_next_attempt_at(uuid)
    end
    assert_equal "pending", idb_status_of(uuid)
    assert_no_selector "[data-pending-catches-target='failedList'] li"
    assert_nil Catch.find_by(client_uuid: uuid)
  end

  # A server-wide blip (redeploy, reverse-proxy 502) backs every queued catch
  # off, and deferRetry escalates to a 15-minute floor. The server is usually
  # healthy again within a minute, but nothing shortens the wait: drainOnce
  # filters pending rows on next_attempt_at, and the widget's Retry button is
  # rendered only for FAILED records — so an angler's fish sat off the
  # leaderboard for up to a quarter of an hour with the queue looking healthy.
  # One successful upload proves the server is reachable, so it must release
  # the rest of the queue.
  test "a successful upload releases catches parked in backoff" do
    parked = SecureRandom.uuid
    fresh = SecureRandom.uuid
    sign_in_as(@user)
    # Staged mid-outage: five failed attempts, still ~15 minutes to wait.
    seed_idb_catch(uuid: parked, species_id: @walleye.id, trigger_js: "void 0",
                   extra_fields: { next_attempt_at: "Date.now() + 900000", attempts: 5 })
    seed_idb_catch(uuid: fresh, species_id: @walleye.id,
                   trigger_js: "window.dispatchEvent(new Event('bsfamilies:try-sync'))")

    assert_catch_received(fresh)
    # Without the release this stays queued behind its 15-minute timer.
    assert_catch_received(parked)
  end

  # The release above is capped, because "the server is healthy" says nothing
  # about a record the server rejects every single time. Uncapped, an angler who
  # lands twenty good fish in an evening hands the broken one twenty releases —
  # and so twenty full-photo re-uploads over lake cellular, which is the exact
  # battery/data drain deferRetry exists to prevent. A record already released
  # its budget's worth (clearBackoff's MAX_RELEASES) serves out its backoff.
  #
  # The same budget is only worth having if a release is charged when it
  # actually buys something. A parked row whose timer has ALREADY lapsed is due
  # — its retry happens with or without clearBackoff — so charging it a release
  # burns budget for nothing. Two such no-op charges exhaust MAX_RELEASES, and
  # the next real outage's recovery then skips the row: the one fish on the
  # phone that serves out its full backoff while the rest of the queue syncs.
  test "the backoff release is spent only where it buys something" do
    control = SecureRandom.uuid
    spent = SecureRandom.uuid
    lapsed = SecureRandom.uuid
    fresh = SecureRandom.uuid
    sign_in_as(@user)
    # All three parked rows are also held (hold_until) so they stay put in
    # IndexedDB for inspection instead of racing an upload the moment they are
    # released. They differ only in what should disqualify them: `spent` has
    # spent all of clearBackoff's MAX_RELEASES, `lapsed`'s timer is already up,
    # and the control has a live timer and a full budget.
    held = { hold_until: "Date.now() + 600000", attempts: 5 }
    running = held.merge(next_attempt_at: "Date.now() + 900000")
    seed_idb_catch(uuid: control, species_id: @walleye.id, trigger_js: "void 0",
                   extra_fields: running)
    seed_idb_catch(uuid: spent, species_id: @walleye.id, trigger_js: "void 0",
                   extra_fields: running.merge(releases: 2))
    seed_idb_catch(uuid: lapsed, species_id: @walleye.id, trigger_js: "void 0",
                   extra_fields: held.merge(next_attempt_at: "Date.now() - 1000"))
    seed_idb_catch(uuid: fresh, species_id: @walleye.id,
                   trigger_js: "window.dispatchEvent(new Event('bsfamilies:try-sync'))")

    assert_catch_received(fresh)
    # The control losing its timer is clearBackoff reporting for duty — wait on
    # that rather than a sleep, so the assertions below can't run too early.
    Timeout.timeout(10) do
      sleep 0.1 while idb_next_attempt_at(control)
    end
    assert idb_next_attempt_at(spent),
           "spent budget: a record that already spent its release budget must serve out its backoff"
    assert idb_next_attempt_at(lapsed),
           "already due: an already-due record must be left alone (its stale timer intact), not released"
  end

  # offline/db.js bumps its schema version as the queue format changes, and an
  # upgrade cannot run while another same-origin context holds the old version
  # open — openDB's promise does not reject there, it hangs forever. Every
  # export in db.js awaits getDB(), so a page without a `blocking` handler
  # silently wedges the next deploy's submit(): the Save button stays disabled
  # and the fish is never written to the queue. Standing aside is what keeps
  # that from happening.
  test "a page holding the offline DB open stands aside for a newer schema" do
    sign_in_as(@user)
    page.execute_script <<~JS
      window.__newer = null;
      (async () => {
        const db = await import("offline/db");
        await db.getDB();                     // this page now holds the connection
        const req = indexedDB.open("bsfamilies", 99);
        req.onupgradeneeded = () => {};
        req.onsuccess = (e) => {
          // Leave the origin as we found it for the next test.
          e.target.result.close();
          indexedDB.deleteDatabase("bsfamilies");
          window.__newer = "open";
        };
        req.onerror = () => { window.__newer = "error" };
      })().catch((e) => { window.__newer = "error: " + e });
    JS

    # Without blocking() this poll times out — the upgrade never gets its turn.
    Timeout.timeout(10) do
      sleep 0.1 until page.evaluate_script("window.__newer")
    end
    assert_equal "open", page.evaluate_script("window.__newer")
  end

  # Every drain trigger (the 45s tick, turbo:load, visibilitychange, pageshow,
  # online) and every pending-widget render scans the queue with
  # getAllFromIndex, which deserializes whole records. Once photos became inline
  # ArrayBuffers rather than out-of-line Blobs, that meant materializing every
  # queued photo into the JS heap just to read next_attempt_at and hold_until.
  # offline/db.js v2 keeps the bytes in a separate store; only getCatch — called
  # once, immediately before an upload — joins them back.
  test "a queued catch keeps its bytes out of the row the queue scan reads" do
    sign_in_as(@user)
    page.execute_script <<~JS
      window.__probe = null;
      (async () => {
        const db = await import("offline/db");
        await db.enqueueCatch({
          client_uuid: "#{SecureRandom.uuid}",
          species_id: "#{@walleye.id}",
          length_inches: "18",
          captured_at_device: new Date().toISOString(),
          photo: { bytes: new ArrayBuffer(2048), type: "image/jpeg", name: "p.jpg" }
        });
        const [row] = await db.pendingCatches();
        const full = await db.getCatch(row.client_uuid);
        window.__probe = {
          scanned_row_has_photo: row.photo !== undefined,
          scanned_row_has_length: row.length_inches === "18",
          joined_read_has_photo: !!(full.photo && full.photo.bytes && full.photo.bytes.byteLength === 2048)
        };
      })().catch((e) => { window.__probe = { error: String(e) }; });
    JS

    probe = nil
    Timeout.timeout(10) do
      sleep 0.1 until (probe = page.evaluate_script("window.__probe"))
    end
    assert_nil probe["error"], "enqueue/read probe errored: #{probe["error"]}"
    assert probe["scanned_row_has_length"], "the queue scan must still see the scheduling metadata"
    refute probe["scanned_row_has_photo"], "the queue scan must not deserialize the photo bytes"
    assert probe["joined_read_has_photo"], "getCatch must still hand the uploader its bytes"
  end

  # One drain, three record shapes that have each broken on their own:
  #
  #   - A real server 422 (Walleye's length cap is 50" — MAX_LENGTH_BY_SPECIES
  #     in app/models/catch.rb) used to be shown to the angler as the raw
  #     response body: {"errors":["Length inches for Walleye can't exceed 50\""]}.
  #     sync.js must extract body.errors and join it into readable text before
  #     it ever reaches markFailed / the bsfamilies:catch-failed detail.
  #   - Synced rows used to be kept forever with their full photo/video blobs —
  #     unbounded IndexedDB growth is what invites iOS storage-pressure
  #     eviction, and eviction takes genuinely-pending catches with it. Rows
  #     left behind in status "synced" by the pre-fix code must be swept even
  #     though nothing new synced them.
  #   - New-format records store raw bytes (ArrayBuffer) instead of a Blob —
  #     ArrayBuffers serialize INLINE in the IndexedDB record, sidestepping
  #     WebKit's file-backed-blob bug entirely. sync.js must upload these.
  #     (The Blob-photo tests above double as the legacy-record regression guard.)
  test "one drain rejects readably, prunes legacy synced rows, and uploads bytes records" do
    rejected = SecureRandom.uuid
    legacy = SecureRandom.uuid
    bytes = SecureRandom.uuid
    sign_in_as(@user)
    seed_idb_catch(uuid: rejected, species_id: @walleye.id, length_inches: "60",
                   trigger_js: "void 0")
    seed_idb_catch(uuid: legacy, species_id: @walleye.id, status: "synced",
                   trigger_js: "void 0")
    seed_idb_catch(uuid: bytes, species_id: @walleye.id,
                   photo_js: IosWebQuirks::BYTES_PHOTO_JS,
                   trigger_js: "window.dispatchEvent(new Event('bsfamilies:try-sync'))")

    assert_catch_received(bytes, "a bytes-format (ArrayBuffer photo) record")
    assert_idb_row_gone(bytes)

    assert page.has_selector?("[data-pending-catches-target='failedList'] li", wait: 5),
           "server 422: the rejected catch must show up in the failed list"
    assert page.has_text?(/can't exceed/, wait: 5),
           "server 422: the reason must be the server's readable message"
    assert page.has_no_text?('{"errors"'), "server 422: the raw JSON body must not be shown"
    assert page.has_no_text?('"errors":'), "server 422: the raw JSON body must not be shown"
    assert_nil Catch.find_by(client_uuid: rejected), "server 422: nothing may be persisted"

    assert_idb_row_gone(legacy)
    assert_nil Catch.find_by(client_uuid: legacy),
               "legacy synced row: must be pruned, not re-POSTed"
  end

  # A 4xx that doesn't come from the Rails API — a reverse-proxy 413 for an
  # oversized photo is the realistic case — has an HTML body. resp.json()
  # fails, and the old fallback rendered the reason as literally "{}". The
  # widget must show a readable message instead. The successful upload runs
  # first, on the real fetch: once the server owns the catch, the local row
  # must go (unbounded IndexedDB growth invites iOS eviction).
  test "a success clears its row and a non-JSON 4xx shows a readable reason" do
    synced = SecureRandom.uuid
    oversized = SecureRandom.uuid
    sign_in_as(@user)

    seed_idb_catch(uuid: synced, species_id: @walleye.id,
                   trigger_js: "window.dispatchEvent(new Event('bsfamilies:try-sync'))")
    assert_catch_received(synced, "a successful upload")
    assert_idb_row_gone(synced)

    page.execute_script <<~JS
      const realFetch = window.fetch;
      window.fetch = (url, opts) => {
        if (String(url).includes("/api/catches")) {
          return Promise.resolve(new Response("<html>413 Request Entity Too Large</html>",
            { status: 413, headers: { "Content-Type": "text/html" } }));
        }
        return realFetch(url, opts);
      };
    JS
    seed_idb_catch(uuid: oversized, species_id: @walleye.id,
                   trigger_js: "window.dispatchEvent(new Event('bsfamilies:try-sync'))")

    assert page.has_selector?("[data-pending-catches-target='failedList'] li", wait: 5),
           "non-JSON 4xx: the rejected catch must show up in the failed list"
    assert page.has_text?(/upload failed \(server error 413\)/i, wait: 5),
           "non-JSON 4xx: the reason must be readable"
    assert page.has_no_text?("{}"), "non-JSON 4xx: the reason must not render as {}"
    assert_nil Catch.find_by(client_uuid: oversized), "non-JSON 4xx: nothing may be persisted"
  end

  private

  # label names the case under test so a merged run says which drain trigger
  # (or record shape) stopped working.
  def assert_catch_received(uuid, label = "the drain trigger")
    catch_record = nil
    begin
      Timeout.timeout(15) do
        loop do
          catch_record = Catch.find_by(client_uuid: uuid)
          break if catch_record
          sleep 0.2
        end
      end
    rescue Timeout::Error
      # Fall through: the assertion below names the case that never arrived.
    end

    assert catch_record, "expected the server to receive the queued catch via #{label}"
    assert_equal @user.id, catch_record.user_id, "#{label}: uploaded under the wrong user"
    assert_equal 18, catch_record.length_inches.to_i, "#{label}: uploaded the wrong length"
  end
end
