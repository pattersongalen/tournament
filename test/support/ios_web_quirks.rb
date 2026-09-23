# Shared helpers for driving the offline/PWA stack in headless Chromium while
# simulating the iOS Safari environment our incidents actually come from:
# no Background Sync API, lifecycle-event-driven sync, camera permission
# denials, and IndexedDB records whose blobs may be unreadable.
#
# Everything here composes a single Page.addScriptToEvaluateOnNewDocument
# script (runs before any page script) plus IndexedDB seed/inspect helpers.
module IosWebQuirks
  # A minimal JPEG header — enough for the upload pipeline to treat it as a photo.
  SYNTHETIC_JPEG_JS = 'new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0])], { type: "image/jpeg" })'.freeze
  # 0 bytes stands in for WebKit's unreadable file-backed blob: materialize()
  # refuses both the same way.
  UNREADABLE_PHOTO_JS = 'new Blob([], { type: "image/jpeg" })'.freeze
  # The new inline-bytes record format written by catch_form_controller.
  BYTES_PHOTO_JS = '{ bytes: new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0]).buffer, type: "image/jpeg", name: "photo.jpg", size: 8 }'.freeze

  # The one spelling of the IndexedDB open + schema-create boilerplate
  # (mirrors offline/db.js), interpolated into every helper below so an
  # offline-schema change edits a single string. Leaves `db` in scope.
  # Always registers onupgradeneeded: an inspect helper that happens to open
  # the DB first (polling before any page script ran) must create the store,
  # not error on it missing.
  IDB_OPEN_JS = <<~JS.freeze
    const dbReq = indexedDB.open("bsfamilies", 2);
    const db = await new Promise((res, rej) => {
      dbReq.onupgradeneeded = (e) => {
        const d = e.target.result;
        if (!d.objectStoreNames.contains("catches")) {
          const s = d.createObjectStore("catches", { keyPath: "client_uuid" });
          s.createIndex("status", "status");
        }
        if (!d.objectStoreNames.contains("blobs")) {
          d.createObjectStore("blobs", { keyPath: "client_uuid" });
        }
      };
      dbReq.onsuccess = (e) => res(e.target.result);
      dbReq.onerror   = (e) => rej(e);
    });
  JS

  def sign_in_as(user)
    SignInToken.issue!(user: user)
    visit consume_session_path(token: SignInToken.last.token)
  end

  # Installs browser-environment shims before any page script runs. All shims
  # are opt-in so each test states exactly which quirks it simulates.
  #
  #   online:             :except_offline_shell — onLine false only on /offline
  #                       true                  — pinned true everywhere
  #                       nil (default)         — leave navigator.onLine alone
  #   deny_geolocation:   getCurrentPosition immediately errors "denied"
  #                       (headless Chrome otherwise fires neither callback)
  #   remove_sync_manager: no Background Sync API, like iOS Safari
  #   sync_retry_ms:      overrides offline/sync.js's retry tick period
  #   extra_js:           appended verbatim for test-specific shims
  def apply_ios_shims(online: nil, deny_geolocation: false, remove_sync_manager: false,
                      sync_retry_ms: nil, extra_js: nil)
    parts = []
    case online
    when :except_offline_shell
      parts << <<~JS
        Object.defineProperty(navigator, "onLine", {
          configurable: true,
          get: () => location.pathname !== "/offline"
        });
      JS
    when true
      parts << 'Object.defineProperty(navigator, "onLine", { configurable: true, get: () => true });'
    end
    if deny_geolocation
      parts << <<~JS
        try {
          navigator.geolocation.getCurrentPosition = function (ok, err) {
            if (typeof err === "function") setTimeout(() => err({ code: 1, message: "denied" }), 0);
          };
        } catch (e) {}
      JS
    end
    parts << "try { delete window.SyncManager; } catch (e) {}" if remove_sync_manager
    parts << "window.__syncRetryMs = #{Integer(sync_retry_ms)};" if sync_retry_ms
    parts << extra_js if extra_js

    page.driver.browser.page.command(
      "Page.addScriptToEvaluateOnNewDocument",
      source: parts.join("\n")
    )
  end

  # Inserts a row into the bsfamilies IndexedDB catches store, then fires
  # trigger_js (pass "void 0" for none). Waits until the seed transaction has
  # committed before returning so server-side polling can start immediately.
  # extra_fields merges arbitrary columns into the seeded row (as a JS object
  # literal), e.g. { next_attempt_at: "Date.now() + 900000", attempts: 5 } to
  # stage a record already parked in the drain's backoff.
  # queued_ago_ms backdates queued_at — the widget uses the row's age to tell a
  # stuck pending catch from one that is merely mid-upload.
  # Seeds the photo INLINE on the catch row — the v1 record shape. offline/db.js
  # v2 writes bytes to the `blobs` store instead and falls back to inline for
  # rows queued before the upgrade, so these seeds keep that fallback covered.
  # The v2 shape is exercised end-to-end by the tests that actually log a catch
  # through enqueueCatch (offline_catch_form_test).
  def seed_idb_catch(uuid:, species_id:, trigger_js:, length_inches: "18",
                     status: "pending", photo_js: SYNTHETIC_JPEG_JS,
                     queued_by_user_id: nil, queued_ago_ms: 0, extra_fields: {})
    page.execute_script <<~JS
      window.__seeded = false;
      window.__seedError = null;
      (async () => {
        #{IDB_OPEN_JS}
        const photo = #{photo_js};
        const tx = db.transaction("catches", "readwrite");
        tx.objectStore("catches").put({
          client_uuid: "#{uuid}",
          species_id: "#{species_id}",
          length_inches: "#{length_inches}",
          captured_at_device: new Date().toISOString(),
          photo: photo,
          status: "#{status}",
          queued_at: Date.now() - #{Integer(queued_ago_ms)}#{queued_by_user_id ? ",\n          queued_by_user_id: \"#{queued_by_user_id}\"" : ""}#{extra_fields.map { |k, v| ",\n          #{k}: #{v}" }.join}
        });
        await new Promise((res, rej) => { tx.oncomplete = res; tx.onerror = rej; });
        #{trigger_js};
        window.__seeded = true;
      })().catch((err) => { window.__seedError = String(err); });
    JS

    Timeout.timeout(5) do
      loop do
        break if page.evaluate_script("window.__seeded === true")
        err = page.evaluate_script("window.__seedError || null")
        flunk "IDB seeding errored: #{err}" if err
        sleep 0.1
      end
    end
  end

  # Returns the row's status string, or "missing" when the row doesn't exist.
  def idb_status_of(uuid)
    page.execute_script <<~JS
      window.__rowStatus = null;
      (async () => {
        #{IDB_OPEN_JS}
        const tx = db.transaction("catches", "readonly");
        const req = tx.objectStore("catches").get("#{uuid}");
        const row = await new Promise((res, rej) => {
          req.onsuccess = () => res(req.result);
          req.onerror = (e) => rej(e);
        });
        window.__rowStatus = row ? row.status : "missing";
      })().catch(() => { window.__rowStatus = "error"; });
    JS
    status = nil
    Timeout.timeout(5) do
      loop do
        status = page.evaluate_script("window.__rowStatus")
        break if status
        sleep 0.05
      end
    end
    status
  end

  # The row's next_attempt_at (ms epoch) or nil — a non-nil value proves the
  # drain's backoff branch (deferRetry) ran for this record.
  def idb_next_attempt_at(uuid)
    page.execute_script <<~JS
      window.__rowNextAttempt = undefined;
      (async () => {
        #{IDB_OPEN_JS}
        const tx = db.transaction("catches", "readonly");
        const req = tx.objectStore("catches").get("#{uuid}");
        const row = await new Promise((res, rej) => {
          req.onsuccess = () => res(req.result);
          req.onerror = (e) => rej(e);
        });
        window.__rowNextAttempt = (row && row.next_attempt_at) || null;
      })().catch(() => { window.__rowNextAttempt = null; });
    JS
    value = nil
    Timeout.timeout(5) do
      loop do
        value = page.evaluate_script("window.__rowNextAttempt === undefined ? 'unset' : window.__rowNextAttempt")
        break unless value == "unset"
        sleep 0.05
      end
    end
    value
  end

  def idb_pending_count
    page.execute_script <<~JS
      window.__pendingCount = null;
      (async () => {
        #{IDB_OPEN_JS}
        const tx = db.transaction("catches", "readonly");
        const req = tx.objectStore("catches").index("status").getAll("pending");
        const rows = await new Promise((res, rej) => {
          req.onsuccess = () => res(req.result);
          req.onerror = (e) => rej(e);
        });
        window.__pendingCount = rows.length;
      })().catch(() => { window.__pendingCount = -1; });
    JS
    count = nil
    Timeout.timeout(5) do
      loop do
        count = page.evaluate_script("window.__pendingCount")
        break unless count.nil?
        sleep 0.05
      end
    end
    count
  end

  # Polls until the row for uuid is deleted from IndexedDB.
  def assert_idb_row_gone(uuid)
    Timeout.timeout(10) do
      sleep 0.2 until idb_status_of(uuid) == "missing"
    end
  rescue Timeout::Error
    flunk "expected IndexedDB row #{uuid} to be deleted, but it is still present"
  end
end
