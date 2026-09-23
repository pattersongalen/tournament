require "test_helper"

# #show and #update are the shared CatchDetailEditing concern (also included
# by Organizers::CatchesController, which carries the full behavioural suite
# for editing: unit-snap, invalid-length handling, out-of-club 404, the
# non-organizer gates). This file keeps one smoke each for #show and #update
# and stays thorough on #index, which is admin-only filtering/scoping logic
# that has no organizers-side twin.
class Admin::CatchesControllerTest < ActionDispatch::IntegrationTest
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
    get admin_catches_path
    assert_response :forbidden
  end

  test "organizer sees the club's catches but not other clubs'" do
    sign_in_as(@organizer)
    get admin_catches_path
    assert_response :success
    assert_includes response.body, "Club Carl"
    refute_includes response.body, "Outsider Olive"
  end

  test "user_id filter scopes the catch list to the selected user" do
    other_member = create(:user, club: @club, name: "Other Member", role: :member)
    create(:catch, user: other_member, length_inches: 14.0)
    sign_in_as(@organizer)
    get admin_catches_path, params: { user_id: @member.id }

    assert_select "ul.grid li", minimum: 1 do
      assert_select "*", text: /Club Carl/
    end
    assert_select "ul.grid li *", text: /Other Member/, count: 0
  end

  # update smoke
  test "organizer can update an in-club catch's length and species" do
    walleye = create(:species)
    sign_in_as(@organizer)
    assert_difference "JudgeAction.count", 1 do
      patch admin_catch_path(@member_catch.id), params: {
        species_id: walleye.id, length: "19.5", length_unit: "inches", note: "remeasured"
      }
    end
    assert_redirected_to admin_catch_path(@member_catch.id)
    @member_catch.reload
    assert_equal 19.5, @member_catch.length_inches.to_f
    assert_equal walleye.id, @member_catch.species_id
  end

  # show smoke
  test "organizer sees the edit form on an in-club catch detail page" do
    sign_in_as(@organizer)
    get admin_catch_path(@member_catch.id)
    assert_response :success
    assert_select "select[name=species_id]"
    assert_select "input[name=length]"
    assert_includes response.body, "Club Carl"
  end

  test "index links each catch to its detail page" do
    sign_in_as(@organizer)
    get admin_catches_path
    assert_select "a[href=?]", admin_catch_path(@member_catch.id)
  end

  test "with no params, admin sees all club submissions (not just one day)" do
    today_c = create(:catch, user: @member, captured_at_device: Time.zone.now.change(hour: 12))
    old_c   = create(:catch, user: @member, captured_at_device: 10.days.ago.change(hour: 12))
    sign_in_as(@organizer)
    get admin_catches_path
    assigned = assigns(:catches).to_a
    assert_includes assigned, today_c
    assert_includes assigned, old_c
    assert_nil assigns(:selected_start)
    assert_nil assigns(:selected_end)
  end

  test "species filter narrows the admin catch list" do
    pike    = create(:species, name: "Pike")
    walleye = create(:species, name: "Walleye")
    pc = create(:catch, user: @member, species: pike,    captured_at_device: 1.day.ago)
    wc = create(:catch, user: @member, species: walleye, captured_at_device: 1.day.ago)
    sign_in_as(@organizer)
    get admin_catches_path, params: { species: pike.id }
    assigned = assigns(:catches).to_a
    assert_includes assigned, pc
    refute_includes assigned, wc
  end

  test "explicit start/end narrows the admin catch list" do
    in_range = create(:catch, user: @member, captured_at_device: Time.zone.parse("2026-05-08 10:00"))
    out      = create(:catch, user: @member, captured_at_device: Time.zone.parse("2026-05-20 10:00"))
    sign_in_as(@organizer)
    get admin_catches_path, params: { start: "2026-05-05", end: "2026-05-12" }
    assigned = assigns(:catches).to_a
    assert_includes assigned, in_range
    refute_includes assigned, out
  end

  test "time-of-day filter narrows the admin catch list" do
    dawn = create(:catch, user: @member, captured_at_device: Time.zone.now.change(hour: 5))
    noon = create(:catch, user: @member, captured_at_device: Time.zone.now.change(hour: 12))
    sign_in_as(@organizer)
    get admin_catches_path, params: { tod: "dawn" }
    assigned = assigns(:catches).to_a
    assert_includes assigned, dawn
    refute_includes assigned, noon
  end

  test "member filter composes with a species filter" do
    pike    = create(:species, name: "Pike")
    walleye = create(:species, name: "Walleye")
    other = create(:user, club: @club, name: "Dana Diver", role: :member)
    mine        = create(:catch, user: @member, species: pike,    captured_at_device: 1.day.ago)
    mine_other  = create(:catch, user: @member, species: walleye, captured_at_device: 1.day.ago)
    theirs      = create(:catch, user: other,   species: pike,    captured_at_device: 1.day.ago)
    sign_in_as(@organizer)
    get admin_catches_path, params: { user_id: @member.id, species: pike.id }
    assigned = assigns(:catches).to_a
    assert_includes assigned, mine
    refute_includes assigned, mine_other
    refute_includes assigned, theirs
  end

  test "calendar counts exclude other-club catches" do
    day = Date.current
    create(:catch, user: @foreign, captured_at_device: Time.zone.now.change(hour: 12)) # other club
    club_today = Catch.where(user_id: @club.members.select(:id))
                      .where(captured_at_device: day.beginning_of_day..day.end_of_day).count
    sign_in_as(@organizer)
    get admin_catches_path
    assert_equal club_today, assigns(:counts_by_date)[day]
  end

  test "admin index renders the filter bar, match-conditions panel, and calendar" do
    sign_in_as(@organizer)
    get admin_catches_path
    assert_response :success
    assert_select "select[name=species]"
    assert_select "select[name=lake]"
    assert_select "[data-test=match-conditions-toggle]"
    assert_select "[data-test=catch-calendar]"
  end

  test "member dropdown carries an active filter through as a hidden field" do
    sign_in_as(@organizer)
    get admin_catches_path, params: { species: "5" }
    member_form = css_select("form").find { |f| f.css("select[name=user_id]").any? }
    assert member_form, "expected a form containing the member dropdown"
    assert member_form.css("input[type=hidden][name=species][value='5']").any?,
           "member dropdown form should carry the active species filter through as a hidden field"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
