require "application_system_test_case"
require_relative "../support/questionnaire_helpers"

class QuestionnaireSystemTest < ApplicationSystemTestCase
  include QuestionnaireHelpers

  setup do
    @club = asking_club
    @tournament = season_tournament(club: @club)
    @first = add_boat(@tournament, length: 30, members: 2, name: "First Boat")
    add_boat(@tournament, length: 28, name: "Second Boat")
    @me, @mate = @first.users.order(:id).to_a
  end

  test "a top-3 member answers from the home card and a teammate edits the answers" do
    sign_in_as(@me)
    visit root_path

    within "#questionnaire-card-#{@first.id}" do
      assert_text "You placed 1st in Wednesday Main"
      click_link "Answer"
    end

    fill_in "Lure used", with: "Jig"
    fill_in "Depth", with: "18 ft"
    click_button "Save answers"

    # Scoped to the flash element, not the whole page: the redirect is a Turbo
    # render that swaps <body>, and a page-wide text read that starts on the
    # old body raises ObsoleteNode instead of retrying.
    assert_selector "#flash_notice", text: "Thanks. Your answers are on the tournament page."
    within "#what-worked [data-place='1']" do
      assert_text "First Boat"
      assert_text "Lure used: Jig"
      assert_text "Depth: 18 ft"
      assert_no_text "Bait used"
      assert_text "Answered by #{@me.name}"
    end
    within "#what-worked [data-place='2']" do
      assert_text "No answers yet."
    end

    visit root_path
    assert_text "Log Catch"
    assert page.has_no_css?("#questionnaire-card-#{@first.id}"), "answered: the card is gone"

    # The teammate sees no card either, and can edit from the tournament page.
    Capybara.reset_sessions!
    sign_in_as(@mate)
    visit root_path
    assert_text "Log Catch"
    assert page.has_no_css?("#questionnaire-card-#{@first.id}")

    visit tournament_path(@tournament)
    within "#what-worked [data-place='1']" do
      click_link "Edit answers"
    end
    assert_field "Lure used", with: "Jig"
    fill_in "Lure used", with: "Spoon"
    fill_in "Bait used", with: "Minnow"
    click_button "Save answers"

    within "#what-worked [data-place='1']" do
      assert_text "Lure used: Spoon"
      assert_text "Bait used: Minnow"
      assert_text "Answered by #{@mate.name}"
    end
  end

  test "Not now hides the card for this member and leaves it for the teammate" do
    sign_in_as(@me)
    visit root_path

    within "#questionnaire-card-#{@first.id}" do
      click_button "Not now"
    end

    assert_text "Log Catch"
    assert page.has_no_css?("#questionnaire-card-#{@first.id}")

    Capybara.reset_sessions!
    sign_in_as(@mate)
    visit root_path
    assert page.has_css?("#questionnaire-card-#{@first.id}")
  end

  test "submitting an empty form keeps the member on the form with the message" do
    sign_in_as(@me)
    visit edit_tournament_entry_questionnaire_path(@tournament, @first)

    click_button "Save answers"

    assert_text "Fill in at least one answer."
    assert_button "Save answers"
  end
end
