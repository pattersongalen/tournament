require "test_helper"

class Catches::ComputeFlagsTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    @walleye = create(:species, club: @club)
  end

  test "no flags when GPS present, in-bounds, no clock skew" do
    catch_record = build(:catch, user: @user, species: @walleye,
                                  latitude: 49.41, longitude: -103.62,
                                  captured_at_device: Time.current,
                                  captured_at_gps: Time.current)
    assert_empty Catches::ComputeFlags.call(catch_record)
  end

  test "geofence flags follow GPS coordinates" do
    cases = {
      "no GPS"                                  => { lat: nil,   lon: nil,      bounds: false, province: false, missing_gps: true },
      "Winnipeg (outside lake and outside SK)"   => { lat: 49.9,  lon: -97.1,    bounds: true,  province: true,  missing_gps: false },
      "Regina (in SK, outside lake)"             => { lat: 50.45, lon: -104.61, bounds: true,  province: false, missing_gps: false }
    }
    cases.each do |label, c|
      catch_record = build(:catch, user: @user, species: @walleye, latitude: c[:lat], longitude: c[:lon])
      flags = Catches::ComputeFlags.call(catch_record)
      assert_equal c[:bounds],      flags.include?("out_of_bounds"),   "#{label}: out_of_bounds"
      assert_equal c[:province],    flags.include?("out_of_province"), "#{label}: out_of_province"
      assert_equal c[:missing_gps], flags.include?("missing_gps"),     "#{label}: missing_gps"
    end
  end

  test "geofence overrides suppress only their own flag" do
    cases = {
      "override_in_lake suppresses out_of_bounds" => {
        lat: 50.45, lon: -104.61, override: :override_in_lake, suppressed: "out_of_bounds", still_set: nil
      },
      "override_in_sask suppresses out_of_province" => {
        lat: 49.9, lon: -97.1, override: :override_in_sask, suppressed: "out_of_province", still_set: "out_of_bounds"
      }
    }
    cases.each do |label, c|
      catch_record = build(:catch, user: @user, species: @walleye,
                            latitude: c[:lat], longitude: c[:lon], **{ c[:override] => true })
      flags = Catches::ComputeFlags.call(catch_record)
      refute_includes flags, c[:suppressed], label
      assert_includes flags, c[:still_set], "#{label}: #{c[:still_set]} should still be set" if c[:still_set]
    end
  end

  test "clock_skew when device and GPS clocks diverge" do
    now = Time.current
    catch_record = build(:catch, user: @user, species: @walleye,
                                  latitude: 49.41, longitude: -103.62,
                                  captured_at_device: now,
                                  captured_at_gps: now - 10.minutes)
    assert_includes Catches::ComputeFlags.call(catch_record), "clock_skew"
  end

  test "possible_duplicate depends on whether the same user's nearest catch is within 90s" do
    {
      30.seconds => true,
      91.seconds => false
    }.each do |gap, expected|
      user = create(:user, club: @club)
      now = Time.current
      create(:catch, user: user, species: @walleye, captured_at_device: now - gap)
      catch_record = build(:catch, user: user, species: @walleye, captured_at_device: now)
      assert_equal expected, Catches::ComputeFlags.call(catch_record).include?("possible_duplicate"), "gap=#{gap}"
    end
  end

  test "possible_duplicate is scoped to current teammates only" do
    # Each scenario below gets its own well-separated timestamp so a prior
    # scenario's tournament window and catches can't leak into the next.
    now1 = Time.current
    now2 = now1 + 10.days
    now3 = now1 + 20.days

    other = create(:user, club: @club)
    create(:catch, user: other, species: @walleye, captured_at_device: now1 - 30.seconds)
    unrelated = build(:catch, user: @user, species: @walleye, captured_at_device: now1)
    refute_includes Catches::ComputeFlags.call(unrelated), "possible_duplicate", "unrelated user"

    teammate = create(:user, club: @club)
    active_tournament = create(:tournament, club: @club, mode: :team,
                                             starts_at: now2 - 1.hour, ends_at: now2 + 1.hour)
    active_entry = create(:tournament_entry, tournament: active_tournament)
    create(:tournament_entry_member, tournament_entry: active_entry, user: @user)
    create(:tournament_entry_member, tournament_entry: active_entry, user: teammate)
    create(:catch, user: teammate, species: @walleye, captured_at_device: now2 - 30.seconds)
    with_teammate = build(:catch, user: @user, species: @walleye, captured_at_device: now2)
    assert_includes Catches::ComputeFlags.call(with_teammate), "possible_duplicate", "current teammate"

    former_teammate = create(:user, club: @club)
    closed_tournament = create(:tournament, club: @club, mode: :team,
                                            starts_at: now3 - 2.days, ends_at: now3 - 1.day)
    closed_entry = create(:tournament_entry, tournament: closed_tournament)
    create(:tournament_entry_member, tournament_entry: closed_entry, user: @user)
    create(:tournament_entry_member, tournament_entry: closed_entry, user: former_teammate)
    create(:catch, user: former_teammate, species: @walleye, captured_at_device: now3 - 30.seconds)
    with_former_teammate = build(:catch, user: @user, species: @walleye, captured_at_device: now3)
    refute_includes Catches::ComputeFlags.call(with_former_teammate), "possible_duplicate",
                    "former teammate (tournament closed)"
  end

  test "recompute preserves out-of-band flags it doesn't own" do
    # imported_photo is written out-of-band by FlagImportedPhotoJob; a location
    # recompute must not wipe it.
    catch_record = create(:catch, user: @user, species: @walleye,
                                   latitude: 49.41, longitude: -103.62,
                                   captured_at_device: Time.current, captured_at_gps: Time.current,
                                   flags: ["imported_photo"])
    assert_equal ["imported_photo"], Catches::ComputeFlags.recompute(catch_record)
  end

  test "recompute re-derives owned flags from current state" do
    catch_record = create(:catch, user: @user, species: @walleye,
                                   latitude: nil, longitude: nil,
                                   flags: ["out_of_bounds"]) # stale owned flag
    recomputed = Catches::ComputeFlags.recompute(catch_record)
    assert_includes recomputed, "missing_gps"
    assert_not_includes recomputed, "out_of_bounds" # owned flags are re-derived, not preserved
  end

  test "recompute does not retroactively stamp video_missing when the requirement is enabled later" do
    tournament = create(:tournament, club: @club,
                        starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                        requires_release_video: false)
    entry = create(:tournament_entry, tournament: tournament)
    create(:tournament_entry_member, tournament_entry: entry, user: @user)
    catch_record = create(:catch, user: @user, species: @walleye,
                          latitude: 49.41, longitude: -103.62,
                          captured_at_device: Time.current, captured_at_gps: Time.current,
                          flags: [])
    tournament.update!(requires_release_video: true)
    assert_not_includes Catches::ComputeFlags.recompute(catch_record), "video_missing"
  end

  test "recompute preserves a video_missing flag stamped at submission" do
    # No requires_release_video tournament is active now — the flag written at
    # create time must still survive a judge-action recompute.
    catch_record = create(:catch, user: @user, species: @walleye,
                          latitude: 49.41, longitude: -103.62,
                          captured_at_device: Time.current, captured_at_gps: Time.current,
                          flags: ["video_missing"])
    assert_includes Catches::ComputeFlags.recompute(catch_record), "video_missing"
  end
end
