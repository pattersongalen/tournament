require "test_helper"

module Placements
  class DetectNotificationsTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
      @walleye = create(:species, club: @club)
      @t = create(:tournament, club: @club, mode: :team, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      create(:scoring_slot, tournament: @t, species: @walleye, slot_count: 1)

      # Joe and Ann share the same entry (team / boat scenario)
      @joe = create(:user, club: @club, name: "Joe")
      @ann = create(:user, club: @club, name: "Ann")
      @shared_entry = create(:tournament_entry, tournament: @t)
      create(:tournament_entry_member, tournament_entry: @shared_entry, user: @joe)
      create(:tournament_entry_member, tournament_entry: @shared_entry, user: @ann)
    end

    test "does not notify the submitter when their own catch bumps a teammate's placement on a shared entry" do
      first = create(:catch, user: @joe, species: @walleye, length_inches: 18)
      Catches::PlaceInSlots.call(catch: first)

      bigger = create(:catch, user: @ann, species: @walleye, length_inches: 22)
      result = Catches::PlaceInSlots.call(catch: bigger)

      payloads = DetectNotifications.call(result: result)
      ann_self_bump = payloads.find { |p| p[:reason] == "bumped" && p[:user] == @ann }
      assert_nil ann_self_bump, "submitter should not get a bumped push for displacing their own team's placement"
      joe_bump = payloads.find { |p| p[:reason] == "bumped" && p[:user] == @joe }
      assert joe_bump, "the actually-bumped teammate should still be notified"
    end

    test "does not notify the submitter when biggest_vs_smallest bumps the submitter's own previous extreme" do
      bvs = build(:tournament, club: @club, format: :biggest_vs_smallest, mode: :solo,
                  starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      bvs.scoring_slots.build(species: @walleye, slot_count: 1)
      bvs.save!
      entry = create(:tournament_entry, tournament: bvs)
      create(:tournament_entry_member, tournament_entry: entry, user: @joe)

      [22, 12].each do |len|
        Catches::PlaceInSlots.call(
          catch: create(:catch, user: @joe, species: @walleye, length_inches: len,
                        captured_at_device: 30.minutes.ago)
        )
      end

      result = Catches::PlaceInSlots.call(
        catch: create(:catch, user: @joe, species: @walleye, length_inches: 25,
                      captured_at_device: 25.minutes.ago)
      )

      payloads = DetectNotifications.call(result: result)
      self_bump = payloads.find { |p| p[:reason] == "bumped" && p[:user] == @joe && p[:tournament] == bvs }
      assert_nil self_bump, "BvS submitter should not be notified for bumping their own previous extreme"
    end

    test "produces a 'took the lead' notification when first place changes" do
      # Separate entry for lead-change detection: solo tournament
      solo_t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      create(:scoring_slot, tournament: solo_t, species: @walleye, slot_count: 1)

      joe_solo = create(:tournament_entry, tournament: solo_t)
      create(:tournament_entry_member, tournament_entry: joe_solo, user: @joe)
      ann_solo = create(:tournament_entry, tournament: solo_t)
      create(:tournament_entry_member, tournament_entry: ann_solo, user: @ann)

      first = create(:catch, user: @joe, species: @walleye, length_inches: 18)
      Catches::PlaceInSlots.call(catch: first)

      bigger = create(:catch, user: @ann, species: @walleye, length_inches: 22)
      result = Catches::PlaceInSlots.call(catch: bigger)

      payloads = DetectNotifications.call(result: result)
      lead = payloads.find { |p| p[:reason] == "took_the_lead" && p[:user] == @ann }
      assert lead, "expected a took_the_lead notification to Ann"
    end

    test "suppresses bumped notification when the affected tournament is blind+active" do
      @t.update_columns(blind_leaderboard: true)

      first = create(:catch, user: @joe, species: @walleye, length_inches: 18)
      Catches::PlaceInSlots.call(catch: first)

      bigger = create(:catch, user: @ann, species: @walleye, length_inches: 22)
      result = Catches::PlaceInSlots.call(catch: bigger)

      payloads = DetectNotifications.call(result: result)
      assert_empty payloads, "expected no notifications during a blind+active tournament"
    end

    test "does not suppress pushes for non-blind tournaments when user is also in a blind one" do
      blind_t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                       blind_leaderboard: true, mode: :solo)
      create(:scoring_slot, tournament: blind_t, species: @walleye, slot_count: 1)
      joe_blind = create(:tournament_entry, tournament: blind_t)
      create(:tournament_entry_member, tournament_entry: joe_blind, user: @joe)
      ann_blind = create(:tournament_entry, tournament: blind_t)
      create(:tournament_entry_member, tournament_entry: ann_blind, user: @ann)

      open_t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now, mode: :solo)
      create(:scoring_slot, tournament: open_t, species: @walleye, slot_count: 1)
      joe_open = create(:tournament_entry, tournament: open_t)
      create(:tournament_entry_member, tournament_entry: joe_open, user: @joe)
      ann_open = create(:tournament_entry, tournament: open_t)
      create(:tournament_entry_member, tournament_entry: ann_open, user: @ann)

      first = create(:catch, user: @joe, species: @walleye, length_inches: 18)
      Catches::PlaceInSlots.call(catch: first)

      bigger = create(:catch, user: @ann, species: @walleye, length_inches: 22)
      result = Catches::PlaceInSlots.call(catch: bigger)

      payloads = DetectNotifications.call(result: result)
      tournaments = payloads.map { |p| p[:tournament] }
      assert_includes tournaments, open_t,    "expected payloads for the non-blind tournament"
      assert_not_includes tournaments, blind_t, "expected no payloads for the blind tournament"
    end

    test "skips lead-change notifications for Hidden Length tournaments while target is unrevealed" do
      club = create(:club)
      walleye = create(:species, club: club)
      user = create(:user, club: club)
      t = build(:tournament, club: club, format: :hidden_length, mode: :solo,
                starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      t.scoring_slots.build(species: walleye, slot_count: 1)
      t.save!
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: user)

      caught = create(:catch, user: user, species: walleye, length_inches: 22,
                      captured_at_device: 30.minutes.ago)
      placement = CatchPlacement.create!(catch: caught, tournament: t,
                                         tournament_entry: entry, species: walleye,
                                         slot_index: 0, active: true)

      result = { created: [placement], bumped: [], affected_tournaments: [t] }
      payloads = DetectNotifications.call(result: result)
      assert_empty payloads.select { |p| p[:reason] == "took_the_lead" },
                   "Hidden Length pre-reveal should not push 'took the lead'"
    end

    test "still emits lead-change notifications after Hidden Length target is rolled" do
      club = create(:club)
      walleye = create(:species, club: club)
      user = create(:user, club: club)
      t = build(:tournament, club: club, format: :hidden_length, mode: :solo,
                starts_at: 2.hours.ago, ends_at: 1.minute.ago)
      t.scoring_slots.build(species: walleye, slot_count: 1)
      t.save!
      t.update!(hidden_length_target: BigDecimal("17.00"))
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: user)

      caught = create(:catch, user: user, species: walleye, length_inches: 17,
                      captured_at_device: 30.minutes.ago)
      placement = CatchPlacement.create!(catch: caught, tournament: t,
                                         tournament_entry: entry, species: walleye,
                                         slot_index: 0, active: true)

      result = { created: [placement], bumped: [], affected_tournaments: [t] }
      payloads = DetectNotifications.call(result: result)
      assert payloads.any? { |p| p[:reason] == "took_the_lead" && p[:user] == user },
             "post-reveal lead changes should still notify"
    end

    test "bingo: an angler who stamps a square and leads gets a took-the-lead push" do
      walleye, = create_bingo_species!
      t = create(:tournament, club: @club, mode: :solo, format: :bingo,
                 starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      alice = create(:user, club: @club, name: "Alice")
      bob = create(:user, club: @club, name: "Bob")
      ea = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: ea, user: alice)
      eb = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: eb, user: bob)

      result = Catches::PlaceInSlots.call(
        catch: create(:catch, user: alice, species: walleye, length_inches: 16,
                      captured_at_device: 30.minutes.ago, status: :synced)
      )

      payloads = DetectNotifications.call(result: result)
      lead = payloads.select { |p| p[:reason] == "took_the_lead" }
      assert_equal [alice], lead.map { |p| p[:user] }
      assert_equal "You took the lead!", lead.first[:body]
    end

    test "bingo: a stamping catch that does not take the lead does not push" do
      walleye, = create_bingo_species!
      t = create(:tournament, club: @club, mode: :solo, format: :bingo,
                 starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      alice = create(:user, club: @club, name: "Alice")
      bob = create(:user, club: @club, name: "Bob")
      ea = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: ea, user: alice)
      eb = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: eb, user: bob)

      # Alice establishes a dominating lead with two walleye (Bob's squares become
      # a strict subset of hers), so Bob's later catch stamps but can't lead.
      Catches::PlaceInSlots.call(catch: create(:catch, user: alice, species: walleye,
        length_inches: 16, captured_at_device: 40.minutes.ago, status: :synced))
      Catches::PlaceInSlots.call(catch: create(:catch, user: alice, species: walleye,
        length_inches: 16, captured_at_device: 38.minutes.ago, status: :synced))

      bob_result = Catches::PlaceInSlots.call(catch: create(:catch, user: bob, species: walleye,
        length_inches: 16, captured_at_device: 36.minutes.ago, status: :synced))

      payloads = DetectNotifications.call(result: bob_result)
      assert_empty payloads.select { |p| p[:reason] == "took_the_lead" },
                   "a stamping catch that doesn't take the lead must not push"
    end

    test "bingo: an established leader is not re-notified when they stamp another square" do
      walleye, = create_bingo_species!
      t = create(:tournament, club: @club, mode: :solo, format: :bingo,
                 starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      alice = create(:user, club: @club, name: "Alice")
      bob = create(:user, club: @club, name: "Bob")
      ea = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: ea, user: alice)
      eb = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: eb, user: bob)

      # Alice takes the lead with her first walleye.
      Catches::PlaceInSlots.call(catch: create(:catch, user: alice, species: walleye,
        length_inches: 16, captured_at_device: 40.minutes.ago, status: :synced))

      # Still comfortably ahead of empty-carded Bob, she stamps a NEW square
      # (her second walleye fills "Catch a second Walleye"). Holding the lead is
      # not taking it — no push.
      result = Catches::PlaceInSlots.call(catch: create(:catch, user: alice, species: walleye,
        length_inches: 16, captured_at_device: 38.minutes.ago, status: :synced))

      payloads = DetectNotifications.call(result: result)
      assert_empty payloads.select { |p| p[:reason] == "took_the_lead" },
                   "an angler who already leads must not be re-notified for holding the lead"
    end

    test "beat_the_average sends no took_the_lead push after the event ends (blind? no longer suppresses)" do
      club = create(:club)
      walleye = create(:species, club: club)
      user = create(:user, club: club)
      # Ended tournament: active? is false, so blind? is false and the line-38
      # reject no longer suppresses. A late offline sync must still not push.
      t = build(:tournament, club: club, format: :beat_the_average, mode: :solo,
                starts_at: 2.hours.ago, ends_at: 1.minute.ago)
      t.scoring_slots.build(species: walleye, slot_count: 1)
      t.save!
      assert_not t.blind?, "tournament should no longer be blind once ended"
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: user)

      caught = create(:catch, user: user, species: walleye, length_inches: 22,
                      captured_at_device: 30.minutes.ago)
      placement = CatchPlacement.create!(catch: caught, tournament: t,
                                         tournament_entry: entry, species: walleye,
                                         slot_index: 0, active: true)

      assert_equal entry.id, Leaderboards::Build.call(tournament: t).first&.dig(:entry)&.id

      result = { created: [placement], bumped: [], affected_tournaments: [t] }
      payloads = DetectNotifications.call(result: result)
      assert_empty payloads.select { |p| p[:reason] == "took_the_lead" },
                   "Beat the Average must not push a lead change after the event ends"
    end

    test "random_bag sends no took_the_lead push after the event ends (blind? no longer suppresses)" do
      club = create(:club)
      walleye = create(:species, club: club)
      user = create(:user, club: club)
      t = build(:tournament, club: club, format: :random_bag, mode: :solo,
                starts_at: 2.hours.ago, ends_at: 1.minute.ago,
                target_min_inches: 70, target_max_inches: 100)
      t.scoring_slots.build(species: walleye, slot_count: 1)
      t.save!
      assert_not t.blind?, "tournament should no longer be blind once ended"
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: user)

      caught = create(:catch, user: user, species: walleye, length_inches: 22,
                      captured_at_device: 30.minutes.ago)
      placement = CatchPlacement.create!(catch: caught, tournament: t,
                                         tournament_entry: entry, species: walleye,
                                         slot_index: 0, active: true)

      assert_equal entry.id, Leaderboards::Build.call(tournament: t).first&.dig(:entry)&.id

      result = { created: [placement], bumped: [], affected_tournaments: [t] }
      payloads = DetectNotifications.call(result: result)
      assert_empty payloads.select { |p| p[:reason] == "took_the_lead" },
                   "Random Bag must not push a lead change after the event ends"
    end

    test "progressive_length sends no bumped push when a rung falls off the ladder" do
      club = create(:club)
      walleye = Species.find_or_create_by!(name: "Walleye")
      angler = create(:user, club: club)
      teammate = create(:user, club: club)
      t = build(:tournament, club: club, format: :progressive_length, mode: :team,
                starts_at: 3.hours.ago, ends_at: 1.hour.from_now)
      t.scoring_slots.build(species: walleye, slot_count: 1)
      t.save!
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: angler)
      create(:tournament_entry_member, tournament_entry: entry, user: teammate)

      [[12, 120], [15, 60]].each do |len, mins|
        c = create(:catch, user: angler, species: walleye, length_inches: len,
                           captured_at_device: mins.minutes.ago, status: :synced)
        Catches::PlaceInSlots.call(catch: c, broadcast: false)
      end

      # A 20" captured between the 12" and the 15" knocks the 15" off the ladder.
      late = create(:catch, user: angler, species: walleye, length_inches: 20,
                            captured_at_device: 90.minutes.ago, status: :synced)
      result = Catches::PlaceInSlots.call(catch: late, broadcast: false)

      assert result[:bumped].any?, "expected the 15\" rung to be bumped"
      payloads = Placements::DetectNotifications.call(result: result)
      assert_empty payloads.select { |p| p[:reason] == "bumped" }
    end

    test "progressive_length sends no took_the_lead push when the sole entry climbs the ladder" do
      club = create(:club)
      walleye = Species.find_or_create_by!(name: "Walleye")
      angler = create(:user, club: club)
      t = build(:tournament, club: club, format: :progressive_length, mode: :solo,
                starts_at: 3.hours.ago, ends_at: 1.hour.from_now)
      t.scoring_slots.build(species: walleye, slot_count: 1)
      t.save!
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: angler)

      first = create(:catch, user: angler, species: walleye, length_inches: 12,
                             captured_at_device: 30.minutes.ago, status: :synced)
      Catches::PlaceInSlots.call(catch: first, broadcast: false)

      # 15" beats 12", adding a rung: the entry (the tournament's sole entry,
      # hence its leader) receives a created placement.
      climbing = create(:catch, user: angler, species: walleye, length_inches: 15,
                                captured_at_device: 20.minutes.ago, status: :synced)
      result = Catches::PlaceInSlots.call(catch: climbing, broadcast: false)

      assert result[:created].any?, "expected the 15\" rung to be a created placement"
      leaderboard = Leaderboards::Build.call(tournament: t)
      assert_equal entry.id, leaderboard.first&.dig(:entry)&.id, "expected the sole entry to be the leader"

      payloads = Placements::DetectNotifications.call(result: result)
      assert_empty payloads.select { |p| p[:reason] == "took_the_lead" },
                   "progressive_length should never push took_the_lead (a created placement doesn't imply a score increase)"
    end
  end
end
