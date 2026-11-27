import { Controller } from "@hotwired/stimulus"
import L from "lib/leaflet_heat"
import { bindBeforeCacheTeardown, unbindBeforeCacheTeardown } from "lib/leaflet_teardown"

// Draws the club heat map: on the member page (catches/heat_map) and as the
// live preview on the site admin's settings page. Points are [lat, lng]
// pairs; options are Leaflet.heat's (radius, blur, max, minOpacity).
export default class extends Controller {
  static values = {
    points: Array,
    options: Object,
    empty: { type: String, default: "No catches match these filters." }
  }

  connect() {
    this.draw()
    bindBeforeCacheTeardown(this)
  }

  draw() {
    // Array.isArray, not truthiness: a coordinate of 0 is a real coordinate.
    const points = this.pointsValue.filter(p =>
      Array.isArray(p) && Number.isFinite(p[0]) && Number.isFinite(p[1]))

    this.element.innerHTML = ""
    if (points.length === 0) {
      const message = document.createElement("div")
      message.className = "flex items-center justify-center h-full text-slate-400 italic text-center px-4"
      message.textContent = this.emptyValue
      this.element.appendChild(message)
      return
    }

    const map = L.map(this.element)
    this.map = map

    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
    }).addTo(map)

    // maxZoom on the fit: a single catch has zero-size bounds, which would
    // otherwise open at the deepest zoom the tiles have.
    map.fitBounds(L.latLngBounds(points).pad(0.1), { maxZoom: 15 })
    this.heat = L.heatLayer(points, this.layerOptions()).addTo(map)
  }

  // The admin page's sliders rewrite data-heat-map-options-value; Stimulus
  // calls this, and the layer redraws in place.
  optionsValueChanged() {
    if (this.heat) this.heat.setOptions(this.layerOptions())
  }

  // maxZoom: 0 switches off Leaflet.heat's zoom scaling. Left on, every catch
  // is divided by 2^(18 - zoom) — an eighth at zoom 15 — so "catches needed
  // for red" would mean eight times what it says and the map would change
  // brightness as a member zooms.
  layerOptions() {
    return { ...this.optionsValue, maxZoom: 0 }
  }

  disconnect() {
    unbindBeforeCacheTeardown(this)
  }

  teardown() {
    if (this.map) {
      this.map.remove()
      this.map = null
      this.heat = null
      // Leave nothing for the snapshot: connect() rebuilds from the values.
      this.element.innerHTML = ""
    }
  }
}
