require "test_helper"
require Rails.root.join("db/migrate/20260924120000_add_in_draw_pool_to_catch_placements")

# The backfill runs once, over prod rows written before in_draw_pool existed.
# Every retirement on prod used a bare update_all, so updated_at can't say
# when a row was retired; the JudgeAction audit trail can.
class AddInDrawPoolBackfillTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    @judge = create(:user, club: @club, role: :organizer)
    @user = create(:user, club: @club)
    @t = build(:tournament, club: @club, format: :tagged, mode: :solo, starts_at: 3.days.ago, ends_at: 2.days.ago)
    @t.scoring_slots.build(species: @tagged, slot_count: 1)
    @t.save!
    @entry = create(:tournament_entry, tournament: @t)
    create(:tournament_entry_member, tournament_entry: @entry, user: @user)
    @drawn_at = 1.day.ago
  end

  def ticket(tag, created_at:, active: true)
    fish = create(:catch, user: @user, species: @tagged, length_inches: 18.0, tag_number: tag,
                  captured_at_device: @t.starts_at + 1.hour)
    row = CatchPlacement.create!(catch: fish, tournament: @t, tournament_entry: @entry, species: @tagged,
                                 slot_index: CatchPlacement.where(tournament: @t).count, active: true)
    # Mirror main's retirement: active flips, updated_at does not.
    row.update_columns(created_at: created_at, updated_at: created_at, active: active)
    row
  end

  def retirement_audit(row, at:)
    JudgeAction.create!(judge_user: @judge, catch: row.catch, action: :disqualify, note: "x", created_at: at,
                        before_state: { "active_placements" => [[@entry.id, row.slot_index]] },
                        after_state:  { "active_placements" => [] })
  end

  test "backfill stamps rows retired after the draw and skips rows retired before it" do
    active_at_draw      = ticket("A1", created_at: @drawn_at - 2.hours)
    retired_after_draw  = ticket("A2", created_at: @drawn_at - 2.hours, active: false)
    retired_before_draw = ticket("A3", created_at: @drawn_at - 2.hours, active: false)
    minted_after_draw   = ticket("A4", created_at: @drawn_at + 2.hours)
    # Retired by a member drop (no audit row): nothing says which side of the
    # draw it left on, so it must not be asserted into the pool.
    retired_no_audit    = ticket("A5", created_at: @drawn_at - 2.hours, active: false)
    retirement_audit(retired_after_draw,  at: @drawn_at + 1.hour)
    retirement_audit(retired_before_draw, at: @drawn_at - 1.hour)
    @t.update_columns(drawn_at: @drawn_at, drawn_winning_placement_id: active_at_draw.id)

    migration = AddInDrawPoolToCatchPlacements.new
    migration.suppress_messages { migration.backfill_draw_pool }

    assert active_at_draw.reload.in_draw_pool
    assert retired_after_draw.reload.in_draw_pool, "retired after the draw: it was drawn from"
    assert_not retired_before_draw.reload.in_draw_pool, "the audit trail shows it left the pool first"
    assert_not minted_after_draw.reload.in_draw_pool
    assert_not retired_no_audit.reload.in_draw_pool,
               "a retired row with no evidence it was still in at the draw must not be stamped"
  end
end
