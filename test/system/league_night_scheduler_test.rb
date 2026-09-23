require "application_system_test_case"

class LeagueNightSchedulerTest < ApplicationSystemTestCase
  MAIN_COUNT = "[data-league-night-target='mainCountRow']".freeze
  SIDE_COUNT = "[data-league-night-target='sideCountRow']".freeze
  SIDE_RANGE = "[data-league-night-target='sideRangeRow']".freeze
  SIDE_BLIND = "[data-league-night-target='sideBlind']".freeze
  # How the controller locks a checkbox it is forcing on — the same idiom
  # tournament_format_controller uses. Deliberately not `disabled`, so the box
  # still submits its own "1" instead of leaning entirely on the model's
  # force_*_blind hooks.
  LOCKED = ".pointer-events-none.opacity-60".freeze

  setup do
    @club = create(:club, name: "Test Anglers")
    @organizer = create(:user, club: @club, role: :organizer, name: "Organizer One")
    # Species are global and the select lists them by name with nothing marked
    # selected, so BOTH columns land on Perch — which is exactly the matched
    # pair the leak warning exists for, and why the warning is expected to be
    # up the moment the screen loads.
    create(:species, name: "Perch")
    create(:species, name: "Walleye")
    @main = create(:tournament_template, club: @club, name: "League Night - Main", mode: :team,
                   default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00",
                   blind_leaderboard: true)
    @side = create(:tournament_template, club: @club, name: "League Night - Side", mode: :team,
                   default_weekday: 3, default_start_time: "18:00", default_end_time: "21:00")
    @main.update!(paired_template: @side)

    token = SignInToken.issue!(user: @organizer)
    visit consume_session_path(token: token.token)
    visit_scheduler
  end

  # Merges the three species/blind warning tests: same-species tracking, a
  # blind Side not counting as a leak, and Main's own blind state gating the
  # warning at all.
  test "the leak warning tracks species match, Side's own blind flag, and whether Main is actually blind" do
    assert page.has_text?("reveals its standings", wait: 5),
           "initial state: matched Perch/Perch should be flagged as a leak"
    assert page.has_text?("Both nights score Perch", wait: 5),
           "initial state: the species line should name Perch"

    select "Walleye", from: "league_night[side][species_id]"
    assert page.has_no_text?("reveals its standings", wait: 5),
           "species mismatch: differing species should silence the warning"

    select "Walleye", from: "league_night[main][species_id]"
    assert page.has_text?("Both nights score Walleye", wait: 5),
           "species rematch: matching again should restate the warning under the new species"

    # Main is always blind, so the warning is about Side being the readable
    # half. A blind Side leaks nothing, whatever species it scores.
    check "league_night[side][blind_leaderboard]"
    assert page.has_no_text?("reveals its standings", wait: 5),
           "blind Side: a blind Side should not be flagged as a leak"

    uncheck "league_night[side][blind_leaderboard]"
    assert page.has_text?("reveals its standings", wait: 5),
           "unblind Side: unblinding Side should restore the warning"

    # Nothing requires a paired template to be blind, and this screen never
    # sets Main's flag. With a non-blind Main there is no leak for a visible
    # Side to reveal, so the warning would be advice about a leak that doesn't
    # exist — and its effective state has to be recomputed as the Main format
    # changes, since a forced-blind format makes Main blind without a reload.
    @main.update!(blind_leaderboard: false)
    visit_scheduler

    assert page.has_no_text?("reveals its standings", wait: 5),
           "non-blind Main: no leak to warn about when Main itself isn't blind"

    select "Catch the Average", from: "league_night[main][format]"
    assert page.has_text?("reveals its standings", wait: 5),
           "forced-blind Main format: Main becomes blind without a reload"

    select "Standard", from: "league_night[main][format]"
    assert page.has_no_text?("reveals its standings", wait: 5),
           "revert Main format: dropping the forced-blind format should drop the warning again"
  end

  # Merges the count-visibility, range-visibility, and Side blind-lock tests —
  # all driven by the same format selects on the same screen.
  test "count and range fields track format per column, and Side's blind box locks for forced-blind formats" do
    assert page.has_selector?(MAIN_COUNT, visible: true, wait: 5),
           "initial state: Main's count row should show for Standard"

    select "Pro Walleye", from: "league_night[main][format]"
    assert page.has_selector?(MAIN_COUNT, visible: :hidden, wait: 5),
           "Pro Walleye: pins the count, so Main's count row should hide"
    assert page.has_selector?(SIDE_COUNT, visible: true, wait: 5),
           "Pro Walleye: Side's count row should be unaffected by Main's format"

    select "Progressive Length", from: "league_night[main][format]"
    assert page.has_selector?(MAIN_COUNT, visible: :hidden, wait: 5),
           "Progressive Length: also pins the count"

    select "Standard", from: "league_night[main][format]"
    assert page.has_selector?(MAIN_COUNT, visible: true, wait: 5),
           "revert Main: Standard should show the count row again"

    assert page.has_selector?(SIDE_RANGE, visible: :hidden, wait: 5),
           "initial state: the target-range fields should start hidden"
    assert page.has_selector?("#{SIDE_BLIND}:not(:checked)", wait: 5),
           "initial state: Side's blind box should start unchecked"
    assert page.has_no_selector?("#{SIDE_BLIND}#{LOCKED}", wait: 5),
           "initial state: and unlocked"

    select "Random Bag", from: "league_night[side][format]"
    assert page.has_selector?(SIDE_RANGE, visible: true, wait: 5),
           "Random Bag: should reveal the target-range fields"
    assert page.has_selector?("#{SIDE_BLIND}:checked", wait: 5),
           "Random Bag: also forces Side blind"
    assert page.has_selector?("#{SIDE_BLIND}#{LOCKED}", wait: 5),
           "Random Bag: the forced blind box should render locked"
    # Locked, but never `disabled` — a disabled box submits nothing, which would
    # make Tournament's force_*_blind hooks the ONLY thing setting the flag.
    assert page.has_no_selector?("#{SIDE_BLIND}[disabled]", wait: 5),
           "Random Bag: locked must not mean disabled"

    select "Catch the Average", from: "league_night[side][format]"
    assert page.has_selector?(SIDE_RANGE, visible: :hidden, wait: 5),
           "Catch the Average: the range fields are Random-Bag-only, so leaving it should hide them"
    assert page.has_selector?("#{SIDE_BLIND}:checked", wait: 5),
           "Catch the Average: also forces Side blind"
    assert page.has_selector?("#{SIDE_BLIND}#{LOCKED}", wait: 5),
           "Catch the Average: the box should still render locked"
    assert page.has_no_selector?("#{SIDE_BLIND}[disabled]", wait: 5),
           "Catch the Average: still not disabled"

    # Back to a format that leaves blind up to the operator: the box unlocks and
    # goes back to the "off" it was rendered with, rather than keeping the tick
    # the forced format put there.
    select "Standard", from: "league_night[side][format]"
    assert page.has_selector?(SIDE_RANGE, visible: :hidden, wait: 5),
           "revert Side: Standard keeps the range fields hidden"
    assert page.has_no_selector?("#{SIDE_BLIND}#{LOCKED}", wait: 5),
           "revert Side: leaving a forced-blind format should unlock the box"
    assert page.has_selector?("#{SIDE_BLIND}:not(:checked)", wait: 5),
           "revert Side: and return it to the 'off' it was rendered with, not keep the forced tick"

    # The Side template can itself be blind, in which case the box is rendered
    # already ticked. Passing through a forced-blind format must not be a way
    # to silently untick it.
    @side.update!(blind_leaderboard: true)
    visit_scheduler

    assert page.has_selector?("#{SIDE_BLIND}:checked", wait: 5),
           "blind-by-default Side: should render already ticked"
    assert page.has_no_selector?("#{SIDE_BLIND}#{LOCKED}", wait: 5),
           "blind-by-default Side: and unlocked, since the operator can still change it"

    select "Catch the Average", from: "league_night[side][format]"
    assert page.has_selector?("#{SIDE_BLIND}#{LOCKED}", wait: 5),
           "blind-by-default Side + forced-blind format: should lock the box"
    assert page.has_selector?("#{SIDE_BLIND}:checked", wait: 5),
           "blind-by-default Side + forced-blind format: and it should stay checked"

    select "Standard", from: "league_night[side][format]"
    assert page.has_no_selector?("#{SIDE_BLIND}#{LOCKED}", wait: 5),
           "blind-by-default Side, revert format: leaving the forced-blind format should unlock the box"
    assert page.has_selector?("#{SIDE_BLIND}:checked", wait: 5),
           "blind-by-default Side, revert format: but it should keep its tick, since the template itself is blind"
  end

  # A half-scheduled night renders ONE column, so half the controller's targets
  # are absent. An unguarded target read would raise on connect and take the
  # rest of the behaviour down with it — including the range rows, which ship
  # hidden and are only ever un-hidden by this controller.
  test "the repair path's single column still gets its behaviour" do
    starts_at, ends_at = @main.next_occurrence_at
    create(:tournament, club: @club, name: @main.name, mode: :team,
           template_source_id: @main.id, starts_at: starts_at, ends_at: ends_at)
    visit_scheduler

    assert_text "Only the missing half will be created."
    assert_no_selector MAIN_COUNT, visible: :all

    assert_selector SIDE_RANGE, visible: :hidden
    select "Random Bag", from: "league_night[side][format]"
    assert_selector SIDE_RANGE, visible: true

    select "Pro Walleye", from: "league_night[side][format]"
    assert_selector SIDE_COUNT, visible: :hidden
  end

  private

  def visit_scheduler
    visit new_organizers_tournament_template_league_night_path(tournament_template_id: @main.id)
  end
end
