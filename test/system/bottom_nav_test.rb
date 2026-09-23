require "application_system_test_case"

class BottomNavTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
  end

  # iOS keeps position:fixed elements pinned to the visual viewport, so the
  # opened keyboard pushes the nav up to float directly over the form — with
  # the Refresh button (which discards an unsaved catch photo/video) one
  # accidental thumb-tap above the keyboard. The nav must hide while a
  # text-entering control has focus, stay hidden across a hop between fields,
  # and return once nothing has focus.
  test "bottom nav hides while typing, stays hidden across a field hop, and returns on blur" do
    create(:species, club: @club, name: "Walleye")
    token = SignInToken.issue!(user: @user)
    visit consume_session_path(token: token.token)
    visit "/catches/new"

    assert page.has_selector?("nav[data-controller~='keyboard-nav']", wait: 5),
           "initial state: the nav should render"

    page.execute_script("document.querySelector('#catch_length_inches').focus()")
    assert page.has_no_selector?("nav[data-controller~='keyboard-nav']", wait: 2),
           "focus: the nav should hide while a text field has focus"

    page.execute_script("document.querySelector('#catch_note').focus()")
    # Past the 150ms re-show delay: a field-to-field hop must not flash the nav back in.
    sleep 0.4
    assert page.has_no_selector?("nav[data-controller~='keyboard-nav']", wait: 2),
           "hop: the nav should stay hidden across a field-to-field focus hop"

    page.execute_script("document.querySelector('#catch_note').blur()")
    assert page.has_selector?("nav[data-controller~='keyboard-nav']", wait: 2),
           "blur: the nav should return once nothing has focus"
  end
end
