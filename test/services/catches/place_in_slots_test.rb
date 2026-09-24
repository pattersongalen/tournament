require "test_helper"

module Catches
  class PlaceInSlotsTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
      @walleye = create(:species, club: @club, name: "Walleye")
      @user = create(:user, club: @club)
      @tournament = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      create(:scoring_slot, tournament: @tournament, species: @walleye, slot_count: 2)
      @entry = create(:tournament_entry, tournament: @tournament)
      create(:tournament_entry_member, tournament_entry: @entry, user: @user)
    end

    test "places a single fish into the first empty slot of its species" do
      catch_record = create(:catch, user: @user, species: @walleye, length_inches: 20)
      result = PlaceInSlots.call(catch: catch_record)

      placement = catch_record.catch_placements.sole
      assert_equal @entry, placement.tournament_entry
      assert_equal @walleye, placement.species
      assert_equal 0, placement.slot_index
      assert placement.active?
      assert_includes result[:created], placement
    end

    test "fills slot_index 1 when slot 0 is occupied" do
      first = create(:catch, user: @user, species: @walleye, length_inches: 14)
      PlaceInSlots.call(catch: first)
      second = create(:catch, user: @user, species: @walleye, length_inches: 17)
      PlaceInSlots.call(catch: second)

      assert_equal [0, 1], CatchPlacement.where(tournament_entry: @entry, active: true).order(:slot_index).pluck(:slot_index)
    end

    test "broadcast path builds each affected leaderboard once, not twice" do
      catch_record = create(:catch, user: @user, species: @walleye, length_inches: 20)
      build_calls = []
      original = Leaderboards::Build.method(:call)
      Leaderboards::Build.define_singleton_method(:call) do |tournament:, **kwargs|
        build_calls << tournament.id
        original.call(tournament: tournament, **kwargs)
      end
      begin
        PlaceInSlots.call(catch: catch_record)
      ensure
        Leaderboards::Build.define_singleton_method(:call, original)
      end

      assert_equal 1, build_calls.count { |id| id == @tournament.id },
                   "leaderboard should be built once per affected tournament on the broadcast path"
    end

    test "ignores tournaments that don't score this species" do
      perch = create(:species, club: @club, name: "Perch")
      catch_record = create(:catch, user: @user, species: perch, length_inches: 10)
      result = PlaceInSlots.call(catch: catch_record)
      assert_empty result[:created]
    end

    test "an equal-length offline swap stays reconcile-consistent but fires no bumped push" do
      # Fill the 2-slot basket with a 10.0 (captured 30m ago) and a 12.0.
      incumbent = create(:catch, user: @user, species: @walleye, length_inches: 10,
                                 captured_at_device: 30.minutes.ago)
      PlaceInSlots.call(catch: incumbent)
      other = create(:catch, user: @user, species: @walleye, length_inches: 12,
                             captured_at_device: 20.minutes.ago)
      PlaceInSlots.call(catch: other)

      # A same-length (10.0) fish captured EARLIER than the incumbent syncs late.
      # rank_key's "earliest-captured wins" swaps it in (matching a reconcile), but
      # the basket total (10 + 12) is unchanged — nobody was really bumped.
      earlier = create(:catch, user: @user, species: @walleye, length_inches: 10,
                               captured_at_device: 50.minutes.ago)
      result = PlaceInSlots.call(catch: earlier)

      # The swap still happens (reconcile consistency): the earlier 10.0 holds the slot.
      assert earlier.catch_placements.sole.active?
      assert_not incumbent.catch_placements.sole.reload.active?
      # But it's score-neutral, so no "you were bumped from a slot" notification.
      assert_empty result[:bumped],
                   "an equal-length swap must not fire a bumped push (score unchanged)"
    end

    test "when all slots are full, replaces the smallest active fish if new is bigger" do
      small = create(:catch, user: @user, species: @walleye, length_inches: 14)
      PlaceInSlots.call(catch: small)
      medium = create(:catch, user: @user, species: @walleye, length_inches: 17)
      PlaceInSlots.call(catch: medium)
      big = create(:catch, user: @user, species: @walleye, length_inches: 22)
      result = PlaceInSlots.call(catch: big)

      assert_includes result[:bumped], small.catch_placements.first
      assert_not small.catch_placements.first.reload.active?
      assert_equal [17, 22],
        CatchPlacement.active.where(tournament_entry: @entry).joins(:catch).order("catches.length_inches").pluck("catches.length_inches").map(&:to_i)
    end

    test "when all slots are full and new fish is smaller, no placement is made" do
      big1 = create(:catch, user: @user, species: @walleye, length_inches: 22)
      big2 = create(:catch, user: @user, species: @walleye, length_inches: 21)
      small = create(:catch, user: @user, species: @walleye, length_inches: 10)
      PlaceInSlots.call(catch: big1)
      PlaceInSlots.call(catch: big2)
      result = PlaceInSlots.call(catch: small)

      assert_empty result[:created]
      assert_empty result[:bumped]
      assert small.catch_placements.empty?
    end

    test "skips placement when membership is dropped between tournament resolution and entry lock" do
      catch_record = create(:catch, user: @user, species: @walleye, length_inches: 20)

      original = ::Tournaments::ActiveForUser.method(:with_entries)
      ::Tournaments::ActiveForUser.define_singleton_method(:with_entries) do |user:, at: Time.current|
        rows = original.call(user: user, at: at)
        # Simulate the user being dropped between this query and PlaceInSlots's entry.lock!
        user.tournament_entry_members.destroy_all
        rows
      end
      begin
        result = PlaceInSlots.call(catch: catch_record)
      ensure
        ::Tournaments::ActiveForUser.define_singleton_method(:with_entries, original)
      end

      assert_empty result[:created]
      assert_equal 0, catch_record.catch_placements.count
    end

    test "credits multiple active tournaments — boat entry and individual entry" do
      # Boat tournament (team mode)
      boat_tournament = create(:tournament, club: @club, mode: :team,
                                starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      create(:scoring_slot, tournament: boat_tournament, species: @walleye, slot_count: 2)
      boat = create(:tournament_entry, tournament: boat_tournament, name: "Curtis's Boat")
      create(:tournament_entry_member, tournament_entry: boat, user: @user)

      # Individual ongoing tournament (already set up in setup as @tournament + @entry)
      catch_record = create(:catch, user: @user, species: @walleye, length_inches: 20)
      result = PlaceInSlots.call(catch: catch_record)

      assert_equal 2, result[:created].size
      entries = result[:created].map(&:tournament_entry).sort_by(&:id)
      assert_equal [@entry, boat].sort_by(&:id), entries
    end

  test "hidden_length: every catch creates a placement, no bumping" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :hidden_length, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    # Three catches; each must produce a placement, even though slot_count is 1.
    [22, 16, 14].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    placements = CatchPlacement.where(tournament: t, active: true).order(:slot_index)
    assert_equal 3, placements.count, "expected all three catches to be placed (no bumping)"
    # Slot indices ascend with creation order
    assert_equal [0, 1, 2], placements.map(&:slot_index)
  end

  test "hidden_length: new catch after a placement is deactivated does not collide on slot_index" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :hidden_length, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [22, 16, 14].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    # Simulate a judge DQ on the middle placement: deactivate slot_index = 1.
    # The unique partial index on (entry, species, slot_index WHERE active=true)
    # leaves indexes 0 and 2 active.
    middle = CatchPlacement.find_by!(tournament: t, slot_index: 1, active: true)
    middle.update!(active: false)

    # A new catch must place without colliding with the existing active row at
    # slot_index = 2.
    assert_nothing_raised do
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: 18,
                      captured_at_device: 25.minutes.ago)
      )
    end

    active_indexes = CatchPlacement.where(tournament: t, active: true).order(:slot_index).pluck(:slot_index)
    assert_equal [0, 2, 3], active_indexes,
                 "expected new placement to land at max(active)+1, never reusing an occupied index"
  end

  test "beat_the_average keeps every catch across multiple species" do
    pike = create(:species, club: @club, name: "Pike")
    t = build(:tournament, club: @club, format: :beat_the_average,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: @walleye, slot_count: 1)
    t.scoring_slots.build(species: pike, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: @user)

    walleye_c1 = create(:catch, user: @user, species: @walleye, length_inches: 20,
                                 captured_at_device: 30.minutes.ago)
    walleye_c2 = create(:catch, user: @user, species: @walleye, length_inches: 16,
                                 captured_at_device: 30.minutes.ago)
    pike_c1 = create(:catch, user: @user, species: pike, length_inches: 24,
                              captured_at_device: 30.minutes.ago)

    [walleye_c1, walleye_c2, pike_c1].each { |c| Catches::PlaceInSlots.call(catch: c, broadcast: false) }

    placements = CatchPlacement.active.where(tournament_id: t.id)
    assert_equal 3, placements.count, "every catch should be placed"
    # slot_index is scoped per (entry, species) — see idx_active_placements_uniq_per_slot
    # — so each species indexes independently rather than sharing one counter.
    assert_equal [0, 1], placements.where(species: @walleye).order(:slot_index).pluck(:slot_index)
    assert_equal [0], placements.where(species: pike).order(:slot_index).pluck(:slot_index)
  end

  test "biggest_vs_smallest: first catch creates one placement at slot_index 0" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :biggest_vs_smallest, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: walleye, length_inches: 18,
                    captured_at_device: 30.minutes.ago)
    )

    placements = CatchPlacement.where(tournament: t, active: true).order(:slot_index)
    assert_equal 1, placements.count
    assert_equal 0, placements.first.slot_index
  end

  test "biggest_vs_smallest: second catch fills the unused slot index, both are kept" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :biggest_vs_smallest, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [18, 12].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    placements = CatchPlacement.where(tournament: t, active: true).order(:slot_index)
    assert_equal 2, placements.count
    assert_equal [0, 1], placements.map(&:slot_index)
  end

  test "biggest_vs_smallest: a catch bigger than current biggest bumps the old biggest, smallest unchanged" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :biggest_vs_smallest, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [18, 12].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: walleye, length_inches: 22,
                    captured_at_device: 25.minutes.ago)
    )

    active = CatchPlacement.where(tournament: t, active: true).includes(:catch).to_a
    active_lens = active.map { |p| p.catch.length_inches }.sort
    assert_equal [12, 22], active_lens, "expected smallest unchanged, biggest replaced"
    assert_equal 2, active.count
  end

  test "biggest_vs_smallest: a catch smaller than current smallest bumps the old smallest, biggest unchanged" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :biggest_vs_smallest, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [18, 12].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: walleye, length_inches: 8,
                    captured_at_device: 25.minutes.ago)
    )

    active = CatchPlacement.where(tournament: t, active: true).includes(:catch).to_a
    active_lens = active.map { |p| p.catch.length_inches }.sort
    assert_equal [8, 18], active_lens, "expected biggest unchanged, smallest replaced"
  end

  test "biggest_vs_smallest: a catch in the middle is dropped — no new placement, no bump" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :biggest_vs_smallest, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [22, 10].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: walleye, length_inches: 16,
                    captured_at_device: 25.minutes.ago)
    )

    active = CatchPlacement.where(tournament: t, active: true).includes(:catch).to_a
    active_lens = active.map { |p| p.catch.length_inches }.sort
    assert_equal [10, 22], active_lens, "expected the middle catch to be ignored"
  end

  test "biggest_vs_smallest: a catch tying the current biggest or smallest is a no-op (first to set wins)" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :biggest_vs_smallest, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [22, 10].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    original_max_id = CatchPlacement.where(tournament: t, active: true)
                                    .joins(:catch).order("catches.length_inches DESC").first.id
    original_min_id = CatchPlacement.where(tournament: t, active: true)
                                    .joins(:catch).order("catches.length_inches ASC").first.id

    [22, 10].each do |tied_len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: tied_len,
                      captured_at_device: 25.minutes.ago)
      )
    end

    active = CatchPlacement.where(tournament: t, active: true).includes(:catch).to_a
    active_lens = active.map { |p| p.catch.length_inches }.sort
    assert_equal [10, 22], active_lens, "expected ties to neither bump nor add a placement"
    assert_equal [original_min_id, original_max_id].sort, active.map(&:id).sort,
                 "expected the original biggest/smallest placements to remain active"
  end

  test "biggest_vs_smallest: new catch after a placement is deactivated fills the freed slot index without colliding" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :biggest_vs_smallest, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [22, 10].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    smaller = CatchPlacement.find_by!(tournament: t, slot_index: 1, active: true)
    smaller.update!(active: false)

    assert_nothing_raised do
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: 14,
                      captured_at_device: 25.minutes.ago)
      )
    end

    active_indexes = CatchPlacement.where(tournament: t, active: true).order(:slot_index).pluck(:slot_index)
    assert_equal [0, 1], active_indexes,
                 "expected new placement to land at the freed slot_index without colliding"
  end

  test "fish_train: first catch matching car 0 species creates a placement at slot_index 0" do
    club = create(:club)
    perch = create(:species, club: club, name: "Perch")
    pike  = create(:species, club: club, name: "Pike")
    user  = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, pike.id, perch.id])
    [perch, pike].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: perch, length_inches: 12,
                    captured_at_device: 30.minutes.ago)
    )

    placements = CatchPlacement.where(tournament: t, active: true).order(:slot_index)
    assert_equal 1, placements.count
    assert_equal 0, placements.first.slot_index
    assert_equal perch, placements.first.species
  end

  test "fish_train: a longer catch of the current car species replaces it" do
    club = create(:club)
    perch = create(:species, club: club)
    pike  = create(:species, club: club)
    user  = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, pike.id, perch.id])
    [perch, pike].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [10, 14].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: perch, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    active = CatchPlacement.where(tournament: t, active: true).includes(:catch)
    assert_equal 1, active.count
    assert_equal 14, active.first.catch.length_inches.to_i
    inactive = CatchPlacement.where(tournament: t, active: false)
    assert_equal 1, inactive.count, "expected the smaller perch placement to be deactivated"
  end

  test "fish_train: a same-or-shorter catch of the current car species is a no-op" do
    club = create(:club)
    perch = create(:species, club: club)
    pike  = create(:species, club: club)
    user  = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, pike.id, perch.id])
    [perch, pike].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: perch, length_inches: 14, captured_at_device: 30.minutes.ago)
    )
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: perch, length_inches: 14, captured_at_device: 25.minutes.ago)
    )
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: perch, length_inches: 10, captured_at_device: 20.minutes.ago)
    )

    active = CatchPlacement.where(tournament: t, active: true).includes(:catch).to_a
    assert_equal 1, active.size
    assert_equal 14, active.first.catch.length_inches.to_i
  end

  test "fish_train: catching the next car species advances and locks the previous car" do
    club = create(:club)
    perch = create(:species, club: club)
    pike  = create(:species, club: club)
    walleye = create(:species, club: club)
    user  = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, pike.id, walleye.id])
    [perch, pike, walleye].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: perch, length_inches: 12, captured_at_device: 30.minutes.ago)
    )
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: pike, length_inches: 22, captured_at_device: 25.minutes.ago)
    )

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1], active.map(&:slot_index)
    assert_equal perch, active[0].species
    assert_equal pike,  active[1].species
  end

  test "fish_train: catching a previously-locked car species is a no-op" do
    club = create(:club)
    perch = create(:species, club: club)
    pike  = create(:species, club: club)
    walleye = create(:species, club: club)
    user  = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, pike.id, walleye.id])
    [perch, pike, walleye].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: perch, length_inches: 12, captured_at_device: 30.minutes.ago)
    )
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: pike, length_inches: 22, captured_at_device: 25.minutes.ago)
    )
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: perch, length_inches: 30, captured_at_device: 20.minutes.ago)
    )

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1], active.map(&:slot_index), "perch car 0 stays locked at the previous length"
    assert_equal 12, active[0].catch.length_inches.to_i, "locked car length unchanged"
  end

  test "fish_train: a repeated species in the train opens a new car after walking through" do
    club = create(:club)
    perch   = create(:species, club: club)
    pike    = create(:species, club: club)
    walleye = create(:species, club: club)
    user    = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, pike.id, walleye.id, perch.id])
    [perch, pike, walleye].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [
      [perch,   12], [pike,    20], [walleye, 18], [perch, 16]
    ].each do |species, len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: species, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1, 2, 3], active.map(&:slot_index)
    assert_equal [perch, pike, walleye, perch], active.map(&:species)
    assert_equal [12, 20, 18, 16], active.map { |p| p.catch.length_inches.to_i }
  end

  test "fish_train: catch of an off-pool species is a no-op" do
    club = create(:club)
    perch = create(:species, club: club)
    pike  = create(:species, club: club)
    off_pool = create(:species, club: club)
    user  = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, pike.id, perch.id])
    [perch, pike].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: off_pool, length_inches: 30,
                    captured_at_device: 30.minutes.ago)
    )

    assert_equal 0, CatchPlacement.where(tournament: t).count
  end

  test "fish_train: improving the last (final) car works indefinitely (no implicit end-of-train lock)" do
    club = create(:club)
    perch = create(:species, club: club)
    pike  = create(:species, club: club)
    user  = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, pike.id, perch.id])
    [perch, pike].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [
      [perch, 10], [pike, 22], [perch, 12], [perch, 14], [perch, 18]
    ].each do |species, len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: species, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1, 2], active.map(&:slot_index)
    assert_equal 10, active[0].catch.length_inches.to_i, "car 0 locked at first perch"
    assert_equal 22, active[1].catch.length_inches.to_i, "car 1 locked at first pike"
    assert_equal 18, active[2].catch.length_inches.to_i, "car 2 (last car) keeps improving"
  end

  test "fish_train: consecutive same-species cars form a top-N group (W=14, W=22 fill both W slots)" do
    club = create(:club)
    perch   = create(:species, club: club)
    walleye = create(:species, club: club)
    user    = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, walleye.id, walleye.id])
    [perch, walleye].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [
      [perch,   10],
      [walleye, 14],
      [walleye, 22]
    ].each do |species, len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: species, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1, 2], active.map(&:slot_index), "all three slots filled (P group + 2-car W group)"
    assert_equal 14, active[1].catch.length_inches.to_i, "first W fills the first W slot"
    assert_equal 22, active[2].catch.length_inches.to_i, "second W fills the second W slot (not improve)"
  end

  test "fish_train: a bigger catch replaces the smallest in a full same-species group; survivor shifts down" do
    club = create(:club)
    perch   = create(:species, club: club)
    walleye = create(:species, club: club)
    user    = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, walleye.id, walleye.id])
    [perch, walleye].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    # State after first three catches: slots [P10, W14, W22].
    # Then W=23 bumps the smallest W (=14). Survivor W=22 shifts from slot 2
    # down to slot 1, and W=23 lands at slot 2 ("fill forward — newest highest").
    # Then W=18 is smaller than the new smallest (22), no-op.
    # Then W=22.5 bumps 22; W=23 shifts to slot 1, W=22.5 to slot 2.
    [
      [perch,   10],
      [walleye, 14],
      [walleye, 22],
      [walleye, 23],
      [walleye, 18],
      [walleye, 22.5]
    ].each do |species, len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: species, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1, 2], active.map(&:slot_index)
    assert_in_delta 10,   active[0].catch.length_inches.to_f
    assert_in_delta 23,   active[1].catch.length_inches.to_f, 0.01, "older survivor (23) in the lower W slot"
    assert_in_delta 22.5, active[2].catch.length_inches.to_f, 0.01, "newest survivor (22.5) in the highest W slot"
  end

  test "fish_train: catching the next group's species locks the previous group permanently" do
    club = create(:club)
    perch   = create(:species, club: club)
    walleye = create(:species, club: club)
    pike    = create(:species, club: club)
    user    = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, walleye.id, walleye.id, pike.id])
    [perch, walleye, pike].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    # Fill P + both W slots, then advance to pike. A later walleye should be
    # a no-op because the W group is now locked.
    [
      [perch,   10],
      [walleye, 14],
      [walleye, 22],
      [pike,    30],
      [walleye, 100]  # bigger than anything in the W group, but locked
    ].each do |species, len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: species, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1, 2, 3], active.map(&:slot_index)
    assert_equal 14, active[1].catch.length_inches.to_i, "W group locked — W=100 did not replace W=14"
    assert_equal 22, active[2].catch.length_inches.to_i, "W group locked — W=100 did not replace W=22"
    assert_equal 30, active[3].catch.length_inches.to_i, "pike advanced and locked the W group"
  end

  test "fish_train: full P→W→K→W→W walkthrough matches the score-maximizing top-N rule" do
    club = create(:club)
    perch   = create(:species, club: club)
    pike    = create(:species, club: club)
    walleye = create(:species, club: club)
    user    = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, walleye.id, pike.id, walleye.id, walleye.id])
    [perch, pike, walleye].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    # User's smoke-test catches: P14, W14, K14, W14, W28, W16
    # Expected with the group rule:
    #   - P14 fills P group (slot 0).
    #   - W14 advances to W-group-1, fills slot 1.
    #   - K14 advances to K group, fills slot 2.
    #   - W14 advances to W-group-2 (slots 3 and 4), fills slot 3.
    #   - W28 fills empty slot 4. State: slot 3=14, slot 4=28.
    #   - W16 bumps smallest (W=14). Survivor W=28 shifts slot 4→3. W=16 lands at slot 4.
    [
      [perch,   14],
      [walleye, 14],
      [pike,    14],
      [walleye, 14],
      [walleye, 28],
      [walleye, 16]
    ].each do |species, len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: species, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1, 2, 3, 4], active.map(&:slot_index), "all 5 cars filled"
    assert_equal [14, 14, 14, 28, 16], active.map { |p| p.catch.length_inches.to_i }
    sum = active.sum { |p| p.catch.length_inches.to_i }
    assert_equal 86, sum, "score = 14+14+14+28+16 (top 2 of {14, 28, 16} placed in W-group-2)"
  end

  test "fish_train: 3-car same-species group, judge DQ + refill + bump exercises survivors crossing paths" do
    club = create(:club)
    walleye = create(:species, club: club)
    user    = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [walleye.id, walleye.id, walleye.id])
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    # Through normal fills+bumps the invariant "older survivor at lower slot"
    # holds, so survivors never need to cross paths during a shift. Judge DQs
    # break that invariant: a refill into a low slot can be NEWER than the
    # survivor at a higher slot. The next bump then needs to swap their slots.
    #
    # Sequence:
    #   1. W=20 → slot 0  (oldest)
    #   2. W=14 → slot 1  (smallest, middle)
    #   3. W=30 → slot 2  (newest at this point)
    #   4. Judge DQs slot 0's placement.        State: slot 1=W14, slot 2=W30.
    #   5. W=25 fills empty slot 0.             State: slot 0=W25, slot 1=W14, slot 2=W30.
    #      Now created_at order: W14 (oldest) < W30 < W25 (newest).
    #      But by slot:          slot 0=W25 (newest), slot 2=W30 (mid), slot 1=W14 (oldest).
    #   6. W=50 bumps W=14 (smallest, slot 1). Survivors are W30 (slot 2, older
    #      than W25) and W25 (slot 0, newest). After sorting by created_at:
    #        [W30 (older, slot 2), W25 (newer, slot 0)] → targets [0, 1].
    #        W30 must move 2→0; W25 must move 0→1. They cross.
    #      Single-pass shift would violate idx_active_placements_uniq_per_slot
    #      when W30 tries to write slot 0 while W25 still occupies it.
    [20, 14, 30].each do |len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: walleye, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end
    CatchPlacement.where(tournament: t, slot_index: 0, active: true).sole.update!(active: false)
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: walleye, length_inches: 25,
                    captured_at_device: 30.minutes.ago)
    )
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: walleye, length_inches: 50,
                    captured_at_device: 30.minutes.ago)
    )

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 1, 2], active.map(&:slot_index), "all three slots filled after crossed-path shift"
    assert_equal [30, 25, 50], active.map { |p| p.catch.length_inches.to_i },
                 "W30 (older survivor) lands at slot 0, W25 at slot 1, new W50 at slot 2"
  end

  test "fish_train: judge DQ in a past group leaves a permanent hole; later same-species catch no-ops" do
    club = create(:club)
    perch   = create(:species, club: club)
    walleye = create(:species, club: club)
    pike    = create(:species, club: club)
    user    = create(:user, club: club)
    t = build(:tournament, club: club, format: :fish_train, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
              train_cars: [perch.id, walleye.id, pike.id])
    [perch, walleye, pike].each { |s| t.scoring_slots.build(species: s, slot_count: 1) }
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    # Fill all 3 cars, then DQ the middle (W) placement and try to refill.
    [[perch, 10], [walleye, 20], [pike, 30]].each do |species, len|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: species, length_inches: len,
                      captured_at_device: 30.minutes.ago)
      )
    end
    w_placement = CatchPlacement.where(tournament: t, species: walleye, active: true).sole
    w_placement.update!(active: false)

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: walleye, length_inches: 25,
                    captured_at_device: 30.minutes.ago)
    )

    active = CatchPlacement.where(tournament: t, active: true).order(:slot_index).includes(:catch).to_a
    assert_equal [0, 2], active.map(&:slot_index),
                 "past-group DQ leaves a permanent hole — slot 1 is not re-filled"
    assert_equal [10, 30], active.map { |p| p.catch.length_inches.to_i }
  end

  test "tagged: every catch with a tag creates a fresh placement, no bumping" do
    club = create(:club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    %w[A0001 A0002 A0003].each do |tag|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: tagged, length_inches: 18.0,
                      tag_number: tag, captured_at_device: 30.minutes.ago)
      )
    end

    placements = CatchPlacement.where(tournament: t, active: true).order(:slot_index)
    assert_equal 3, placements.count
    assert_equal [0, 1, 2], placements.map(&:slot_index)
  end

  test "tagged: a catch placed after the draw earns no ticket" do
    club = create(:club)
    user = create(:user, club: club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    first = create(:catch, user: user, species: tagged, length_inches: 18.0,
                   tag_number: "A0001", captured_at_device: 2.hours.ago)
    PlaceInSlots.call(catch: first)
    ticket = CatchPlacement.find_by!(tournament: t, catch: first, active: true)
    t.update_columns(drawn_winning_placement_id: ticket.id, drawn_at: Time.current)
    ticket.update_column(:in_draw_pool, true)

    late = create(:catch, user: user, species: tagged, length_inches: 17.0,
                  tag_number: "A0002", captured_at_device: 90.minutes.ago)
    result = PlaceInSlots.call(catch: late)

    assert_equal 0, CatchPlacement.where(tournament: t, catch: late).count
    assert_empty result[:affected_tournaments]
  end

  test "tagged: a catch re-placed after the draw keeps its ticket" do
    club = create(:club)
    user = create(:user, club: club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    fish = create(:catch, user: user, species: tagged, length_inches: 18.0,
                  tag_number: "A0001", captured_at_device: 2.hours.ago)
    PlaceInSlots.call(catch: fish)
    ticket = CatchPlacement.find_by!(tournament: t, catch: fish, active: true)
    t.update_columns(drawn_winning_placement_id: ticket.id, drawn_at: Time.current)
    ticket.update_column(:in_draw_pool, true)

    # The judge flows deactivate before re-placing (correction, DQ -> reinstate).
    ticket.update!(active: false)
    result = PlaceInSlots.call(catch: fish)

    reissued = CatchPlacement.find_by!(tournament: t, catch: fish, active: true)
    assert_equal 1, CatchPlacement.where(tournament: t, catch: fish, active: true).count,
                 "a fish that was in the draw keeps a ticket after a post-draw re-placement"
    assert reissued.in_draw_pool, "the re-issued ticket inherits the fish's place in the pool"
    assert_equal reissued.id, t.reload.drawn_winning_placement_id,
                 "the recorded winner follows the re-issued row wherever the re-placement came from"
    assert_equal [t], result[:affected_tournaments]
  end

  test "tagged: the draw state is read from the DB under the lock, not from the handed-in row" do
    club = create(:club)
    user = create(:user, club: club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    late = create(:catch, user: user, species: tagged, length_inches: 17.0,
                  tag_number: "A0002", captured_at_device: 90.minutes.ago)
    # The caller resolved its rows before a draw committed elsewhere: the
    # in-memory tournament still says undrawn while the DB says drawn.
    stale_rows = Tournaments::ActiveForUser.with_entries(user: user, at: late.captured_at_device)
    assert_nil stale_rows.first[:tournament].drawn_at
    t.update_columns(drawn_at: Time.current)

    result = PlaceInSlots.call(catch: late, rows: stale_rows)

    assert_empty result[:created], "a stale undrawn row must not mint a ticket into a drawn pool"
    assert_equal 0, CatchPlacement.where(tournament: t, catch: late).count
  end

  test "tagged: the draw state is read with a key-share lock on the tournament, after the entry lock, in one query" do
    club = create(:club)
    user = create(:user, club: club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    fish = create(:catch, user: user, species: tagged, length_inches: 18.0,
                  tag_number: "A0001", captured_at_device: 2.hours.ago)

    sql_log = []
    probe = ->(_name, _start, _finish, _id, payload) { sql_log << payload[:sql].to_s }
    ActiveSupport::Notifications.subscribed(probe, "sql.active_record") do
      PlaceInSlots.call(catch: fish, broadcast: false)
    end

    entry_lock = sql_log.index { |sql| sql.include?('"tournament_entries"') && sql.include?("FOR UPDATE") }
    tournament_reads = sql_log.each_index.select { |i| sql_log[i].match?(/SELECT .*FROM "tournaments"/) && sql_log[i].include?("drawn_at") }
    assert entry_lock, "the entry lock must be taken"
    assert_equal 1, tournament_reads.size, "one query decides drawn + in-pool, not a pick and an exists"
    assert tournament_reads.first > entry_lock, "the tournament row is locked after the entry, never before"
    assert_includes sql_log[tournament_reads.first], "FOR KEY SHARE",
                    "the read must conflict with the draw's FOR UPDATE so a ticket can't slip between its snapshot and stamp"
    assert_equal 1, CatchPlacement.where(tournament: t, catch: fish, active: true).count
  end

  test "tagged: re-placing a non-winning fish after the draw leaves the recorded winner alone" do
    club = create(:club)
    user = create(:user, club: club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    winner = create(:catch, user: user, species: tagged, length_inches: 18.0,
                    tag_number: "A0001", captured_at_device: 2.hours.ago)
    other = create(:catch, user: user, species: tagged, length_inches: 17.0,
                   tag_number: "A0002", captured_at_device: 100.minutes.ago)
    PlaceInSlots.call(catch: winner)
    PlaceInSlots.call(catch: other)
    winning_ticket = CatchPlacement.find_by!(tournament: t, catch: winner, active: true)
    CatchPlacement.where(tournament: t).update_all(in_draw_pool: true)
    t.update_columns(drawn_winning_placement_id: winning_ticket.id, drawn_at: Time.current)

    CatchPlacement.where(tournament: t, catch: other).deactivate_all
    PlaceInSlots.call(catch: other)

    assert_equal winning_ticket.id, t.reload.drawn_winning_placement_id
  end

  test "tagged: a fish whose ticket was pulled before the draw earns no ticket after it" do
    club = create(:club)
    user = create(:user, club: club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    fish = create(:catch, user: user, species: tagged, length_inches: 18.0,
                  tag_number: "A0001", captured_at_device: 2.hours.ago)
    PlaceInSlots.call(catch: fish)
    ticket = CatchPlacement.find_by!(tournament: t, catch: fish, active: true)

    # Pulled from the pool (a DQ) BEFORE the draw ran: the row exists, but the
    # draw never stamped it. A later write to the retired row (a backfill, a
    # touch) must not change that: pool membership is a recorded fact, not a
    # timestamp comparison.
    CatchPlacement.where(id: ticket.id).deactivate_all
    t.update_columns(drawn_winning_placement_id: nil, drawn_at: 30.minutes.ago)
    ticket.update_column(:updated_at, Time.current)

    result = PlaceInSlots.call(catch: fish)

    assert_equal 0, CatchPlacement.where(tournament: t, catch: fish, active: true).count,
                 "a fish that was out of the pool when the winner was drawn must not get a ticket now"
    assert_empty result[:affected_tournaments]
    assert_equal [t.id], result[:withheld]
    # The member's own submission path reads nothing off the result, so the
    # catch itself must say it earned no ticket: a member-visible flag.
    assert_includes fish.reload.flags, "no_draw_ticket"
    assert_not fish.needs_review?, "an informational flag, not a review trigger"

    PlaceInSlots.call(catch: fish)
    assert_equal 1, fish.reload.flags.count("no_draw_ticket"), "add_flag! is idempotent across re-runs"
  end

  test "tagged: new catch after a placement is deactivated does not collide on slot_index" do
    club = create(:club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    %w[A0001 A0002].each do |tag|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: user, species: tagged, length_inches: 18.0,
                      tag_number: tag, captured_at_device: 30.minutes.ago)
      )
    end

    # Judge DQ on slot_index 0:
    CatchPlacement.where(tournament: t, slot_index: 0).update_all(active: false)

    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: tagged, length_inches: 18.0,
                    tag_number: "A0003", captured_at_device: 5.minutes.ago)
    )

    # The new placement must take slot_index 2 (max+1), not 0 (which would
    # violate idx_active_placements_uniq_per_slot once the DQ is reversed).
    assert_equal [1, 2], CatchPlacement.where(tournament: t, active: true).pluck(:slot_index).sort
  end

  test "smallest_fish: a smaller catch bumps the largest active placement once the basket is full" do
    t = create(:tournament, club: @club, format: :smallest_fish, mode: :solo, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: t, species: @walleye, slot_count: 2)
    entry = create(:tournament_entry, tournament: t)
    angler = create(:user, club: @club)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)

    # Fill the 2 slots with 14 and 12.
    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 14))
    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 12))

    # A smaller 10 should bump the largest (14), leaving {12, 10}.
    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 10))

    active = CatchPlacement.active.where(tournament_entry: entry).includes(:catch)
    assert_equal [10, 12], active.map { |p| p.catch.length_inches.to_i }.sort
  end

  test "smallest_fish: a larger catch is ignored once the basket is full" do
    t = create(:tournament, club: @club, format: :smallest_fish, mode: :solo, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: t, species: @walleye, slot_count: 2)
    entry = create(:tournament_entry, tournament: t)
    angler = create(:user, club: @club)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)

    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 14))
    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 12))

    # A bigger 20 must not displace anything.
    result = PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 20))

    assert_empty result[:created]
    active = CatchPlacement.active.where(tournament_entry: entry).includes(:catch)
    assert_equal [12, 14], active.map { |p| p.catch.length_inches.to_i }.sort
  end

  test "smallest_fish: fills empty slots before any bumping (same as standard)" do
    t = create(:tournament, club: @club, format: :smallest_fish, mode: :solo, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: t, species: @walleye, slot_count: 2)
    entry = create(:tournament_entry, tournament: t)
    angler = create(:user, club: @club)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)

    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 18))
    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 16))

    assert_equal [0, 1],
      CatchPlacement.where(tournament_entry: entry, active: true).order(:slot_index).pluck(:slot_index)
  end

  test "smallest_fish: a catch tying the largest is a no-op once the basket is full (first to set wins)" do
    t = create(:tournament, club: @club, format: :smallest_fish, mode: :solo, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: t, species: @walleye, slot_count: 2)
    entry = create(:tournament_entry, tournament: t)
    angler = create(:user, club: @club)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)

    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 14))
    PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 12))

    # A new catch equal to the current largest (14) must not bump it.
    result = PlaceInSlots.call(catch: create(:catch, user: angler, species: @walleye, length_inches: 14))

    assert_empty result[:created]
    active = CatchPlacement.active.where(tournament_entry: entry).includes(:catch)
    assert_equal [12, 14], active.map { |p| p.catch.length_inches.to_i }.sort
  end

  test "override_in_sask lets an out-of-province catch place" do
    club = create(:club)
    walleye = create(:species, club: club)
    t = create(:tournament, club: club, local: true, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: t, species: walleye, slot_count: 1)
    angler = create(:user, club: club)
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)

    c = create(:catch, user: angler, species: walleye, length_inches: 22,
                       latitude: 49.9, longitude: -97.1, # outside SK and lake
                       override_in_sask: true, override_in_lake: true)
    Catches::PlaceInSlots.call(catch: c)
    assert_equal 1, c.catch_placements.active.count
  end

  test "progressive_length: logging climbing fish builds a ladder" do
    club = create(:club)
    walleye = Species.find_or_create_by!(name: "Walleye")
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :progressive_length, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [[12, 120], [9, 100], [15, 80]].each do |len, mins|
      c = create(:catch, user: user, species: walleye, length_inches: len,
                         captured_at_device: mins.minutes.ago, status: :synced)
      Catches::PlaceInSlots.call(catch: c)
    end

    rungs = entry.catch_placements.where(active: true).order(:slot_index)
                 .map { |p| p.catch.length_inches.to_i }
    assert_equal [12, 15], rungs
  end

  test "progressive_length: does not run the per-species active_placements query it never reads" do
    club = create(:club)
    walleye = Species.find_or_create_by!(name: "Walleye")
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :progressive_length, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    c = create(:catch, user: user, species: walleye, length_inches: 15,
                       captured_at_device: 120.minutes.ago, status: :synced)

    # ReconcileProgressiveLength re-derives the ladder itself, so the eager
    # active_placements load (ordered by slot_index) is thrown away for this
    # format — it must not run at all.
    queries = count_queries(/FROM .?catch_placements.?.*ORDER BY.*slot_index/im) do
      Catches::PlaceInSlots.call(catch: c, broadcast: false)
    end
    assert_equal 0, queries, "progressive_length must not run the unused active_placements query"
  end

  test "progressive_length: a no-op catch does not mark the tournament affected" do
    club = create(:club)
    walleye = Species.find_or_create_by!(name: "Walleye")
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :progressive_length, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    first = create(:catch, user: user, species: walleye, length_inches: 15,
                           captured_at_device: 120.minutes.ago, status: :synced)
    Catches::PlaceInSlots.call(catch: first)

    dink = create(:catch, user: user, species: walleye, length_inches: 10,
                          captured_at_device: 60.minutes.ago, status: :synced)
    result = Catches::PlaceInSlots.call(catch: dink)

    assert_empty result[:created]
    assert_empty result[:bumped]
    assert_empty result[:affected_tournaments]
  end

  test "re-running PlaceInSlots for an already-placed catch is a no-op (dedup race guard)" do
    catch_record = create(:catch, user: @user, species: @walleye, length_inches: 20)

    first = Catches::PlaceInSlots.call(catch: catch_record)
    assert_equal 1, first[:created].size

    assert_no_difference "CatchPlacement.count" do
      second = Catches::PlaceInSlots.call(catch: catch_record)
      assert_empty second[:created]
    end
  end

  test "re-running PlaceInSlots for an already-placed hidden_length catch is a no-op (dedup race guard)" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :hidden_length, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    catch_record = create(:catch, user: user, species: walleye, length_inches: 20,
                                   captured_at_device: 30.minutes.ago)

    first = Catches::PlaceInSlots.call(catch: catch_record)
    assert_equal 1, first[:created].size

    assert_no_difference "CatchPlacement.count" do
      second = Catches::PlaceInSlots.call(catch: catch_record)
      assert_empty second[:created]
    end
  end

  test "random_bag: every catch creates a placement, no bumping" do
    club = create(:club)
    walleye = create(:species, club: club)
    user = create(:user, club: club)
    t = build(:tournament, club: club, format: :random_bag, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)

    [15, 16, 17].each do |len|
      c = create(:catch, user: user, species: walleye, length_inches: len,
                 captured_at_device: 30.minutes.ago)
      Catches::PlaceInSlots.call(catch: c, broadcast: false)
    end

    active = entry.catch_placements.where(active: true)
    assert_equal 3, active.count, "no bumping — all three fish are kept"
    assert_equal [0, 1, 2], active.order(:slot_index).pluck(:slot_index)
  end

  test "tournaments: scope with one tournament places only into that tournament" do
    other = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: other, species: @walleye, slot_count: 2)
    other_entry = create(:tournament_entry, tournament: other)
    create(:tournament_entry_member, tournament_entry: other_entry, user: @user)

    catch_record = create(:catch, user: @user, species: @walleye, length_inches: 20)
    PlaceInSlots.call(catch: catch_record, tournaments: [@tournament])

    assert_equal [@tournament.id], catch_record.catch_placements.pluck(:tournament_id),
                 "scoped call must not place into the other overlapping tournament"
  end

  test "tournaments: scope places into exactly the listed tournaments" do
    other = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: other, species: @walleye, slot_count: 2)
    other_entry = create(:tournament_entry, tournament: other)
    create(:tournament_entry_member, tournament_entry: other_entry, user: @user)
    third = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: third, species: @walleye, slot_count: 2)
    third_entry = create(:tournament_entry, tournament: third)
    create(:tournament_entry_member, tournament_entry: third_entry, user: @user)

    catch_record = create(:catch, user: @user, species: @walleye, length_inches: 20)
    PlaceInSlots.call(catch: catch_record, tournaments: [@tournament, third])

    assert_equal [@tournament.id, third.id].sort, catch_record.catch_placements.pluck(:tournament_id).sort
  end

  test "tournaments: with an empty list places nowhere" do
    catch_record = create(:catch, user: @user, species: @walleye, length_inches: 20)
    PlaceInSlots.call(catch: catch_record, tournaments: [])
    assert_equal 0, catch_record.catch_placements.count
  end

  end
end
