require "test_helper"

class Judges::ManualOverridesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    @walleye = create(:species, club: @club)
    @pike = create(:species, club: @club)
    create(:scoring_slot, tournament: @t, species: @walleye, slot_count: 1)
    create(:scoring_slot, tournament: @t, species: @pike, slot_count: 1)
    @judge = create(:user, club: @club)
    create(:tournament_judge, tournament: @t, user: @judge)
    angler = create(:user, club: @club)
    entry = create(:tournament_entry, tournament: @t)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)
    @catch = create(:catch, user: angler, species: @walleye, length_inches: 20)
    Catches::PlaceInSlots.call(catch: @catch)
    sign_in_as(@judge)
  end

  test "POST resolves length param combinations (raw inches, unit conversion, grid snapping) to length_inches" do
    {
      "raw length_inches param stored as-is" => {
        params: { length_inches: "19.75", note: "tail" },
        expected_inches: 19.75,
        exact: true
      },
      "inches value stored as-is, records the inches unit" => {
        params: { length: "19.5", length_unit: "inches", note: "remeasured" },
        expected_inches: 19.5,
        expected_unit: "inches"
      },
      # 50 cm / 2.54 = 19.685 in, stored to 2dp by the schema (~19.69)
      "centimeters value converted to inches, records the centimeters unit" => {
        params: { length: "50", length_unit: "centimeters", note: "remeasured" },
        expected_inches: 19.685,
        expected_unit: "centimeters"
      },
      # 50.1 cm snaps to 50.0 cm (nearest 0.25), then 50 / 2.54 = 19.685 in.
      # Without the snap it would store 50.1 / 2.54 = 19.72.
      "centimeters snapped to the quarter grid before converting" => {
        params: { length: "50.1", length_unit: "centimeters", note: "remeasured" },
        expected_inches: 19.685
      },
      "inches snapped to the quarter grid" => {
        params: { length: "19.8", length_unit: "inches", note: "remeasured" },
        expected_inches: 19.75
      }
    }.each do |label, row|
      @catch.update!(length_inches: 20, length_unit: "inches")

      post judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: @catch.id),
           params: row[:params]

      @catch.reload
      if row[:exact]
        assert_equal row[:expected_inches], @catch.length_inches.to_f, label
      else
        assert_in_delta row[:expected_inches], @catch.length_inches.to_f, 0.01, label
      end
      assert_equal row[:expected_unit], @catch.length_unit, label if row[:expected_unit]
    end
  end

  test "GET new prefills cm length snapped to the quarter grid like the show page" do
    # Seed from the catch's own logged unit (cm), not the judge's preference.
    @catch.update!(length_unit: "centimeters")
    get new_judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: @catch.id)
    assert_response :success
    # 20 in = 50.8 cm, which snaps to the 0.25 grid as 50.75 — the same value the
    # catch show page prefills. (A plain .round(1) would give 50.8.)
    assert_select "input#length[value=?]", "50.75"
  end

  test "GET new seeds the unit toggle from the catch's logged unit, not the judge's preference" do
    # Catch logged in inches; judge prefers cm. The form must seed the catch's
    # unit so a species- or note-only override round-trips instead of re-snapping
    # length and flipping the unit — LengthParamParsing's untouched-length guard
    # only fires when the submitted unit matches the catch's.
    @judge.update!(length_unit: "centimeters")
    get new_judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: @catch.id)
    assert_select "input[name=length_unit][value=inches][checked=checked]"
    assert_select "input[name=length_unit][value=centimeters][checked=checked]", count: 0
  end

  test "POST note-only override by a differently-unit'd judge does not drift the length" do
    # Regression: a judge who prefers cm opens an inches-logged catch and edits
    # only the note. With the form seeded from the catch's unit, the resubmitted
    # prefill (20 inches) must round-trip — no length change, no re-score.
    @judge.update!(length_unit: "centimeters")
    assert_no_changes -> { @catch.reload.length_inches } do
      post judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: @catch.id),
           params: { species_id: @catch.species_id, length: "20", length_unit: "inches", note: "clean fish" }
    end
    assert_equal "inches", @catch.reload.length_unit
  end

  test "requests referencing another tournament's catch or entry are not found" do
    {
      "GET new on a catch from another tournament" => -> {
        foreign_catch = build_foreign_catch
        get new_judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: foreign_catch.id)
        assert_response :not_found, "GET new on a catch from another tournament"
      },
      "POST override on a catch from another tournament" => -> {
        foreign_catch = build_foreign_catch
        post judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: foreign_catch.id),
             params: { length_inches: "40", note: "drive-by" }
        assert_response :not_found, "POST override on a catch from another tournament"
        assert_equal 21, foreign_catch.reload.length_inches.to_f,
                     "POST override on a catch from another tournament: catch untouched"
      },
      "POST override with entry from another tournament" => -> {
        other_t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
        other_entry = create(:tournament_entry, tournament: other_t)
        create(:scoring_slot, tournament: other_t, species: @walleye, slot_count: 1)
        post judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: @catch.id),
             params: { slot_index: "0", entry_id: other_entry.id, note: "drive-by" }
        assert_response :not_found, "POST override with entry from another tournament"
        assert_equal 0, other_entry.catch_placements.count,
                     "POST override with entry from another tournament: no placement created"
      }
    }.each { |_label, block| block.call }
  end

  test "POST with species_id changes the catch's species" do
    post judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: @catch.id),
         params: { species_id: @pike.id, note: "misidentified" }

    @catch.reload
    assert_equal @pike.id, @catch.species_id
    assert_equal @pike.id, @catch.catch_placements.active.first.species_id
  end

  test "GET new shows the force-slot fields on a slot-based format, hides them on a re-derive format" do
    {
      "slot-based format shows force-slot fields" => -> (label) {
        get new_judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: @catch.id)
        assert_response :success, label
        assert_select "input[name=slot_index]", true, label
        assert_select "input[name=entry_id]", true, label
      },
      "re-derive format (Pro Walleye) hides force-slot fields" => -> (label) {
        pw, catch = pro_walleye_setup
        get new_judges_tournament_catch_manual_override_path(tournament_id: pw.id, catch_id: catch.id)
        assert_response :success, label
        assert_select "input[name=slot_index]", { count: 0 }, label
        assert_select "input[name=entry_id]", { count: 0 }, label
      }
    }.each { |label, block| block.call(label) }
  end

  test "POST redirects with an alert instead of 500 on invalid input" do
    {
      "invalid length" => -> {
        post judges_tournament_catch_manual_override_path(tournament_id: @t.id, catch_id: @catch.id),
             params: { length_inches: "-5", note: "typo" }
        assert_redirected_to judges_tournament_catch_path(tournament_id: @t.id, id: @catch.id), "invalid length"
        assert_not_nil flash[:alert], "invalid length"
        assert_equal 20, @catch.reload.length_inches.to_f, "invalid length: override should not persist"
      },
      "force-slot on a re-derive format" => -> {
        pw, catch, entry = pro_walleye_setup(with_entry: true)
        post judges_tournament_catch_manual_override_path(tournament_id: pw.id, catch_id: catch.id),
             params: { slot_index: "2", entry_id: entry.id, note: "force" }
        assert_redirected_to judges_tournament_catch_path(tournament_id: pw.id, id: catch.id), "force-slot on a re-derive format"
        assert_not_nil flash[:alert], "force-slot on a re-derive format"
      }
    }.each { |_label, block| block.call }
  end

  private

  def pro_walleye_setup(with_entry: false)
    walleye = Species.find_or_create_by!(name: "Walleye")
    pw = build(:tournament, club: @club, format: :pro_walleye, mode: :team,
               starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    pw.scoring_slots.build(species: walleye, slot_count: 5)
    pw.save!
    create(:tournament_judge, tournament: pw, user: @judge)
    angler = create(:user, club: @club)
    entry = create(:tournament_entry, tournament: pw)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)
    catch = create(:catch, user: angler, species: walleye, length_inches: 23,
                           captured_at_device: 30.minutes.ago)
    Catches::PlaceInSlots.call(catch: catch)
    with_entry ? [pw, catch, entry] : [pw, catch]
  end

  def build_foreign_catch
    other_t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    other_angler = create(:user, club: @club)
    other_entry = create(:tournament_entry, tournament: other_t)
    create(:tournament_entry_member, tournament_entry: other_entry, user: other_angler)
    create(:scoring_slot, tournament: other_t, species: @walleye, slot_count: 1)
    foreign_catch = create(:catch, user: other_angler, species: @walleye, length_inches: 21, status: :synced)
    Catches::PlaceInSlots.call(catch: foreign_catch)
    foreign_catch
  end

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
