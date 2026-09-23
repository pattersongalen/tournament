require "test_helper"

class Api::CatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    @walleye = create(:species, club: @club)
    @tournament = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: @tournament, species: @walleye, slot_count: 2)
    entry = create(:tournament_entry, tournament: @tournament)
    create(:tournament_entry_member, tournament_entry: entry, user: @user)
    sign_in_as(@user)
  end

  # Merges: "creates and places a catch", "is idempotent on client_uuid",
  # "dedup retry does NOT double-place a catch that already has placements",
  # "dedup response reports the catch's real flags".
  test "POST /api/catches creates and places a catch; a duplicate submit is idempotent and reports the catch's real flags" do
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")

    assert_difference -> { Catch.count } => 1, -> { CatchPlacement.count } => 1 do
      post "/api/catches", params: {
        catch: {
          species_id: @walleye.id,
          length_inches: 19.5,
          captured_at_device: Time.current.iso8601,
          captured_at_gps: Time.current.iso8601,
          latitude: 49.41, longitude: -103.62, gps_accuracy_m: 8,
          app_build: "phase2-rc1",
          client_uuid: "uuid-A",
          photo: photo
        }
      }, headers: { "Accept" => "application/json" }
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "synced", body["status"]
    assert_equal 1, body["placements"].size

    # A duplicate submit (missing GPS, so it also carries a real flag) neither
    # double-creates the Catch nor double-places it, and reports the catch's
    # actual flags rather than a stale/empty snapshot.
    dup_payload = lambda {
      post "/api/catches", params: {
        catch: { species_id: @walleye.id, length_inches: 20, captured_at_device: Time.current.iso8601,
                 client_uuid: "uuid-DUPFLAGS", photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg") }
      }, headers: { "Accept" => "application/json" }
    }
    dup_payload.call
    assert_no_difference -> { Catch.count } do
      assert_no_difference -> { CatchPlacement.count } do
        dup_payload.call
      end
    end
    assert_response :ok
    assert_includes JSON.parse(response.body)["flags"], "missing_gps"
  end

  # Merges: "missing GPS flags catch as needs_review", "clock skew > threshold
  # flags as needs_review", "out-of-bounds GPS flags catch as needs_review",
  # "POST /api/catches persists flags on the catch record".
  test "flags: missing GPS, clock skew, and out-of-bounds GPS mark the catch needs_review and persist the flag" do
    now = Time.current
    cases = {
      "missing_gps" => { client_uuid: "uuid-NOGPS", extra: {} },
      "clock_skew" => {
        client_uuid: "uuid-SKEW",
        extra: { captured_at_gps: (now - 10.minutes).iso8601, latitude: 49.0, longitude: -98.0, gps_accuracy_m: 5 }
      },
      "out_of_bounds" => {
        client_uuid: "uuid-OOB",
        extra: { captured_at_gps: now.iso8601, latitude: 49.9, longitude: -97.1, gps_accuracy_m: 5 }
      }
    }

    cases.each do |flag, cfg|
      photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
      post "/api/catches", params: {
        catch: { species_id: @walleye.id, length_inches: 12, captured_at_device: now.iso8601,
                 client_uuid: cfg[:client_uuid], photo: photo }.merge(cfg[:extra])
      }, headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      assert_equal "needs_review", body["status"], "#{flag}: status"
      assert_includes body["flags"], flag, "#{flag}: response flags"
      persisted = Catch.find_by(client_uuid: cfg[:client_uuid])
      assert_includes persisted.flags, flag, "#{flag}: persisted flags"
    end
  end

  test "POST /api/catches persists note but does not echo it in response" do
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    post "/api/catches", params: {
      catch: {
        species_id: @walleye.id,
        length_inches: 18,
        captured_at_device: Time.current.iso8601,
        latitude: 49.0, longitude: -98.0, gps_accuracy_m: 5,
        client_uuid: "uuid-NOTE",
        photo: photo,
        note: "personal-secret-XYZ"
      }
    }, headers: { "Accept" => "application/json" }

    assert_response :created
    persisted = Catch.find_by(client_uuid: "uuid-NOTE")
    assert_equal "personal-secret-XYZ", persisted.note
    assert_not_includes response.body, "personal-secret-XYZ"
    assert_not_includes response.body, "note"
  end

  test "POST /api/catches persists the logged length_unit" do
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    post "/api/catches", params: {
      catch: {
        species_id: @walleye.id,
        length_inches: 14.47,
        length_unit: "centimeters",
        captured_at_device: Time.current.iso8601,
        latitude: 49.0, longitude: -98.0, gps_accuracy_m: 5,
        client_uuid: "uuid-CM",
        photo: photo
      }
    }, headers: { "Accept" => "application/json" }

    assert_response :created
    persisted = Catch.find_by(client_uuid: "uuid-CM")
    assert_equal "centimeters", persisted.length_unit
  end

  # Merges: "returns 401 once the user is deactivated" and "clears the stale
  # session when the user is deactivated".
  test "POST /api/catches returns 401 and clears the stale session once the user is deactivated" do
    @user.update!(deactivated_at: Time.current)
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    post "/api/catches", params: {
      catch: {
        species_id: @walleye.id,
        length_inches: 19.5,
        captured_at_device: Time.current.iso8601,
        client_uuid: "uuid-DEACT",
        photo: photo
      }
    }, headers: { "Accept" => "application/json" }
    assert_response :unauthorized
    assert_nil session[:user_id], "deactivated user's session should be cleared, not left poisoned"
  end

  test "POST /api/catches with valid teammate files catch under teammate and stamps logger" do
    @tournament.update!(mode: :team)
    teammate = create(:user, club: @club, name: "Boatmate")
    entry = TournamentEntry.joins(:tournament_entry_members).find_by(tournament_entry_members: { user_id: @user.id })
    create(:tournament_entry_member, tournament_entry: entry, user: teammate)
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    now = Time.current

    post "/api/catches", params: {
      teammate_user_id: teammate.id,
      catch: {
        species_id: @walleye.id, length_inches: 18.5,
        captured_at_device: now.iso8601, captured_at_gps: now.iso8601,
        latitude: 49.41, longitude: -103.62,
        client_uuid: "uuid-team", photo: photo
      }
    }, headers: { "Accept" => "application/json" }
    assert_response :created
    persisted = Catch.find_by(client_uuid: "uuid-team")
    assert_equal teammate.id, persisted.user_id
    assert_equal @user.id, persisted.logged_by_user_id
  end

  # Merges: "rejects teammate from another club" and "rejects teammate
  # without a shared entry".
  test "POST /api/catches rejects an invalid teammate (foreign club, or no shared entry)" do
    other_club = create(:club)
    foreigner = create(:user, club: other_club)
    other_user = create(:user, club: @club)
    other_entry = create(:tournament_entry, tournament: @tournament)
    create(:tournament_entry_member, tournament_entry: other_entry, user: other_user)

    {
      foreigner.id => "Teammate not found",
      other_user.id => "aren't on the same entry"
    }.each do |teammate_id, expected_message|
      photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
      assert_no_difference -> { Catch.count } do
        post "/api/catches", params: {
          teammate_user_id: teammate_id,
          catch: {
            species_id: @walleye.id, length_inches: 18.5,
            captured_at_device: Time.current.iso8601,
            client_uuid: "uuid-teammate-#{teammate_id}", photo: photo
          }
        }, headers: { "Accept" => "application/json" }
      end
      assert_response :unprocessable_entity, "teammate_id=#{teammate_id}"
      assert_match expected_message, response.body, "teammate_id=#{teammate_id}"
    end
  end

  test "POST /api/catches is idempotent for retry of a teammate catch" do
    @tournament.update!(mode: :team)
    teammate = create(:user, club: @club)
    entry = TournamentEntry.joins(:tournament_entry_members).find_by(tournament_entry_members: { user_id: @user.id })
    create(:tournament_entry_member, tournament_entry: entry, user: teammate)

    payload = lambda {
      post "/api/catches", params: {
        teammate_user_id: teammate.id,
        catch: { species_id: @walleye.id, length_inches: 18.5,
                 captured_at_device: Time.current.iso8601,
                 client_uuid: "uuid-team-retry",
                 photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg") }
      }, headers: { "Accept" => "application/json" }
    }
    payload.call
    assert_no_difference "Catch.count" do
      payload.call
    end
    assert_response :ok
  end

  # Merges: "persists tag_number on a Tagged Walleye catch", "persists
  # weight_text on a Tagged Walleye catch", "accepts blank weight_text on a
  # Tagged Walleye catch".
  test "Tagged Walleye catches persist tag_number and weight_text (blank weight_text accepted)" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")

    uuid1 = SecureRandom.uuid
    post "/api/catches", params: {
      catch: {
        species_id: tagged.id, length_inches: 18.5, captured_at_device: 1.minute.ago.iso8601,
        client_uuid: uuid1, tag_number: "a1234",
        photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg")
      }
    }, headers: { "Accept" => "application/json" }
    assert_response :created
    assert_equal "A1234", Catch.find_by(client_uuid: uuid1).tag_number, "tag_number should upcase-persist"

    uuid2 = SecureRandom.uuid
    post "/api/catches", params: {
      catch: {
        species_id: tagged.id, length_inches: 18.5, captured_at_device: 1.minute.ago.iso8601,
        client_uuid: uuid2, tag_number: "A1234", weight_text: "4 lbs 3oz",
        photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg")
      }
    }, headers: { "Accept" => "application/json" }
    assert_response :created
    assert_equal "4 lbs 3oz", Catch.find_by(client_uuid: uuid2).weight_text, "weight_text should persist"

    uuid3 = SecureRandom.uuid
    post "/api/catches", params: {
      catch: {
        species_id: tagged.id, length_inches: 18.5, captured_at_device: 1.minute.ago.iso8601,
        client_uuid: uuid3, tag_number: "A1234",
        photo: fixture_file_upload("sample_walleye.jpg", "image/jpeg")
      }
    }, headers: { "Accept" => "application/json" }
    assert_response :created
    assert_nil Catch.find_by(client_uuid: uuid3).weight_text, "blank weight_text should be accepted as nil"
  end

  # WebKit can send a request with NO body at all when it fails to stream a
  # file-backed IndexedDB blob (the 2026-07-15 incident: 595 empty-bodied
  # 400s). Rails' default ParameterMissing response is an HTML page, which
  # sync.js can't parse — the angler saw "{}" as the failure reason. The API
  # must answer with readable JSON so the pending-catches widget can show
  # something actionable.
  test "POST /api/catches with an empty body returns readable JSON 400" do
    post "/api/catches", params: {}, headers: { "Accept" => "application/json" }

    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_kind_of Array, body["errors"]
    assert_match(/empty/i, body["errors"].join(", "))
  end

  # Regression lock: Api::CatchesController#create calls save BEFORE its
  # photo.attached? check — only the model's photo_must_be_attached validation
  # stops a photo-less row from persisting. If that validation is ever removed,
  # a photo-less 422 would leave a row behind and the client_uuid retry would
  # return 200 for a catch with no photo (poisoned idempotency, catch never
  # placed). This regression lock also covers the retry-with-photo recovery
  # path, since both share the same client_uuid.
  test "a photo-less submit persists no row, and a retry with the same client_uuid and a photo succeeds" do
    assert_no_difference "Catch.count" do
      post "/api/catches", params: {
        catch: { species_id: @walleye.id, length_inches: 18,
                 captured_at_device: Time.current.iso8601, client_uuid: "uuid-RETRY-PHOTO" }
      }, headers: { "Accept" => "application/json" }
    end
    assert_response :unprocessable_entity
    assert_match(/photo/i, JSON.parse(response.body)["errors"].join(", "))

    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    assert_difference "Catch.count", 1 do
      post "/api/catches", params: {
        catch: { species_id: @walleye.id, length_inches: 18,
                 captured_at_device: Time.current.iso8601,
                 client_uuid: "uuid-RETRY-PHOTO", photo: photo }
      }, headers: { "Accept" => "application/json" }
    end
    assert_response :created
    assert Catch.find_by(client_uuid: "uuid-RETRY-PHOTO").photo.attached?
  end

  test "dedup retry places a saved-but-unplaced catch (post-500 recovery)" do
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    payload = lambda {
      post "/api/catches", params: {
        catch: { species_id: @walleye.id, length_inches: 20, captured_at_device: Time.current.iso8601,
                 client_uuid: "uuid-RECONCILE", photo: photo }
      }, headers: { "Accept" => "application/json" }
    }
    payload.call
    catch_record = Catch.find_by!(client_uuid: "uuid-RECONCILE")
    # Simulate the crash window: catch committed, PlaceInSlots' transaction
    # rolled back. In a real crash the evaluated stamp is never written (it
    # lands after the pipeline), so clear it along with the placements.
    catch_record.catch_placements.destroy_all
    catch_record.update_column(:placements_evaluated_at, nil)

    assert_difference "CatchPlacement.count", 1 do
      payload.call
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal 1, body["placements"].size
  end

  test "dedup retry finishes the pipeline when the crash landed after placement but before the jobs" do
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    payload = lambda {
      post "/api/catches", params: {
        catch: { species_id: @walleye.id, length_inches: 20, captured_at_device: Time.current.iso8601,
                 client_uuid: "uuid-HALFRUN", photo: photo }
      }, headers: { "Accept" => "application/json" }
    }
    payload.call
    catch_record = Catch.find_by!(client_uuid: "uuid-HALFRUN")
    # Simulate the narrower crash window: PlaceInSlots' transaction committed
    # (placements exist), then the process died before the condition/photo jobs
    # were enqueued — the stamp (written last) is still nil.
    catch_record.update_column(:placements_evaluated_at, nil)

    assert_no_difference "CatchPlacement.count" do
      assert_enqueued_jobs 2, only: [FetchCatchConditionsJob, FlagImportedPhotoJob] do
        payload.call
      end
    end
    assert_response :ok
    assert_not_nil catch_record.reload.placements_evaluated_at
  end

  # A bingo catch legitimately keeps zero placements (the card is derived on
  # read), so "no placements yet" cannot mean "not yet processed". Without the
  # placements_evaluated_at stamp, every dedup retry (flaky LTE losing the 201,
  # 45s ticks) re-ran the whole pipeline — rebroadcasting the card and
  # re-enqueueing the flag/condition jobs indefinitely.
  test "a dedup retry for a bingo catch does not re-run the placement pipeline" do
    create_bingo_species!
    bingo_user = create(:user, club: @club)
    bingo = build(:tournament, club: @club, mode: :solo, format: :bingo,
                  starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    bingo.save!
    entry = create(:tournament_entry, tournament: bingo)
    create(:tournament_entry_member, tournament_entry: entry, user: bingo_user)
    sign_in_as(bingo_user)

    walleye = Species.find_by!(name: "Walleye")
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    payload = lambda {
      post "/api/catches", params: {
        catch: { species_id: walleye.id, length_inches: 18, captured_at_device: Time.current.iso8601,
                 client_uuid: "uuid-BINGO-DEDUP", photo: photo }
      }, headers: { "Accept" => "application/json" }
    }
    payload.call
    assert_response :created
    assert_not_nil Catch.find_by!(client_uuid: "uuid-BINGO-DEDUP").placements_evaluated_at

    assert_no_enqueued_jobs only: [FetchCatchConditionsJob, FlagImportedPhotoJob] do
      payload.call
    end
    assert_response :ok
  end

  # Merges: "queued_by_user_id mismatch is rejected..." and "matching
  # queued_by_user_id is accepted".
  test "queued_by_user_id: mismatched id rejected, matching id accepted" do
    {
      "mismatched" => { id: -> { @user.id + 1 }, expect_created: false },
      "matching" => { id: -> { @user.id }, expect_created: true }
    }.each do |label, cfg|
      photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
      post "/api/catches", params: {
        catch: { species_id: @walleye.id, length_inches: 20, captured_at_device: Time.current.iso8601,
                 client_uuid: "uuid-QUEUED-#{label}", photo: photo,
                 queued_by_user_id: cfg[:id].call }
      }, headers: { "Accept" => "application/json" }
      if cfg[:expect_created]
        assert_response :created, "#{label} should be accepted"
      else
        assert_response :unprocessable_entity, "#{label} should be rejected"
        assert_match(/different account/i, JSON.parse(response.body)["errors"].join)
      end
    end
  end

  test "teammate submission with no active club membership returns 422, not 500" do
    @user.club_memberships.destroy_all
    photo = fixture_file_upload("sample_walleye.jpg", "image/jpeg")
    post "/api/catches", params: {
      teammate_user_id: 999_999,
      catch: { species_id: @walleye.id, length_inches: 20, captured_at_device: Time.current.iso8601,
               client_uuid: "uuid-NOCLUB", photo: photo }
    }, headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
