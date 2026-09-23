require "test_helper"

class Organizers::TournamentTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    sign_in_as(@organizer)
  end

  test "POST clone creates a tournament" do
    walleye = create(:species, club: @club)
    template = create(:tournament_template, club: @club, name: "Monthly Walleye")
    template.tournament_template_scoring_slots.create!(species: walleye, slot_count: 1)

    assert_difference "Tournament.count", 1 do
      post clone_organizers_tournament_template_path(template),
           params: { starts_at: 1.day.from_now, ends_at: 1.day.from_now + 4.hours }
    end
    assert_redirected_to organizers_tournaments_path
  end

  test "create accepts season_tag, default_duration_days, awards_season_points, blind_leaderboard, and entrants_only_leaderboard together" do
    assert_difference -> { TournamentTemplate.count }, 1 do
      post organizers_tournament_templates_path, params: {
        tournament_template: {
          name: "Wednesday League", mode: "solo",
          season_tag: "2026", default_duration_days: 2,
          awards_season_points: "1", blind_leaderboard: "1", entrants_only_leaderboard: "1"
        }
      }
    end
    assert_redirected_to organizers_tournament_templates_path
    t = TournamentTemplate.last
    {
      season_tag: "2026",
      default_duration_days: 2,
      awards_season_points?: true,
      blind_leaderboard?: true,
      entrants_only_leaderboard?: true
    }.each do |attr, expected|
      assert_equal expected, t.public_send(attr), "#{attr}: should persist from a single submission"
    end
  end

  test "create accepts each format-specific permitted attribute" do
    walleye = create(:species, club: @club)
    perch   = create(:species, club: @club, name: "Perch")
    pike    = create(:species, club: @club, name: "Pike")

    {
      "big_fish_season" => {
        extra: { format: "big_fish_season",
                 tournament_template_scoring_slots_attributes: { "0" => { species_id: walleye.id, slot_count: 1 } } },
        check: ->(t) { assert t.format_big_fish_season?, "big_fish_season: format should persist" }
      },
      "hidden_length" => {
        extra: { format: "hidden_length",
                 tournament_template_scoring_slots_attributes: { "0" => { species_id: walleye.id, slot_count: 1 } } },
        check: ->(t) { assert t.format_hidden_length?, "hidden_length: format should persist" }
      },
      "biggest_vs_smallest" => {
        extra: { format: "biggest_vs_smallest",
                 tournament_template_scoring_slots_attributes: { "0" => { species_id: walleye.id, slot_count: 1 } } },
        check: ->(t) { assert t.format_biggest_vs_smallest?, "biggest_vs_smallest: format should persist" }
      },
      "fish_train" => {
        extra: { format: "fish_train", train_cars: [ perch.id.to_s, pike.id.to_s, perch.id.to_s ],
                 tournament_template_scoring_slots_attributes: {
                   "0" => { species_id: perch.id, slot_count: 1 },
                   "1" => { species_id: pike.id, slot_count: 1 }
                 } },
        check: ->(t) {
          assert t.format_fish_train?, "fish_train: format should persist"
          assert_equal [ perch.id, pike.id, perch.id ], t.train_cars, "fish_train: train_cars should persist"
        }
      }
    }.each do |label, spec|
      assert_difference -> { TournamentTemplate.count }, 1, "#{label}: should create a template" do
        post organizers_tournament_templates_path, params: {
          tournament_template: { name: "#{label} Monthly", mode: "solo" }.merge(spec[:extra])
        }
      end
      spec[:check].call(TournamentTemplate.order(:id).last)
    end
  end

  test "an organizer pairs two templates from the form" do
    main = create(:tournament_template, club: @club, name: "Wednesday Main", mode: :team)
    side = create(:tournament_template, club: @club, name: "Wednesday Side", mode: :team)

    patch organizers_tournament_template_path(main),
          params: { tournament_template: { name: main.name, paired_template_id: side.id } }

    assert_equal side, main.reload.paired_template
    assert_equal main, side.reload.paired_template
  end

  # Offering a solo template in the picker is an offer that can only end in a
  # validation failure: a league night's two tournaments share a roster through
  # a link group, and Tournament allows link groups on team mode only.
  test "the pairing picker offers team templates only" do
    main = create(:tournament_template, club: @club, name: "Wednesday Main", mode: :team)
    team_candidate = create(:tournament_template, club: @club, name: "Wednesday Side", mode: :team)
    solo_candidate = create(:tournament_template, club: @club, name: "Saturday Solo", mode: :solo)

    get edit_organizers_tournament_template_path(main)

    assert_response :success
    assert_select "select#tournament_template_paired_template_id option[value=?]",
                  team_candidate.id.to_s, 1
    assert_select "select#tournament_template_paired_template_id option[value=?]",
                  solo_candidate.id.to_s, 0
  end

  test "pairing two solo templates is rejected" do
    main = create(:tournament_template, club: @club, name: "Big Walleye Local", mode: :solo)
    side = create(:tournament_template, club: @club, name: "Big Walleye Travel", mode: :solo)

    patch organizers_tournament_template_path(main),
          params: { tournament_template: { name: main.name, paired_template_id: side.id } }

    assert_response :unprocessable_entity
    assert_nil main.reload.paired_template_id
    assert_nil side.reload.paired_template_id
    assert_match(/team template/, response.body)
  end

  test "pairing with a template from another club is rejected" do
    main = create(:tournament_template, club: @club, name: "Wednesday Main", mode: :team)
    foreign = create(:tournament_template, club: create(:club), mode: :team)

    patch organizers_tournament_template_path(main),
          params: { tournament_template: { name: main.name, paired_template_id: foreign.id } }

    assert_nil main.reload.paired_template_id
  end

  test "a paired template shows once, with a league-night action instead of Schedule next" do
    main = create(:tournament_template, club: @club, name: "League Night - Main", mode: :team,
                  default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00")
    side = create(:tournament_template, club: @club, name: "League Night - Side", mode: :team,
                  default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00")
    main.update!(paired_template: side)

    get organizers_tournament_templates_path

    assert_response :success
    assert_select "form[action=?]",
                  new_organizers_tournament_template_league_night_path(tournament_template_id: main.id),
                  count: 1 do
      assert_select "button", text: "Schedule next league night", count: 1
    end
    assert_match(/League Night - Main \+ League Night - Side/, response.body)
    assert_select "form[action=?]", clone_organizers_tournament_template_path(main), count: 0
    assert_select "form[action=?]", clone_organizers_tournament_template_path(side), count: 0
  end

  test "a paired template with no weekday or times still links to the scheduler" do
    main = create(:tournament_template, club: @club, name: "League Night - Main", mode: :team)
    side = create(:tournament_template, club: @club, name: "League Night - Side", mode: :team)
    main.update!(paired_template: side)

    get organizers_tournament_templates_path

    assert_select "form[action=?]",
                  new_organizers_tournament_template_league_night_path(tournament_template_id: main.id),
                  count: 1 do
      assert_select "button", text: "Schedule next league night", count: 1
    end
    assert_no_match(/either template/, response.body)
    assert_select "form[action=?]", clone_organizers_tournament_template_path(main), count: 0
    assert_select "form[action=?]", clone_organizers_tournament_template_path(side), count: 0
  end

  test "the paired row keeps an Edit link and a Delete button for each half" do
    main = create(:tournament_template, club: @club, name: "League Night - Main", mode: :team,
                  default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00")
    side = create(:tournament_template, club: @club, name: "League Night - Side", mode: :team,
                  default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00")
    main.update!(paired_template: side)

    get organizers_tournament_templates_path

    assert_select "a[href=?]", edit_organizers_tournament_template_path(main), count: 1
    assert_select "a[href=?]", edit_organizers_tournament_template_path(side), count: 1
    assert_select "form[action=?]", organizers_tournament_template_path(main), count: 1
    assert_select "form[action=?]", organizers_tournament_template_path(side), count: 1
  end

  test "an unpaired template keeps its own Schedule next button" do
    solo = create(:tournament_template, club: @club, name: "Saturday LML",
                  default_weekday: 6, default_start_time: "08:00", default_end_time: "16:00")

    get organizers_tournament_templates_path

    assert_select "form[action=?]", clone_organizers_tournament_template_path(solo), count: 1
    assert_select "form[action=?]",
                  new_organizers_tournament_template_league_night_path(tournament_template_id: solo.id),
                  count: 0
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
