import { Controller } from "@hotwired/stimulus"

// The site admin's heat map sliders. Each move rewrites the preview map's
// options attribute; the heat-map controller on that element redraws.
// Nothing is saved until the form is submitted.
export default class extends Controller {
  static targets = ["slider", "preview"]

  connect() {
    this.update()
  }

  update() {
    const options = {}
    this.sliderTargets.forEach(slider => {
      const value = Number(slider.value)
      const output = this.element.querySelector(`[data-output-for="${slider.dataset.option}"]`)
      if (output) output.textContent = value + (slider.dataset.unit || "")
      // The faintest-blob slider is a percentage; the map wants a fraction.
      options[slider.dataset.option] = slider.dataset.option === "minOpacity" ? value / 100 : value
    })
    if (this.hasPreviewTarget) {
      this.previewTarget.setAttribute("data-heat-map-options-value", JSON.stringify(options))
    }
  }

  reset() {
    this.sliderTargets.forEach(slider => { slider.value = slider.dataset.default })
    this.update()
  }
}
