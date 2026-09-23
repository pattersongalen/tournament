require "application_system_test_case"

class BingoCardTest < ApplicationSystemTestCase
  setup do
    @club = Club.first || create(:club)
    @walleye, = create_bingo_species!
    @angler = create(:user, club: @club, name: "Angler A")
  end

  test "logging a qualifying catch stamps a bingo square" do
    t = build(:tournament, club: @club, name: "Bingo Night", mode: :solo, format: :bingo,
              starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
    t.save!

    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: @angler)

    sign_in_as(@angler)

    visit bingo_card_tournament_path(t)
    assert_selector "[data-bingo-cell]", count: 25
    filled_before = all("[data-bingo-cell].bg-emerald-600").count

    # Place a qualifying Walleye directly (the camera flow is covered elsewhere).
    # Capybara polls until the live Turbo Stream broadcast repaints the card.
    Catches::PlaceInSlots.call(
      catch: create(:catch, user: @angler, species: @walleye,
                    length_inches: 15, captured_at_device: 5.minutes.ago)
    )

    assert_selector "[data-bingo-cell].bg-emerald-600", minimum: filled_before + 1
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
