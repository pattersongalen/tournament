class AddInDrawPoolToCatchPlacements < ActiveRecord::Migration[8.0]
  # Records, as a fact, which tickets were in the pool when a tagged
  # tournament's winner was drawn. Tournaments::DrawTaggedWinner stamps the
  # rows it drew from; Catches::PlaceInSlots re-issues a ticket after the
  # draw only for a fish that holds a stamped row.
  def up
    add_column :catch_placements, :in_draw_pool, :boolean, default: false, null: false
    backfill_draw_pool
  end

  def down
    remove_column :catch_placements, :in_draw_pool
  end

  # Backfill drawn tournaments: a ticket was in the pool if it existed at the
  # draw and was still active then. The created_at bound matters: before this
  # column PlaceInSlots minted tickets after the draw too (a late offline
  # sync, a judge re-placement), and those rows are active but were never
  # drawn from. A fish genuinely in the pool always has a row from before the
  # draw, so the by-catch lookup in PlaceInSlots still finds it through that
  # row.
  #
  # Whether a retired row was still active at the draw can't be read off
  # updated_at: every retirement before this column was a bare update_all,
  # which leaves the stamp at creation time. The JudgeAction audit trail
  # can say it. Its before/after snapshots list the catch's active
  # (entry, slot) pairs, so a judge action recorded at or after the draw
  # whose snapshots show this row going active -> inactive retired it after
  # the draw: the row was in the pool. Only that positive evidence stamps a
  # retired row. A retirement with no audit row (a member dropped from a
  # boat) could have happened on either side of the draw, and a stamp is
  # read: the late-entrant backfill re-places a re-added member's fish and
  # would mint a live ticket for one the draw never saw. Left unstamped, a
  # fish that WAS in the draw and is re-placed later earns no ticket and
  # says so (the withheld-ticket notice), which is the recoverable error.
  def backfill_draw_pool
    execute <<~SQL
      UPDATE catch_placements cp
         SET in_draw_pool = TRUE
        FROM tournaments t
       WHERE t.id = cp.tournament_id
         AND t.drawn_at IS NOT NULL
         AND cp.created_at <= t.drawn_at
         AND (cp.active OR EXISTS (
               SELECT 1
                 FROM judge_actions ja
                WHERE ja.catch_id = cp.catch_id
                  AND ja.created_at >= cp.created_at
                  AND ja.created_at >= t.drawn_at
                  AND EXISTS (SELECT 1 FROM jsonb_array_elements(ja.before_state -> 'active_placements') b
                               WHERE b = jsonb_build_array(cp.tournament_entry_id, cp.slot_index))
                  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ja.after_state -> 'active_placements') a
                                   WHERE a = jsonb_build_array(cp.tournament_entry_id, cp.slot_index))
             ))
    SQL
  end
end
