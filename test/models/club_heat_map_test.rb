require "test_helper"

class ClubHeatMapTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
  end

  test "a new club has the heat map off and the default display values" do
    club = Club.find(@club.id)
    assert_equal false, club.heat_map_enabled
    assert_equal 25, club.heat_map_radius
    assert_equal 15, club.heat_map_blur
    assert_equal 5, club.heat_map_max
    assert_equal 30, club.heat_map_min_opacity
  end

  test "the constants match the column defaults" do
    Club::HEAT_MAP_DEFAULTS.each do |attribute, value|
      assert_equal value, Club.column_defaults[attribute.to_s], attribute
    end
  end

  test "each display value accepts both ends of its range and rejects one past either end" do
    Club::HEAT_MAP_RANGES.each do |attribute, range|
      [range.min, range.max].each do |value|
        @club.assign_attributes(attribute => value)
        assert @club.valid?, "#{attribute}=#{value} should be valid: #{@club.errors.full_messages}"
      end
      [range.min - 1, range.max + 1].each do |value|
        @club.assign_attributes(attribute => value)
        assert_not @club.valid?, "#{attribute}=#{value} should be invalid"
        assert @club.errors[attribute].any?, "#{attribute}=#{value} should carry the error"
      end
      @club.restore_attributes
    end
  end

  test "each display value rejects non-integers and blanks" do
    Club::HEAT_MAP_RANGES.each_key do |attribute|
      ["abc", "12.5", "", nil].each do |value|
        @club.assign_attributes(attribute => value)
        assert_not @club.valid?, "#{attribute}=#{value.inspect} should be invalid"
      end
      @club.restore_attributes
    end
  end

  test "heat_map_options is in the shape the map needs, with the percentage as a fraction" do
    @club.update!(heat_map_radius: 40, heat_map_blur: 10, heat_map_max: 8, heat_map_min_opacity: 45)

    assert_equal({ radius: 40, blur: 10, max: 8, minOpacity: 0.45 }, @club.heat_map_options)
  end

  test "heat_map_options at the defaults" do
    assert_equal({ radius: 25, blur: 15, max: 5, minOpacity: 0.3 }, @club.heat_map_options)
  end
end
