// Leaflet with the heat layer plugin attached (L.heatLayer). Import order is
// load-bearing: modules evaluate in the order they are imported, and the
// plugin reads the global that lib/leaflet_global sets.
import L from "lib/leaflet_global"
import "leaflet-heat"

export default L
