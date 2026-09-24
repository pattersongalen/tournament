class AddInDrawPoolToCatchPlacements < ActiveRecord::Migration[8.0]
  # Records, as a fact, which tickets were in the pool when a tagged
  # tournament's winner was drawn. Tournaments::DrawTaggedWinner stamps the
  # rows it drew from; Catches::PlaceInSlots re-issues a ticket after the
  # draw only for a fish that holds a stamped row. Before this column the
  # same question was inferred from updated_at against drawn_at, which any
  # later write to a retired row could falsify.
  def up
    add_column :catch_placements, :in_draw_pool, :boolean, default: false, null: false

    # Backfill drawn tournaments with the inference the column replaces: a
    # ticket still active, or retired after the draw, was in the pool.
    execute <<~SQL
      UPDATE catch_placements cp
         SET in_draw_pool = TRUE
        FROM tournaments t
       WHERE t.id = cp.tournament_id
         AND t.drawn_at IS NOT NULL
         AND (cp.active OR cp.updated_at >= t.drawn_at)
    SQL
  end

  def down
    remove_column :catch_placements, :in_draw_pool
  end
end
