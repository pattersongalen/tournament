require "test_helper"

class CatchesHeatMapTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club, name: "Heat FC")
    @club.update!(heat_map_enabled: true)
    @member = create(:user, club: @club, name: "Viewer Vic")
    @angler = create(:user, club: @club, name: "Secretive Sam")
    @walleye = create(:species, name: "Walleye")
    @pike = create(:species, name: "Pike")
  end

  def log_catch(**overrides)
    attrs = { user: @angler, species: @walleye, length_inches: 20, status: :synced,
              latitude: 49.76, longitude: -95.19, captured_at_device: 10.days.ago }.merge(overrides)
    create(:catch, **attrs)
  end

  def points_on_page
    JSON.parse(css_select("#heat-map").first["data-heat-map-points-value"])
  end

  test "access: who can open the page, by club switch" do
    organizer = create(:user, club: @club, role: :organizer)
    site_admin = create(:user, club: @club, admin: true)

    { "member" => @member, "organizer" => organizer, "site admin" => site_admin }.each do |label, user|
      sign_in_as(user)

      @club.update!(heat_map_enabled: true)
      get heat_map_catches_path
      assert_response :success, "#{label}, switch on"

      @club.update!(heat_map_enabled: false)
      get heat_map_catches_path
      assert_response :not_found, "#{label}, switch off"
    end
  end

  test "a signed-out visitor is sent to sign in" do
    get heat_map_catches_path
    assert_redirected_to new_session_path
  end

  test "a member with no club gets a 404" do
    sign_in_as(create(:user, club: nil))
    get heat_map_catches_path
    assert_response :not_found
  end

  # Review Focus 4.
  test "turning the switch off removes the page and the Fishing map button" do
    sign_in_as(@member)

    get map_catches_path
    assert_select "a[href=?]", heat_map_catches_path, text: "Club heat map"
    get heat_map_catches_path
    assert_response :success

    @club.update!(heat_map_enabled: false)

    get map_catches_path
    assert_select "a[href=?]", heat_map_catches_path, 0
    get heat_map_catches_path
    assert_response :not_found
  end

  test "the page shows other members' catches at their exact coordinates" do
    log_catch(latitude: 49.123456, longitude: -95.654321)
    sign_in_as(@member)
    get heat_map_catches_path

    assert_response :success
    assert_select "h1", text: "Club heat map"
    assert_equal [[49.123456, -95.654321]], points_on_page
    assert_select "#heat-map-count", text: "Showing 1 catch"
  end

  test "the count is pluralised" do
    2.times { log_catch }
    sign_in_as(@member)
    get heat_map_catches_path

    assert_select "#heat-map-count", text: "Showing 2 catches"
  end

  test "the map carries the club's saved display options" do
    @club.update!(heat_map_radius: 40, heat_map_blur: 10, heat_map_max: 8, heat_map_min_opacity: 45)
    log_catch
    sign_in_as(@member)
    get heat_map_catches_path

    options = JSON.parse(css_select("#heat-map").first["data-heat-map-options-value"])
    assert_equal({ "radius" => 40, "blur" => 10, "max" => 8, "minOpacity" => 0.45 }, options)
  end

  test "nothing but coordinates reaches the browser" do
    caught = log_catch(note: "UNIQUE-NOTE-TEXT", length_inches: 23.75, latitude: 49.5, longitude: -95.5)
    sign_in_as(@member)
    get heat_map_catches_path

    assert_not_includes response.body, "Secretive Sam"
    assert_not_includes response.body, "UNIQUE-NOTE-TEXT"
    assert_not_includes response.body, "23.75"
    assert_not_includes response.body, catch_path(caught)
    assert_select "#heat-map img", 0
    assert points_on_page.all? { |point| point.size == 2 }, "each point is exactly [lat, lng]"
  end

  test "another club's catches never appear" do
    other = create(:club)
    log_catch(user: create(:user, club: other), latitude: 10.0, longitude: 10.0)
    log_catch(latitude: 49.0, longitude: -95.0)
    sign_in_as(@member)
    get heat_map_catches_path

    assert_equal [[49.0, -95.0]], points_on_page
  end

  test "each filter narrows the points" do
    log_catch(species: @walleye, length_inches: 15, latitude: 1.0, captured_at_device: 5.days.ago)
    log_catch(species: @walleye, length_inches: 25, latitude: 2.0, captured_at_device: 40.days.ago)
    log_catch(species: @pike,    length_inches: 30, latitude: 3.0, captured_at_device: 5.days.ago)
    sign_in_as(@member)

    lats = ->(params) {
      get heat_map_catches_path, params: params
      assert_response :success
      points_on_page.map(&:first).sort
    }

    assert_equal [1.0, 2.0, 3.0], lats.call({})
    assert_equal [3.0], lats.call(filtered: "1", species: [@pike.id])
    assert_equal [2.0, 3.0], lats.call(min_length: "20")
    assert_equal [1.0], lats.call(max_length: "20")
    assert_equal [1.0, 3.0], lats.call(from: 10.days.ago.to_date.iso8601, to: Date.current.iso8601)
    assert_equal [2.0], lats.call(filtered: "1", species: [@walleye.id], min_length: "20")
  end

  test "unticking every species shows the empty state, not everything" do
    log_catch
    sign_in_as(@member)
    get heat_map_catches_path, params: { filtered: "1" }

    assert_response :success
    assert_equal [], points_on_page
    assert_select "#heat-map[data-heat-map-empty-value=?]", "No catches match these filters."
    assert_select "#heat-map-count", text: "Showing 0 catches"
  end

  test "the form reflects the filters in use" do
    sign_in_as(@member)
    get heat_map_catches_path, params: { filtered: "1", species: [@pike.id], min_length: "18.5",
                                         from: "2026-05-01", to: "2026-06-15" }

    assert_select "form[method=get][action=?]", heat_map_catches_path
    assert_select "input[type=hidden][name=filtered][value='1']"
    assert_select "input[type=checkbox][name='species[]'][value='#{@pike.id}'][checked]", 1
    assert_select "input[type=checkbox][name='species[]'][value='#{@walleye.id}'][checked]", 0
    assert_select "input[name=min_length][value='18.5']"
    assert_select "input[name=max_length]" do |inputs|
      assert_nil inputs.first["value"]
    end
    assert_select "input[type=date][name=from][value='2026-05-01']"
    assert_select "input[type=date][name=to][value='2026-06-15']"
  end

  # Review Focus 1 and 2.
  test "malformed and extreme params never cause an error" do
    log_catch
    sign_in_as(@member)
    [
      { species: @walleye.id.to_s, filtered: "1" },
      { from: ["2026-05-01"], to: { x: "y" } },
      { min_length: { a: "1" }, max_length: ["1"] },
      { min_length: "1e400", max_length: "NaN" },
      { min_length: "-5", max_length: "99999999999999999999" },
      { from: "banana", to: "2026-02-31" },
      { filtered: "1", species: ["banana", "-1", "999999999999999999999"] }
    ].each do |params|
      get heat_map_catches_path, params: params
      assert_response :success, params.inspect
    end
  end

  test "the Fishing map keeps showing only the member's own catches" do
    log_catch(user: @angler, latitude: 49.111, captured_at_device: Time.current)
    sign_in_as(@member)
    get map_catches_path

    assert_response :success
    assert_not_includes response.body, "49.111"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
