require "application_system_test_case"

class CatchesFilteringTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    @walleye = create(:species, club: @club, name: "Walleye")
    token = SignInToken.issue!(user: @user)
    visit consume_session_path(token: token.token)
  end

  # Merges the wind-chip, lake-select, and min-length filter-bar controls into
  # one scenario — each is a JS auto-submit behaviour on the same screen.
  # Server-side filtering correctness (including the lake "other"/unknown-key
  # branches) is covered by test/services/catches/apply_filters_test.rb and
  # test/controllers/catches_controller_test.rb.
  test "chips, the lake select, and Enter in min-length each auto-submit a filter" do
    ne = create(:catch, user: @user, species: @walleye, length_inches: 18,
                        captured_at_device: Time.current, wind_direction_deg: 45)
    sw = create(:catch, user: @user, species: @walleye, length_inches: 18,
                        captured_at_device: Time.current, wind_direction_deg: 225)

    visit catches_path(start: "")
    assert page.has_text?("Match conditions", wait: 5),
           "wind chip: the conditions filter section should render"

    find("[data-test='match-conditions-toggle']").click
    assert page.has_selector?("[data-test='chip-wind_dir-ne']", visible: :visible, wait: 5),
           "wind chip: the toggle should reveal the chip row"

    find("[data-test='chip-wind_dir-ne']").click

    # After submit, page reloads with wind_dir=ne; only the NE catch should be in the grid.
    assert page.has_current_path?(/wind_dir=ne/, url: true, wait: 5),
           "wind chip: selecting NE should submit wind_dir=ne"
    assert page.has_selector?("a[href='#{catch_path(ne.id)}']", wait: 5),
           "wind chip: the NE catch should be in the grid"
    assert page.has_no_selector?("a[href='#{catch_path(sw.id)}']", wait: 5),
           "wind chip: the SW catch should be filtered out"

    # Tapping the active chip clears it; the param is dropped entirely
    # (not just emptied) -- that distinction is JS behaviour, which is exactly
    # why this stays a system test.
    find("[data-test='chip-wind_dir-ne']").click
    # Wait for the cleared-filter page to render before checking the URL --
    # assert_no_match against current_url doesn't auto-retry, but
    # has_selector? does, so let it gate on the SW catch reappearing.
    assert page.has_selector?("a[href='#{catch_path(sw.id)}']", wait: 5),
           "wind chip: clearing the chip should bring the SW catch back"
    assert page.has_selector?("a[href='#{catch_path(ne.id)}']", wait: 5),
           "wind chip: and keep the NE catch"
    assert_no_match(/wind_dir=/, current_url,
                     "wind chip: the cleared param should be dropped, not emptied")

    # Lake select auto-submits on change, same as the chips.
    tobin = create(:catch, user: @user, species: @walleye, length_inches: 22.5,
                           lake: "tobin", latitude: 53.55, longitude: -103.65,
                           captured_at_device: 2.days.ago)
    visit catches_path(start: "", end: "")
    assert page.has_text?('22.5"', wait: 5),
           "lake select: the Tobin catch should start visible"
    assert page.has_text?('18"', wait: 5),
           "lake select: the non-Tobin catches should also start visible"

    find("select[name='lake']").find("option", text: "Tobin Lake").select_option

    assert page.has_current_path?(/lake=tobin/, url: true, wait: 5),
           "lake select: choosing Tobin Lake should auto-submit lake=tobin"
    assert page.has_text?('22.5"', wait: 5),
           "lake select: the Tobin catch should still show"
    assert page.has_no_text?('18"', wait: 5),
           "lake select: catches without a Tobin lake match should be filtered out"

    # Min-length input submits on Enter, not on every keystroke.
    long = create(:catch, user: @user, species: @walleye, length_inches: 26, captured_at_device: Time.current)
    visit catches_path(start: "")
    input = find("input[name='min_length']")
    input.fill_in with: "20"
    input.send_keys(:return)

    assert page.has_current_path?(/min_length=20/, url: true, wait: 5),
           "min-length: pressing Enter should submit min_length=20"
    assert page.has_selector?("a[href='#{catch_path(long.id)}']", wait: 5),
           "min-length: the 26\" catch should stay"
    assert page.has_no_selector?("a[href='#{catch_path(ne.id)}']", wait: 5),
           "min-length: the shorter catches should be filtered out"
  end
end
