import { Controller } from "@hotwired/stimulus"

// Shows the science-tag field on the organizer catch editor only when it can
// matter: the selected species is Tagged Walleye, or the catch already carries
// a tag that the organizer may want to clear. The field stays in the form
// while hidden so an untouched tag round-trips unchanged (a no-op server-side).
export default class extends Controller {
  static targets = ["wrapper", "input"]
  static values = { taggedSpeciesId: String }

  toggle(event) {
    const tagged = event.target.value === this.taggedSpeciesIdValue
    const hasTag = this.inputTarget.value.trim() !== ""
    this.wrapperTarget.classList.toggle("hidden", !(tagged || hasTag))
  }
}
