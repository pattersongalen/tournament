require "test_helper"

module TournamentTemplates
  class CloneTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
      @walleye = create(:species, club: @club)
      @template = create(:tournament_template, club: @club, name: "Monthly Walleye", mode: :solo)
      @template.tournament_template_scoring_slots.create!(species: @walleye, slot_count: 1)
    end

    test "clone copies template into a new tournament with given dates" do
      starts = 1.day.from_now
      ends   = 1.day.from_now + 4.hours
      tournament = Clone.call(template: @template, starts_at: starts, ends_at: ends)
      assert tournament.persisted?
      assert_equal "Monthly Walleye", tournament.name
      assert_equal 1, tournament.scoring_slots.count
      assert_equal @walleye, tournament.scoring_slots.first.species
      assert_in_delta starts, tournament.starts_at, 1
      assert_equal @template.id, tournament.template_source_id
    end

    test "carries awards_season_points and blind_leaderboard flags from template to tournament, true and false" do
      on = create(:tournament_template, club: @club, awards_season_points: true)
      tournament_on = Clone.call(template: on, starts_at: 1.day.from_now, ends_at: 1.day.from_now + 4.hours)
      assert tournament_on.awards_season_points?, "awards_season_points: true should carry over"

      off = create(:tournament_template, club: @club, awards_season_points: false)
      tournament_off = Clone.call(template: off, starts_at: 1.day.from_now, ends_at: 1.day.from_now + 4.hours)
      refute tournament_off.awards_season_points?, "awards_season_points: false should carry over"

      blind_on = create(:tournament_template, club: @club, blind_leaderboard: true)
      cloned_blind_on = TournamentTemplates::Clone.call(
        template: blind_on, starts_at: 1.hour.from_now, ends_at: 4.hours.from_now, name: "League Night"
      )
      assert cloned_blind_on.blind_leaderboard?, "blind_leaderboard: true should carry over"

      blind_off = create(:tournament_template, club: @club, blind_leaderboard: false)
      cloned_blind_off = TournamentTemplates::Clone.call(
        template: blind_off, starts_at: 1.hour.from_now, ends_at: 4.hours.from_now
      )
      assert_not cloned_blind_off.blind_leaderboard?, "blind_leaderboard: false should carry over"
    end

    test "clones template format (and its scoring slots) onto the new tournament" do
      cases = {
        "big_fish_season" => -> {
          template = build(:tournament_template, club: @club, format: :big_fish_season)
          template.tournament_template_scoring_slots.build(species: @walleye, slot_count: 3)
          template.save!
          template
        },
        "standard (default)" => -> {
          template = create(:tournament_template, club: @club)
          template.tournament_template_scoring_slots.create!(species: @walleye, slot_count: 1)
          template
        },
        "hidden_length" => -> {
          walleye = create(:species, club: @club)
          tpl = build(:tournament_template, club: @club, name: "Hidden Length Wed",
                      format: :hidden_length, mode: :solo)
          tpl.tournament_template_scoring_slots.build(species: walleye, slot_count: 1)
          tpl.save!
          tpl
        },
        "biggest_vs_smallest" => -> {
          walleye = create(:species, club: @club)
          tpl = build(:tournament_template, club: @club, name: "BvS Wed",
                      format: :biggest_vs_smallest, mode: :solo)
          tpl.tournament_template_scoring_slots.build(species: walleye, slot_count: 1)
          tpl.save!
          tpl
        }
      }

      cases.each do |label, build_template|
        template = build_template.call
        tournament = TournamentTemplates::Clone.call(
          template: template, starts_at: 1.day.from_now, ends_at: 2.days.from_now
        )

        assert tournament.persisted?, "#{label}: should persist"
        assert_equal template.format, tournament.format, "#{label}: format should carry over"
        assert_equal template.tournament_template_scoring_slots.count, tournament.scoring_slots.count,
                     "#{label}: scoring slot count should carry over"
        assert_equal template.tournament_template_scoring_slots.map(&:species_id).sort,
                     tournament.scoring_slots.map(&:species_id).sort,
                     "#{label}: scoring slot species should carry over"
      end
    end

    test "copies fish_train format and train_cars to the cloned tournament" do
      perch = create(:species, club: @club)
      pike  = create(:species, club: @club)
      tpl = build(:tournament_template, club: @club, name: "FT Wed",
                  format: :fish_train, mode: :solo,
                  train_cars: [perch.id, pike.id, perch.id])
      [perch, pike].each { |sp| tpl.tournament_template_scoring_slots.build(species: sp, slot_count: 1) }
      tpl.save!

      cloned = Clone.call(template: tpl,
                          starts_at: 1.day.from_now,
                          ends_at:   1.day.from_now + 4.hours)

      assert cloned.persisted?
      assert cloned.format_fish_train?
      assert_equal [perch.id, pike.id, perch.id], cloned.train_cars
      assert_equal 2, cloned.scoring_slots.count
    end

    test "clones a pro_walleye template into a valid tournament with a 5-count Walleye slot" do
      walleye = create(:species, club: @club, name: "Walleye")
      template = build(:tournament_template, club: @club, format: :pro_walleye, mode: :team)
      template.tournament_template_scoring_slots.build(species: walleye, slot_count: 5)
      template.save!

      t = TournamentTemplates::Clone.call(template: template, starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)

      assert t.persisted?
      assert t.format_pro_walleye?
      assert_equal walleye.id, t.scoring_slots.sole.species_id
      assert_equal 5, t.scoring_slots.sole.slot_count
    end
  end
end
