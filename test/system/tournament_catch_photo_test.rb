require "application_system_test_case"

class TournamentCatchPhotoTest < ApplicationSystemTestCase
  test "member opens and closes a catch photo modal on a non-blind tournament" do
    club = create(:club)
    walleye = create(:species, club: club, name: "Walleye")
    angler = create(:user, club: club, name: "Angler A", role: :member)
    other  = create(:user, club: club, name: "Angler B", role: :member)

    tournament = create(:tournament, club: club, name: "Open League",
                        starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                        blind_leaderboard: false)
    create(:scoring_slot, tournament: tournament, species: walleye, slot_count: 1)

    my_entry = create(:tournament_entry, tournament: tournament, name: "My Boat")
    create(:tournament_entry_member, tournament_entry: my_entry, user: angler)

    other_entry = create(:tournament_entry, tournament: tournament, name: "Other Boat")
    create(:tournament_entry_member, tournament_entry: other_entry, user: other)

    other_catch = create(:catch, user: other, species: walleye, length_inches: 22.5,
                                  captured_at_device: 30.minutes.ago)
    create(:catch_placement, catch: other_catch, tournament: tournament,
                              tournament_entry: other_entry, species: walleye, slot_index: 0)

    sign_in_as(angler)
    visit tournament_path(tournament)

    # The leaderboard fish link for "Other Boat" should target the modal frame.
    fish_link = find("a", text: /Walleye.*22\.5/, match: :first)
    assert_equal "catch_photo_modal", fish_link["data-turbo-frame"]

    fish_link.click

    # Modal content should appear inside the frame.
    within "turbo-frame#catch_photo_modal" do
      assert_selector "img"
      assert_text "Walleye"
      assert_text "22.5"
      assert_text other.name
    end

    # Close button empties the frame.
    within "turbo-frame#catch_photo_modal" do
      find("button[aria-label=Close]").click
    end

    # Frame is now empty (no children).
    assert_selector "turbo-frame#catch_photo_modal:empty", visible: :all

    # Click again — modal reopens with fresh content.
    find("a", text: /Walleye.*22\.5/, match: :first).click
    within "turbo-frame#catch_photo_modal" do
      assert_selector "img"
    end
  end

  private

  def sign_in_as(user)
    visit new_session_path
    fill_in "Email", with: user.email
    click_button "Send sign-in link"
    assert_text "Check your email"  # wait for the POST to commit the token before reading it
    visit consume_session_path(token: SignInToken.last.token)
  end
end
