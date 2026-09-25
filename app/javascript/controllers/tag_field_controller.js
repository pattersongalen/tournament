import { Controller } from "@hotwired/stimulus"
import { isTaggedSpecies } from "lib/tag_rule"

// Shows the science-tag field on the organizer catch editor only when it can
// matter: the selected species is Tagged Walleye, or the catch already carries
// a tag that the organizer may want to clear. The field stays in the form
// while hidden so an untouched tag round-trips unchanged (a no-op server-side).
//
// With a tag in the field and any other species selected, the field stays
// visible (so the organizer can see what is there, and switching back keeps
// it) but a hint under it says the save will drop the tag: the server never
// keeps a tag on anything but a Tagged Walleye, and a populated field would
// otherwise read as the tag being kept.
//
// The server renders the initial state from the STORED species, but the
// browser can restore the select to something else (Firefox keeps form values
// across a reload; a Turbo restore visit brings back an edited form), leaving
// Tagged Walleye selected with the tag field hidden — and the submit rejected
// for a blank tag the organizer can't see. So the rule is re-applied on
// connect against whatever the select actually shows.
export default class extends Controller {
  static targets = ["wrapper", "input", "species", "hint"]
  static values = { taggedSpeciesId: String }

  connect() {
    if (this.hasSpeciesTarget) this.apply(this.speciesTarget.value)
  }

  toggle(event) {
    this.apply(event.target.value)
  }

  // Also fired on input: a tag typed or cleared while a plain species is
  // selected changes whether the hint applies.
  retype() {
    if (this.hasSpeciesTarget) this.apply(this.speciesTarget.value)
  }

  apply(speciesId) {
    const tagged = isTaggedSpecies(speciesId, this.taggedSpeciesIdValue)
    const hasTag = this.inputTarget.value.trim() !== ""
    this.wrapperTarget.classList.toggle("hidden", !(tagged || hasTag))
    if (this.hasHintTarget) this.hintTarget.classList.toggle("hidden", tagged || !hasTag)
  }
}
