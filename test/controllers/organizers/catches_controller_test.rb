require "test_helper"

class Organizers::CatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @member = create(:user, club: @club, name: "Club Carl", role: :member)
    @other_club = create(:club)
    @foreign = create(:user, club: @other_club, name: "Outsider Olive", role: :member)
    @member_catch = create(:catch, user: @member, length_inches: 22.5)
    @foreign_catch = create(:catch, user: @foreign, length_inches: 19.0)
  end

  test "non-organizer member is forbidden" do
    sign_in_as(@member)
    get organizers_catches_path
    assert_response :forbidden
  end

  test "organizer sees the club's catches but not other clubs'" do
    sign_in_as(@organizer)
    get organizers_catches_path
    assert_response :success
    assert_includes response.body, "Club Carl"
    refute_includes response.body, "Outsider Olive"
  end

  test "user_id filter scopes the catch list to the selected user" do
    other_member = create(:user, club: @club, name: "Other Member", role: :member)
    create(:catch, user: other_member, length_inches: 14.0)
    sign_in_as(@organizer)
    get organizers_catches_path, params: { user_id: @member.id }

    assert_select "ul.grid li", minimum: 1 do
      assert_select "*", text: /Club Carl/
    end
    assert_select "ul.grid li *", text: /Other Member/, count: 0
  end

  test "organizer can update an in-club catch's length and species" do
    walleye = create(:species)
    sign_in_as(@organizer)
    assert_difference "JudgeAction.count", 1 do
      patch organizers_catch_path(@member_catch.id), params: {
        species_id: walleye.id, length: "19.5", length_unit: "inches", note: "remeasured"
      }
    end
    assert_redirected_to organizers_catch_path(@member_catch.id)
    @member_catch.reload
    assert_equal 19.5, @member_catch.length_inches.to_f
    assert_equal walleye.id, @member_catch.species_id
  end

  test "update snaps cm entry to the quarter grid and converts to inches" do
    sign_in_as(@organizer)
    # 50.1 cm snaps to 50.0 cm; 50.0 / 2.54 = 19.685...
    patch organizers_catch_path(@member_catch.id), params: {
      length: "50.1", length_unit: "centimeters", note: "cm"
    }
    @member_catch.reload
    assert_equal "centimeters", @member_catch.length_unit
    assert_in_delta 19.685, @member_catch.length_inches.to_f, 0.01
  end

  test "update with an invalid length redirects with an alert instead of 500" do
    sign_in_as(@organizer)
    patch organizers_catch_path(@member_catch.id), params: { length: "0", length_unit: "inches" }

    assert_redirected_to organizers_catch_path(@member_catch.id)
    assert_not_nil flash[:alert]
    assert_equal 22.5, @member_catch.reload.length_inches.to_f, "invalid edit should not persist"
  end

  test "a note-only edit of a cm-tagged catch does not drift its stored length" do
    # Legacy inch-grid fish mis-tagged cm: stored 8.50", the editor prefills
    # 21.5 cm. Changing only the note resubmits that exact prefill; length_inches
    # must stay 8.50 rather than round-tripping to a drifted 8.46.
    @member_catch.update!(length_inches: 8.50, length_unit: "centimeters")
    sign_in_as(@organizer)
    patch organizers_catch_path(@member_catch.id), params: {
      species_id: @member_catch.species_id, length: "21.5", length_unit: "centimeters",
      note: "just a note"
    }
    assert_equal 8.50, @member_catch.reload.length_inches.to_f,
                 "prefilled cm length must round-trip, not drift"
  end

  test "organizer cannot update an out-of-club catch (404)" do
    sign_in_as(@organizer)
    patch organizers_catch_path(@foreign_catch.id), params: { length: "10", length_unit: "inches" }
    assert_response :not_found
  end

  test "organizer sees the edit form on an in-club catch detail page" do
    sign_in_as(@organizer)
    get organizers_catch_path(@member_catch.id)
    assert_response :success
    assert_select "select[name=species_id]"
    assert_select "input[name=length]"
    assert_includes response.body, "Club Carl"
  end

  test "edit form defaults the unit toggle to the catch's own logged unit, not the organizer's" do
    # @organizer prefers inches (factory default); the catch was logged in cm.
    # The form must seed from the catch's unit so an untouched length round-trips
    # instead of being re-snapped/flipped on a species- or note-only edit.
    @member_catch.update!(length_unit: "centimeters")
    sign_in_as(@organizer)
    get organizers_catch_path(@member_catch.id)
    assert_select "input[name=length_unit][value=centimeters][checked=checked]"
    assert_select "input[name=length_unit][value=inches][checked=checked]", count: 0
  end

  test "site admin sees the reference-photo upload on a catch detail page" do
    admin = create(:user, club: @club, role: :organizer, admin: true)
    sign_in_as(admin)
    get organizers_catch_path(@member_catch.id)
    assert_response :success
    assert_select "input[type=file][name=photo]"
  end

  test "non-admin organizer does not see the reference-photo upload" do
    sign_in_as(@organizer)
    get organizers_catch_path(@member_catch.id)
    assert_select "input[type=file][name=photo]", count: 0
  end

  test "detail page 404s for an out-of-club catch" do
    sign_in_as(@organizer)
    get organizers_catch_path(@foreign_catch.id)
    assert_response :not_found
  end

  test "index shows an informational flag in its own style and never hides a needs-review state" do
    sign_in_as(@organizer)
    create(:catch, user: @member, flags: %w[no_draw_ticket], status: :synced,
                   captured_at_device: 2.hours.ago)
    flagged = create(:catch, user: @member, flags: %w[no_draw_ticket], status: :needs_review,
                     captured_at_device: 1.hour.ago)

    get organizers_catches_path
    assert_response :success
    assert_select "[data-flag='no_draw_ticket']", count: 2
    assert_select "[data-flag='no_draw_ticket'].bg-amber-900\\/40", { count: 0 }, "informational, not a review badge"
    cards = css_select("ul > li")
    card_for = ->(c) { cards.find { |li| li.css("a[href='#{organizers_catch_path(c.id)}']").any? } }
    assert_match(/needs review/, card_for.call(flagged).text, "the informational flag must not hide the review state")
    assert_equal 1, cards.count { |li| li.text.include?("needs review") }, "only the judge-flagged catch needs review"
  end

  test "index links each catch to its detail page" do
    sign_in_as(@organizer)
    get organizers_catches_path
    assert_select "a[href=?]", organizers_catch_path(@member_catch.id)
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  test "organizer can correct a Tagged Walleye science tag" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    fish = create(:catch, user: @member, species: tagged, length_inches: 18.0, tag_number: "X1795\u201d")
    sign_in_as(@organizer)
    patch organizers_catch_path(fish.id), params: {
      species_id: tagged.id, length: "18", length_unit: "inches", tag_number: "X1795", note: "typo"
    }
    assert_redirected_to organizers_catch_path(fish.id)
    assert_equal "X1795", fish.reload.tag_number
  end

  test "changing the drawn winner's species away from Tagged Walleye says the draw is void" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    walleye = Species.find_or_create_by!(name: "Walleye")
    t = build(:tournament, club: @club, format: :tagged, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: @member)
    drawn = create(:catch, user: @member, species: tagged, length_inches: 19.0,
                   tag_number: "A0001", captured_at_device: 2.hours.ago)
    Catches::PlaceInSlots.call(catch: drawn)
    Tournaments::DrawTaggedWinner.call(tournament: t.reload, drawn_by: @organizer)

    sign_in_as(@organizer)
    patch organizers_catch_path(drawn.id), params: {
      species_id: walleye.id, length: "19", length_unit: "inches", tag_number: "", note: "mis-ID"
    }
    assert_redirected_to organizers_catch_path(drawn.id)
    assert_equal walleye, drawn.reload.species
    assert_match(/Catch updated\..*draw is void/, flash[:notice])
  end

  test "adding a tag after the draw says no ticket was issued" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    t = build(:tournament, club: @club, format: :tagged, mode: :solo,
              starts_at: 3.hours.ago, ends_at: 1.hour.ago)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: @member)
    drawn = create(:catch, user: @member, species: tagged, length_inches: 19.0,
                   tag_number: "A0001", captured_at_device: 2.hours.ago)
    Catches::PlaceInSlots.call(catch: drawn)
    Tournaments::DrawTaggedWinner.call(tournament: t.reload, drawn_by: @organizer)
    stranded = create(:catch, user: @member, species: tagged, length_inches: 18.0,
                      tag_number: "TMP", captured_at_device: 90.minutes.ago)
    stranded.update_column(:tag_number, nil)

    sign_in_as(@organizer)
    patch organizers_catch_path(stranded.id), params: {
      species_id: tagged.id, length: "18", length_unit: "inches", tag_number: "A0042", note: "from photo"
    }

    assert_redirected_to organizers_catch_path(stranded.id)
    assert_match(/no ticket was issued/, flash[:notice])
    assert_equal "A0042", stranded.reload.tag_number
    assert_equal 0, CatchPlacement.where(tournament: t, catch: stranded).count
  end

  test "edit form shows the current science tag" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    fish = create(:catch, user: @member, species: tagged, length_inches: 18.0, tag_number: "A0042")
    sign_in_as(@organizer)
    get organizers_catch_path(fish.id)
    assert_select "input[name=tag_number][value=A0042]"
  end

  test "blanking the tag on a Tagged Walleye redirects with the validation message" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    fish = create(:catch, user: @member, species: tagged, length_inches: 18.0, tag_number: "A0042")
    sign_in_as(@organizer)
    patch organizers_catch_path(fish.id), params: {
      species_id: tagged.id, length: "18", length_unit: "inches", tag_number: "", note: ""
    }
    assert_redirected_to organizers_catch_path(fish.id)
    assert_match(/required for Tagged Walleye/, flash[:alert])
    assert_equal "A0042", fish.reload.tag_number
  end
  test "edit form hides the science tag field for a species that is not Tagged Walleye" do
    fish = create(:catch, user: @member, length_inches: 18.0)
    sign_in_as(@organizer)
    get organizers_catch_path(fish.id)
    assert_select "[data-tag-field-target='wrapper'].hidden input[name=tag_number]"
  end

  test "edit form shows the science tag field for a non-Tagged-Walleye catch that carries a stray tag" do
    fish = create(:catch, user: @member, length_inches: 18.0, tag_number: "STRAY")
    sign_in_as(@organizer)
    get organizers_catch_path(fish.id)
    assert_select "[data-tag-field-target='wrapper']:not(.hidden) input[name=tag_number][value=STRAY]"
  end
end
