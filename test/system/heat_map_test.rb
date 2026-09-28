require "application_system_test_case"

class HeatMapSystemTest < ApplicationSystemTestCase
  HEAT_PIXELS_JS = <<~JS
    (function (selector) {
      var canvas = document.querySelector(selector + " canvas.leaflet-heatmap-layer");
      if (!canvas) return -1;
      var data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
      var painted = 0;
      for (var i = 3; i < data.length; i += 4) { if (data[i] > 0) painted++; }
      return painted;
    })
  JS

  setup do
    @club = create(:club)
    @club.update!(heat_map_enabled: true)
    @member = create(:user, club: @club)
    @angler = create(:user, club: @club)
    @walleye = create(:species, name: "Walleye")
    @pike = create(:species, name: "Pike")
  end

  def log_catch(**overrides)
    attrs = { user: @angler, species: @walleye, length_inches: 20, status: :synced,
              latitude: 49.76, longitude: -95.19, captured_at_device: 10.days.ago }.merge(overrides)
    create(:catch, **attrs)
  end

  def heat_pixels(selector)
    page.evaluate_script("#{HEAT_PIXELS_JS}(#{selector.to_json})")
  end

  def wait_for_heat(selector)
    assert page.has_css?("#{selector} canvas.leaflet-heatmap-layer", wait: 10), "the heat canvas should exist"
    20.times do
      return if heat_pixels(selector).positive?
      sleep 0.25
    end
    flunk "the heat canvas never painted"
  end

  test "a member's map draws heat for Walleye only, with no species boxes" do
    3.times { |i| log_catch(species: @walleye, latitude: 49.76 + i * 0.002) }
    2.times { |i| log_catch(species: @pike, latitude: 49.70 + i * 0.002) }

    sign_in_as(@member)
    visit map_catches_path
    click_link "Club heat map"

    assert_text "Showing 3 catches"
    assert_text "Showing Walleye"
    assert_no_field "Pike"
    wait_for_heat("#heat-map")

    fill_in "Min length (in)", with: "30"
    click_button "Update map"

    assert_text "Showing 0 catches"
    assert_text "No catches match these filters."
  end

  test "a site admin's map draws heat, and unticking a species changes the count and the map" do
    3.times { |i| log_catch(species: @walleye, latitude: 49.76 + i * 0.002) }
    2.times { |i| log_catch(species: @pike, latitude: 49.70 + i * 0.002) }

    sign_in_as(create(:user, club: @club, admin: true))
    visit map_catches_path
    click_link "Club heat map"

    assert_text "Showing 5 catches"
    wait_for_heat("#heat-map")

    uncheck "Pike"
    click_button "Update map"

    assert_text "Showing 3 catches"
    wait_for_heat("#heat-map")
    assert_no_checked_field "Pike"
    assert_checked_field "Walleye"
  end

  test "Select none then Update map shows the empty state and no canvas" do
    log_catch
    sign_in_as(create(:user, club: @club, admin: true))
    visit heat_map_catches_path
    wait_for_heat("#heat-map")

    click_button "Select none"
    click_button "Update map"

    assert_text "No catches match these filters."
    assert_text "Showing 0 catches"
    assert page.has_no_css?("#heat-map canvas")
  end

  # Review Focus 3: one catch has zero-size bounds.
  test "a club with a single catch opens at a sensible zoom" do
    log_catch
    sign_in_as(@member)
    visit heat_map_catches_path

    wait_for_heat("#heat-map")
    zoom = page.evaluate_script(<<~JS)
      (function () {
        var tile = document.querySelector("#heat-map img.leaflet-tile");
        if (!tile) return null;
        var match = tile.src.match(/\\/(\\d+)\\/\\d+\\/\\d+\\.png/);
        return match ? parseInt(match[1], 10) : null;
      })()
    JS
    assert_equal 15, zoom, "a lone catch opens at the capped zoom, not the tiles' maximum"
  end

  # Review Focus 5.
  test "a catch at latitude 0, longitude 0 is drawn" do
    log_catch(latitude: 0, longitude: 0)
    sign_in_as(@member)
    visit heat_map_catches_path

    assert_text "Showing 1 catch"
    wait_for_heat("#heat-map")
  end

  # Leaflet.heat scales every point down by zoom unless told not to: at zoom
  # 15 a catch would count as 1/8, so "Catches needed for red" = 1 would need
  # eight catches, and the map would change brightness as a member zooms.
  test "with red set to one catch and no floor, a single catch is drawn at full strength" do
    @club.update!(heat_map_max: 1, heat_map_min_opacity: 0)
    log_catch
    sign_in_as(@member)
    visit heat_map_catches_path
    wait_for_heat("#heat-map")

    peak = page.evaluate_script(<<~JS)
      (function () {
        var canvas = document.querySelector("#heat-map canvas.leaflet-heatmap-layer");
        var data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
        var peak = 0;
        for (var i = 3; i < data.length; i += 4) { if (data[i] > peak) peak = data[i]; }
        return peak;
      })()
    JS
    assert_operator peak, :>, 200, "one catch at max=1 should reach near-full opacity at its centre"
  end

  # The notice popup must block the map too. Leaflet's panes and zoom buttons
  # carry z-indexes in the hundreds; unless the map container isolates them
  # they paint over the popup.
  test "a due notice covers the map and its zoom buttons" do
    notice = create(:club_notice, club: @club, title: "Read me", starts_on: Date.current, ends_on: Date.current)
    create(:club_notice_recipient, club_notice: notice, user: @member)
    log_catch
    sign_in_as(@member)
    visit heat_map_catches_path
    assert page.has_css?("#notice-popup")
    assert page.has_css?("#heat-map .leaflet-control-zoom-in", wait: 10)

    on_top = page.evaluate_script(<<~JS)
      (function () {
        function topAt(el) {
          var r = el.getBoundingClientRect();
          var hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          return !!(hit && hit.closest("#notice-popup"));
        }
        document.querySelector("#heat-map").scrollIntoView({ block: "center" });
        return {
          zoom: topAt(document.querySelector("#heat-map .leaflet-control-zoom-in")),
          map: topAt(document.querySelector("#heat-map")),
          button: topAt(document.querySelector("#notice-popup button"))
        };
      })()
    JS
    assert_equal({ "zoom" => true, "map" => true, "button" => true }, on_top)
  end

  test "going Back to the heat map rebuilds one map, not two" do
    log_catch
    sign_in_as(@member)
    visit heat_map_catches_path
    wait_for_heat("#heat-map")

    click_link "My map"
    assert_text "Fishing Map"
    page.go_back

    wait_for_heat("#heat-map")
    assert_equal 1, page.all("#heat-map canvas.leaflet-heatmap-layer").size
    assert_equal 1, page.all("#heat-map .leaflet-map-pane").size
  end

  test "on the admin page a slider redraws the preview, and Save keeps the value" do
    8.times { |i| log_catch(latitude: 49.76 + i * 0.01, longitude: -95.19 + i * 0.01) }
    admin = create(:user, club: @club, admin: true)

    sign_in_as(admin)
    visit edit_admin_club_heat_map_path(@club)
    wait_for_heat("#heat-map-preview")
    small = heat_pixels("#heat-map-preview")

    page.execute_script(<<~JS)
      var slider = document.querySelector("input[name='club[heat_map_radius]']");
      slider.value = 60;
      slider.dispatchEvent(new Event("input", { bubbles: true }));
    JS

    assert_selector "output[data-output-for='radius']", text: "60 px"
    bigger = nil
    20.times do
      bigger = heat_pixels("#heat-map-preview")
      break if bigger > small
      sleep 0.25
    end
    assert_operator bigger, :>, small, "a larger radius paints more of the preview"
    assert_equal 25, @club.reload.heat_map_radius, "moving a slider saves nothing"

    click_button "Save"

    assert_text "Heat map settings saved."
    assert_equal 60, @club.reload.heat_map_radius
  end

  test "Reset to defaults puts the sliders back without saving" do
    @club.update!(heat_map_radius: 50, heat_map_blur: 30, heat_map_max: 12, heat_map_min_opacity: 60)
    log_catch
    admin = create(:user, club: @club, admin: true)

    sign_in_as(admin)
    visit edit_admin_club_heat_map_path(@club)
    assert_selector "output[data-output-for='radius']", text: "50 px"

    click_button "Reset to defaults"

    assert_selector "output[data-output-for='radius']", text: "25 px"
    assert_selector "output[data-output-for='blur']", text: "15 px"
    assert_selector "output[data-output-for='max']", text: /\A5\z/
    assert_selector "output[data-output-for='minOpacity']", text: "30%"
    assert_equal 50, @club.reload.heat_map_radius
  end
end
