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
  # can say it. Its before snapshot lists the catch's active (entry, slot)
  # pairs at that moment, so the FIRST judge action on the catch at or after
  # the draw whose before snapshot lists this row's pair saw it still active
  # at or after the draw: the row was in the pool. A row is never
  # reactivated, so "active at a later moment" implies "active at the draw".
  #
  # Only the first post-draw action can speak. A pair identifies a slot, not
  # a row: a re-issue (a GPS fix on an entry's only fish) retires the row
  # and mints its replacement at the same slot index, so a later action's
  # snapshot lists the pair for the replacement, which may have been minted
  # after the draw for a fish the draw never saw (a pre-draw DQ reinstated
  # after it). Matching the first action instead means the pair it lists is
  # the row that was active when the pool closed (or one minted since, for a
  # fish that already had its pre-draw row retired: that fish's first
  # post-draw action then shows the mint, an empty before snapshot). The
  # after snapshot says nothing: a same-slot re-issue lists the pair on both
  # sides, and reading it as "still active" would leave a drawn winner's
  # pool row unstamped, so its next correction would void the draw.
  #
  # A retirement with no audit row (a member dropped from a boat) could have
  # happened on either side of the draw, and a stamp is read: the
  # late-entrant backfill re-places a re-added member's fish and would mint a
  # live ticket for one the draw never saw. Left unstamped, a fish that WAS
  # in the draw and is re-placed later earns no ticket and says so (the
  # withheld-ticket notice): an error the organizer is told about, rather
  # than a silent ticket for a fish the draw never saw.
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
                WHERE ja.id = (SELECT earliest.id
                                 FROM judge_actions earliest
                                WHERE earliest.catch_id = cp.catch_id
                                  AND earliest.created_at >= t.drawn_at
                                ORDER BY earliest.created_at, earliest.id
                                LIMIT 1)
                  AND EXISTS (SELECT 1 FROM jsonb_array_elements(ja.before_state -> 'active_placements') b
                               WHERE b = jsonb_build_array(cp.tournament_entry_id, cp.slot_index))
             ))
    SQL
  end
end
