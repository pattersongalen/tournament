class AddHeatMapToClubs < ActiveRecord::Migration[8.0]
  # The club heat map: off for every club until a site admin turns it on.
  # The four display values are the site admin's per-club tuning of the heat
  # layer; min_opacity is a percentage (30 means 0.3).
  def change
    add_column :clubs, :heat_map_enabled, :boolean, null: false, default: false
    add_column :clubs, :heat_map_radius, :integer, null: false, default: 25
    add_column :clubs, :heat_map_blur, :integer, null: false, default: 15
    add_column :clubs, :heat_map_max, :integer, null: false, default: 5
    add_column :clubs, :heat_map_min_opacity, :integer, null: false, default: 30
  end
end
