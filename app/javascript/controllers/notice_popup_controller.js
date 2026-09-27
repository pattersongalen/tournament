import { Controller } from "@hotwired/stimulus"

// The blocking daily notice popup (shared/_notice_popup). It locks page
// scroll behind the overlay, keeps keyboard focus on the one button, and
// swallows Escape, so the only way past is to acknowledge.
export default class extends Controller {
  static targets = ["confirm"]

  connect() {
    document.body.classList.add("overflow-hidden")
    this.onKeydown = this.onKeydown.bind(this)
    // Capture phase on the document: the popup must win even when focus has
    // wandered to the page behind it.
    document.addEventListener("keydown", this.onKeydown, true)
    this.confirmTarget.focus()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown, true)
    // When the acknowledgment swaps in the NEXT notice, the replacement is
    // already in the document as this one disconnects. Only unlock the page
    // when no popup is left.
    if (!document.getElementById("notice-popup")) {
      document.body.classList.remove("overflow-hidden")
    }
  }

  onKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
    } else if (event.key === "Tab") {
      event.preventDefault()
      this.confirmTarget.focus()
    }
  }
}
