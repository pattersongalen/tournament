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
    audit(row.catch, at: at, before: [[@entry.id, row.slot_index]], after: [])
  end

  def audit(fish, at:, before:, after:, action: :disqualify)
    JudgeAction.create!(judge_user: @judge, catch: fish, action: action, note: "x", created_at: at,
                        before_state: { "active_placements" => before },
                        after_state:  { "active_placements" => after })
  end

  # A post-draw re-issue on prod (a GPS fix, a geofence override): the pool
  # row is retired and a fresh row minted at the same slot index, so the
  # audit's before and after snapshots both list the same pair.
  def reissue(row, at:)
    replacement = CatchPlacement.create!(catch: row.catch, tournament: @t, tournament_entry: @entry,
                                         species: @tagged, slot_index: row.slot_index, active: true)
    replacement.update_columns(created_at: at, updated_at: at)
    audit(row.catch, at: at, action: :correct_location,
          before: [[@entry.id, row.slot_index]], after: [[@entry.id, row.slot_index]])
    replacement
  end

  def run_backfill
    migration = AddInDrawPoolToCatchPlacements.new
    migration.suppress_messages { migration.backfill_draw_pool }
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

    run_backfill

    assert active_at_draw.reload.in_draw_pool
    assert retired_after_draw.reload.in_draw_pool, "retired after the draw: it was drawn from"
    assert_not retired_before_draw.reload.in_draw_pool, "the audit trail shows it left the pool first"
    assert_not minted_after_draw.reload.in_draw_pool
    assert_not retired_no_audit.reload.in_draw_pool,
               "a retired row with no evidence it was still in at the draw must not be stamped"
  end

  test "backfill stamps a pool row retired by a post-draw re-issue at the same slot" do
    # The winning fish was corrected after the draw: its pool row was retired
    # and re-minted at slot 0 (the entry's only active row), so the audit's
    # after snapshot still lists [entry, 0]. The retired row was in the draw;
    # it must carry the stamp or the next correction voids a legitimate draw.
    winner = ticket("A1", created_at: @drawn_at - 2.hours, active: false)
    replacement = reissue(winner, at: @drawn_at + 1.hour)
    @t.update_columns(drawn_at: @drawn_at, drawn_winning_placement_id: replacement.id)

    run_backfill

    assert winner.reload.in_draw_pool, "the retired row was still active at the draw: the first post-draw audit saw it"
    assert_not replacement.reload.in_draw_pool, "minted after the draw"
    assert CatchPlacement.where(catch_id: winner.catch_id, tournament: @t, in_draw_pool: true).exists?,
           "PlaceInSlots looks the pool up by catch, so the fish re-issues its ticket"
  end

  test "backfill does not stamp a row retired before the draw because a later re-issue reused its slot" do
    # DQ'd before the draw, reinstated after it (pre-PR that minted a fresh
    # slot-0 row), then corrected again: the second post-draw audit lists
    # [entry, 0] in its before snapshot, but that pair is the reinstated row,
    # not the pre-draw one. Only the FIRST audit after the draw can speak for
    # the pool, and its before snapshot is empty.
    pulled = ticket("A2", created_at: @drawn_at - 2.hours, active: false)
    retirement_audit(pulled, at: @drawn_at - 1.hour)
    reinstated = CatchPlacement.create!(catch: pulled.catch, tournament: @t, tournament_entry: @entry,
                                        species: @tagged, slot_index: pulled.slot_index, active: true)
    reinstated.update_columns(created_at: @drawn_at + 1.hour, updated_at: @drawn_at + 1.hour)
    audit(pulled.catch, at: @drawn_at + 1.hour, action: :reinstate, before: [], after: [[@entry.id, pulled.slot_index]])
    reinstated.update_column(:active, false)
    reissue(reinstated, at: @drawn_at + 2.hours)
    @t.update_columns(drawn_at: @drawn_at)

    run_backfill

    assert_not CatchPlacement.where(catch_id: pulled.catch_id, tournament: @t, in_draw_pool: true).exists?,
               "the draw never saw this fish"
  end
end
