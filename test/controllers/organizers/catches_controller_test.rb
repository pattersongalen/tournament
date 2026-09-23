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
end
