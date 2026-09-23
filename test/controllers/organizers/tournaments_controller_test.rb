require "test_helper"

class Organizers::TournamentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @member = create(:user, club: @club, role: :member)
    @organizer = create(:user, club: @club, role: :organizer)
  end

  test "members are forbidden" do
    sign_in_as(@member)
    get organizers_tournaments_path
    assert_response :forbidden
  end

  test "organizers can list tournaments" do
    sign_in_as(@organizer)
    create(:tournament, club: @club, name: "Wednesday Throwdown")
    get organizers_tournaments_path
    assert_response :success
    assert_match "Wednesday Throwdown", response.body
  end

  test "organizers can create a tournament with scoring slots" do
    sign_in_as(@organizer)
    species = create(:species, club: @club, name: "Walleye")
    assert_difference -> { Tournament.count } => 1, -> { ScoringSlot.count } => 1 do
      post organizers_tournaments_path, params: {
        tournament: {
          name: "Wed Night",
          mode: "solo",
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 4.hours,
          season_tag: "Open Water 2026",
          scoring_slots_attributes: { "0" => { species_id: species.id, slot_count: 3 } }
        }
      }
    end
    assert_redirected_to organizers_tournaments_path
  end

  test "create accepts season_tag, local, awards_season_points, blind_leaderboard, entrants_only_leaderboard, and judged together, and defaults local to true when omitted" do
    sign_in_as(@organizer)
    species = create(:species, club: @club)

    post organizers_tournaments_path, params: {
      tournament: {
        name: "Full Attrs", mode: "solo",
        starts_at: 1.hour.from_now, ends_at: 4.hours.from_now,
        season_tag: "Full Attrs 2026",
        local: "0", awards_season_points: "1", blind_leaderboard: "1",
        entrants_only_leaderboard: "1", judged: "1",
        scoring_slots_attributes: { "0" => { species_id: species.id, slot_count: 1 } }
      }
    }
    assert_redirected_to organizers_tournaments_path
    t = Tournament.order(:id).last
    {
      season_tag: "Full Attrs 2026",
      local: false,
      awards_season_points?: true,
      blind_leaderboard?: true,
      entrants_only_leaderboard?: true,
      judged?: true
    }.each do |attr, expected|
      assert_equal expected, t.public_send(attr), "#{attr}: should persist from a single submission"
    end

    post organizers_tournaments_path, params: {
      tournament: { name: "Local Omitted", mode: "solo",
                    starts_at: 1.hour.from_now, ends_at: 4.hours.from_now }
    }
    assert_equal true, Tournament.order(:id).last.local,
                 "local: should default to true when the checkbox is omitted"
  end

  test "index shows (away) tag for non-local tournaments" do
    organizer = create(:user, club: @club, role: :organizer)
    sign_in_as(organizer)
    away = create(:tournament, club: @club, local: false, name: "Out of Town",
                               starts_at: 1.day.from_now, ends_at: 2.days.from_now)
    get organizers_tournaments_path
    assert_response :success
    assert_match "(away)", response.body
  end

  test "edit form locks blind_leaderboard after starts_at has passed" do
    sign_in_as(@organizer)
    t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
               blind_leaderboard: true)
    get edit_organizers_tournament_path(t)
    assert_response :success
    assert_select "input[type=checkbox][name='tournament[blind_leaderboard]'][disabled]"
    assert_select "input[type=hidden][name='tournament[blind_leaderboard]'][value='1']"
  end

  test "update rejects toggling blind_leaderboard after starts_at" do
    sign_in_as(@organizer)
    t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
               blind_leaderboard: false)
    patch organizers_tournament_path(t), params: { tournament: { blind_leaderboard: "1" } }
    assert_response :unprocessable_entity
    t.reload
    assert_not t.blind_leaderboard?
  end

  test "create accepts each format-specific permitted attribute" do
    sign_in_as(@organizer)
    walleye = create(:species, club: @club, name: "Walleye")
    perch   = create(:species, club: @club, name: "Perch")
    pike    = create(:species, club: @club, name: "Pike")

    {
      "big_fish_season" => {
        extra: { format: "big_fish_season",
                 scoring_slots_attributes: { "0" => { species_id: walleye.id, slot_count: 3 } } },
        check: ->(t) { assert t.format_big_fish_season?, "big_fish_season: format should persist" }
      },
      "hidden_length" => {
        extra: { format: "hidden_length", hidden_length_target: "17.25",
                 scoring_slots_attributes: { "0" => { species_id: walleye.id, slot_count: 1 } } },
        check: ->(t) {
          assert t.format_hidden_length?, "hidden_length: format should persist"
          assert_nil t.hidden_length_target, "hidden_length: hidden_length_target should be dropped by strong params"
        }
      },
      "biggest_vs_smallest" => {
        extra: { format: "biggest_vs_smallest",
                 scoring_slots_attributes: { "0" => { species_id: walleye.id, slot_count: 1 } } },
        check: ->(t) { assert t.format_biggest_vs_smallest?, "biggest_vs_smallest: format should persist" }
      },
      "fish_train" => {
        extra: { format: "fish_train", train_cars: [ perch.id.to_s, pike.id.to_s, perch.id.to_s ],
                 scoring_slots_attributes: { "0" => { species_id: perch.id, slot_count: 1 },
                                              "1" => { species_id: pike.id, slot_count: 1 } } },
        check: ->(t) {
          assert t.format_fish_train?, "fish_train: format should persist"
          assert_equal [ perch.id, pike.id, perch.id ], t.train_cars, "fish_train: train_cars should persist"
        }
      }
    }.each do |label, spec|
      assert_difference -> { Tournament.count }, 1, "#{label}: should create a tournament" do
        post organizers_tournaments_path, params: {
          tournament: { name: "#{label} Wed", mode: "solo",
                        starts_at: 1.day.from_now, ends_at: 1.day.from_now + 4.hours }.merge(spec[:extra])
        }
      end
      spec[:check].call(Tournament.order(:id).last)
    end
  end

  test "create rejects big_fish_season + team mode" do
    sign_in_as(@organizer)
    walleye = create(:species, club: @club)
    assert_no_difference -> { Tournament.count } do
      post organizers_tournaments_path, params: {
        tournament: {
          name: "Bad Combo",
          mode: "team",
          format: "big_fish_season",
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 4.hours,
          scoring_slots_attributes: { "0" => { species_id: walleye.id, slot_count: 1 } }
        }
      }
    end
    assert_response :unprocessable_entity
    assert_match "must be solo", response.body
  end

  test "create rejects big_fish_season with multiple scoring slots" do
    sign_in_as(@organizer)
    walleye = create(:species, club: @club)
    pike = create(:species, club: @club)
    assert_no_difference -> { Tournament.count } do
      post organizers_tournaments_path, params: {
        tournament: {
          name: "Two Species",
          mode: "solo",
          format: "big_fish_season",
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 4.hours,
          scoring_slots_attributes: {
            "0" => { species_id: walleye.id, slot_count: 1 },
            "1" => { species_id: pike.id, slot_count: 1 }
          }
        }
      }
    end
    assert_response :unprocessable_entity
    assert_match "exactly one species configured", response.body
  end

  test "update rejects format change after the tournament has started" do
    sign_in_as(@organizer)
    species = create(:species, club: @club)
    tournament = create(:tournament, club: @club, format: :standard, mode: :solo,
                        starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: tournament, species: species, slot_count: 1)

    patch organizers_tournament_path(tournament), params: {
      tournament: { format: "big_fish_season" }
    }

    assert_response :unprocessable_entity
    assert_match "once the tournament has started", response.body
    assert tournament.reload.format_standard?
  end

  test "update silently ignores hidden_length_target submitted via params" do
    sign_in_as(@organizer)
    walleye = create(:species, club: @club, name: "Walleye HL2")
    t = build(:tournament, club: @club, format: :hidden_length, mode: :solo,
              starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!

    patch organizers_tournament_path(t), params: {
      tournament: { hidden_length_target: "17.25" }
    }

    assert_nil t.reload.hidden_length_target,
               "expected strong params to drop hidden_length_target"
  end

  test "organizer can create a bingo tournament with no scoring slots" do
    sign_in_as(@organizer)
    create_bingo_species!
    assert_difference -> { Tournament.count }, 1 do
      post organizers_tournaments_path, params: { tournament: {
        name: "Bingo Night", format: "bingo", mode: "solo",
        starts_at: 1.hour.from_now, ends_at: 4.hours.from_now
      } }
    end
    t = Tournament.order(:id).last
    assert t.format_bingo?
    assert_equal 25, t.bingo_layout.size
  end

  test "draw: organizer can trigger the tagged draw and is redirected with notice" do
    club = create(:club)
    organizer = create(:user, club: club, role: :organizer)
    user = create(:user, club: club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 2.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: tagged, length_inches: 18.0,
                    tag_number: "A001", captured_at_device: 90.minutes.ago)
    )

    sign_in_as organizer
    post draw_organizers_tournament_url(t)

    assert_redirected_to organizers_tournaments_url
    assert_not_nil t.reload.drawn_at
  end

  test "draw: force=true triggers a re-draw" do
    club = create(:club)
    organizer = create(:user, club: club, role: :organizer)
    user = create(:user, club: club)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: club, format: :tagged, mode: :solo,
              starts_at: 2.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: user, species: tagged, length_inches: 18.0,
                    tag_number: "A001", captured_at_device: 90.minutes.ago)
    )

    sign_in_as organizer
    post draw_organizers_tournament_url(t)
    first_drawn_at = t.reload.drawn_at

    travel 1.second do
      post draw_organizers_tournament_url(t), params: { force: "1" }
      assert_not_equal first_drawn_at, t.reload.drawn_at
    end
  end

  test "creates a pro_walleye tournament with a forced 5-count Walleye slot" do
    sign_in_as(@organizer)
    walleye = create(:species, club: @club, name: "Walleye")
    assert_difference -> { Tournament.count } => 1, -> { ScoringSlot.count } => 1 do
      post organizers_tournaments_path, params: {
        tournament: {
          name: "Sask Slot Limit", mode: "team", format: "pro_walleye",
          starts_at: 1.hour.from_now, ends_at: 3.hours.from_now,
          scoring_slots_attributes: { "0" => { species_id: walleye.id, slot_count: "1" } }
        }
      }
    end
    t = Tournament.order(:id).last
    assert t.format_pro_walleye?
    assert_equal 5, t.scoring_slots.sole.slot_count
  end

  test "organizer creates a random_bag tournament with a custom target range" do
    sign_in_as(@organizer)
    species = create(:species, club: @club, name: "Walleye")
    assert_difference -> { Tournament.count } => 1 do
      post organizers_tournaments_path, params: {
        tournament: {
          name: "Random Bag Night", mode: "team", format: "random_bag",
          starts_at: 1.hour.from_now, ends_at: 3.hours.from_now,
          target_min_inches: "72.5", target_max_inches: "95",
          scoring_slots_attributes: { "0" => { species_id: species.id, slot_count: 1 } }
        }
      }
    end
    t = Tournament.order(:created_at).last
    assert t.format_random_bag?
    assert t.blind_leaderboard, "blind forced on"
    assert_equal BigDecimal("72.5"), t.target_min_inches
    assert_equal BigDecimal("95"), t.target_max_inches
  end

  test "organizers update ignores a submitted backfill_late_entrants param" do
    sign_in_as(@organizer)
    tournament = create(:tournament, club: @club, starts_at: 4.hours.ago, ends_at: 1.hour.ago)

    patch organizers_tournament_path(tournament),
          params: { tournament: { name: "Renamed", backfill_late_entrants: "1" } }

    assert_equal "Renamed", tournament.reload.name
    assert_not tournament.backfill_late_entrants?,
               "the backfill flag is admin-panel-only and must not be settable from organizers"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  test "the season-points hint on the form counts entries, not anglers" do
    sign_in_as(@organizer)
    get new_organizers_tournament_path
    assert_response :success
    assert_no_match(/angler count/, response.body)
    assert_match(/entries/, response.body)
  end
end
