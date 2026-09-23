require "test_helper"

class CatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    @walleye = create(:species, club: @club, name: "Walleye")
    @tournament = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: @tournament, species: @walleye, slot_count: 2)
    @entry = create(:tournament_entry, tournament: @tournament)
    create(:tournament_entry_member, tournament_entry: @entry, user: @user)
    sign_in_as(@user)
  end

  # --- POST /catches -----------------------------------------------------------

  test "POST /catches creates a catch and triggers placement" do
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")

    assert_difference -> { Catch.count } => 1, -> { CatchPlacement.count } => 1 do
      post catches_path, params: {
        catch: {
          species_id: @walleye.id,
          length_inches: 18.5,
          captured_at_device: Time.current,
          client_uuid: "client-1",
          tag_number: "a1234",
          weight_text: "4 lbs 3oz",
          photo: photo
        }
      }
    end

    placement = CatchPlacement.last
    assert_equal @entry, placement.tournament_entry
    assert_equal 0, placement.slot_index

    # The HTML controller keeps its own permit list, independent of the API's.
    persisted = Catch.find_by(client_uuid: "client-1")
    assert_equal "A1234", persisted.tag_number, "tag_number is permitted and normalized"
    assert_equal "4 lbs 3oz", persisted.weight_text, "weight_text is permitted"
  end

  test "POST /catches persists flags and status derived from the submitted GPS" do
    now = Time.current
    # The two rows are more than the 90s duplicate window apart so the second
    # submission isn't flagged as a possible duplicate of the first.
    {
      "no GPS" => [{ client_uuid: "client-flags", captured_at_device: 3.minutes.ago },
                   ["missing_gps"], "needs_review"],
      "in-bounds GPS" => [{ client_uuid: "client-clean", captured_at_device: now, captured_at_gps: now,
                            latitude: 49.41, longitude: -103.62 }, [], "synced"]
    }.each do |label, (extra, expected_flags, expected_status)|
      post catches_path, params: {
        catch: { species_id: @walleye.id, length_inches: 18.5,
                 photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg") }.merge(extra)
      }
      persisted = Catch.find_by(client_uuid: extra[:client_uuid])
      assert_not_nil persisted, "#{label}: catch was not created"
      if expected_flags.empty?
        assert_empty persisted.flags, "#{label}: expected no flags"
      else
        expected_flags.each { |flag| assert_includes persisted.flags, flag, "#{label}: expected the #{flag} flag" }
      end
      assert_equal expected_status, persisted.status, "#{label}: status"
    end
  end

  test "POST /catches sets lake from the submitted GPS" do
    {
      "GPS inside the Tobin polygon" => [{ latitude: 53.55, longitude: -103.65, client_uuid: "client-tobin" }, "tobin"],
      "no GPS" => [{ client_uuid: "client-no-gps" }, nil]
    }.each do |label, (extra, expected_lake)|
      post catches_path, params: {
        catch: { species_id: @walleye.id, length_inches: 18.5, captured_at_device: Time.current,
                 photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg") }.merge(extra)
      }
      lake = Catch.find_by(client_uuid: extra[:client_uuid])&.lake
      if expected_lake.nil?
        assert_nil lake, "#{label}: lake"
      else
        assert_equal expected_lake, lake, "#{label}: lake"
      end
    end
  end

  test "missing photo is rejected" do
    assert_no_difference "Catch.count" do
      post catches_path, params: {
        catch: { species_id: @walleye.id, length_inches: 14, captured_at_device: Time.current, client_uuid: "u" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "POST /catches with valid teammate files catch under teammate and stamps logger" do
    @tournament.update!(mode: :team)
    teammate = create(:user, club: @club, name: "Boatmate")
    create(:tournament_entry_member, tournament_entry: @entry, user: teammate)
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    now = Time.current

    post catches_path, params: {
      teammate_user_id: teammate.id,
      catch: {
        species_id: @walleye.id,
        length_inches: 18.5,
        captured_at_device: now, captured_at_gps: now,
        latitude: 49.41, longitude: -103.62,
        client_uuid: "client-team-1", photo: photo
      }
    }
    assert_redirected_to root_path
    persisted = Catch.find_by(client_uuid: "client-team-1")
    assert_equal teammate.id, persisted.user_id
    assert_equal @user.id, persisted.logged_by_user_id
  end

  test "POST /catches rejects a teammate who doesn't share an active entry" do
    now = Time.current
    other_user = create(:user, club: @club)
    other_entry = create(:tournament_entry, tournament: @tournament)
    create(:tournament_entry_member, tournament_entry: other_entry, user: other_user)

    @tournament.update!(mode: :team)
    teammate = create(:user, club: @club)
    create(:tournament_entry_member, tournament_entry: @entry, user: teammate)

    {
      "teammate on another entry" => [other_user, "client-team-bad", -> {}],
      "shared entry but no active tournament" =>
        [teammate, "client-team-expired", -> { @tournament.update!(starts_at: 3.days.ago, ends_at: 2.days.ago) }]
    }.each do |label, (target, uuid, prepare)|
      prepare.call
      assert_no_difference -> { Catch.count }, label do
        post catches_path, params: {
          teammate_user_id: target.id,
          catch: {
            species_id: @walleye.id, length_inches: 18.5,
            captured_at_device: now, captured_at_gps: now,
            latitude: 49.41, longitude: -103.62,
            client_uuid: uuid,
            photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg")
          }
        }
      end
      assert_response :unprocessable_entity, label
      assert_match "on the same entry", response.body, "#{label}: expected the shared-entry error"
    end
  end

  # --- Catch detail visibility -------------------------------------------------

  test "show: owner sees humanized flag badges, their note and edit form, and the recorded weight" do
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5,
                         flags: ["missing_gps", "out_of_bounds"], status: :needs_review,
                         note: "OWNER-NOTE-VISIBLE", weight_text: "4 lbs 3oz")
    get catch_path(own.id)
    assert_response :success
    assert_match "no GPS", response.body
    assert_match "outside local", response.body
    assert_match "OWNER-NOTE-VISIBLE", response.body
    assert_select "form[action=?][method=?]", catch_path(own.id), "post" do
      assert_select "input[name=?][value=?]", "_method", "patch"
      assert_select "textarea[name=?]", "catch[note]"
    end
    # Weight is only ever entered on a Tagged Walleye, but the detail page
    # renders it for any catch that carries one.
    assert_match "Weight:", response.body
    assert_match "4 lbs 3oz", response.body
  end

  test "show: owner sees exact GPS coords linked to Google Maps" do
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5,
                         latitude: 49.123456, longitude: -103.987654)
    get catch_path(own.id)
    assert_response :success
    assert_select "a[href=?]", "https://maps.google.com/?q=49.123456,-103.987654"
    assert_match "49.12346, -103.98765", response.body   # full precision, not fuzzed
    assert_match "Open in Maps", response.body
  end

  test "show: possible-duplicate and imported-photo badges are staff-only" do
    catch_record = create(:catch, user: @user, species: @walleye, length_inches: 18.5,
                                  flags: ["missing_gps", "possible_duplicate", "imported_photo"],
                                  status: :needs_review)
    Catches::PlaceInSlots.call(catch: catch_record)
    organizer = create(:user, club: @club, role: :organizer)
    judge = create(:user, club: @club)
    create(:tournament_judge, tournament: @tournament, user: judge)

    {
      "owner (plain member)" => [@user, false],
      "organizer" => [organizer, true],
      "judge of the relevant tournament" => [judge, true]
    }.each do |label, (viewer, staff)|
      sign_in_as(viewer)
      get catch_path(catch_record.id)
      assert_response :success, label
      assert_match "no GPS", response.body, "#{label}: a non-suppressed flag still shows"
      if staff
        assert_match "possible duplicate", response.body, "#{label}: should see the duplicate badge"
        assert_match "imported photo", response.body, "#{label}: should see the imported-photo badge"
      else
        refute_match "possible duplicate", response.body, "#{label}: duplicate badge must be hidden"
        refute_match "imported photo", response.body, "#{label}: imported-photo badge must be hidden"
      end
    end
  end

  test "show: organizer viewing a member's catch sees fuzzed coords and no note" do
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5,
                         latitude: 49.123456, longitude: -103.987654, note: "OWNER-NOTE-HIDDEN")
    organizer = create(:user, club: @club, role: :organizer)
    sign_in_as(organizer)

    get catch_path(own.id)
    assert_response :success
    assert_match "~49.12, -103.99", response.body        # fuzzed to ~1km
    assert_no_match %r{maps\.google\.com}, response.body
    assert_no_match "OWNER-NOTE-HIDDEN", response.body
    assert_select "textarea[name=?]", "catch[note]", 0, "organizer gets no note editor"
  end

  test "show: member cannot view another member's catch detail" do
    other_user = create(:user, club: @club)
    foreign = create(:catch, user: other_user, species: @walleye, length_inches: 22)
    get catch_path(foreign.id)
    assert_response :forbidden
  end

  test "show: organizer sees the review forms on a friendly tournament but not on a judged one" do
    catch_record = create(:catch, user: @user, species: @walleye, length_inches: 18.5)
    Catches::PlaceInSlots.call(catch: catch_record)
    organizer = create(:user, club: @club, role: :organizer)
    sign_in_as(organizer)
    review_path = judges_tournament_catch_review_path(tournament_id: @tournament.id, catch_id: catch_record.id)
    override_path = judges_tournament_catch_manual_override_path(tournament_id: @tournament.id, catch_id: catch_record.id)

    get catch_path(catch_record.id, t: @tournament.id)
    assert_response :success, "friendly tournament"
    assert_select "form[action=?]", review_path, { minimum: 1 }, "friendly: DQ/review form is offered"
    assert_select "form[action=?]", override_path, { minimum: 1 }, "friendly: edit-length form is offered"

    @tournament.update!(judged: true)
    get catch_path(catch_record.id, t: @tournament.id)
    assert_response :success, "judged tournament"
    assert_select "form[action=?]", review_path, 0, "judged: a non-judge organizer gets no actions"
  end

  test "index lists only the signed-in member's catches and hides the possible-duplicate badge" do
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5,
                         flags: ["possible_duplicate"], status: :needs_review,
                         captured_at_device: Time.current)
    other_user = create(:user, club: @club)
    other = create(:catch, user: other_user, species: @walleye, length_inches: 22,
                           captured_at_device: Time.current)

    get catches_path
    assert_response :success
    assert_select "a[href=?]", catch_path(own.id), { minimum: 1 }, "own catch is listed"
    assert_select "a[href=?]", catch_path(other.id), 0, "another member's catch is not listed"
    refute_match "possible duplicate", response.body
  end

  test "show: logger of a teammate's catch can view it" do
    @tournament.update!(mode: :team)
    teammate = create(:user, club: @club)
    create(:tournament_entry_member, tournament_entry: @entry, user: teammate)
    teammate_catch = create(:catch, user: teammate, species: @walleye,
                                    length_inches: 18.5, logged_by_user_id: @user.id)
    get catch_path(teammate_catch.id)
    assert_response :success
    assert_match "Logged by", response.body
  end

  # --- Approve action ----------------------------------------------------------

  # A reviewer (judge for needs_review; organizer for synced/disputed) sees the
  # Approve action for every reviewable status. Each iteration gets its own
  # single-slot tournament so the catch always places (a shared 2-slot tournament
  # would leave the third catch unplaced and hide the action section).
  test "show: reviewer sees Approve action for every reviewable catch status" do
    reviewer_for = {
      needs_review: ->(tournament) {
        judge = create(:user, club: @club)
        create(:tournament_judge, tournament: tournament, user: judge)
        judge
      },
      synced:   ->(_tournament) { create(:user, club: @club, role: :organizer) },
      disputed: ->(_tournament) { create(:user, club: @club, role: :organizer) }
    }
    reviewer_for.each do |status, make_reviewer|
      tournament = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      create(:scoring_slot, tournament: tournament, species: @walleye, slot_count: 1)
      entry = create(:tournament_entry, tournament: tournament)
      create(:tournament_entry_member, tournament_entry: entry, user: @user)

      catch_record = create(:catch, user: @user, species: @walleye, length_inches: 18.5, status: status)
      Catches::PlaceInSlots.call(catch: catch_record)
      sign_in_as(make_reviewer.call(tournament))

      get catch_path(catch_record.id, t: tournament.id)
      assert_response :success, "status #{status}"
      assert_select "input[name=?][value=?]", "action_kind", "approve", 1, "status #{status}"
    end
  end

  test "show: Approve button is replaced or hidden when it can't be used" do
    # Already approved → the approver's name instead of the button.
    approver = create(:user, club: @club, role: :organizer, name: "Pat Approver")
    approved = create(:catch, user: @user, species: @walleye, length_inches: 18.5, status: :synced)
    Catches::PlaceInSlots.call(catch: approved)
    create(:judge_action, judge_user: approver, catch: approved, action: :approve)
    sign_in_as(create(:user, club: @club, role: :organizer))

    get catch_path(approved.id, t: @tournament.id)
    assert_response :success, "already approved"
    assert_select "input[name=?][value=?]", "action_kind", "approve", 0, "already approved: no Approve button"
    assert_match "Approved by Pat Approver", response.body

    # Disqualified → no Approve action at all. Real-world flow: the catch was
    # placed first, then a judge DQ'd it — the placement row stays with
    # active: false. PlaceInSlots refuses to place a DQ'd catch, so mirror that
    # final state directly here.
    dqd = create(:catch, user: @user, species: @walleye, length_inches: 18.5, status: :disqualified)
    create(:catch_placement, catch: dqd, tournament: @tournament,
           tournament_entry: @entry, species: @walleye, active: false)
    judge = create(:user, club: @club)
    create(:tournament_judge, tournament: @tournament, user: judge)
    sign_in_as(judge)

    get catch_path(dqd.id, t: @tournament.id)
    assert_response :success, "disqualified"
    assert_select "input[name=?][value=?]", "action_kind", "approve", 0, "disqualified: no Approve button"

    # Owner who is themselves an organizer → can't approve their own catch.
    @user.club_memberships.find_by(club: @club).update!(role: :organizer)
    sign_in_as(@user)
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5, status: :synced)
    Catches::PlaceInSlots.call(catch: own)

    get catch_path(own.id, t: @tournament.id)
    assert_response :success, "own catch"
    assert_select "input[name=?][value=?]", "action_kind", "approve", 0, "own catch: no Approve button"
    assert_match "You can't approve your own catch", response.body
  end

  # --- Reference photo ---------------------------------------------------------

  test "reference_photo is site-admin only and returns the admin to the page they came from" do
    c = create(:catch, user: @user, species: @walleye, length_inches: 18.5, status: :synced)
    assert_equal 0, c.catch_placements.count, "this catch is unplaced — no tournament"
    assert_not c.reference_photo.attached?

    # @user (signed in by setup) is a plain member, not a site admin.
    assert_no_difference "JudgeAction.count", "member must not be able to add a reference photo" do
      patch reference_photo_catch_path(c),
            params: { photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg") }
    end
    assert_response :forbidden
    assert_not c.reload.reference_photo.attached?

    # Site admin succeeds, even on a catch that was never placed.
    admin = create(:user, club: @club, admin: true)
    sign_in_as(admin)
    assert_difference "JudgeAction.count", 1 do
      patch reference_photo_catch_path(c),
            params: { photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg"), note: "clearer shot" }
    end
    assert_redirected_to catch_path(c)
    assert c.reload.reference_photo.attached?

    # …and lands back on whichever page they posted from.
    referer = "http://www.example.com/judges/tournaments/9/catches/#{c.id}"
    patch reference_photo_catch_path(c),
          params: { photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg") },
          headers: { "HTTP_REFERER" => referer }
    assert_redirected_to referer
  end

  test "catch detail page shows the reference-photo form to a site admin only" do
    c = create(:catch, user: @user, species: @walleye, length_inches: 18.5, status: :synced)

    # Owner (plain member) viewing their own catch: no admin form.
    get catch_path(c)
    assert_response :success
    assert_select "form[action=?]", reference_photo_catch_path(c), count: 0

    # Site admin viewing: form present (and they can load the page at all).
    admin = create(:user, club: @club, admin: true)
    sign_in_as(admin)
    get catch_path(c)
    assert_response :success
    assert_select "form[action=?]", reference_photo_catch_path(c), count: 1
  end

  test "show: displays both the reference photo and the angler's original, labelled" do
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5, status: :synced)
    own.reference_photo.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample_walleye.jpg")),
      filename: "reference.jpg", content_type: "image/jpeg"
    )
    get catch_path(own.id)
    assert_response :success
    assert_select "img", minimum: 2
    assert_match "Reference photo", response.body
    assert_match "Original photo", response.body
  end

  test "show: Save photo button downloads the public photo, with a reference photo superseding the original" do
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5,
                         captured_at_device: Time.zone.local(2026, 4, 30, 14, 35))
    get catch_path(own.id)
    assert_response :success

    assert_select "[data-controller~=?]", "photo-save" do |containers|
      container = containers.first
      assert_match %r{rails/active_storage|/blobs/}, container["data-photo-save-url-value"],
                   "original only: expected an Active Storage URL"
      assert_equal "Walleye - 18.5 in - 2026-04-30 1435.jpg",
                   container["data-photo-save-filename-value"], "original only: download filename"
    end
    assert_select "button[data-action=?]", "photo-save#save", text: "Save photo"

    own.reference_photo.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample_walleye.jpg")),
      filename: "reference.jpg", content_type: "image/jpeg"
    )
    get catch_path(own.id)
    assert_response :success
    assert_select "[data-controller~=?]", "photo-save" do |containers|
      assert_match %r{reference\.jpg}, containers.first["data-photo-save-url-value"],
                   "with a reference photo: the public photo is the reference image"
    end
  end

  # --- Notes -------------------------------------------------------------------

  test "update: owner can save a note and strong-params discard non-note fields" do
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5)
    patch catch_path(own.id), params: { catch: { note: "released near bridge", length_inches: 99 } }
    assert_redirected_to catch_path(own.id)
    own.reload
    assert_equal "released near bridge", own.note
    assert_equal 18.5, own.length_inches.to_f, "length_inches must not be assignable from the note form"
  end

  test "update: non-owner gets 404" do
    other_user = create(:user, club: @club)
    foreign = create(:catch, user: other_user, species: @walleye, length_inches: 18.5)
    patch catch_path(foreign.id), params: { catch: { note: "sneaky" } }
    assert_response :not_found
    assert_nil foreign.reload.note
  end

  test "update: overly long note is rejected, re-renders show, and preserves typed text" do
    own = create(:catch, user: @user, species: @walleye, length_inches: 18.5)
    long_note = "a" * 501
    patch catch_path(own.id), params: { catch: { note: long_note } }
    assert_response :unprocessable_entity
    assert_nil own.reload.note
    assert_match "too long", response.body
    assert_match long_note, response.body
  end

  # --- Date-range params -------------------------------------------------------

  test "GET /catches date params filter the range, swap a reversed range, and treat a lone start as one day" do
    may4  = create_catch(captured_at: Time.zone.parse("2026-05-04 10:00"))
    may5  = create_catch(captured_at: Time.zone.parse("2026-05-05 10:00"))
    may6  = create_catch(captured_at: Time.zone.parse("2026-05-06 10:00"))
    may8  = create_catch(captured_at: Time.zone.parse("2026-05-08 10:00"))
    may13 = create_catch(captured_at: Time.zone.parse("2026-05-13 10:00"))

    {
      "start=2026-05-05&end=2026-05-12" =>
        [{ start: "2026-05-05", end: "2026-05-12" }, [may5, may6, may8], [may4, may13],
         Date.new(2026, 5, 5), Date.new(2026, 5, 12)],
      "reversed range is swapped" =>
        [{ start: "2026-05-12", end: "2026-05-05" }, [may5, may6, may8], [may4, may13],
         Date.new(2026, 5, 5), Date.new(2026, 5, 12)],
      "lone start is a single day" =>
        [{ start: "2026-05-05" }, [may5], [may4, may6, may8, may13],
         Date.new(2026, 5, 5), Date.new(2026, 5, 5)]
    }.each do |label, (params, included, excluded, selected_start, selected_end)|
      get catches_path, params: params
      assigned = assigns(:catches).to_a
      included.each do |c|
        assert_includes assigned, c, "#{label}: #{c.captured_at_device.to_date} should be in range"
      end
      excluded.each do |c|
        refute_includes assigned, c, "#{label}: #{c.captured_at_device.to_date} should be out of range"
      end
      assert_equal selected_start, assigns(:selected_start), "#{label}: selected_start"
      assert_equal selected_end, assigns(:selected_end), "#{label}: selected_end"
    end
  end

  test "GET /catches?start=&end= treats explicit empty as no date filter" do
    a = create_catch(captured_at: 3.days.ago)
    b = create_catch(captured_at: 30.days.ago)
    get catches_path, params: { start: "", end: "" }
    assigned = assigns(:catches).to_a
    assert_includes assigned, a
    assert_includes assigned, b
    assert_nil assigns(:selected_start)
    assert_nil assigns(:selected_end)
  end

  test "GET /catches with no params defaults to today, falling back to the most recent day with catches" do
    today_catch = create_catch(captured_at: Time.zone.now.change(hour: 12))
    yesterday_catch = create_catch(captured_at: 1.day.ago.change(hour: 12))

    get catches_path
    assigned = assigns(:catches).to_a
    assert_includes assigned, today_catch, "default: today's catch is listed"
    refute_includes assigned, yesterday_catch, "default: yesterday's catch is not"
    assert_equal Date.current, assigns(:selected_start), "default: selected_start is today"
    assert_equal Date.current, assigns(:selected_end), "default: selected_end is today"

    today_catch.destroy!
    get catches_path
    fallback_day = yesterday_catch.captured_at_device.to_date
    assert_equal fallback_day, assigns(:selected_start), "fallback: most recent day with catches"
    assert_equal fallback_day, assigns(:selected_end), "fallback: selected_end matches"
    assert_includes assigns(:catches).to_a, yesterday_catch, "fallback: that day's catch is listed"
  end

  # --- Sort + filter wiring ----------------------------------------------------

  test "GET /catches?sort= orders the list" do
    short = create_catch(captured_at: 1.hour.ago, length: 14.0)
    long  = create_catch(captured_at: 2.hours.ago, length: 32.0)
    mid   = create_catch(captured_at: 3.hours.ago, length: 22.0)

    {
      "longest"  => [long, mid, short],
      "shortest" => [short, mid, long],
      "newest"   => [short, long, mid]   # captured_at_device desc
    }.each do |sort, expected|
      get catches_path, params: { sort: sort, start: "", end: "" }
      assert_equal expected, assigns(:catches).to_a.first(3), "sort=#{sort}"
    end
  end

  # One wiring row per filter param: the predicates themselves are unit-tested in
  # test/services/catches/apply_filters_test.rb — this only proves each param
  # reaches the service from both the list and the map.
  test "every filter param reaches ApplyFilters on the index and the map" do
    pike = create(:species, club: @club, name: "Pike")
    # Pinned to a fixed August instant: the month=5 row below asserts an exact
    # id list, which these "recent" fixtures would join if the suite ran in May.
    now = Time.zone.local(2026, 8, 1, 12)
    w_tobin = create(:catch, user: @user, species: @walleye, length_inches: 22.5, lake: "tobin",
                             captured_at_device: now, latitude: 53.55, longitude: -103.65,
                             wind_direction_deg: 45, barometric_pressure_hpa: 1025)
    p_tobin = create(:catch, user: @user, species: pike, length_inches: 30.0, lake: "tobin",
                             captured_at_device: now, latitude: 53.55, longitude: -103.65,
                             wind_direction_deg: 225, barometric_pressure_hpa: 1005)
    w_other = create(:catch, user: @user, species: @walleye, length_inches: 12.0, lake: nil,
                             captured_at_device: now, latitude: 49.41, longitude: -103.62,
                             wind_direction_deg: 225, barometric_pressure_hpa: 1005)
    old_may = create(:catch, user: @user, species: pike, length_inches: 40.0, lake: nil,
                             captured_at_device: Time.zone.local(2023, 5, 10, 9),
                             latitude: 49.41, longitude: -103.62,
                             wind_direction_deg: 225, barometric_pressure_hpa: 1005)

    {
      "species"        => [{ species: @walleye.id }, [w_tobin, w_other]],
      "lake=tobin"     => [{ lake: "tobin" }, [w_tobin, p_tobin]],
      "lake=other"     => [{ lake: "other" }, [w_other, old_may]],
      "lake=all"       => [{ lake: "all" }, [w_tobin, p_tobin, w_other, old_may]],
      "min_length"     => [{ min_length: 18 }, [w_tobin, p_tobin, old_may]],
      "wind_dir"       => [{ wind_dir: "ne" }, [w_tobin]],
      "pressure"       => [{ pressure: "high" }, [w_tobin]],
      "species + lake" => [{ species: @walleye.id, lake: "tobin" }, [w_tobin]]
    }.each do |label, (filter, expected)|
      { "index" => catches_path, "map" => map_catches_path }.each do |page, path|
        get path, params: filter.merge(start: "", end: "")
        assert_response :success, "#{label} (#{page})"
        assert_equal expected.map(&:id).sort, assigns(:catches).map(&:id).sort, "#{label} (#{page})"
      end
    end

    get catches_path, params: { month: 5, start: "2026-01-01", end: "2026-12-31" }
    assert_equal [old_may.id], assigns(:catches).map(&:id), "month=5 overrides an explicit date range"

    day = now.to_date.iso8601
    get catches_path, params: { start: day, end: day, species: pike.id, sort: "longest" }
    assert_equal [p_tobin.id], assigns(:catches).map(&:id), "range + species + sort all apply together"
  end

  test "index ignores unknown lake keys and shows all catches" do
    tobin = create(:catch, user: @user, species: @walleye, length_inches: 22.5, lake: "tobin")
    other = create(:catch, user: @user, species: @walleye, length_inches: 18.0, lake: nil)
    get catches_path, params: { lake: "not-a-lake", start: "", end: "" }
    assert_response :success
    assert_select "a[href=?]", catch_path(tobin.id)
    assert_select "a[href=?]", catch_path(other.id)
    # Dropdown should reflect "All lakes" — i.e. no option carries the raw value,
    # and the empty-value "All lakes" option is the one marked selected.
    assert_select "select[name='lake'] option[selected][value='not-a-lake']", count: 0
    assert_select "select[name='lake'] option[selected][value='']"
  end

  # --- Calendar / month state --------------------------------------------------

  test "GET /catches assigns @month_start and @counts_by_date for the displayed month only" do
    create_catch(captured_at: Time.zone.parse("2026-05-08 10:00"))
    create_catch(captured_at: Time.zone.parse("2026-05-08 14:00"))
    create_catch(captured_at: Time.zone.parse("2026-05-12 10:00"))
    create_catch(captured_at: Time.zone.parse("2026-04-30 10:00"))
    create_catch(captured_at: Time.zone.parse("2026-06-01 10:00"))

    get catches_path, params: { start: "2026-05-08", end: "2026-05-08" }
    assert_equal Date.new(2026, 5, 1), assigns(:month_start), "month_start is the selected month's first day"
    counts = assigns(:counts_by_date)
    assert_equal 2, counts[Date.new(2026, 5, 8)], "two catches on May 8"
    assert_equal 1, counts[Date.new(2026, 5, 12)], "one catch on May 12"
    assert_nil counts[Date.new(2026, 4, 30)], "April 30 is outside the displayed month"
    assert_nil counts[Date.new(2026, 6, 1)], "June 1 is outside the displayed month"
  end

  test "GET /catches counts_by_date buckets by Time.zone-local date, not UTC" do
    Time.use_zone("America/Regina") do
      # 11pm Regina May 8 = 5am UTC May 9. Buggy DATE(captured_at_device)
      # would bucket onto May 9; fixed code keys by local date (May 8).
      late_evening = Time.zone.local(2026, 5, 8, 23, 0)
      create_catch(captured_at: late_evening)
      get catches_path, params: { start: "2026-05-08", end: "2026-05-08", month_nav: "2026-05-01" }
      counts = assigns(:counts_by_date)
      assert_equal 1, counts[Date.new(2026, 5, 8)]
      assert_nil counts[Date.new(2026, 5, 9)]
    end
  end

  test "GET /catches?month_nav controls the displayed month, and garbage falls back to the current month" do
    create_catch(captured_at: Time.zone.parse("2026-05-15 10:00"))

    get catches_path, params: { start: "", end: "", month_nav: "2026-05-01" }
    assert_equal Date.new(2026, 5, 1), assigns(:month_start), "month_nav=2026-05-01: displayed month"
    assert_equal 1, assigns(:counts_by_date)[Date.new(2026, 5, 15)], "month_nav=2026-05-01: counts for that month"

    get catches_path, params: { start: "", end: "", month_nav: "banana" }
    assert_response :ok, "month_nav=banana must not raise"
    assert_equal Date.current.beginning_of_month, assigns(:month_start), "month_nav=banana: falls back to this month"
  end

  test "GET /catches renders the catch calendar with count badges and the selected day marked" do
    create_catch(captured_at: Time.zone.parse("2026-05-08 10:00"))
    get catches_path, params: { start: "2026-05-08", end: "2026-05-08", month_nav: "2026-05-01" }
    assert_response :ok
    assert_select "[data-test='catch-calendar']"
    assert_select "[data-test='calendar-day-2026-05-08']"
    assert_select "[data-test='calendar-day-2026-05-08'] [data-test='count-badge']", text: /1/
    assert_select "[data-test='calendar-day-2026-05-09'] [data-test='count-badge']", count: 0
    assert_select "[data-test='calendar-day-2026-05-08'][data-selected='true']"
  end

  test "index: month-of-year mode notes the mode, suppresses count badges, and drops :month from calendar nav" do
    create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.zone.local(2024, 5, 10))
    create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.current)

    get catches_path
    assert_response :success
    assert_select "[data-test='count-badge']", { minimum: 1 }, "without month-of-year: today's badge renders"

    get catches_path(month: 5)
    assert_response :success
    assert_select "[data-test='month-of-year-note']", text: /Showing all years · May/
    %w[Previous Next].each do |dir|
      assert_select "a[aria-label='#{dir} month']" do |els|
        assert_no_match(/[?&]month=/, els.first["href"], "#{dir} month link must drop :month")
      end
    end

    # Badges would represent only the current month while the list shows all
    # years — hide them to avoid the mismatch.
    get catches_path(month: Date.current.month.to_s)
    assert_response :success
    assert_select "[data-test='count-badge']", 0, "month-of-year active: badges are suppressed"
  end

  # --- Filter bar --------------------------------------------------------------

  # iOS Safari zooms the whole viewport when focusing any form control whose
  # font-size is under 16px — and never zooms back. Member-facing filter
  # controls must render at text-base; the length input (the most-typed field
  # in the app) must also raise the big decimal keypad via inputmode.
  test "filter controls render at 16px and the length fields get the decimal keypad" do
    get catches_path
    assert_response :success
    assert_select "select#species[class*=?]", "text-base"
    assert_select "select#lake[class*=?]", "text-base"
    assert_select "select#sort[class*=?]", "text-base"
    assert_select "input#min_length[inputmode=decimal][class*=?]", "text-base"

    get new_catch_path
    assert_response :success
    assert_select "input#catch_length_inches[inputmode=decimal]"
  end

  test "GET /catches renders the species filter dropdown ordered by name with the current one selected" do
    pike  = create(:species, club: @club, name: "Pike")
    perch = create(:species, club: @club, name: "Perch")

    get catches_path
    assert_equal %w[Perch Pike Walleye], assigns(:available_species).map(&:name),
                 "@available_species is ordered by name"
    assert_select "select[name='species']" do
      assert_select "option", text: "All species"
      assert_select "option[value='#{perch.id}']", text: "Perch"
      assert_select "option[value='#{pike.id}']", text: "Pike"
      assert_select "option[value='#{@walleye.id}']", text: "Walleye"
    end

    get catches_path, params: { species: pike.id, start: "", end: "" }
    assert_select "select[name='species'] option[selected][value='#{pike.id}']"
  end

  test "GET /catches renders sort dropdown with the four labels and current selection" do
    get catches_path, params: { sort: "longest", start: "", end: "" }
    assert_select "select[name='sort'] option[selected][value='longest']"
    %w[newest longest shortest].each do |key|
      assert_select "select[name='sort'] option[value='#{key}']"
    end
  end

  test "GET /catches renders Show all dates link that clears start/end but keeps species/sort" do
    get catches_path, params: { start: "2026-05-08", species: "0", sort: "longest" }
    assert_select "a[data-test='show-all-dates']" do |els|
      href = els.first["href"]
      assert_includes href, "sort=longest"
      refute_includes href, "start=2026-05-08"
    end
  end

  test "index: match conditions panel renders chips, aria state and the active count" do
    create(:catch, user: @user, species: @walleye, length_inches: 18, captured_at_device: Time.current)

    get catches_path
    assert_response :success
    assert_select "[data-test='chip-wind_dir-ne']"
    assert_select "[data-test='chip-wind_speed-mod']"
    assert_select "[data-test='chip-pressure-low']"
    assert_select "[data-test='chip-moon-full']"
    assert_select "[data-test='chip-tod-noon']"
    assert_select "[data-test='month-of-year']"
    # No active conditions → panel collapsed → aria-expanded=false.
    assert_select "[data-test='match-conditions-toggle'][aria-expanded='false'][aria-controls='match-conditions-panel']",
                  { minimum: 1 }, "no active conditions: panel is collapsed"
    assert_select "#match-conditions-panel"

    # An active condition auto-opens the panel → aria-expanded=true.
    get catches_path(wind_dir: "ne")
    assert_select "[data-test='match-conditions-toggle'][aria-expanded='true'][aria-controls='match-conditions-panel']",
                  { minimum: 1 }, "an active condition auto-opens the panel"

    get catches_path(wind_dir: "ne", moon: "full")
    assert_response :success
    assert_select "[data-test='mc-active-count']", text: /\(2 active\)/

    get catches_path(month: "13", wind_dir: "up", moon: "halfmoon")
    assert_response :success
    assert_select "[data-test='mc-active-count']", 0, "invalid condition values don't count as active"
  end

  # --- Conditions panel on the detail page -------------------------------------

  test "show: conditions panel renders pressure in kPa, with the 24h trend only when recorded" do
    {
      "trend recorded" => [4.0, "rising 0.4 kPa over 24h"],
      "no trend recorded" => [nil, nil]
    }.each do |label, (trend, expected_line)|
      catch_record = create(:catch,
        user: @user, species: @walleye, length_inches: 18.5,
        barometric_pressure_hpa: 1013.25,
        pressure_trend_24h_hpa: trend,
        moon_phase: "Full Moon"
      )

      get catch_path(catch_record.id)
      assert_response :success, label
      assert_match "101.3 kPa", response.body, "#{label}: pressure shown in kPa"
      refute_match "hPa", response.body, "#{label}: never hPa"
      if expected_line
        assert_match expected_line, response.body, "#{label}: trend line"
      else
        refute_match "over 24h", response.body, "#{label}: trend line omitted"
      end
    end
  end

  test "show: conditions panel renders the compass label only when wind direction is recorded" do
    {
      "direction recorded" => [315.0, true],   # NW
      "legacy catch with no direction" => [nil, false]
    }.each do |label, (degrees, labelled)|
      catch_record = create(:catch,
        user: @user, species: @walleye, length_inches: 18.5,
        wind_speed_kph: 12.0,
        wind_direction_deg: degrees,
        moon_phase: "Full Moon"
      )

      get catch_path(catch_record.id)
      assert_response :success, label
      assert_match "12.0 km/h", response.body, "#{label}: wind speed"
      if labelled
        assert_match "NW", response.body, "#{label}: compass label after the speed"
      else
        # No compass label between speed and the next field — the wind line ends cleanly.
        assert_no_match(/12\.0 km\/h \/ [\d\.]+ mph (?:N|NE|E|SE|S|SW|W|NW)/, response.body,
                        "#{label}: no compass label")
      end
    end
  end

  # --- Map ---------------------------------------------------------------------

  test "map: defaults to today, includes signed-in user's geolocated catches only" do
    own_with_gps = create(:catch, user: @user, species: @walleye, length_inches: 18.5,
                          captured_at_device: Time.current, latitude: 49.1, longitude: -97.2)
    own_without_gps = create(:catch, user: @user, species: @walleye, length_inches: 12,
                             captured_at_device: Time.current, latitude: nil, longitude: nil)
    other_user = create(:user, club: @club)
    other_user_catch = create(:catch, user: other_user, species: @walleye, length_inches: 22,
                              captured_at_device: Time.current, latitude: 49.1, longitude: -97.2)

    get map_catches_path
    assert_response :success
    assert_match Time.current.strftime("%B %Y"), response.body
    assert_equal Date.current, assigns(:selected_start), "map defaults to today"
    assert_equal Date.current, assigns(:selected_end), "map defaults to today"
    assert_select "a[href=?]", catch_path(own_with_gps.id)
    assert_select "a[href=?]", catch_path(own_without_gps.id)
    assert_select "a[href=?]", catch_path(other_user_catch.id), 0, "another member's catch is not on my map"

    points = JSON.parse(css_select("[data-map-points-value]").first["data-map-points-value"])
    assert_equal 1, points.length, "only the geolocated catch becomes a point"
    assert_in_delta 49.1, points.first["lat"]
  end

  test "map: date params filter the listed catches and the map points" do
    in_range = create_catch(captured_at: Time.zone.parse("2026-05-08 10:00"), length: 18.0)
    in_range.update!(latitude: 49.41, longitude: -103.62)
    out_of_range  = create_catch(captured_at: Time.zone.parse("2026-04-08 10:00"))
    yesterday_catch = create_catch(captured_at: 1.day.ago)
    today_catch = create_catch(captured_at: Time.current)

    get map_catches_path, params: { start: "2026-05-05", end: "2026-05-12" }
    assigned = assigns(:catches).to_a
    assert_includes assigned, in_range, "explicit range: the May 8 catch is listed"
    refute_includes assigned, out_of_range, "explicit range: the April catch is not"
    assert_kind_of Array, assigns(:map_points)
    assert_equal 1, assigns(:map_points).length, "explicit range: one geolocated catch → one point"

    d = 1.day.ago.to_date.iso8601
    get map_catches_path(start: d, end: d)
    assert_response :success
    assert_select "a[href=?]", catch_path(yesterday_catch.id), { minimum: 1 }, "single day: yesterday's catch"
    assert_select "a[href=?]", catch_path(today_catch.id), 0, "single day: today's catch is excluded"
  end

  test "map: unparseable date param falls back to today, and counts_by_date covers the displayed month" do
    get map_catches_path(start: "banana", end: "banana")
    assert_response :success
    assert_match Time.current.strftime("%B %Y"), response.body

    create_catch(captured_at: Time.zone.parse("2026-05-08 10:00"))
    create_catch(captured_at: Time.zone.parse("2026-05-12 10:00"))
    get map_catches_path, params: { start: "2026-05-08", end: "2026-05-08" }
    assert_equal 1, assigns(:counts_by_date)[Date.new(2026, 5, 8)], "May 8 count"
    assert_equal 1, assigns(:counts_by_date)[Date.new(2026, 5, 12)], "May 12 count (same month)"
  end

  # --- Teammate / species chooser ----------------------------------------------
  # @tournament defaults to solo (one angler per entry); these tests need team mode.

  test "GET /catches/select_teammate lists this club's teammates once, flat, plus a Myself option" do
    @tournament.update!(mode: :team)
    mate = create(:user, club: @club, name: "Boatmate")
    create(:tournament_entry_member, tournament_entry: @entry, user: mate)
    other = create(:user, club: @club, name: "Other Boat")
    other_entry = create(:tournament_entry, tournament: @tournament)
    create(:tournament_entry_member, tournament_entry: other_entry, user: other)

    # A second team tournament: its teammate is aggregated flat (no per-tournament
    # grouping), and the teammate shared with the first entry appears only once.
    t2 = create(:tournament, club: @club, name: "Second Cup", mode: :team,
                             starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    entry2 = create(:tournament_entry, tournament: t2)
    create(:tournament_entry_member, tournament_entry: entry2, user: @user)
    create(:tournament_entry_member, tournament_entry: entry2, user: mate)
    mate2 = create(:user, club: @club, name: "Boatmate Two")
    create(:tournament_entry_member, tournament_entry: entry2, user: mate2)

    # Another club's team tournament the same user is in: its teammate must not leak.
    other_club = create(:club)
    create(:club_membership, user: @user, club: other_club)
    other_t = create(:tournament, club: other_club, name: "Other Club Cup", mode: :team,
                                  starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    other_club_entry = create(:tournament_entry, tournament: other_t)
    create(:tournament_entry_member, tournament_entry: other_club_entry, user: @user)
    other_club_mate = create(:user, club: other_club, name: "Other Club Mate")
    create(:tournament_entry_member, tournament_entry: other_club_entry, user: other_club_mate)

    sign_in_as(@user)

    get select_teammate_catches_path
    assert_response :success
    assert_select "a[href=?]", select_species_catches_path, { text: "Myself" }, "the Myself option is offered"
    assert_select "a[href=?]", select_species_catches_path(teammate_user_id: mate.id), 1,
                  "a teammate shared across two tournaments is listed once"
    assert_match "Boatmate Two", response.body
    assert_no_match "Second Cup", response.body, "teammates are flat, not grouped by tournament"
    assert_no_match "Other Boat", response.body, "a member on another entry is not my teammate"
    assert_no_match "Other Club Mate", response.body, "another club's teammate must not leak"
  end

  test "GET /catches/select_teammate redirects to the species step when the user has no teammates" do
    # @tournament is solo by default, so the user has no team teammates.
    get select_teammate_catches_path
    assert_redirected_to select_species_catches_path
  end

  test "GET /catches/select_species lists species linking into the catch form, threading any teammate" do
    first = Species.in_log_order.first

    get select_species_catches_path
    assert_response :success
    assert_select "a[href=?]", new_catch_path(species_id: first.id), { text: first.name },
                  "no teammate: plain species link"

    @tournament.update!(mode: :team)
    teammate = create(:user, club: @club, name: "Boatmate")
    create(:tournament_entry_member, tournament_entry: @entry, user: teammate)

    get select_species_catches_path(teammate_user_id: teammate.id)
    assert_response :success
    assert_select "a[href=?]",
                  new_catch_path(species_id: first.id, teammate_user_id: teammate.id),
                  { text: first.name }, "teammate is threaded onto the species link"
  end

  # The tournament page gates on THIS tournament's teammates (per-tournament
  # TeammatesFor.exists?), not club-wide.
  test "tournament show routes 'Log Catch' to the chooser only when this tournament has teammates" do
    assert_log_catch_link select_species_catches_path, "solo tournament"

    @tournament.update!(mode: :team)
    assert_log_catch_link select_species_catches_path, "team tournament with no teammates"

    other = create(:tournament, club: @club, name: "Other Cup", mode: :team,
                                starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    other_entry = create(:tournament_entry, tournament: other)
    create(:tournament_entry_member, tournament_entry: other_entry, user: @user)
    create(:tournament_entry_member, tournament_entry: other_entry,
                                     user: create(:user, club: @club, name: "Other Boatmate"))
    assert_log_catch_link select_species_catches_path, "the only teammate is in another tournament"

    create(:tournament_entry_member, tournament_entry: @entry,
                                     user: create(:user, club: @club, name: "Boatmate"))
    assert_log_catch_link select_teammate_catches_path, "team tournament with a teammate on my entry"
  end

  test "GET /catches/new with a valid teammate assigns @teammate, shows the banner and threads the Change link" do
    @tournament.update!(mode: :team)
    teammate = create(:user, club: @club, name: "Boatmate")
    create(:tournament_entry_member, tournament_entry: @entry, user: teammate)

    get new_catch_path(teammate_user_id: teammate.id)
    assert_response :success
    assert_equal teammate, assigns(:teammate)
    assert_match "Logging for", response.body
    assert_match "Boatmate", response.body

    species = Species.in_log_order.first
    get new_catch_path(species_id: species.id, teammate_user_id: teammate.id)
    assert_response :success
    assert_select "a[href=?]", select_species_catches_path(teammate_user_id: teammate.id),
                  { text: "Change" }, "the Change link keeps the teammate"
  end

  test "GET /catches/new with foreign-club teammate redirects with alert" do
    other_club = create(:club)
    foreigner = create(:user, club: other_club)
    get new_catch_path(teammate_user_id: foreigner.id)
    assert_redirected_to new_catch_path
    assert_equal "Teammate not found.", flash[:alert]
  end

  test "GET /catches/new assigns @selected_species only for a known species_id" do
    species = Species.in_log_order.first
    {
      "valid species_id"   => [{ species_id: species.id }, species],
      "no species_id"      => [{}, nil],
      "unknown species_id" => [{ species_id: 0 }, nil]
    }.each do |label, (params, expected)|
      get new_catch_path(params)
      assert_response :success, label
      if expected.nil?
        assert_nil assigns(:selected_species), "#{label}: @selected_species"
      else
        assert_equal expected, assigns(:selected_species), "#{label}: @selected_species"
      end
    end
  end

  test "GET /catches/new with species_id renders a read-only species banner and hidden select" do
    species = Species.in_log_order.first
    get new_catch_path(species_id: species.id)
    assert_response :success
    assert_select "a[href=?]", select_species_catches_path, text: "Change"
    assert_match "Species:", response.body
    # The select is still present (so the JS controller keeps working) but hidden.
    assert_select "select#catch_species_id.hidden option[selected][value=?]",
                  species.id.to_s, text: species.name
  end

  test "GET /catches/new without species_id renders the editable species dropdown" do
    get new_catch_path
    assert_response :success
    assert_select "label[for=catch_species_id]", text: "Species"
    assert_select "select#catch_species_id:not(.hidden)"
  end

  test "new: species dropdown is ordered by Species::LOG_ORDER, not alphabetically" do
    # setup already creates "Walleye"; create the rest so Species.all is
    # exactly the LOG_ORDER set and the rendered options can be compared to it.
    Species::LOG_ORDER.each { |name| Species.find_or_create_by!(name: name) }

    get new_catch_path
    assert_response :success

    rendered = css_select("#catch_species_id option").map { |option| option.text.strip }
    assert_equal Species::LOG_ORDER, rendered
  end

  # --- Index rendering ---------------------------------------------------------

  test "catch index eager-loads judge_actions instead of N+1 per row" do
    judge = create(:user, club: @club, role: :organizer)
    3.times do |i|
      c = create(:catch, user: @user, species: @walleye, length_inches: 15 + i,
                         captured_at_device: Time.current)
      create(:judge_action, catch: c, judge_user: judge, action: :approve)
    end

    judge_action_queries = count_queries(/\bfrom\s+"?judge_actions"?/i) do
      get catches_path
    end
    assert_response :success
    assert_operator judge_action_queries, :<=, 1,
                    "expected judge_actions to be eager-loaded in one query, got #{judge_action_queries}"
  end

  test "catch index shows a cm-logged length as the exact quarter-cm value" do
    cm_user = create(:user, club: @club, length_unit: "centimeters")
    create(:catch, user: cm_user, species: @walleye, length_inches: 6.99,
                   length_unit: "centimeters", captured_at_device: Time.current)
    sign_in_as(cm_user)

    get catches_path

    assert_response :success
    assert_includes response.body, "17.75 cm"
    assert_not_includes response.body, "17.8 cm"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  def create_catch(captured_at:, length: 18.0, species: @walleye)
    rec = build(:catch, user: @user, species: species, length_inches: length,
                        captured_at_device: captured_at)
    rec.photo.attach(io: file_fixture("sample_walleye.jpg").open,
                     filename: "sample_walleye.jpg", content_type: "image/jpeg")
    rec.save!
    rec
  end

  def assert_log_catch_link(expected_path, label)
    get tournament_path(@tournament)
    assert_response :success, label
    assert_select "a[href=?]", expected_path, { text: "Log Catch" },
                  "#{label}: Log Catch should point at #{expected_path}"
    assert_no_match "Log for teammate", response.body, "#{label}: no separate teammate button"
  end
end
