require "application_system_test_case"

# One browser scenario for the whole tournament_format Stimulus controller's
# *new-form* behaviour: the format description copy, the Random Bag target-range
# reveal, and the force/lock/restore cycle on the blind checkbox. Every step
# carries a message naming the format it just selected, so a failure says which
# transition broke. Replaces the per-format select tests that used to live in
# beat_the_average / random_bag / progressive_length _tournament_test.rb.
class TournamentFormatSelectTest < ApplicationSystemTestCase
  setup do
    @club = Club.first || create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
  end

  test "format select drives the description, the Random Bag range fields, and the blind checkbox" do
    sign_in_as @organizer
    visit new_organizers_tournament_path

    # Read the checkbox through page-level selectors rather than a cached
    # `find`: the element is always in the DOM, so `find(...).checked?` is a
    # waitless attribute read that can observe the pre-change-handler state.
    # `has_selector?` retries until the Stimulus controller has run.
    blind = "input[type=checkbox][name='tournament[blind_leaderboard]']"

    # Progressive Length — plain copy swap, no blind/range side effects.
    select "Progressive Length", from: "Format"
    assert page.has_text?("Every fish must beat your previous fish", wait: 5),
           "after selecting Progressive Length: the format description should update"
    assert page.has_text?("Slots (ignored)", wait: 5),
           "after selecting Progressive Length: the slot-count label should read Slots (ignored)"

    # Catch the Average — always blind during play, so the checkbox is forced on
    # and locked (locked via pointer-events, not `disabled`, so it still submits).
    select "Catch the Average", from: "Format"
    assert page.has_text?("hidden running average", wait: 5),
           "after selecting Catch the Average: the format description should update"
    assert page.has_text?("Every catch counts toward one combined average; the slot count is ignored.", wait: 5),
           "after selecting Catch the Average: the slots help should update"
    assert page.has_selector?("#{blind}:checked", wait: 5),
           "after selecting Catch the Average: blind should be forced on"
    assert page.has_selector?("#{blind}.pointer-events-none", wait: 5),
           "after selecting Catch the Average: blind should be locked"

    # Bingo is the sharpest restore case: Tournament's bingo_not_blind validation
    # forbids blind_leaderboard = true for Bingo, so if the forced-checked state
    # lingers here the form becomes unsubmittable with no in-UI fix.
    select "Bingo", from: "Format"
    assert page.has_no_selector?("#{blind}:checked", wait: 5),
           "after selecting Bingo from Catch the Average: the forced-on blind value must not linger"
    assert page.has_no_selector?("#{blind}.pointer-events-none", wait: 5),
           "after selecting Bingo from Catch the Average: blind should be unlocked"

    # Random Bag — same forced blind, plus its own target-range section.
    select "Random Bag", from: "Format"
    assert page.has_text?("random target length", wait: 5),
           "after selecting Random Bag: the format description should update"
    assert page.has_text?("Random Bag target range", wait: 5),
           "after selecting Random Bag: the target-range section should be revealed"
    assert page.has_field?("Min (inches)", wait: 5),
           "after selecting Random Bag: the min field should be reachable"
    assert page.has_field?("Max (inches)", wait: 5),
           "after selecting Random Bag: the max field should be reachable"
    assert page.has_selector?("#{blind}:checked", wait: 5),
           "after selecting Random Bag: blind should be forced on"
    assert page.has_selector?("#{blind}.pointer-events-none", wait: 5),
           "after selecting Random Bag: blind should be locked"

    select "Bingo", from: "Format"
    assert page.has_no_text?("Random Bag target range", wait: 5),
           "after selecting Bingo from Random Bag: the target-range section should be hidden again"
    assert page.has_no_selector?("#{blind}:checked", wait: 5),
           "after selecting Bingo from Random Bag: the forced-on blind value must not linger"
    assert page.has_no_selector?("#{blind}.pointer-events-none", wait: 5),
           "after selecting Bingo from Random Bag: blind should be unlocked"
  end

  private

  def sign_in_as(user)
    visit consume_session_path(token: SignInToken.issue!(user: user).token)
  end
end
