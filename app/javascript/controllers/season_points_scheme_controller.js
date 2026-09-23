import { Controller } from "@hotwired/stimulus"

// Dims the ladder fieldsets that the selected scheme doesn't use. Deliberately
// dims rather than hides: switching schemes must not make configuration you
// already entered look lost.
export default class extends Controller {
  static targets = ["radio", "tieredLadders", "baseLadder"]

  connect() {
    this.refresh()
  }

  refresh() {
    const selected = this.radioTargets.find((radio) => radio.checked)
    const scheme = selected ? selected.value : "tiered_ladders"
    this.#setDimmed(this.tieredLaddersTarget, scheme !== "tiered_ladders")
    this.#setDimmed(this.baseLadderTarget, scheme !== "base_ladder")
  }

  #setDimmed(element, dimmed) {
    element.classList.toggle("opacity-40", dimmed)
  }
}
