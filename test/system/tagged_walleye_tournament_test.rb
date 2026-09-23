require "application_system_test_case"

# The one browser-only behaviour left in the Tagged format: the catch form's
# tag-number and weight inputs are revealed by JS when the Tagged Walleye
# species is chosen, and hidden again for any other species. Everything else
# the Tagged format renders (ticket counts, tag links, the draw) is server-side
# HTML and is asserted in test/controllers/tournaments_controller_test.rb and
# test/controllers/organizers/tournaments_controller_test.rb.
class TaggedWalleyeTournamentTest < ApplicationSystemTestCase
  setup do
    @club = Club.first || create(:club)
    @angler = create(:user, club: @club, role: :member, name: "Tagged Angler")
    @tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    Species.find_or_create_by!(name: "Walleye") # so the species dropdown has another option
  end

  test "tag and weight inputs appear when Tagged Walleye is selected and hide for other species" do
    sign_in_as(@angler)
    visit new_catch_path

    # Walleye is the default selection; both tag-only fields start hidden.
    assert page.has_no_selector?("#catch_tag_number", visible: true, wait: 5),
           "with Walleye selected: the tag-number input should be hidden"
    assert page.has_no_selector?("#catch_weight_text", visible: true, wait: 5),
           "with Walleye selected: the weight input should be hidden"

    select "Tagged Walleye", from: "catch_species_id"
    assert page.has_selector?("#catch_tag_number", visible: true, wait: 5),
           "after selecting Tagged Walleye: the tag-number input should be revealed"
    assert page.has_selector?("#catch_weight_text", visible: true, wait: 5),
           "after selecting Tagged Walleye: the weight input should be revealed"

    select "Walleye", from: "catch_species_id"
    assert page.has_no_selector?("#catch_tag_number", visible: true, wait: 5),
           "after selecting Walleye again: the tag-number input should be hidden"
    assert page.has_no_selector?("#catch_weight_text", visible: true, wait: 5),
           "after selecting Walleye again: the weight input should be hidden"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    visit consume_session_path(token: token.token)
  end
end
