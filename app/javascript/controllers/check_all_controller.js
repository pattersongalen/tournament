import { Controller } from "@hotwired/stimulus"

// Select all / select none for a list of checkboxes.
export default class extends Controller {
  static targets = ["box"]

  all() {
    this.boxTargets.forEach(box => { box.checked = true })
  }

  none() {
    this.boxTargets.forEach(box => { box.checked = false })
  }
}
