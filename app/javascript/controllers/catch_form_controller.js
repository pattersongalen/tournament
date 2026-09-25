import { Controller } from "@hotwired/stimulus"
import { enqueueCatch, updateCoords, releaseHold, extendHold } from "offline/db"
import { currentUserId } from "offline/current_user"
import { convertLength, snapToGrid } from "lib/length_convert"
import { isTaggedSpecies } from "lib/tag_rule"

// How long a freshly queued catch is held out of drains while submit() waits
// for a GPS fix. One constant for both the initial hold_until and the
// re-armed hold on iOS resume: if the two windows drift apart, a resumed page
// re-arms a shorter hold than submit() set and the visibilitychange drain
// uploads the record coordless just before the resumed fix lands — the exact
// missing_gps race the re-arm exists to close.
const GPS_HOLD_MS = 12000

export default class extends Controller {
  static targets = ["speciesSelect", "lengthInput", "lengthLabel", "noteInput", "submitButton", "status", "tagWrapper", "tagInput", "weightInput"]
  static values = { csrfToken: String, capsBySpeciesId: Object, teammateUserId: String, taggedSpeciesId: String, videoRequired: Boolean }

  connect() {
    this.photoBlob = null
    this.videoBlob = null
    this.videoFailed = false
    this.clientUuid = crypto.randomUUID()
    this._restoreUnitFromStorage()
    this.refresh()
  }

  _restoreUnitFromStorage() {
    let stored
    try { stored = localStorage.getItem("catchLengthUnit") } catch (_) { return }
    if (!stored) return
    if (!["inches", "centimeters"].includes(stored)) return
    const current = this.lengthInputTarget.dataset.catchFormUnit
    if (stored === current) return
    const radio = this.element.querySelector(`input[name="length_unit_toggle"][value="${stored}"]`)
    if (!radio) return
    radio.checked = true
    this.setUnit({ target: radio })
  }

  onPhotoCaptured(event) { this.photoBlob = event.detail.blob; this.refresh() }
  onVideoCaptured(event) { this.videoBlob = event.detail.blob; this.videoFailed = false; this.refresh() }

  onVideoFailed(event) {
    this.videoBlob = null
    this.videoFailed = true
    this.refresh()
    // An interruption reason (call/lock/app-switch killed the recording, video
    // too large) must be shown — the angler believes they recorded and would
    // otherwise submit a video-less catch without noticing.
    const reason = event && event.detail && event.detail.reason
    if (reason) this.statusTarget.textContent = reason
  }

  refresh() {
    const isTagged = this._isTaggedSpecies()
    if (this.hasTagWrapperTarget) this.tagWrapperTarget.classList.toggle("hidden", !isTagged)
    // The submit reads the tag and weight inputs whether or not they show, so
    // a tag typed for Tagged Walleye and then hidden by a species switch would
    // ride along on a plain Walleye. Clear them with the wrapper.
    if (!isTagged) {
      if (this.hasTagInputTarget) this.tagInputTarget.value = ""
      if (this.hasWeightInputTarget) this.weightInputTarget.value = ""
    }
    this.statusTarget.textContent = this._missingFieldMessage() ?? ""
  }

  _isTaggedSpecies() {
    return isTaggedSpecies(this.speciesSelectTarget.value, this.taggedSpeciesIdValue)
  }

  _missingFieldMessage() {
    if (!this.speciesSelectTarget.value) return "Pick a species."
    if (!this.lengthInputTarget.value)   return "Enter the length."
    const cap = this.capsBySpeciesIdValue[this.speciesSelectTarget.value]
    const inches = parseFloat(this._toInches(this.lengthInputTarget.value))
    if (cap && inches > cap) {
      const speciesName = this.speciesSelectTarget.selectedOptions[0]?.text ?? "this species"
      return `${speciesName} can't exceed ${cap}″.`
    }
    const isTagged = this._isTaggedSpecies()
    if (isTagged && this.hasTagInputTarget && !this.tagInputTarget.value.trim()) {
      return "Enter the tag number on the fish."
    }
    if (!this.photoBlob) return "Take a photo first."
    if (this.hasVideoRequiredValue && this.videoRequiredValue && !this.videoBlob && !this.videoFailed) {
      return "Record the release video, or tap “Mark video failed”."
    }
    return null
  }

