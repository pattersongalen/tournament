import { Controller } from "@hotwired/stimulus"

// Shows the science-tag field on the organizer catch editor only when it can
// matter: the selected species is Tagged Walleye, or the catch already carries
// a tag that the organizer may want to clear. The field stays in the form
// while hidden so an untouched tag round-trips unchanged (a no-op server-side).
export default class extends Controller {
  static targets = ["wrapper", "input"]
  static values = { taggedSpeciesId: String }

  toggle(event) {
    // Same "is the selected species the tagged one" rule as catch_form_controller:
    // an empty tagged id (species not seeded) never matches.
    const tagged = this.taggedSpeciesIdValue !== ""
                && String(event.target.value) === String(this.taggedSpeciesIdValue)
    const hasTag = this.inputTarget.value.trim() !== ""
    this.wrapperTarget.classList.toggle("hidden", !(tagged || hasTag))
  }
}
