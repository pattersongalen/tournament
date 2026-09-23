require "application_system_test_case"

# One browser scenario for the tournament_format Stimulus controller's *edit-form*
# slot handling: switching a draft tournament between formats hides the extra
# scoring-slot rows and ticks their `_destroy` boxes, switching back to a
# multi-row format un-ticks exactly the boxes we ticked, and Fish Train reveals
# its car builder. The final save proves the ticked `_destroy` actually reaches
# accepts_nested_attributes_for. Replaces the near-identical draft-switch tests
# that used to live in big_fish_season / biggest_vs_smallest / hidden_length /
# smallest_fish / fish_train _tournament_test.rb.
class TournamentFormatSwitchTest < ApplicationSystemTestCase
  setup do
    @club = Club.first || create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @walleye = create(:species, club: @club, name: "Walleye")
    @pike    = create(:species, club: @club, name: "Pike")
  end

  test "switching a draft tournament's format suppresses and restores the extra slot rows" do
    tournament = create(:tournament, club: @club, name: "Two Species Draft",
                                     mode: :solo, format: :standard,
                                     starts_at: 1.day.from_now, ends_at: 2.days.from_now)
    create(:scoring_slot, tournament: tournament, species: @walleye, slot_count: 2)
    create(:scoring_slot, tournament: tournament, species: @pike,    slot_count: 1)

    sign_in_as @organizer
    visit edit_organizers_tournament_path(tournament)

    # Two persisted rows plus the blank row #edit builds; only the persisted ones
    # carry a `_destroy` checkbox.
    destroy_boxes = -> { all("input[type=checkbox][name$='[_destroy]']", visible: :all) }
    assert_equal [false, false], destroy_boxes.call.map(&:checked?),
                 "on load: no slot row is marked for removal"
    assert page.has_no_text?("Train cars", wait: 5),
           "on load as Standard: the Fish Train car builder should be hidden"

    # Single-species format — every row past the first is hidden and suppressed.
    select "Big Fish Season", from: "Format"
    assert page.has_selector?("[data-tournament-format-target='slotRow']", count: 1, wait: 5),
           "after selecting Big Fish Season: only the first slot row stays visible"
    assert_equal [false, true], destroy_boxes.call.map(&:checked?),
                 "after selecting Big Fish Season: only the extra persisted row's _destroy is ticked"

    # Multi-species format — the rows we suppressed come back, un-ticked.
    select "Smallest Fish", from: "Format"
    assert page.has_selector?("[data-tournament-format-target='slotRow']", count: 3, wait: 5),
           "after selecting Smallest Fish: every slot row is visible again"
    assert_equal [false, false], destroy_boxes.call.map(&:checked?),
                 "after selecting Smallest Fish: the _destroy boxes we ticked are un-ticked"

    # Fish Train reveals its ordered-car builder with the default 3 car rows.
    select "Fish Train", from: "Format"
    assert page.has_text?("Train cars", wait: 5),
           "after selecting Fish Train: the car builder should be revealed"
    assert page.has_selector?("select[name='tournament[train_cars][]']", count: 3, wait: 5),
           "after selecting Fish Train: three default car rows should render"

    # Save as a single-species format: the ticked _destroy must survive the round
    # trip, leaving exactly the first row's slot behind.
    select "Hidden Length", from: "Format"
    assert page.has_no_text?("Train cars", wait: 5),
           "after selecting Hidden Length: the car builder should be hidden again"
    assert_equal [false, true], destroy_boxes.call.map(&:checked?),
                 "after selecting Hidden Length: the extra persisted row is marked for removal again"

    click_button "Update Tournament"
    assert_current_path organizers_tournaments_path

    tournament.reload
    assert tournament.format_hidden_length?, "the chosen format should persist"
    assert_equal 1, tournament.scoring_slots.count,
                 "the suppressed slot row should be destroyed on save"
    assert_equal @walleye.id, tournament.scoring_slots.first.species_id,
                 "the surviving slot should be the first row's species"
  end

  private

  def sign_in_as(user)
    visit consume_session_path(token: SignInToken.issue!(user: user).token)
  end
end
