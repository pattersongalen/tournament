require "test_helper"

class Catches::HeatMapFiltersTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 9, 27)

  setup do
    @walleye = create(:species, name: "Walleye")
    @pike = create(:species, name: "Pike")
    @species = [@walleye, @pike]
  end

  def filters(params)
    Catches::HeatMapFilters.from_params(ActionController::Parameters.new(params), species: @species, today: TODAY)
  end

  test "with no params: all species, no length limits, the last 12 months" do
    f = filters({})

    assert_equal [@walleye.id, @pike.id].sort, f.species_ids.sort
    assert_nil f.min_length
    assert_nil f.max_length
    assert_equal Date.new(2025, 9, 27), f.from
    assert_equal TODAY, f.to
  end

  test "valid params are used as given" do
    f = filters(filtered: "1", species: [@pike.id.to_s], min_length: "18.5", max_length: "30",
                from: "2026-05-01", to: "2026-06-15")

    assert_equal [@pike.id], f.species_ids
    assert_equal 18.5, f.min_length
    assert_equal 30.0, f.max_length
    assert_equal Date.new(2026, 5, 1), f.from
    assert_equal Date.new(2026, 6, 15), f.to
  end

  test "to_query is the keyword arguments HeatMapPoints takes" do
    f = filters(filtered: "1", species: [@pike.id.to_s], min_length: "18")

    assert_equal({ species_ids: [@pike.id], min_length: 18.0, max_length: nil,
                   from: Date.new(2025, 9, 27), to: TODAY }, f.to_query)
  end

  test "species: unticking everything shows none; an unfiltered visit shows all" do
    assert_equal [], filters(filtered: "1").species_ids
    assert_equal [@walleye.id, @pike.id].sort, filters({}).species_ids.sort
  end

  test "species: unknown ids and junk are dropped" do
    f = filters(filtered: "1", species: [@walleye.id.to_s, "999999", "banana", "", "-1"])
    assert_equal [@walleye.id], f.species_ids
  end

  test "length: a minimum above the maximum swaps the two" do
    f = filters(min_length: "30", max_length: "18")
    assert_equal 18.0, f.min_length
    assert_equal 30.0, f.max_length
  end

  test "dates: a start after the end swaps the two" do
    f = filters(from: "2026-06-15", to: "2026-05-01")
    assert_equal Date.new(2026, 5, 1), f.from
    assert_equal Date.new(2026, 6, 15), f.to
  end

  test "dates: unparseable values fall back to their own default" do
    {
      "banana" => "garbage",
      "2026-02-31" => "impossible date",
      "" => "blank",
      "2026-13-01" => "month 13",
      "20260501" => "wrong format"
    }.each do |value, label|
      f = filters(from: value, to: value)
      assert_equal Date.new(2025, 9, 27), f.from, "from: #{label}"
      assert_equal TODAY, f.to, "to: #{label}"
    end
  end

  # Review Focus 2.
  test "length: extreme and invalid numbers are treated as absent" do
    ["-5", "abc", "", "NaN", "Infinity", "-Infinity", "1e400", "12abc", " "].each do |value|
      f = filters(min_length: value, max_length: value)
      assert_nil f.min_length, "min_length=#{value.inspect}"
      assert_nil f.max_length, "max_length=#{value.inspect}"
    end
  end

  test "length: a huge but finite number is capped so it cannot overflow the column" do
    f = filters(min_length: "99999999999999999999", max_length: "99999999999999999999")
    assert_equal 999.0, f.min_length
    assert_equal 999.0, f.max_length
  end

  test "length: zero is a real value" do
    assert_equal 0.0, filters(min_length: "0").min_length
  end

  # Review Focus 1.
  test "params of the wrong shape fall back to defaults" do
    f = filters(filtered: "1", species: @walleye.id.to_s, min_length: { a: "1" }, max_length: ["1"],
                from: ["2026-05-01"], to: { x: "y" })

    assert_equal [], f.species_ids, "a scalar species param is not a list of ticks"
    assert_nil f.min_length
    assert_nil f.max_length
    assert_equal Date.new(2025, 9, 27), f.from
    assert_equal TODAY, f.to
  end

  test "a plain hash with symbol keys works like request params" do
    f = Catches::HeatMapFilters.from_params({ min_length: "20" }, species: @species, today: TODAY)
    assert_equal 20.0, f.min_length
  end
end
