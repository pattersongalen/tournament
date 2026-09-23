require "test_helper"

class Admin::Clubs::SeasonPointsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @home_club = create(:club, name: "Admin Home FC")
    @admin     = create(:user, club: @home_club, admin: true)
    @organizer = create(:user, club: @home_club, role: :organizer)

    @target_club = create(:club, name: "Target FC")
  end

  test "a club organizer without the site-admin flag is forbidden" do
    sign_in_as(@organizer)
    get edit_admin_club_season_points_path(@target_club)
    assert_response :forbidden
  end

  test "admin sees the editor with the current settings and a preview" do
    sign_in_as(@admin)
    get edit_admin_club_season_points_path(@target_club)
    assert_response :success
    assert_includes response.body, "Season points"
    assert_includes response.body, "9, 6, 3"
  end

  test "update saves the scheme, amounts, and ladders" do
    sign_in_as(@admin)
    patch admin_club_season_points_path(@target_club), params: {
      club: {
        season_points_scheme: "full_field",
        season_points_attendance: "1.0",
        season_points_min_entries: "4",
        season_points_ladders_text: ["10, 8, 6", "12, 10, 8", "14, 12, 10", "16, 14, 12"],
        season_points_base_ladder_text: "5, 4, 3",
        season_points_tier_multipliers_text: "1, 1.5, 2, 2.5"
      }
    }
    assert_redirected_to admin_club_path(@target_club)

    @target_club.reload
    assert_equal "full_field", @target_club.season_points_scheme
    assert_equal 1.0, @target_club.season_points_attendance.to_f
    assert_equal 4, @target_club.season_points_min_entries
    assert_equal [10.0, 8.0, 6.0], @target_club.season_points_ladders.first
    assert_equal [5.0, 4.0, 3.0], @target_club.season_points_base_ladder
    assert_equal [1.0, 1.5, 2.0, 2.5], @target_club.season_points_tier_multipliers
  end

  test "invalid input re-renders the form as 422 and changes nothing" do
    sign_in_as(@admin)
    patch admin_club_season_points_path(@target_club), params: {
      club: {
        season_points_scheme: "tiered_ladders",
        season_points_attendance: "0.5",
        season_points_min_entries: "3",
        season_points_ladders_text: ["1, 2, 3", "6, 4, 2", "9, 6, 3", "9, 6, 3"],
        season_points_base_ladder_text: "3, 2, 1",
        season_points_tier_multipliers_text: "1, 2, 3, 3"
      }
    }
    assert_response :unprocessable_entity
    assert_equal [[3, 2, 1], [6, 4, 2], [9, 6, 3], [9, 6, 3]], @target_club.reload.season_points_ladders
  end

  # FIX 1 regression, end to end through the controller/view: a typo in one
  # band used to shift the OTHER bands' displayed text down a slot on 422
  # re-render, so retyping just the broken band and resubmitting the rest
  # (as shown) silently saved a ladder against the wrong band.
  test "a typo in one band, fixed and resubmitted, saves every band against its original position" do
    sign_in_as(@admin)
    @target_club.update!(
      season_points_ladders: [[10, 8, 6], [12, 10, 8], [14, 12, 10], [16, 14, 12]]
    )

    patch admin_club_season_points_path(@target_club), params: {
      club: {
        season_points_scheme: "tiered_ladders",
        season_points_attendance: "0.5",
        season_points_min_entries: "3",
        season_points_ladders_text: ["10, 8, 6", "12,1O,8", "14, 12, 10", "16, 14, 12"],
        season_points_base_ladder_text: "3, 2, 1",
        season_points_tier_multipliers_text: "1, 2, 3, 3"
      }
    }
    assert_response :unprocessable_entity
    assert_select "input[name='club[season_points_ladders_text][]']" do |inputs|
      assert_equal "10, 8, 6",   inputs[0]["value"]
      assert_equal "12,1O,8",    inputs[1]["value"]
      assert_equal "14, 12, 10", inputs[2]["value"]
      assert_equal "16, 14, 12", inputs[3]["value"]
    end

    patch admin_club_season_points_path(@target_club), params: {
      club: {
        season_points_scheme: "tiered_ladders",
        season_points_attendance: "0.5",
        season_points_min_entries: "3",
        season_points_ladders_text: ["10, 8, 6", "12, 10, 8", "14, 12, 10", "16, 14, 12"],
        season_points_base_ladder_text: "3, 2, 1",
        season_points_tier_multipliers_text: "1, 2, 3, 3"
      }
    }
    assert_redirected_to admin_club_path(@target_club)
    assert_equal [[10.0, 8.0, 6.0], [12.0, 10.0, 8.0], [14.0, 12.0, 10.0], [16.0, 14.0, 12.0]],
                 @target_club.reload.season_points_ladders
  end

  test "an out-of-range scheme is a 422, not a 500" do
    sign_in_as(@admin)
    patch admin_club_season_points_path(@target_club), params: {
      club: {
        season_points_scheme: "nonsense",
        season_points_attendance: "0.5",
        season_points_min_entries: "3",
        season_points_ladders_text: ["3, 2, 1", "6, 4, 2", "9, 6, 3", "9, 6, 3"],
        season_points_base_ladder_text: "3, 2, 1",
        season_points_tier_multipliers_text: "1, 2, 3, 3"
      }
    }
    assert_response :unprocessable_entity
    assert_equal "tiered_ladders", @target_club.reload.season_points_scheme
  end

  # The 422 re-render used to 500 when a numeric field came back blank: the
  # "What the saved settings pay" preview read the invalid in-memory record
  # (Integer <=> nil inside PointsScale; format("%.2f", nil) for attendance).
  test "blank minimum entries or attendance re-renders as 422, not a 500" do
    sign_in_as(@admin)
    { "season_points_min_entries" => "", "season_points_attendance" => "" }.each do |field, blank|
      patch admin_club_season_points_path(@target_club), params: { club: valid_params.merge(field => blank) }
      assert_response :unprocessable_entity, "#{field} blank"
      assert_includes response.body, "9, 6, 3", "#{field} blank: the preview still shows the SAVED ladder"
    end
    assert_equal 3, @target_club.reload.season_points_min_entries
  end

  # decimal(5,2) and int4 columns raise ActiveRecord::RangeError at save for
  # values that pass `valid?`; that is a 500, not a 422, unless validated.
  test "out-of-range amounts are a 422, not a database RangeError" do
    sign_in_as(@admin)
    { "season_points_attendance" => "1000", "season_points_min_entries" => "99999999999" }.each do |field, value|
      patch admin_club_season_points_path(@target_club), params: { club: valid_params.merge(field => value) }
      assert_response :unprocessable_entity, "#{field}=#{value}"
    end
    assert_equal 0.5, @target_club.reload.season_points_attendance.to_f
  end

  # A junk base ladder / multiplier list used to come back as an EMPTY field on
  # 422 (typed text lost) while the preview ran against the in-memory [] and
  # showed blank cells or "0, 0, 0" under a heading that says "saved settings".
  test "junk base-ladder or multiplier text re-renders as typed and the preview keeps the saved values" do
    sign_in_as(@admin)
    @target_club.update!(season_points_scheme: "base_ladder")
    {
      "season_points_base_ladder_text"     => "3, 2, x",
      "season_points_tier_multipliers_text" => "1, 1.5, 2, 2.S"
    }.each do |field, junk|
      patch admin_club_season_points_path(@target_club),
            params: { club: valid_params.merge("season_points_scheme" => "base_ladder", field => junk) }
      assert_response :unprocessable_entity, field
      assert_select "input[name='club[#{field}]'][value='#{junk}']", true, "#{field}: typed text is echoed"
      preview = css_select("table").last.text
      assert_match "3, 2, 1", preview, "#{field}: preview shows the saved base ladder x1"
      assert_no_match(/0, 0, 0/, preview, "#{field}: preview must not run against an in-memory []")
    end
  end

  private

  def valid_params
    {
      "season_points_scheme" => "tiered_ladders",
      "season_points_attendance" => "0.5",
      "season_points_min_entries" => "3",
      "season_points_ladders_text" => ["3, 2, 1", "6, 4, 2", "9, 6, 3", "9, 6, 3"],
      "season_points_base_ladder_text" => "3, 2, 1",
      "season_points_tier_multipliers_text" => "1, 2, 3, 3"
    }
  end

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
