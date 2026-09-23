class AddSeasonPointsSettingsToClubs < ActiveRecord::Migration[8.0]
  def change
    add_column :clubs, :season_points_scheme, :integer, default: 0, null: false
    add_column :clubs, :season_points_attendance, :decimal, precision: 5, scale: 2, default: 0.5, null: false
    add_column :clubs, :season_points_min_entries, :integer, default: 3, null: false
    add_column :clubs, :season_points_ladders, :jsonb,
               default: [[3, 2, 1], [6, 4, 2], [9, 6, 3], [9, 6, 3]], null: false
    add_column :clubs, :season_points_base_ladder, :jsonb, default: [3, 2, 1], null: false
    add_column :clubs, :season_points_tier_multipliers, :jsonb, default: [1, 2, 3, 3], null: false
  end
end
