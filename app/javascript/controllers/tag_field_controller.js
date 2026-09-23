import { Controller } from "@hotwired/stimulus"
import { isTaggedSpecies } from "lib/tag_rule"

// Shows the science-tag field on the organizer catch editor only when it can
// matter: the selected species is Tagged Walleye, or the catch already carries
// a tag that the organizer may want to clear. The field stays in the form
// while hidden so an untouched tag round-trips unchanged (a no-op server-side).
//
// The server renders the initial state from the STORED species, but the
// browser can restore the select to something else (Firefox keeps form values
// across a reload; a Turbo restore visit brings back an edited form), leaving
// Tagged Walleye selected with the tag field hidden — and the submit rejected
// for a blank tag the organizer can't see. So the rule is re-applied on
// connect against whatever the select actually shows.
export default class extends Controller {
  static targets = ["wrapper", "input", "species"]
  static values = { taggedSpeciesId: String }

  connect() {
    if (this.hasSpeciesTarget) this.apply(this.speciesTarget.value)
  }

  toggle(event) {
    this.apply(event.target.value)
  }

  apply(speciesId) {
    const tagged = isTaggedSpecies(speciesId, this.taggedSpeciesIdValue)
    const hasTag = this.inputTarget.value.trim() !== ""
    this.wrapperTarget.classList.toggle("hidden", !(tagged || hasTag))
  }
}
