require "test_helper"

class Catches::HeatMapPointsTest < ActiveSupport::TestCase
  ZONE = "Saskatchewan"
  FROM = Date.new(2026, 9, 1)
  TO   = Date.new(2026, 9, 20)

  setup do
    @club = create(:club)
    @angler = create(:user, club: @club)
    @walleye = create(:species, name: "Walleye")
    @pike = create(:species, name: "Pike")
  end

  # The default catch of the spec's state table.
  def log_catch(**overrides)
    attrs = {
      user: @angler, species: @walleye, length_inches: 20, status: :synced,
      latitude: 49.76, longitude: -95.19,
      captured_at_device: Time.zone.local(2026, 9, 10, 12, 0)
    }.merge(overrides)
    create(:catch, **attrs)
  end

  def points(**overrides)
    query = { club: @club, species_ids: [@walleye.id, @pike.id], from: FROM, to: TO }.merge(overrides)
    Catches::HeatMapPoints.call(**query)
  end

  test "state table: which catches are included" do
    Time.use_zone(ZONE) do
      other_club_angler = create(:user, club: create(:club))
      gone = create(:user, club: @club, deactivated_at: Time.current)
      teammate = create(:user, club: @club)

      rows = {
        "1 the default catch"            => [true,  -> { log_catch }, {}],
        "2 status needs_review"          => [true,  -> { log_catch(status: :needs_review) }, {}],
        "3 status disqualified"          => [false, -> { log_catch(status: :disqualified) }, {}],
        "4 no latitude"                  => [false, -> { log_catch(latitude: nil) }, {}],
        "5 no longitude"                 => [false, -> { log_catch(longitude: nil) }, {}],
        "6 angler in another club"       => [false, -> { log_catch(user: other_club_angler) }, {}],
        "7 angler deactivated"           => [false, -> { log_catch(user: gone) }, {}],
        "8 species not chosen"           => [false, -> { log_catch(species: @pike) }, { species_ids: [@walleye.id] }],
        "9 min_length equal"             => [true,  -> { log_catch }, { min_length: 20.0 }],
        "10 min_length just above"       => [false, -> { log_catch }, { min_length: 20.25 }],
        "11 max_length equal"            => [true,  -> { log_catch }, { max_length: 20.0 }],
        "12 max_length just below"       => [false, -> { log_catch }, { max_length: 19.75 }],
        "13 on the from date, 00:05"     => [true,  -> { log_catch(captured_at_device: Time.zone.local(2026, 9, 1, 0, 5)) }, {}],
        "14 day before from, 23:55"      => [false, -> { log_catch(captured_at_device: Time.zone.local(2026, 8, 31, 23, 55)) }, {}],
        "15 on the to date, 23:55"       => [true,  -> { log_catch(captured_at_device: Time.zone.local(2026, 9, 20, 23, 55)) }, {}],
        "16 day after to, 00:05"         => [false, -> { log_catch(captured_at_device: Time.zone.local(2026, 9, 21, 0, 5)) }, {}],
        "17 logged by a teammate"        => [true,  -> { log_catch(logged_by_user: teammate) }, {}],
        "18 species_ids empty"           => [false, -> { log_catch }, { species_ids: [] }]
      }

      rows.each do |label, (expected, arrange, query)|
        Catch.delete_all
        arrange.call

        result = points(**query)

        assert_equal (expected ? 1 : 0), result.size, "row #{label}"
      end
    end
  end

  test "points are [latitude, longitude] pairs of Floats and nothing else" do
    log_catch(latitude: 49.123456, longitude: -95.654321)

    result = points

    assert_equal [[49.123456, -95.654321]], result
    assert result.flatten.all? { |value| value.is_a?(Float) }
  end

  test "a coordinate of exactly zero is kept" do
    log_catch(latitude: 0, longitude: 0)
    assert_equal [[0.0, 0.0]], points
  end

  test "one query, and no Catch record is instantiated" do
    3.times { log_catch }
    instantiated = 0
    subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      instantiated += payload[:record_count] if payload[:class_name] == "Catch"
    end

    queries = count_queries(/./) { points }

    assert_equal 1, queries
    assert_equal 0, instantiated
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "the order is shuffled, so array position says nothing about when a catch was logged" do
    40.times { |i| log_catch(latitude: 49 + i * 0.001, captured_at_device: Time.zone.local(2026, 9, 10, 12, i)) }

    in_logged_order = Catch.order(:id).pluck(:latitude, :longitude).map { |lat, lng| [lat.to_f, lng.to_f] }
    result = points

    assert_equal in_logged_order.sort, result.sort, "same points"
    assert_not_equal in_logged_order, result, "different order"
  end

  test "a nil club returns nothing" do
    log_catch
    assert_equal [], points(club: nil)
  end
end
