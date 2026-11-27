require "test_helper"

class Admin::Clubs::HeatMapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create(:user, club: create(:club, name: "Admin Home FC"), admin: true)
    @club = create(:club, name: "Target FC")
    @angler = create(:user, club: @club, name: "Secretive Sam")
    @walleye = create(:species, name: "Walleye")
  end

  def log_catch(**overrides)
    attrs = { user: @angler, species: @walleye, length_inches: 20, status: :synced,
              latitude: 49.76, longitude: -95.19, captured_at_device: 10.days.ago }.merge(overrides)
    create(:catch, **attrs)
  end

  def valid_params(overrides = {})
    { club: { heat_map_enabled: "1", heat_map_radius: "40", heat_map_blur: "10",
              heat_map_max: "8", heat_map_min_opacity: "45" }.merge(overrides) }
  end

  test "only a site admin can see or change the settings" do
    organizer = create(:user, club: @club, role: :organizer)
    member = create(:user, club: @club, role: :member)
    deputy = create(:user, club: @club, role: :member)
    upcoming = create(:tournament, club: @club, starts_at: 2.days.from_now, ends_at: 3.days.from_now)
    create(:tournament_deputy, tournament: upcoming, user: deputy, granted_by_user: organizer)

    { "organizer" => organizer, "member" => member, "deputy" => deputy }.each do |label, user|
      sign_in_as(user)

      get edit_admin_club_heat_map_path(@club)
      assert_response :forbidden, "#{label}: edit"

      patch admin_club_heat_map_path(@club), params: valid_params
      assert_response :forbidden, "#{label}: update"
      assert_equal false, @club.reload.heat_map_enabled, "#{label}: switch untouched"
      assert_equal 25, @club.heat_map_radius, "#{label}: radius untouched"
    end
  end

  test "the page shows the switch, the warning and a slider per display value" do
    sign_in_as(@admin)
    get edit_admin_club_heat_map_path(@club)

    assert_response :success
    assert_select "input[type=checkbox][name='club[heat_map_enabled]']"
    assert_select "label", text: "Members can see the club heat map"
    assert_select "p", text: "While this is on, every member of the club can see the exact location of every catch logged by the club's members."

    { heat_map_radius: [5, 60, 25], heat_map_blur: [1, 40, 15],
      heat_map_max: [1, 20, 5], heat_map_min_opacity: [1, 80, 30] }.each do |attribute, (min, max, value)|
      assert_select "input[type=range][name='club[#{attribute}]'][min='#{min}'][max='#{max}'][value='#{value}']" \
                    "[data-default='#{value}']", 1, attribute.to_s
    end
    assert_select "button", text: "Reset to defaults"
  end

  test "saving turns the switch on and stores the display values" do
    sign_in_as(@admin)
    patch admin_club_heat_map_path(@club), params: valid_params

    assert_redirected_to admin_club_path(@club)
    @club.reload
    assert_equal true, @club.heat_map_enabled
    assert_equal [40, 10, 8, 45],
                 [@club.heat_map_radius, @club.heat_map_blur, @club.heat_map_max, @club.heat_map_min_opacity]
  end

  test "saving with the box unticked turns the switch off" do
    @club.update!(heat_map_enabled: true)
    sign_in_as(@admin)
    patch admin_club_heat_map_path(@club), params: valid_params(heat_map_enabled: "0")

    assert_equal false, @club.reload.heat_map_enabled
  end

  test "an invalid display value is a 422 and saves nothing, including the switch" do
    sign_in_as(@admin)
    {
      "radius too big"     => { heat_map_radius: "61" },
      "radius too small"   => { heat_map_radius: "4" },
      "blur not a number"  => { heat_map_blur: "abc" },
      # Leaflet.heat reads a blur or a floor of 0 as "not set" and draws its
      # own default, so 0 is not on offer.
      "blur zero"          => { heat_map_blur: "0" },
      "max zero"           => { heat_map_max: "0" },
      "opacity too high"   => { heat_map_min_opacity: "81" },
      "opacity zero"       => { heat_map_min_opacity: "0" },
      "decimal"            => { heat_map_radius: "12.5" },
      "blank"              => { heat_map_max: "" }
    }.each do |label, overrides|
      patch admin_club_heat_map_path(@club), params: valid_params(overrides)

      assert_response :unprocessable_entity, label
      @club.reload
      assert_equal false, @club.heat_map_enabled, "#{label}: switch not saved"
      assert_equal [25, 15, 5, 30],
                   [@club.heat_map_radius, @club.heat_map_blur, @club.heat_map_max, @club.heat_map_min_opacity],
                   "#{label}: values not saved"
    end
  end

  test "a failed save re-renders with the saved values and an error message" do
    sign_in_as(@admin)
    patch admin_club_heat_map_path(@club), params: valid_params(heat_map_radius: "999")

    assert_select "#heat-map-errors", 1
    assert_select "input[type=range][name='club[heat_map_radius]'][value='25']", 1
    options = JSON.parse(css_select("#heat-map-preview").first["data-heat-map-options-value"])
    assert_equal 25, options["radius"]
  end

  test "the preview carries this club's catches from the last 12 months, as coordinates only" do
    caught = log_catch(latitude: 49.5, longitude: -95.5, note: "UNIQUE-NOTE-TEXT")
    log_catch(latitude: 48.0, longitude: -94.0, captured_at_device: 13.months.ago)
    log_catch(latitude: 47.0, longitude: -93.0, status: :disqualified)
    other_club = create(:club)
    log_catch(user: create(:user, club: other_club), latitude: 10.0, longitude: 10.0)

    sign_in_as(@admin)
    get edit_admin_club_heat_map_path(@club)

    preview = css_select("#heat-map-preview").first
    assert_equal [[49.5, -95.5]], JSON.parse(preview["data-heat-map-points-value"])
    assert_equal "This club has no catches with GPS yet.", preview["data-heat-map-empty-value"]
    assert_not_includes response.body, "Secretive Sam"
    assert_not_includes response.body, "UNIQUE-NOTE-TEXT"
    assert_not_includes response.body, catch_path(caught)
  end

  # The sliders are tuned for what members see, and members see Walleye only.
  test "the preview plots Walleye only, as the member map does" do
    log_catch(latitude: 49.5, longitude: -95.5)
    log_catch(species: create(:species, name: "Pike"), latitude: 48.0, longitude: -94.0)
    log_catch(species: create(:species, name: Species::TAGGED_WALLEYE_NAME), tag_number: "T100",
              latitude: 47.0, longitude: -93.0)

    sign_in_as(@admin)
    get edit_admin_club_heat_map_path(@club)

    preview = css_select("#heat-map-preview").first
    assert_equal [[49.5, -95.5]], JSON.parse(preview["data-heat-map-points-value"])
    assert_select "p", text: /last 12 months, Walleye only, as members see it: 1 catch\./
  end

  test "the preview works while the switch is off" do
    log_catch
    sign_in_as(@admin)
    get edit_admin_club_heat_map_path(@club)

    assert_equal false, @club.reload.heat_map_enabled
    assert_equal 1, JSON.parse(css_select("#heat-map-preview").first["data-heat-map-points-value"]).size
  end

  test "the preview uses the club's saved display options" do
    @club.update!(heat_map_radius: 40, heat_map_min_opacity: 45)
    sign_in_as(@admin)
    get edit_admin_club_heat_map_path(@club)

    options = JSON.parse(css_select("#heat-map-preview").first["data-heat-map-options-value"])
    assert_equal({ "radius" => 40, "blur" => 15, "max" => 5, "minOpacity" => 0.45 }, options)
  end

  test "a missing club parameter is a 400, not a 500" do
    sign_in_as(@admin)
    patch admin_club_heat_map_path(@club)
    assert_response :bad_request
  end

  test "the form cannot change anything else about the club" do
    sign_in_as(@admin)
    patch admin_club_heat_map_path(@club),
          params: valid_params(name: "Renamed", recovery_tool_enabled: "1", banner_message: "Hacked")

    @club.reload
    assert_equal "Target FC", @club.name
    assert_equal false, @club.recovery_tool_enabled
    assert_nil @club.banner_message
  end

  test "the club page shows the card with the current state" do
    sign_in_as(@admin)

    get admin_club_path(@club)
    assert_select "a[href=?]", edit_admin_club_heat_map_path(@club) do
      assert_select "[data-heat-map-state]", text: "Off"
    end

    @club.update!(heat_map_enabled: true)
    get admin_club_path(@club)
    assert_select "a[href=?] [data-heat-map-state]", edit_admin_club_heat_map_path(@club), text: "On"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
