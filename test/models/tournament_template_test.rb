require "test_helper"

# TournamentTemplate carries its own copy of the format validations (it is not a
# shared concern with Tournament), so these mirror the Tournament model tests
# rather than duplicating them. The format enum integers for both classes are
# asserted once in TournamentTest#"format enum integers are stable".
class TournamentTemplateTest < ActiveSupport::TestCase
  setup { @club = create(:club) }

  test "scheduled? requires all three default fields" do
    t = create(:tournament_template, club: @club)
    assert_not t.scheduled?
    t.update!(default_weekday: 3, default_start_time: "19:00", default_end_time: "21:00")
    assert t.scheduled?
  end

  test "schedule validation rejects partial and inverted schedules" do
    {
      "weekday without times" => [{ default_weekday: 3 }, :base, "must all be set together"],
      "end time before start" => [{ default_weekday: 3, default_start_time: "21:00", default_end_time: "19:00" },
                                  :default_end_time, "after the start time"]
    }.each do |label, (attrs, attribute, fragment)|
      t = build(:tournament_template, club: @club, **attrs)
      assert_not t.valid?, "#{label} should be invalid"
      assert_includes t.errors[attribute].join, fragment, "#{label}: expected #{attribute} to mention #{fragment.inspect}"
    end
  end

  test "next_occurrence_at finds the next scheduled window" do
    Time.use_zone("Saskatchewan") do
      t = create(:tournament_template, club: @club,
                 default_weekday: 3, default_start_time: "19:00", default_end_time: "21:00")

      {
        "wednesday before the start time" => [Time.zone.local(2026, 5, 6, 12, 0),
                                              Time.zone.local(2026, 5, 6, 19, 0), Time.zone.local(2026, 5, 6, 21, 0)],
        "wednesday after the start time"  => [Time.zone.local(2026, 5, 6, 22, 0),
                                              Time.zone.local(2026, 5, 13, 19, 0), Time.zone.local(2026, 5, 13, 21, 0)],
        "a different weekday"             => [Time.zone.local(2026, 5, 4, 9, 0),
                                              Time.zone.local(2026, 5, 6, 19, 0), Time.zone.local(2026, 5, 6, 21, 0)]
      }.each do |label, (now, expected_starts, expected_ends)|
        starts, ends = t.next_occurrence_at(now: now)
        assert_equal expected_starts, starts, "#{label}: starts_at"
        assert_equal expected_ends, ends, "#{label}: ends_at"
      end

      assert_nil create(:tournament_template, club: @club).next_occurrence_at,
                 "an unscheduled template has no next occurrence"
    end
  end

  test "big_fish_season template requires solo mode and exactly one scoring slot" do
    {
      "solo with one species" => [:solo, 1, nil, nil],
      "team mode"             => [:team, 1, :format, "Big Fish Season tournaments must be solo"],
      "no species"            => [:solo, 0, :tournament_template_scoring_slots, "Big Fish Season tournaments must have exactly one species configured"],
      "two species"           => [:solo, 2, :tournament_template_scoring_slots, "Big Fish Season tournaments must have exactly one species configured"]
    }.each do |label, (mode, species_count, attribute, message)|
      t = build(:tournament_template, club: @club, format: :big_fish_season, mode: mode)
      species_count.times { t.tournament_template_scoring_slots.build(species: create(:species), slot_count: 3) }

      if message
        assert_not t.valid?, "#{label} should be invalid"
        assert_includes t.errors[attribute], message, "#{label}: expected the #{attribute} message"
      else
        assert t.valid?, "#{label} should be valid: #{t.errors.full_messages.to_sentence}"
      end
    end
  end

  test "hidden_length template requires exactly one scoring slot and accepts either mode" do
    {
      "solo with one species" => [:solo, 1, nil],
      "team with one species" => [:team, 1, nil],
      "no species"            => [:solo, 0, "Hidden Length tournaments must have exactly one species configured"],
      "two species"           => [:solo, 2, "Hidden Length tournaments must have exactly one species configured"]
    }.each do |label, (mode, species_count, message)|
      tpl = build(:tournament_template, club: @club, format: :hidden_length, mode: mode)
      species_count.times { tpl.tournament_template_scoring_slots.build(species: create(:species), slot_count: 1) }

      if message
        assert_not tpl.valid?, "#{label} should be invalid"
        assert_includes tpl.errors[:tournament_template_scoring_slots], message,
                        "#{label}: expected the scoring slots message"
      else
        assert tpl.valid?, "#{label} should be valid: #{tpl.errors.full_messages.inspect}"
        assert tpl.format_hidden_length?, "#{label}: format_hidden_length?"
      end
    end
  end

  test "biggest_vs_smallest template requires exactly one scoring slot and accepts either mode" do
    {
      "solo with one species" => [:solo, 1, nil],
      "team with one species" => [:team, 1, nil],
      "no species"            => [:solo, 0, "Biggest vs Smallest tournaments must have exactly one species configured"],
      "two species"           => [:solo, 2, "Biggest vs Smallest tournaments must have exactly one species configured"]
    }.each do |label, (mode, species_count, message)|
      tpl = build(:tournament_template, club: @club, format: :biggest_vs_smallest, mode: mode)
      species_count.times { tpl.tournament_template_scoring_slots.build(species: create(:species), slot_count: 1) }

      if message
        assert_not tpl.valid?, "#{label} should be invalid"
        assert_includes tpl.errors[:tournament_template_scoring_slots], message,
                        "#{label}: expected the scoring slots message"
      else
        assert tpl.valid?, "#{label} should be valid: #{tpl.errors.full_messages.inspect}"
        assert tpl.format_biggest_vs_smallest?, "#{label}: format_biggest_vs_smallest?"
      end
    end
  end

  test "fish_train template validates its species pool and its car list" do
    s1 = create(:species, club: @club)
    s2 = create(:species, club: @club)
    s3 = create(:species, club: @club)
    s4 = create(:species, club: @club)

    {
      "solo, 3 cars from a 1-species pool" => [:solo, [s1], [s1, s1, s1], nil, nil],
      "team, 6 cars over a 2-species pool" => [:team, [s1, s2], [s1, s2, s1, s2, s1, s2], nil, nil],
      "empty pool"                         => [:solo, [], [s1, s1, s1], :tournament_template_scoring_slots, "Fish Train tournaments must have between 1 and 3 species in the pool"],
      "4-species pool"                     => [:solo, [s1, s2, s3, s4], [s1, s2, s3], :tournament_template_scoring_slots, "Fish Train tournaments must have between 1 and 3 species in the pool"],
      "2-car train"                        => [:solo, [s1], [s1, s1], :train_cars, "Fish Train must have between 3 and 6 cars"],
      "7-car train"                        => [:solo, [s1], [s1, s1, s1, s1, s1, s1, s1], :train_cars, "Fish Train must have between 3 and 6 cars"],
      "car species off the pool"           => [:solo, [s1], [s1, s2, s1], :train_cars, "Fish Train cars must reference species in the pool"]
    }.each do |label, (mode, pool, cars, attribute, message)|
      tpl = build(:tournament_template, club: @club, format: :fish_train, mode: mode,
                  train_cars: cars.map(&:id))
      pool.each { |species| tpl.tournament_template_scoring_slots.build(species: species, slot_count: 1) }

      if message
        assert_not tpl.valid?, "#{label} should be invalid"
        assert_includes tpl.errors[attribute], message, "#{label}: expected the #{attribute} message"
      else
        assert tpl.valid?, "#{label} should be valid: #{tpl.errors.full_messages.inspect}"
        assert tpl.format_fish_train?, "#{label}: format_fish_train?"
      end
    end
  end

  test "tagged template requires solo mode and one Tagged Walleye scoring slot" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    other  = create(:species, name: "Walleye Test #{SecureRandom.hex(2)}")
    slot_error = "Tagged Walleye tournaments must have exactly one scoring slot for the Tagged Walleye species"

    {
      "solo with the Tagged Walleye slot" => [:solo, tagged, nil, nil],
      "team mode"                         => [:team, tagged, :format, "Tagged Walleye tournaments must be solo"],
      "slot for another species"          => [:solo, other, :tournament_template_scoring_slots, slot_error],
      "no scoring slot"                   => [:solo, nil, :tournament_template_scoring_slots, slot_error]
    }.each do |label, (mode, species, attribute, message)|
      tpl = build(:tournament_template, club: @club, format: :tagged, mode: mode)
      tpl.tournament_template_scoring_slots.build(species: species, slot_count: 1) if species

      if message
        assert_not tpl.valid?, "#{label} should be invalid"
        assert_includes tpl.errors[attribute], message, "#{label}: expected the #{attribute} message"
      else
        assert tpl.valid?, "#{label} should be valid: #{tpl.errors.full_messages.to_sentence}"
      end
    end
  end

  test "pro_walleye template requires one Walleye scoring slot" do
    club = create(:club)
    walleye = create(:species, name: "Walleye")
    tmpl = build(:tournament_template, club: club, format: :pro_walleye, mode: :team)
    assert_not tmpl.valid?
    tmpl.tournament_template_scoring_slots.build(species: walleye, slot_count: 5)
    assert tmpl.valid?, tmpl.errors.full_messages.to_sentence
  end

  test "pro_walleye template pins its scoring slot to the basket size" do
    walleye = create(:species, name: "Walleye")
    tmpl = build(:tournament_template, club: @club, format: :pro_walleye, mode: :team)
    # The slot_count field is "ignored" in the UI; whatever is entered, the basket
    # is a fixed 5 (matching Tournament#force_pro_walleye_slot_count).
    tmpl.tournament_template_scoring_slots.build(species: walleye, slot_count: 3)
    tmpl.save!
    assert_equal Catches::ProWalleye::BASKET_SIZE, tmpl.tournament_template_scoring_slots.first.slot_count
  end

  test "progressive_length template requires exactly one scoring slot" do
    walleye = Species.find_or_create_by!(name: "Walleye")
    pike    = Species.find_or_create_by!(name: "Pike")

    {
      "one species"  => [[walleye], nil],
      "two species"  => [[walleye, pike], "Progressive Length tournaments must have exactly one species configured"]
    }.each do |label, (pool, message)|
      tpl = build(:tournament_template, club: @club, format: :progressive_length, mode: :solo)
      pool.each { |species| tpl.tournament_template_scoring_slots.build(species: species, slot_count: 1) }

      if message
        assert_not tpl.valid?, "#{label} should be invalid"
        assert_includes tpl.errors[:tournament_template_scoring_slots], message,
                        "#{label}: expected the scoring slots message"
      else
        assert tpl.valid?, "#{label} should be valid: #{tpl.errors.full_messages.inspect}"
      end
    end
  end

  test "pairing is mirrored onto the partner and unpairing clears both sides" do
    club = create(:club)
    main = create(:tournament_template, club: club, name: "Main", mode: :team)
    side = create(:tournament_template, club: club, name: "Side", mode: :team)

    main.update!(paired_template: side)
    assert_equal side, main.reload.paired_template, "main points at side"
    assert_equal main, side.reload.paired_template, "the pairing is mirrored onto side"
    assert main.paired?, "main is paired?"

    main.update!(paired_template: nil)
    assert_nil main.reload.paired_template, "unpairing clears main"
    assert_nil side.reload.paired_template, "unpairing clears side too"
  end

  test "invalid pairing targets are rejected" do
    club = create(:club)
    taken_main = create(:tournament_template, club: club, name: "Taken Main", mode: :team)
    taken_side = create(:tournament_template, club: club, name: "Taken Side", mode: :team)
    taken_main.update!(paired_template: taken_side)
    other_club_template = create(:tournament_template, club: create(:club), mode: :team)

    {
      "itself"                     => [->(template) { template.id }, "can't be the same template"],
      "a template in another club" => [->(_template) { other_club_template.id }, "must belong to the same club"],
      "an already-paired template" => [->(_template) { taken_side.id }, "is already paired with another template"],
      "a template that is gone"    => [->(_template) { TournamentTemplate.maximum(:id).to_i + 1 }, "must exist"]
    }.each do |label, (target, message)|
      template = create(:tournament_template, club: club, mode: :team)
      template.paired_template_id = target.call(template)
      assert_not template.valid?, "pairing with #{label} should be invalid"
      assert_includes template.errors[:paired_template], message, "pairing with #{label}: expected the message"
    end
  end

  # A league night's two tournaments share a roster through a link group, which
  # Tournament allows on team mode only. Pairing two solo templates used to save
  # cleanly and then dead-end the scheduler on "Link group is only available for
  # team tournaments" at every submit, with no way back.
  test "two solo templates can't be paired" do
    club = create(:club)
    main = create(:tournament_template, club: club, name: "Local", mode: :solo)
    side = create(:tournament_template, club: club, name: "Travel", mode: :solo)

    main.paired_template = side

    assert_not main.valid?
    assert_includes main.errors[:mode], "must be team while paired with another template"
    assert_includes main.errors[:paired_template],
                    "must be a team template — league nights are team-mode only"
  end

  test "a team template can't pair with a solo one" do
    club = create(:club)
    main = create(:tournament_template, club: club, name: "Main", mode: :team)
    side = create(:tournament_template, club: club, name: "Side", mode: :solo)

    main.paired_template = side

    assert_not main.valid?
    assert_empty main.errors[:mode]
    assert_includes main.errors[:paired_template],
                    "must be a team template — league nights are team-mode only"
  end

  # The rule keeps applying after the pairing is made, or flipping a paired
  # template back to solo would quietly re-create the same dead end.
  test "a paired template can't be switched to solo" do
    club = create(:club)
    main = create(:tournament_template, club: club, name: "Main", mode: :team)
    side = create(:tournament_template, club: club, name: "Side", mode: :team)
    main.update!(paired_template: side)

    main.mode = :solo

    assert_not main.valid?
    assert_includes main.errors[:mode], "must be team while paired with another template"
    # And unpairing first is the way out.
    main.paired_template = nil
    assert main.valid?, main.errors.full_messages.inspect
  end

  test "destroying a template clears the partner's pairing" do
    club = create(:club)
    main = create(:tournament_template, club: club, name: "Main", mode: :team)
    side = create(:tournament_template, club: club, name: "Side", mode: :team)
    main.update!(paired_template: side)

    main.destroy

    assert_nil side.reload.paired_template_id
  end
end