  async submit(event) {
    event.preventDefault()
    const missing = this._missingFieldMessage()
    if (missing) { this.statusTarget.textContent = missing; return }

    this._setSubmitting(true)
    try {
      // Read the photo bytes NOW, while the angler is still holding the fish
      // and can retake the shot. WebKit stores IndexedDB blobs as file
      // references that can become unreadable later — by drain time the fish
      // is released and the photo is unrecoverable. Storing the bytes inline
      // (ArrayBuffer, not Blob) sidesteps that failure mode entirely.
      const photo = await this._packBlob(this.photoBlob, "photo.jpg", "image/jpeg")
      if (!photo) {
        this._setSubmitting(false)
        this.statusTarget.textContent = "That photo couldn't be read — retake it and submit again."
        return
      }
      // Video is optional: an unreadable one is dropped rather than blocking the catch.
      const video = this.videoBlob ? await this._packBlob(this.videoBlob, "video", "video/mp4") : null

      // Persist FIRST, geolocate second. The GPS wait can run 8-10s and the
      // angler's natural next move is to lock the phone and release the fish;
      // before this reorder, an iOS jetsam during that window lost the catch
      // and the photo permanently (camera-input files never reach the Photos
      // library). hold_until keeps drains off the record while we wait, and
      // expires on its own if this page dies mid-geolocate.
      const record = {
        client_uuid: this.clientUuid,
        species_id: this.speciesSelectTarget.value,
        length_inches: this._toInches(this.lengthInputTarget.value),
        length_unit: this.lengthInputTarget.dataset.catchFormUnit,
        captured_at_device: new Date().toISOString(),
        captured_at_gps: null,
        latitude: null,
        longitude: null,
        gps_accuracy_m: null,
        app_build: document.documentElement.dataset.appBuild,
        note: this.noteInputTarget.value,
        tag_number: (this.hasTagInputTarget ? this.tagInputTarget.value : "").trim().toUpperCase() || null,
        weight_text: (this.hasWeightInputTarget ? this.weightInputTarget.value : "").trim() || null,
        photo: photo,
        video: video,
        video_failed: this.videoFailed,
        teammate_user_id: this.teammateUserIdValue || null,
        // NOT read straight off the meta: the precached /offline shell's meta
        // can be the PREVIOUS user's after an account switch (shared phone).
        queued_by_user_id: currentUserId(),
        hold_until: Date.now() + GPS_HOLD_MS
      }
      await enqueueCatch(record)

      // Locking the phone mid-fix suspends this page but not the wall clock,
      // so the hold can be expired the moment the page resumes — and the
      // visibilitychange drain would upload the record coordless just before
      // the resumed fix lands. Re-arm the hold on resume; the drain re-reads
      // each row right before upload (offline/sync.js), so the fresh hold and
      // late coords are both seen. A killed page never resumes: the original
      // hold expires and the catch syncs GPS-less, as designed.
      const extendOnResume = () => {
        if (document.visibilityState === "visible") extendHold(this.clientUuid, GPS_HOLD_MS).catch(() => {})
      }
      document.addEventListener("visibilitychange", extendOnResume)
      try {
        const position = await this.tryGeolocate()
        if (position) {
          await updateCoords(this.clientUuid, {
            captured_at_gps: position.gpsTime,
            latitude: position.coords.latitude,
            longitude: position.coords.longitude,
            gps_accuracy_m: position.coords.accuracy
          }).catch(() => {})
        }
      } finally {
        document.removeEventListener("visibilitychange", extendOnResume)
      }
      await releaseHold(this.clientUuid).catch(() => {})

      if ("serviceWorker" in navigator && "SyncManager" in window) {
        try {
          // serviceWorker.ready is spec'd never to reject — with no active
          // registration (failed install, corrupted SW state) it pends forever,
          // and an unguarded await here strands the angler on a disabled Save
          // button AFTER the catch is already queued; re-entering it from a
          // fresh form is a genuine duplicate. Background Sync is best-effort
          // anyway (the destination page drains the queue on load), so give it
          // a short window and move on.
          const reg = await withTimeout(navigator.serviceWorker.ready, 3000)
          await reg.sync.register("catch-sync")
        } catch (_) {}
      }

      // Don't dispatch try-sync here: the upload would race window.location.href below
      // and Safari kills in-flight fetches when a page navigates. The destination page's
      // load handler in offline/sync.js drains the queue on arrival.
      window.location.href = "/"
    } catch (err) {
      this._setSubmitting(false)
      // A few failures know exactly what the angler has to do (offline/db.js
      // sets userMessage when another window is holding the old schema open);
      // "try again" on its own would have them tapping Save forever.
      this.statusTarget.textContent = err?.userMessage || "Couldn't save your catch — try again."
      throw err
    }
  }

