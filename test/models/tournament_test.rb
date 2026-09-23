require "test_helper"

class TournamentTest < ActiveSupport::TestCase
  setup { @club = create(:club) }

  test "requires name, mode, starts_at" do
    assert_not Tournament.new(club: @club).valid?
  end

  test "ends_at is required and must be after starts_at" do
    {
      "missing ends_at"          => { ends_at: nil },
      "ends_at before starts_at" => { starts_at: 1.hour.from_now, ends_at: 1.hour.ago }
    }.each do |label, attrs|
      t = build(:tournament, club: @club, **attrs)
      assert_not t.valid?, "#{label} should be invalid"
      assert t.errors[:ends_at].any?, "#{label} should flag ends_at"
    end
  end

  test "active? and ended? follow the tournament window" do
    {
      "now inside the window"    => [1.hour.ago,      1.hour.from_now,  true,  false],
      "started, no ends_at"      => [1.day.ago,       nil,              true,  false],
      "not started yet"          => [1.hour.from_now, 5.hours.from_now, false, false],
      "ends_at in the past"      => [2.days.ago,      1.hour.ago,       false, true]
    }.each do |label, (starts_at, ends_at, active, ended)|
      t = build(:tournament, club: @club, starts_at: starts_at, ends_at: ends_at)
      assert_equal active, t.active?, "#{label}: active?"
      assert_equal ended, t.ended?, "#{label}: ended?"
    end
  end

  test "friendly? and judged? are opposites and default to friendly" do
    {
      "default"    => [{}, true, false],
      "judged: true" => [{ judged: true }, false, true]
    }.each do |label, (attrs, friendly, judged)|
      t = create(:tournament, club: @club, **attrs)
      assert_equal friendly, t.friendly?, "#{label}: friendly?"
      assert_equal judged, t.judged?, "#{label}: judged?"
    end
  end

  test "blind? is true only while a blind-leaderboard tournament is running" do
    {
      "blind_leaderboard false"      => [false, 1.hour.ago,      1.hour.from_now,  nil,                 false],
      "blind and active"             => [true,  1.hour.ago,      1.hour.from_now,  nil,                 true],
      "blind but ended"              => [true,  2.hours.ago,     1.hour.ago,       nil,                 false],
      "blind but not started"        => [true,  1.hour.from_now, 5.hours.from_now, nil,                 false],
      "at: after the tournament ends" => [true, 1.hour.ago,      1.hour.from_now,  2.hours.from_now,    false],
      "at: mid-tournament"           => [true,  1.hour.ago,      1.hour.from_now,  30.minutes.from_now, true]
    }.each do |label, (blind, starts_at, ends_at, at, expected)|
      t = create(:tournament, club: @club, starts_at: starts_at, ends_at: ends_at,
                 blind_leaderboard: blind)
      actual = at.nil? ? t.blind? : t.blind?(at: at)
      assert_equal expected, actual, "#{label}: blind?"
    end
  end

  test "blind_leaderboard requires ends_at" do
    t = build(:tournament, club: @club, blind_leaderboard: true, ends_at: nil)
    assert_not t.valid?, "blind with no ends_at should be invalid"
    assert t.errors[:ends_at].any?, "blind with no ends_at should flag ends_at"

    valid = build(:tournament, club: @club, blind_leaderboard: true,
                  starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    assert valid.valid?, "blind with ends_at should be valid: #{valid.errors.full_messages.to_sentence}"
  end

  test "blind_leaderboard is locked once the tournament has started" do
    started = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                     blind_leaderboard: false)
    started.blind_leaderboard = true
    assert_not started.valid?, "started: blind_leaderboard change should be invalid"
    assert started.errors[:blind_leaderboard].any? { |e| e.include?("can't be changed") },
           "started: expected the can't-be-changed message"

    upcoming = create(:tournament, club: @club, starts_at: 1.hour.from_now, ends_at: 5.hours.from_now,
                      blind_leaderboard: false)
    upcoming.blind_leaderboard = true
    assert upcoming.valid?, "not started: blind_leaderboard change should be allowed"

    renamed = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                     blind_leaderboard: true)
    renamed.name = "Renamed mid-event"
    assert renamed.valid?, "unrelated attribute on a started tournament should not trip the lock"
  end

  test "big_fish_season requires solo mode and exactly one scoring slot" do
    {
      "solo with one species"  => [:solo, 1, nil, nil],
      "team mode"              => [:team, 1, :format, "Big Fish Season tournaments must be solo"],
      "solo with no species"   => [:solo, 0, :scoring_slots, "Big Fish Season tournaments must have exactly one species configured"],
      "solo with two species"  => [:solo, 2, :scoring_slots, "Big Fish Season tournaments must have exactly one species configured"]
    }.each do |label, (mode, species_count, attribute, message)|
      t = build(:tournament, club: @club, format: :big_fish_season, mode: mode)
      species_count.times { t.scoring_slots.build(species: create(:species), slot_count: 3) }

      if message
        assert_not t.valid?, "#{label} should be invalid"
        assert_includes t.errors[attribute], message, "#{label}: expected the #{attribute} message"
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.to_sentence}"
      end
    end
  end

  test "format is locked once the tournament has started" do
    species = create(:species)

    started = create(:tournament, club: @club, format: :standard, mode: :solo,
                     starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: started, species: species, slot_count: 1)
    started.format = :big_fish_season
    assert_not started.valid?, "started: format change should be invalid"
    assert_includes started.errors[:format], "can't be changed once the tournament has started",
                    "started: expected the locked message"

    upcoming = create(:tournament, club: @club, format: :standard, mode: :solo,
                      starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    create(:scoring_slot, tournament: upcoming, species: species, slot_count: 1)
    upcoming.format = :big_fish_season
    assert upcoming.valid?, "not started: format change should be allowed: #{upcoming.errors.full_messages.to_sentence}"
  end

  test "scoring slots are locked once the tournament has started" do
    species = create(:species)
    other   = create(:species)

    {
      "changing a slot's quantity" => ->(slot) { [{ id: slot.id, species_id: species.id, slot_count: 5 }] },
      "removing a slot"            => ->(slot) { [{ id: slot.id, _destroy: "1" }] },
      "adding a slot"              => ->(_slot) { [{ species_id: other.id, slot_count: 1 }] }
    }.each do |label, edit|
      t = create(:tournament, club: @club, format: :standard, mode: :solo,
                 starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      slot = create(:scoring_slot, tournament: t, species: species, slot_count: 2)
      t.reload
      t.scoring_slots_attributes = edit.call(slot)
      assert_not t.valid?, "#{label} after the start should be invalid"
      assert_includes t.errors[:scoring_slots], "can't be changed once the tournament has started",
                      "#{label}: expected the locked message"
    end

    upcoming = create(:tournament, club: @club, format: :standard, mode: :solo,
                      starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    upcoming_slot = create(:scoring_slot, tournament: upcoming, species: species, slot_count: 2)
    upcoming.reload
    upcoming.scoring_slots_attributes = [{ id: upcoming_slot.id, species_id: species.id, slot_count: 5 }]
    assert upcoming.valid?, "not started: slot changes should be allowed: #{upcoming.errors.full_messages.to_sentence}"

    untouched = create(:tournament, club: @club, format: :standard, mode: :solo,
                       starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: untouched, species: species, slot_count: 2)
    untouched.reload
    untouched.name = "Renamed mid-tournament"
    assert untouched.valid?, "untouched slots: #{untouched.errors.full_messages.to_sentence}"
    assert untouched.save, "a started tournament with untouched slots should still save"
  end

  test "hidden_length requires exactly one scoring slot and accepts either mode" do
    {
      "solo with one species" => [:solo, 1, nil],
      "team with one species" => [:team, 1, nil],
      "no species"            => [:solo, 0, "Hidden Length tournaments must have exactly one species configured"],
      "two species"           => [:solo, 2, "Hidden Length tournaments must have exactly one species configured"]
    }.each do |label, (mode, species_count, message)|
      t = build(:tournament, club: @club, format: :hidden_length, mode: mode,
                ends_at: 2.hours.from_now)
      species_count.times { t.scoring_slots.build(species: create(:species), slot_count: 1) }

      if message
        assert_not t.valid?, "#{label} should be invalid"
        assert_includes t.errors[:scoring_slots], message, "#{label}: expected the scoring_slots message"
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.inspect}"
        assert t.format_hidden_length?, "#{label}: format_hidden_length?"
      end
    end
  end

  test "hidden_length_target is locked once set" do
    walleye = create(:species, club: @club)
    t = build(:tournament, club: @club, format: :hidden_length, mode: :solo,
              ends_at: 2.hours.from_now, hidden_length_target: 17.25)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    t.hidden_length_target = 18.00
    assert_not t.valid?
    assert_includes t.errors[:hidden_length_target], "can't be changed once set"
  end

  test "hidden_length_target must be a quarter-inch step in [12.00, 22.00]" do
    walleye = create(:species, club: @club)
    base_attrs = { club: @club, format: :hidden_length, mode: :solo,
                   ends_at: 2.hours.from_now }

    [11.75, 22.25, 17.10].each do |bad|
      t = build(:tournament, **base_attrs, hidden_length_target: bad)
      t.scoring_slots.build(species: walleye, slot_count: 1)
      assert_not t.valid?, "expected #{bad} to be rejected"
      assert_includes t.errors[:hidden_length_target],
                      "must be a quarter-inch step between 12.00 and 22.00"
    end

    [12.00, 12.25, 17.50, 22.00].each do |good|
      t = build(:tournament, **base_attrs, hidden_length_target: good)
      t.scoring_slots.build(species: walleye, slot_count: 1)
      assert t.valid?, "expected #{good} to be accepted: #{t.errors.full_messages.inspect}"
    end
  end

  test "biggest_vs_smallest requires exactly one scoring slot and accepts either mode" do
    {
      "solo with one species" => [:solo, 1, nil],
      "team with one species" => [:team, 1, nil],
      "no species"            => [:solo, 0, "Biggest vs Smallest tournaments must have exactly one species configured"],
      "two species"           => [:solo, 2, "Biggest vs Smallest tournaments must have exactly one species configured"]
    }.each do |label, (mode, species_count, message)|
      t = build(:tournament, club: @club, format: :biggest_vs_smallest, mode: mode,
                ends_at: 2.hours.from_now)
      species_count.times { t.scoring_slots.build(species: create(:species), slot_count: 1) }

      if message
        assert_not t.valid?, "#{label} should be invalid"
        assert_includes t.errors[:scoring_slots], message, "#{label}: expected the scoring_slots message"
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.inspect}"
        assert t.format_biggest_vs_smallest?, "#{label}: format_biggest_vs_smallest?"
      end
    end
  end

  test "fish_train validates its species pool and its car list" do
    s1 = create(:species, club: @club)
    s2 = create(:species, club: @club)
    s3 = create(:species, club: @club)
    s4 = create(:species, club: @club)

    {
      "solo, 3 cars from a 1-species pool" => [:solo, [s1], [s1, s1, s1], nil, nil],
      "team mode"                          => [:team, [s1], [s1, s1, s1], nil, nil],
      "6 cars over a 3-species pool"       => [:solo, [s1, s2, s3], [s1, s2, s3, s1, s2, s3], nil, nil],
      "empty pool"                         => [:solo, [], [s1, s1, s1], :scoring_slots, "Fish Train tournaments must have between 1 and 3 species in the pool"],
      "4-species pool"                     => [:solo, [s1, s2, s3, s4], [s1, s2, s3], :scoring_slots, "Fish Train tournaments must have between 1 and 3 species in the pool"],
      "2-car train"                        => [:solo, [s1], [s1, s1], :train_cars, "Fish Train must have between 3 and 6 cars"],
      "7-car train"                        => [:solo, [s1], [s1, s1, s1, s1, s1, s1, s1], :train_cars, "Fish Train must have between 3 and 6 cars"],
      "car species off the pool"           => [:solo, [s1], [s1, s2, s1], :train_cars, "Fish Train cars must reference species in the pool"]
    }.each do |label, (mode, pool, cars, attribute, message)|
      t = build(:tournament, club: @club, format: :fish_train, mode: mode,
                ends_at: 2.hours.from_now, train_cars: cars.map(&:id))
      pool.each { |species| t.scoring_slots.build(species: species, slot_count: 1) }

      if message
        assert_not t.valid?, "#{label} should be invalid"
        assert_includes t.errors[attribute], message, "#{label}: expected the #{attribute} message"
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.inspect}"
        assert t.format_fish_train?, "#{label}: format_fish_train?"
      end
    end
  end

  test "train_cars are locked once the tournament has started" do
    species = create(:species, club: @club)

    started = build(:tournament, club: @club, format: :fish_train, mode: :solo,
                    starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                    train_cars: [species.id, species.id, species.id])
    started.scoring_slots.build(species: species, slot_count: 1)
    started.save!
    started.train_cars = [species.id] * 4
    assert_not started.valid?, "started: train_cars change should be invalid"
    assert_includes started.errors[:train_cars], "can't be changed once the tournament has started",
                    "started: expected the locked message"

    upcoming = build(:tournament, club: @club, format: :fish_train, mode: :solo,
                     starts_at: 1.hour.from_now, ends_at: 4.hours.from_now,
                     train_cars: [species.id, species.id, species.id])
    upcoming.scoring_slots.build(species: species, slot_count: 1)
    upcoming.save!
    upcoming.train_cars = [species.id] * 4
    assert upcoming.valid?, "not started: train_cars change should be allowed: #{upcoming.errors.full_messages.to_sentence}"
  end

  test "tagged requires solo mode and one Tagged Walleye scoring slot" do
    tagged_species = Species.find_or_create_by!(name: "Tagged Walleye")
    other_species  = create(:species, name: "Walleye Test #{SecureRandom.hex(2)}")

    {
      "solo with the Tagged Walleye slot" => [:solo, tagged_species, nil, nil],
      "team mode"                         => [:team, tagged_species, :format, "Tagged Walleye tournaments must be solo"],
      "slot for another species"          => [:solo, other_species, :scoring_slots, "Tagged Walleye tournaments must have exactly one scoring slot for the Tagged Walleye species"]
    }.each do |label, (mode, species, attribute, message)|
      t = build(:tournament, club: @club, format: :tagged, mode: mode,
                starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      t.scoring_slots.build(species: species, slot_count: 1)

      if message
        assert_not t.valid?, "#{label} should be invalid"
        assert_includes t.errors[attribute], message, "#{label}: expected the #{attribute} message"
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.to_sentence}"
      end
    end
  end

  test "smallest_fish is a valid format with per-species scoring slots" do
    club = create(:club)
    walleye = create(:species, club: club)
    t = build(:tournament, club: club, format: :smallest_fish,
              mode: :solo, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 3)

    assert t.valid?, t.errors.full_messages.to_sentence
    assert t.format_smallest_fish?
  end

  test "pro_walleye requires exactly one Walleye scoring slot" do
    club = create(:club)
    walleye = create(:species, name: "Walleye")
    pike = create(:species, name: "Pike")

    t = build(:tournament, club: club, format: :pro_walleye, mode: :team,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    assert_not t.valid?, "no slot => invalid"

    t.scoring_slots.build(species: pike, slot_count: 1)
    assert_not t.valid?, "wrong species => invalid"

    t = build(:tournament, club: club, format: :pro_walleye, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    assert t.valid?, t.errors.full_messages.to_sentence
  end

  test "pro_walleye forces the Walleye slot count to 5" do
    club = create(:club)
    walleye = create(:species, name: "Walleye")
    t = build(:tournament, club: club, format: :pro_walleye, mode: :team,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!
    assert_equal 5, t.scoring_slots.sole.slot_count
  end

  test "supports_forced_slot? only for slot-based formats where a forced placement is durable" do
    # Slot-based top-N / append-only formats: slot_index is a meaningful position
    # and no whole-basket re-derive silently reverts a manual force.
    %i[standard big_fish_season fish_train].each do |fmt|
      assert build(:tournament, club: @club, format: fmt).supports_forced_slot?,
             "#{fmt} should support forced slot placement"
    end
    # Re-derive-from-length formats (basket is derived, not positioned) and the
    # every-catch formats: a forced slot is meaningless and/or reverted.
    %i[hidden_length biggest_vs_smallest tagged smallest_fish pro_walleye].each do |fmt|
      assert_not build(:tournament, club: @club, format: fmt).supports_forced_slot?,
                 "#{fmt} should not support forced slot placement"
    end
  end

  test "progressive_length requires exactly one scoring slot in either mode" do
    walleye = Species.find_or_create_by!(name: "Walleye")
    pike = Species.find_or_create_by!(name: "Pike")

    {
      "solo with one species" => [:solo, [walleye], nil],
      "team with one species" => [:team, [walleye], nil],
      "two species"           => [:solo, [walleye, pike], "Progressive Length tournaments must have exactly one species configured"]
    }.each do |label, (mode, pool, message)|
      t = build(:tournament, club: @club, format: :progressive_length, mode: mode,
                starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
      pool.each { |species| t.scoring_slots.build(species: species, slot_count: 1) }

      if message
        assert_not t.valid?, "#{label} should be invalid"
        assert_includes t.errors[:scoring_slots], message, "#{label}: expected the scoring_slots message"
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.join(', ')}"
      end
    end
  end

  test "progressive_length forces slot_count to 1" do
    club = create(:club)
    walleye = Species.find_or_create_by!(name: "Walleye")

    t = build(:tournament, club: club, format: :progressive_length, mode: :team,
              starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 5)
    t.save!

    assert_equal 1, t.scoring_slots.first.slot_count
  end

  # The integers are what the DB stores: renumbering any of them silently
  # re-labels every existing tournament and template row.
  test "format enum integers are stable" do
    assert_equal({
      "standard" => 0, "big_fish_season" => 1, "hidden_length" => 2, "biggest_vs_smallest" => 3,
      "fish_train" => 4, "tagged" => 5, "smallest_fish" => 6, "pro_walleye" => 7, "bingo" => 8,
      "progressive_length" => 9, "beat_the_average" => 10, "random_bag" => 11
    }, Tournament.formats.to_hash, "Tournament.formats")

    assert_equal({
      "standard" => 0, "big_fish_season" => 1, "hidden_length" => 2, "biggest_vs_smallest" => 3,
      "fish_train" => 4, "tagged" => 5, "smallest_fish" => 6, "pro_walleye" => 7,
      "progressive_length" => 9, "beat_the_average" => 10
    }, TournamentTemplate.formats.to_hash, "TournamentTemplate.formats")
  end

  test "beat_the_average needs at least one species and forces a blind leaderboard" do
    {
      "solo with one species"  => [:solo, 1, nil],
      "team with two species"  => [:team, 2, nil],
      "no species"             => [:solo, 0, "Catch the Average tournaments must have at least one species configured"]
    }.each do |label, (mode, species_count, message)|
      t = build(:tournament, club: @club, format: :beat_the_average, mode: mode,
                starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, blind_leaderboard: false)
      species_count.times { t.scoring_slots.build(species: create(:species), slot_count: 1) }

      if message
        assert_not t.valid?, "#{label} should be invalid"
        assert_includes t.errors[:scoring_slots], message, "#{label}: expected the scoring_slots message"
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.to_sentence}"
        assert t.blind_leaderboard?, "#{label}: blind_leaderboard should be forced true"
      end
    end
  end

  test "random_bag validates its target range and species pool" do
    {
      "default range"     => [1, 70,    100,    nil, nil],
      "equal min and max" => [1, 85,    85,     nil, nil],
      "on-grid bounds"    => [1, 70.25, 100.75, nil, nil],
      "no species"        => [0, 70,    100,    :scoring_slots,     "at least one species"],
      "max below min"     => [1, 100,   70,     :target_max_inches, nil],
      "negative minimum"  => [1, -5,    100,    :target_min_inches, "must be at least 0"],
      "off-grid max"      => [1, 70,    100.10, :target_max_inches, "1/4-inch"],
      "off-grid min"      => [1, 70.1,  100,    :target_min_inches, "1/4-inch"]
    }.each do |label, (species_count, min, max, attribute, fragment)|
      t = build(:tournament, club: @club, format: :random_bag, blind_leaderboard: false,
                target_min_inches: min, target_max_inches: max)
      species_count.times { t.scoring_slots.build(species: create(:species), slot_count: 1) }

      if attribute
        assert_not t.valid?, "#{label} should be invalid"
        if fragment
          assert t.errors[attribute].any? { |m| m.include?(fragment) },
                 "#{label}: expected #{attribute} to mention #{fragment.inspect}"
        else
          assert t.errors[attribute].any?, "#{label}: expected an error on #{attribute}"
        end
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.to_sentence}"
        assert t.format_random_bag?, "#{label}: format_random_bag?"
        assert t.blind_leaderboard, "#{label}: blind should be forced true"
      end
    end
  end

  test "random_bag target range is locked once the tournament has started" do
    started = build(:tournament, club: @club, format: :random_bag,
                    starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    started.scoring_slots.build(species: create(:species), slot_count: 1)
    started.save!
    started.target_max_inches = started.target_max_inches.to_d + 10
    assert_not started.valid?, "started: target range change should be invalid"
    assert started.errors[:base].any? { |m| m.include?("Target range can't be changed") },
           "started: expected the locked message"

    upcoming = build(:tournament, club: @club, format: :random_bag,
                     starts_at: 1.hour.from_now, ends_at: 2.hours.from_now)
    upcoming.scoring_slots.build(species: create(:species), slot_count: 1)
    upcoming.save!
    upcoming.target_max_inches = upcoming.target_max_inches.to_d + 10
    assert upcoming.valid?, "not started: target range change should be allowed: #{upcoming.errors.full_messages.to_sentence}"
  end

  test "linked_tournaments returns the other tournaments in the group, never across clubs" do
    group = SecureRandom.uuid
    main = create(:tournament, club: @club, mode: :team, link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, link_group_id: group)
    unrelated = create(:tournament, club: @club, mode: :team)
    other_club = create(:tournament, club: create(:club), mode: :team, link_group_id: group)

    assert_equal [side], main.linked_tournaments, "main sees only its partner"
    assert_equal [main], side.linked_tournaments, "side sees only its partner"
    assert_empty unrelated.linked_tournaments, "a tournament with no link group sees nobody"
    assert_empty other_club.linked_tournaments, "the same link group in another club stays separate"
  end

  test "a solo tournament cannot be linked" do
    solo = build(:tournament, mode: :solo, link_group_id: SecureRandom.uuid)
    assert_not solo.valid?
    assert_includes solo.errors[:link_group_id], "is only available for team tournaments"
  end
end
