import { Controller } from "@hotwired/stimulus"

// Client-side filter + sort for the members Attendance page. Rows carry
// data-name and data-nights; the server renders them most-nights-first, and
// this controller re-sorts in place when a toggle is tapped and hides rows
// whose name doesn't contain the typed text. Club rosters are a few dozen
// people, so there is no need for a round trip.
export default class extends Controller {
  static targets = ["query", "list", "row", "sortButton"]
  static values = { sort: { type: String, default: "nights" } }

  connect() {
    this.apply()
  }

  filter() {
    this.apply()
  }

  sortBy(event) {
    this.sortValue = event.currentTarget.dataset.sort
    this.apply()
  }

  apply() {
    const needle = (this.hasQueryTarget ? this.queryTarget.value : "").trim().toLowerCase()
    const rows = this.rowTargets.slice().sort((a, b) => this.compare(a, b))
    rows.forEach((row) => {
      row.hidden = needle !== "" && !row.dataset.name.toLowerCase().includes(needle)
      this.listTarget.appendChild(row)
    })
    this.sortButtonTargets.forEach((button) => {
      const active = button.dataset.sort === this.sortValue
      button.setAttribute("aria-pressed", active ? "true" : "false")
      button.classList.toggle("bg-blue-600", active)
      button.classList.toggle("text-white", active)
      button.classList.toggle("bg-slate-700", !active)
      button.classList.toggle("text-slate-300", !active)
    })
  }

  compare(a, b) {
    const byName = a.dataset.name.localeCompare(b.dataset.name, undefined, { sensitivity: "base" })
    if (this.sortValue === "name") return byName
    return (Number(b.dataset.nights) - Number(a.dataset.nights)) || byName
  }
}
