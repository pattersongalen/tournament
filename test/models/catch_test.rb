require "test_helper"

class CatchTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    @walleye = create(:species, club: @club, name: "Walleye")
  end

  test "a catch requires its core fields and a positive length" do
    assert_not Catch.new.valid?,
               "a blank catch (no user, species, length_inches, captured_at_device) should be invalid"
    assert_not build(:catch, user: @user, species: @walleye, length_inches: 0).valid?,
               "a zero length should be invalid"
  end

  test "client_uuid must be unique" do
    create(:catch, user: @user, species: @walleye, client_uuid: "abc")
    duplicate = build(:catch, user: @user, species: @walleye, client_uuid: "abc")
    assert_not duplicate.valid?
  end

  test "add_flag! appends the flag and is idempotent" do
    catch_record = create(:catch, user: @user, species: @walleye)
    catch_record.add_flag!("imported_photo")
    assert_includes catch_record.reload.flags, "imported_photo", "first add appends the flag"
    catch_record.add_flag!("imported_photo")
    assert_equal ["imported_photo"], catch_record.reload.flags, "a repeat add must not duplicate the flag"
  end

  test "add_flag! does not clobber a flag added concurrently after the instance was loaded" do
    catch_record = create(:catch, user: @user, species: @walleye)
    # Simulate a second writer (e.g. a teammate's FlagDuplicates) appending a
    # flag to the row after this instance snapshotted flags == [].
    Catch.where(id: catch_record.id).update_all("flags = ARRAY['possible_duplicate']::text[]")
    catch_record.add_flag!("imported_photo")
    assert_equal %w[possible_duplicate imported_photo].sort, catch_record.reload.flags.sort
  end

  test "add_flag! with bump_to_review only moves a synced catch to needs_review" do
    { "synced" => "needs_review", "disqualified" => "disqualified" }.each do |start_status, expected|
      catch_record = create(:catch, user: @user, species: @walleye, status: start_status)
      catch_record.add_flag!("imported_photo", bump_to_review: true)
      assert_equal expected, catch_record.reload.status, "starting from #{start_status}"
    end
  end

  test "display_photo prefers the reference photo and falls back to the original" do
    catch_record = build(:catch, user: @user, species: @walleye)
    catch_record.photo.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample_walleye.jpg")),
      filename: "original.jpg", content_type: "image/jpeg"
    )
    catch_record.save!
    assert catch_record.photo.attached?, "the submission photo attaches and saves"
    assert_equal catch_record.photo.blob, catch_record.display_photo.blob,
                 "with no reference photo attached the original is shown"

    catch_record.reference_photo.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample_walleye.jpg")),
      filename: "reference.jpg", content_type: "image/jpeg"
    )
    catch_record.save!
    assert_equal "reference.jpg", catch_record.display_photo.blob.filename.to_s,
                 "an attached reference photo wins over the original"
  end

  test "photo attachments outside the allowed type and size are rejected" do
    [
      ["a non-image content_type",
       { io: StringIO.new("not really an image"), filename: "evil.txt", content_type: "text/plain" },
       "JPEG"],
      ["a photo larger than the byte cap",
       { io: StringIO.new("x" * (Catch::PHOTO_MAX_BYTES + 1)), filename: "huge.jpg", content_type: "image/jpeg" },
       "larger"]
    ].each do |label, upload, message|
      catch_record = build(:catch, user: @user, species: @walleye)
      catch_record.photo.attach(**upload)
      assert_not catch_record.valid?, "#{label} should be invalid"
      assert_includes catch_record.errors[:photo].join, message, "#{label}: error text"
    end
  end

  test "video attachments are gated on content type and size" do
    # `Minitest::Object#stub` needs minitest/mock, which isn't loadable under
    # this app's bundled minitest 6.0.6 (no mock.rb shipped, unlike the
    # 5.x default gem still present system-wide) — attach real oversized
    # content instead, mirroring the photo byte-cap test above.
    [
      ["a non-video content type",
       { io: StringIO.new("not a video"), filename: "evil.exe", content_type: "application/octet-stream" },
       :invalid, nil],
      ["a video over the size cap",
       { io: StringIO.new("x" * (Catch::VIDEO_MAX_BYTES + 1)), filename: "clip.mp4", content_type: "video/mp4" },
       :invalid, "MB"],
      ["an mp4 within limits",
       { io: StringIO.new("x"), filename: "clip.mp4", content_type: "video/mp4" },
       :valid, nil]
    ].each do |label, upload, expectation, message|
      catch_record = build(:catch, user: @user, species: @walleye)
      catch_record.video.attach(**upload)
      catch_record.valid?

      if expectation == :valid
        assert_empty catch_record.errors[:video], "#{label} should be accepted"
      else
        assert catch_record.errors[:video].any?, "#{label} should be rejected"
        assert(catch_record.errors[:video].any? { |m| m.include?(message) }, "#{label}: error text") if message
      end
    end
  end

  test "a legacy video the old API accepted unvalidated does not block later saves" do
    catch_record = create(:catch, user: @user, species: @walleye)
    # Attach directly at the Active Storage layer, bypassing model validation —
    # the state a pre-gate catch row is actually in.
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("x"), filename: "clip.3gp", content_type: "video/3gpp"
    )
    ActiveStorage::Attachment.create!(name: "video", record: catch_record, blob: blob)
    catch_record.reload

    catch_record.status = :needs_review
    assert catch_record.valid?, catch_record.errors.full_messages.join(", ")
  end

  # One row per capped species: a catch over the cap is invalid and the error
  # names the species, while a catch at exactly the cap is valid.
  LENGTH_CAPS = {
    "Walleye" => 50, "Perch" => 20, "Pike" => 70, "Bass" => 35,
    "Lake Trout" => 55, "Stocked Trout" => 35, "Tagged Walleye" => 50,
    "Other" => 200
  }.freeze

  test "species length caps reject over-cap catches, allow exactly-at-cap, and ignore uncapped species" do
    LENGTH_CAPS.each do |name, cap|
      species = name == "Walleye" ? @walleye : create(:species, club: @club, name: name)
      attrs = { user: @user, species: species }
      attrs[:tag_number] = "A1" if name == "Tagged Walleye"

      too_big = build(:catch, **attrs, length_inches: cap + 0.5)
      assert_not too_big.valid?, "#{name} over #{cap}\" should be invalid"
      assert_includes too_big.errors[:length_inches].join, name, "#{name} over-cap error names the species"

      at_cap = build(:catch, **attrs, length_inches: cap)
      assert at_cap.valid?,
             "#{name} at exactly #{cap}\" should be valid: #{at_cap.errors.full_messages.to_sentence}"
    end

    crappie = create(:species, club: @club, name: "Crappie")
    uncapped = build(:catch, user: @user, species: crappie, length_inches: 500)
    assert uncapped.valid?, "a species not in the cap table accepts any positive length"
  end

  test "length_cap_for looks up the cap by species name, case-insensitive" do
    assert_equal 50, Catch.length_cap_for(@walleye)
    assert_equal 35, Catch.length_cap_for(create(:species, club: @club, name: "Bass"))
    assert_nil Catch.length_cap_for(create(:species, club: @club, name: "Crappie"))
    assert_nil Catch.length_cap_for(nil)
  end

  test "note is optional and capped at 500 chars" do
    {
      nil => nil,
      "a" * 500 => nil,
      "a" * 501 => "too long"
    }.each do |note, error|
      label = note.nil? ? "a nil note" : "a #{note.length}-char note"
      catch_record = build(:catch, user: @user, species: @walleye, note: note)

      if error
        assert_not catch_record.valid?, "#{label} should be invalid"
        assert_includes catch_record.errors[:note].join, error, "#{label}: error text"
      else
        assert catch_record.valid?, "#{label} should be valid: #{catch_record.errors.full_messages.to_sentence}"
      end
    end
  end

  test "latest_approver is the judge of the most recent approve, and nil otherwise" do
    judge = create(:user, club: @club, role: :organizer, name: "Judy")

    approved = create(:catch, user: @user, species: @walleye, status: :needs_review)
    create(:judge_action, catch: approved, judge_user: judge, action: :approve)
    assert_equal judge, approved.latest_approver, "most recent action is an approve"

    untouched = create(:catch, user: @user, species: @walleye)
    assert_nil untouched.latest_approver, "no judge actions exist"

    reflagged = create(:catch, user: @user, species: @walleye, status: :needs_review)
    create(:judge_action, catch: reflagged, judge_user: judge, action: :approve, created_at: 2.minutes.ago)
    create(:judge_action, catch: reflagged, judge_user: judge, action: :flag, created_at: 1.minute.ago)
    assert_nil reflagged.latest_approver, "most recent action is a flag"
  end

  test "disqualification_note returns the latest DQ note, breaks ties by id, and is nil unless disqualified" do
    judge = create(:user, club: @club, role: :organizer)

    single = create(:catch, user: @user, species: @walleye, status: :disqualified)
    create(:judge_action, catch: single, judge_user: judge, action: :disqualify, note: "blurry photo")
    assert_equal "blurry photo", single.disqualification_note, "one disqualify action"

    multiple = create(:catch, user: @user, species: @walleye, status: :disqualified)
    create(:judge_action, catch: multiple, judge_user: judge, action: :disqualify,
                          note: "first reason", created_at: 2.minutes.ago)
    create(:judge_action, catch: multiple, judge_user: judge, action: :disqualify,
                          note: "actual reason", created_at: 1.minute.ago)
    assert_equal "actual reason", multiple.disqualification_note, "most recent of multiple DQ actions"

    tied = create(:catch, user: @user, species: @walleye, status: :disqualified)
    same_time = 1.minute.ago
    create(:judge_action, catch: tied, judge_user: judge, action: :disqualify,
                          note: "earlier row", created_at: same_time)
    create(:judge_action, catch: tied, judge_user: judge, action: :disqualify,
                          note: "later row", created_at: same_time)
    assert_equal "later row", tied.disqualification_note, "created_at tie broken by highest id"

    not_dqd = create(:catch, user: @user, species: @walleye, status: :needs_review)
    create(:judge_action, catch: not_dqd, judge_user: judge, action: :disqualify, note: "stale")
    assert_nil not_dqd.disqualification_note, "catch is not disqualified"
  end

  test "disqualification_note consumes eager-loaded judge_actions without re-querying" do
    judge = create(:user, club: @club, role: :organizer)
    2.times do
      c = create(:catch, user: @user, species: @walleye, status: :disqualified)
      create(:judge_action, catch: c, judge_user: judge, action: :disqualify, note: "bad")
    end

    loaded = Catch.where(status: :disqualified).includes(:judge_actions).to_a
    judge_action_queries = count_queries(/\bfrom\s+"?judge_actions"?/i) do
      loaded.each(&:disqualification_note)
    end
    assert_equal 0, judge_action_queries,
                 "disqualification_note should read the preloaded association, not re-query per row"
  end

  test "tag_number is upcased, required for Tagged Walleye, and length checked" do
    user = create(:user)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")

    normalized = build(:catch, user: user, species: tagged, tag_number: "a1234", length_inches: 18.0)
    normalized.valid?
    assert_equal "A1234", normalized.tag_number, "tag numbers are upcased before validation"

    # Real tags get typed on a boat: smart quotes from an inch mark, spaces,
    # punctuation. A rejected tag strands the queued catch on the phone (the
    # 2026-09-12 stuck-walleye incident), so any text is accepted and fixed
    # up later by an organizer rather than bounced at sync time.
    ["X1795\u201D", "abc 123!", "A/B.C"].each do |tag|
      loose = build(:catch, user: user, species: tagged, tag_number: tag, length_inches: 18.0)
      assert loose.valid?, "tag_number #{tag.inspect} should be accepted: #{loose.errors.full_messages.to_sentence}"
      assert_equal tag.strip.upcase, loose.tag_number
    end

    untagged_species = create(:species, name: "Walleye Test #{SecureRandom.hex(2)}")
    optional = build(:catch, user: user, species: untagged_species, tag_number: nil, length_inches: 18.0)
    assert optional.valid?,
           "tag_number is not required off Tagged Walleye: #{optional.errors.full_messages.to_sentence}"

    {
      nil => "is required for Tagged Walleye catches",
      "A" * 17 => nil # over the 16-char max; the message names the limit
    }.each do |tag, message|
      c = build(:catch, user: user, species: tagged, tag_number: tag, length_inches: 18.0)
      assert_not c.valid?, "tag_number #{tag.inspect} should be invalid"

      if message
        assert_includes c.errors[:tag_number], message, "tag_number #{tag.inspect}: error text"
      else
        assert(c.errors[:tag_number].any? { |m| m.include?("16") },
               "tag_number #{tag.inspect}: error should name the 16-char max")
      end
    end
  end

  test "weight_text is optional freeform text, trimmed, and capped at 32 chars" do
    user = create(:user)
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    with_weight = lambda do |value|
      build(:catch, user: user, species: tagged, tag_number: "A1", weight_text: value, length_inches: 18.0)
    end

    {
      nil => nil,                          # optional even for Tagged Walleye
      "4 lbs 3oz" => "4 lbs 3oz",
      "2.1kg" => "2.1kg",
      "approx 2kg!?" => "approx 2kg!?",
      "3 pounds" => "3 pounds",
      "  4 lbs 3oz  " => "4 lbs 3oz",      # trimmed
      "   " => nil                         # whitespace-only becomes nil
    }.each do |value, expected|
      c = with_weight.call(value)
      assert c.valid?, "weight_text #{value.inspect} should be valid: #{c.errors.full_messages.to_sentence}"

      if expected.nil?
        assert_nil c.weight_text, "weight_text #{value.inspect} normalizes to nil"
      else
        assert_equal expected, c.weight_text, "weight_text #{value.inspect} is kept verbatim"
      end
    end

    too_long = with_weight.call("x" * 33)
    assert_not too_long.valid?, "a 33-char weight_text should be invalid"
    assert(too_long.errors[:weight_text].any? { |m| m.include?("32") },
           "the weight_text error should name the 32-char max")
  end

  test "length_unit must be inches or centimeters" do
    c = build(:catch, length_unit: "furlongs")
    assert_not c.valid?
    assert_includes c.errors[:length_unit], "is not included in the list"
  end

  test "a missing length_unit is inferred from the value on validation" do
    { 6.99 => "centimeters", 18.5 => "inches" }.each do |value, expected|
      c = build(:catch, length_inches: value, length_unit: nil)
      c.valid?
      assert_equal expected, c.length_unit, "#{value} should infer #{expected}"
    end
  end
end
