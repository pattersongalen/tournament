// Leaflet.heat is a classic script that extends a global `L`. The vendored
// Leaflet build happens to set window.L itself; this module makes that
// dependency explicit rather than relying on it. It must be its own module,
// imported BEFORE the plugin: imports are hoisted, so assigning window.L in
// the same module that imports the plugin would run too late.
import L from "leaflet"

window.L = L

export default L
