require "test_helper"

module Tournaments
  class BackfillEntrantCatchesTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    # The league-night scenario: the tournament is already OVER when the missed
    # angler is entered and the sweep runs. Placement still works because
    # PlaceInSlots evaluates eligibility at each catch's captured_at_device.
    setup do
      @club = create(:club)
      @walleye = create(:species, name: "Walleye")
      @tournament = create(:tournament, club: @club, starts_at: 4.hours.ago, ends_at: 1.hour.ago)
      create(:scoring_slot, tournament: @tournament, species: @walleye, slot_count: 2)
      @late_user = create(:user, club: @club)
      @entry = create(:tournament_entry, tournament: @tournament)
      create(:tournament_entry_member, tournament_entry: @entry, user: @late_user)
    end

    test "places a late entrant's in-window catches after the tournament ended" do
      in_window  = create(:catch, user: @late_user, species: @walleye,
                          length_inches: 20, captured_at_device: 3.hours.ago)
      too_early  = create(:catch, user: @late_user, species: @walleye,
                          length_inches: 25, captured_at_device: 5.hours.ago)

      placed = BackfillEntrantCatches.call(tournament: @tournament)

      assert_equal 1, placed
      assert_equal [in_window.id],
                   CatchPlacement.where(tournament: @tournament, active: true).pluck(:catch_id)
      assert_empty too_early.catch_placements
    end

    test "replays in capture order so bump history matches live submission" do
      # slot_count 1: replayed oldest-first, the 10 placed first and was then
      # bumped by the 12 — leaving an inactive placement row. Replayed in the
      # wrong order the 10 would never place at all.
      @tournament.scoring_slots.first.update!(slot_count: 1)
      small = create(:catch, user: @late_user, species: @walleye,
                     length_inches: 10, captured_at_device: 3.hours.ago)
      big   = create(:catch, user: @late_user, species: @walleye,
                     length_inches: 12, captured_at_device: 2.hours.ago)

      BackfillEntrantCatches.call(tournament: @tournament)

      assert_equal [big.id],
                   CatchPlacement.where(tournament: @tournament, active: true).pluck(:catch_id)
      assert CatchPlacement.exists?(catch_id: small.id, tournament_id: @tournament.id, active: false),
             "the smaller earlier catch should have been placed then bumped, as live"
    end

    test "tagged: re-adding the drawn winner after a member drop re-issues the ticket and repoints the winner" do
      tagged = Species.find_or_create_by!(name: "Tagged Walleye")
      t = build(:tournament, club: @club, format: :tagged, mode: :solo,
                starts_at: 4.hours.ago, ends_at: 1.hour.ago, backfill_late_entrants: true)
      t.scoring_slots.build(species: tagged, slot_count: 1)
      t.save!
      organizer = create(:user, club: @club, role: :organizer)
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: @late_user)
      fish = create(:catch, user: @late_user, species: tagged, length_inches: 19.0,
                    tag_number: "A0001", captured_at_device: 3.hours.ago)
      Catches::PlaceInSlots.call(catch: fish)
      DrawTaggedWinner.call(tournament: t.reload, drawn_by: organizer)
      old_ticket = t.reload.drawn_winning_placement
      assert old_ticket.in_draw_pool

      # Dropped from the boat after the draw (no judge action), then put on
      # another boat with the backfill sweep.
      Catches::DropMemberFromEntry.call(entry: entry, user: @late_user)
      assert t.reload.drawn_winner_voided?
      new_entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: new_entry, user: @late_user)

      BackfillEntrantCatches.call(tournament: t, users: [@late_user])

      reissued = CatchPlacement.find_by!(tournament: t, catch: fish, active: true)
      assert_equal new_entry.id, reissued.tournament_entry_id
      assert reissued.in_draw_pool, "the fish was in the draw; the re-issued row says so"
      assert_equal reissued.id, t.reload.drawn_winning_placement_id,
                   "the recorded winner must follow the live ticket, not stay on the boat the member left"
      assert_not t.drawn_winner_voided?
    end

    test "second run is a no-op" do
      create(:catch, user: @late_user, species: @walleye,
             length_inches: 20, captured_at_device: 3.hours.ago)
      BackfillEntrantCatches.call(tournament: @tournament)

      assert_no_difference "CatchPlacement.count" do
        assert_equal 0, BackfillEntrantCatches.call(tournament: @tournament)
      end
    end

    test "skips disqualified catches" do
      create(:catch, user: @late_user, species: @walleye, status: :disqualified,
             length_inches: 20, captured_at_device: 3.hours.ago)

      assert_equal 0, BackfillEntrantCatches.call(tournament: @tournament)
      assert_empty CatchPlacement.where(tournament: @tournament)
    end

    test "users: subset only backfills those users" do
      other_user = create(:user, club: @club)
      other_entry = create(:tournament_entry, tournament: @tournament)
      create(:tournament_entry_member, tournament_entry: other_entry, user: other_user)
      create(:catch, user: @late_user, species: @walleye,
             length_inches: 20, captured_at_device: 3.hours.ago)
      create(:catch, user: other_user, species: @walleye,
             length_inches: 22, captured_at_device: 3.hours.ago)

      BackfillEntrantCatches.call(tournament: @tournament, users: [@late_user])

      assert_equal [@entry.id],
                   CatchPlacement.where(tournament: @tournament, active: true).pluck(:tournament_entry_id)
    end

    test "does not touch other overlapping tournaments the user is entered in" do
      other = create(:tournament, club: @club, starts_at: 4.hours.ago, ends_at: 1.hour.ago)
      create(:scoring_slot, tournament: other, species: @walleye, slot_count: 2)
      other_entry = create(:tournament_entry, tournament: other)
      create(:tournament_entry_member, tournament_entry: other_entry, user: @late_user)
      create(:catch, user: @late_user, species: @walleye,
             length_inches: 20, captured_at_device: 3.hours.ago)

      BackfillEntrantCatches.call(tournament: @tournament)

      assert_empty CatchPlacement.where(tournament: other),
                   "backfill of one tournament must stay forward-only for the other"
    end

    test "enqueues no push notifications even when the sweep bumps and takes the lead" do
      # A rival placed live; the late entrant's replayed catches bump their own
      # basket AND take the lead — both would push on the live path.
      rival = create(:user, club: @club)
      rival_entry = create(:tournament_entry, tournament: @tournament)
      create(:tournament_entry_member, tournament_entry: rival_entry, user: rival)
      rival_catch = create(:catch, user: rival, species: @walleye,
                           length_inches: 15, captured_at_device: 3.hours.ago)
      Catches::PlaceInSlots.call(catch: rival_catch, broadcast: false)

      @tournament.scoring_slots.first.update!(slot_count: 1)
      create(:catch, user: @late_user, species: @walleye,
             length_inches: 10, captured_at_device: 3.hours.ago)
      create(:catch, user: @late_user, species: @walleye,
             length_inches: 20, captured_at_device: 2.hours.ago)

      assert_no_enqueued_jobs(only: DeliverPushNotificationJob) do
        BackfillEntrantCatches.call(tournament: @tournament)
      end
    end

    # Fish Train is non-monotone: a catch a live submission rejected (train not
    # yet at that species' group) leaves no placement row at all, so a plain
    # candidate query can't tell "live-rejected" apart from "never seen." See
    # reject_stale_fish_train_rejects in backfill_entrant_catches.rb.
    test "fish train: a live-rejected catch is not re-offered against the train's final state" do
      perch = create(:species, name: "Perch")
      train = [@walleye.id, perch.id, perch.id] # group0: walleye x1, group1: perch x2
      t = build(:tournament, club: @club, format: :fish_train, mode: :solo,
                starts_at: 4.hours.ago, ends_at: 1.hour.ago, train_cars: train)
      train.uniq.each { |sp_id| t.scoring_slots.build(species_id: sp_id, slot_count: 1) }
      t.save!
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: @late_user)

      # 7pm: Perch caught before the train has advanced past the walleye group
      # (group 0). Live no-op — next_group is walleye, not perch — no row.
      early_perch = create(:catch, user: @late_user, species: perch, length_inches: 12,
                           captured_at_device: 3.hours.ago)
      Catches::PlaceInSlots.call(catch: early_perch, broadcast: false)
      assert_empty early_perch.catch_placements, "sanity: live submission must reject this catch"

      # 8pm: Walleye caught, legitimately fills group 0 and advances the train.
      placed_walleye = create(:catch, user: @late_user, species: @walleye, length_inches: 20,
                              captured_at_device: 2.hours.ago)
      Catches::PlaceInSlots.call(catch: placed_walleye, broadcast: false)
      assert_equal [placed_walleye.id], CatchPlacement.where(tournament: t, active: true).pluck(:catch_id)

      # An admin later toggles the backfill flag on for a different missed
      # angler; the sweep covers this whole tournament, including this entrant.
      BackfillEntrantCatches.call(tournament: t)

      assert_empty early_perch.reload.catch_placements,
                   "the live-rejected Perch catch must not place against the train's final state"
      assert_equal [placed_walleye.id], CatchPlacement.where(tournament: t, active: true).pluck(:catch_id),
                   "the train must not advance on a car never legitimately earned"
    end

    test "fish train: a late entrant's untouched history still replays in capture order" do
      perch = create(:species, name: "Perch")
      train = [@walleye.id, perch.id, perch.id]
      t = build(:tournament, club: @club, format: :fish_train, mode: :solo,
                starts_at: 4.hours.ago, ends_at: 1.hour.ago, train_cars: train)
      train.uniq.each { |sp_id| t.scoring_slots.build(species_id: sp_id, slot_count: 1) }
      t.save!
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: @late_user)

      # No placements exist yet for this entry (no cutoff) — a late entrant
      # added after the fact must still replay their whole in-window history.
      walleye_catch = create(:catch, user: @late_user, species: @walleye, length_inches: 20,
                             captured_at_device: 3.hours.ago)
      perch_catch = create(:catch, user: @late_user, species: perch, length_inches: 12,
                           captured_at_device: 2.hours.ago)

      placed = BackfillEntrantCatches.call(tournament: t)

      assert_equal 2, placed
      assert_equal [walleye_catch.id, perch_catch.id].sort,
                   CatchPlacement.where(tournament: t, active: true).pluck(:catch_id).sort
    end

    test "broadcasts the leaderboard exactly once, and not at all when nothing placed" do
      create(:catch, user: @late_user, species: @walleye,
             length_inches: 20, captured_at_device: 3.hours.ago)

      broadcast_calls = 0
      original = Placements::BroadcastLeaderboard.method(:call)
      Placements::BroadcastLeaderboard.define_singleton_method(:call) do |**kwargs|
        broadcast_calls += 1
        original.call(**kwargs)
      end
      begin
        BackfillEntrantCatches.call(tournament: @tournament)
        assert_equal 1, broadcast_calls
        BackfillEntrantCatches.call(tournament: @tournament) # no-op run
        assert_equal 1, broadcast_calls, "a sweep that places nothing must not rebroadcast"
      ensure
        Placements::BroadcastLeaderboard.define_singleton_method(:call, original)
      end
    end
  end
end