  // Packs a Blob/File into { bytes, type, name, size } for inline IndexedDB
  // storage. Returns null when the blob is missing, unreadable, or empty —
  // the same three cases offline/blob.js#materialize refuses to upload.
  async _packBlob(blob, fallbackName, fallbackType) {
    if (!blob) return null
    try {
      const bytes = await blob.arrayBuffer()
      if (!bytes || bytes.byteLength === 0) return null
      return { bytes: bytes, type: blob.type || fallbackType, name: blob.name || fallbackName, size: bytes.byteLength }
    } catch (_) {
      return null
    }
  }

  _setSubmitting(flag) {
    if (!this.hasSubmitButtonTarget) return
    const btn = this.submitButtonTarget
    if (flag) {
      btn.disabled = true
      if (btn.dataset.originalLabel == null) btn.dataset.originalLabel = btn.textContent
      btn.textContent = "Submitting…"
    } else {
      btn.disabled = false
      if (btn.dataset.originalLabel) btn.textContent = btn.dataset.originalLabel
    }
  }

  setUnit(event) {
    const newUnit = event.target.value
    const oldUnit = this.lengthInputTarget.dataset.catchFormUnit
    if (oldUnit === newUnit) return

    const v = parseFloat(this.lengthInputTarget.value)
    if (!Number.isNaN(v)) {
      this.lengthInputTarget.value = convertLength(v, oldUnit, newUnit).toFixed(2)
    }

    this.lengthInputTarget.dataset.catchFormUnit = newUnit
    this.lengthInputTarget.step = "0.25"
    if (this.hasLengthLabelTarget) {
      this.lengthLabelTarget.textContent = newUnit === "centimeters" ? "Length (cm)" : "Length (in)"
    }

    try { localStorage.setItem("catchLengthUnit", newUnit) } catch (_) {}

    fetch("/me", {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfTokenValue
      },
      body: JSON.stringify({ user: { length_unit: newUnit } })
    }).catch(() => {})

    this.refresh()
  }

  uppercaseTag() {
    if (!this.hasTagInputTarget) return
    this.tagInputTarget.value = this.tagInputTarget.value.toUpperCase()
  }

  _toInches(rawValue) {
    const v = parseFloat(rawValue)
    if (Number.isNaN(v)) return rawValue
    // Snap to the 0.25 grid of the currently selected unit, then convert.
    // This makes the quarter-increment rule real rather than advisory.
    const snapped = snapToGrid(v)
    const unit = this.lengthInputTarget.dataset.catchFormUnit
    return convertLength(snapped, unit, "inches").toFixed(2)
  }

  async tryGeolocate() {
    if (!navigator.geolocation) return null
    return new Promise((resolve) => {
      // Safety timeout: some browsers (notably desktop with no GPS) never fire
      // success or error, leaving submit stuck on "Submitting…" forever.
      const safetyTimeout = setTimeout(() => resolve(null), 10000)
      navigator.geolocation.getCurrentPosition(
        (pos) => {
          clearTimeout(safetyTimeout)
          resolve({ coords: pos.coords, gpsTime: new Date(pos.timestamp).toISOString() })
        },
        () => {
          clearTimeout(safetyTimeout)
          resolve(null)
        },
        { enableHighAccuracy: true, timeout: 8000, maximumAge: 0 }
      )
    })
  }
}

function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`timeout after ${ms}ms`)), ms))
  ])
}
