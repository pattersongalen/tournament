require "test_helper"

class ClubTest < ActiveSupport::TestCase
  test "name is required and must be unique" do
    assert_not Club.new.valid?

    create(:club, name: "Test Fishing Club")
    duplicate = build(:club, name: "Test Fishing Club")
    assert_not duplicate.valid?
  end

  test "current_rules_revision returns the latest revision for the active season, nil with no revisions, and tracks active_rules_season changes" do
    club = create(:club)
    assert_nil club.current_rules_revision

    user = create(:user, club: club)
    create(:club_rules_revision, club: club, edited_by_user: user, season: :open_water,
                                 body: "old", created_at: 2.days.ago)
    newer = create(:club_rules_revision, club: club, edited_by_user: user, season: :open_water,
                                         body: "new", created_at: 1.day.ago)
    assert_equal newer, club.current_rules_revision

    ice_rev = create(:club_rules_revision, club: club, edited_by_user: user, season: :ice)
    club.update!(active_rules_season: :ice)
    assert_equal ice_rev, club.current_rules_revision
  end

  test "banner_message defaults to nil, banner_style defaults to info, and banner_style maps to integers good=1 alert=2" do
    club = Club.create!(name: "Banner Defaults FC")
    assert_nil club.banner_message
    assert_equal "info", club.banner_style

    club.update!(banner_style: :alert)
    raw = Club.connection.select_value(Club.where(id: club.id).select(:banner_style).to_sql)
    assert_equal 2, raw
  end

  test "new club gets the default season points settings" do
    club = create(:club)
    assert_equal "tiered_ladders", club.season_points_scheme
    assert_equal 0.5, club.season_points_attendance.to_f
    assert_equal 3, club.season_points_min_entries
    assert_equal [[3, 2, 1], [6, 4, 2], [9, 6, 3], [9, 6, 3]], club.season_points_ladders
    assert_equal [3, 2, 1], club.season_points_base_ladder
    assert_equal [1, 2, 3, 3], club.season_points_tier_multipliers
  end

  test "season_points_ladders validation: ordering, equal adjacents, negative/empty/wrong-count, and string amounts" do
    {
      "amounts increase"              => { ladders: [[3, 2, 1], [2, 4, 6], [9, 6, 3], [9, 6, 3]], valid: false, error_substr: "highest first" },
      "equal adjacent amounts"        => { ladders: [[3, 3, 1], [6, 4, 2], [9, 6, 3], [9, 6, 3]], valid: true },
      "negative amount"               => { ladders: [[3, 2, -1], [6, 4, 2], [9, 6, 3], [9, 6, 3]], valid: false },
      "empty band"                    => { ladders: [[], [6, 4, 2], [9, 6, 3], [9, 6, 3]], valid: false },
      "wrong band count"              => { ladders: [[3, 2, 1], [6, 4, 2]], valid: false },
      "string amount (FIX 2)"         => { ladders: [["9", "6", "3"], [6, 4, 2], [9, 6, 3], [9, 6, 3]], valid: false, error_substr: "numbers" }
    }.each do |label, spec|
      club = create(:club)
      club.season_points_ladders = spec[:ladders]
      if spec[:valid]
        assert club.valid?, "#{label}: #{club.errors.full_messages.join(", ")}"
      else
        assert_not club.valid?, "#{label}: should be invalid"
        assert_includes club.errors[:season_points_ladders].join, spec[:error_substr], "#{label}: error text" if spec[:error_substr]
      end
    end
  end

  test "rejects a non-positive multiplier, a negative attendance, min entries below 1, and string amounts in base ladder or tier multipliers" do
    club = create(:club)
    club.season_points_tier_multipliers = [1, 0, 3, 3]
    assert_not club.valid?

    club = create(:club)
    club.season_points_attendance = -1
    assert_not club.valid?

    club = create(:club)
    club.season_points_min_entries = 0
    assert_not club.valid?

    club = create(:club)
    club.season_points_base_ladder = ["3", "2", "1"]
    assert_not club.valid?
    assert_includes club.errors[:season_points_base_ladder].join, "numbers"

    club = create(:club)
    club.season_points_tier_multipliers = ["1", 2, 3, 3]
    assert_not club.valid?
    assert_includes club.errors[:season_points_tier_multipliers].join, "numbers"
  end

  test "ladder text writers parse comma-separated strings" do
    club = create(:club)
    club.season_points_ladders_text = ["10, 8, 6, 5", "12,10,8", "14, 12, 10", "16,14,12"]
    club.season_points_base_ladder_text = "5, 4, 3"
    club.season_points_tier_multipliers_text = "1, 1.5, 2, 2.5"
    assert club.valid?, club.errors.full_messages.join(", ")
    assert_equal [10.0, 8.0, 6.0, 5.0], club.season_points_ladders.first
    assert_equal [5.0, 4.0, 3.0], club.season_points_base_ladder
    assert_equal [1.0, 1.5, 2.0, 2.5], club.season_points_tier_multipliers
  end

  test "a junk token in a ladder text field is a validation error, not an exception" do
    club = create(:club)
    club.season_points_ladders_text = ["10, eight, 6", "6,4,2", "9,6,3", "9,6,3"]
    assert_not club.valid?
    assert_includes club.errors[:season_points_ladders].join, "numbers"
  end

  test "ladder text round-trips through season_points_ladder_text, and base ladder / tier multiplier text trim .0" do
    club = create(:club)
    club.season_points_ladders_text = ["10, 8, 6", "6,4,2", "9,6,3", "9,6,3"]
    assert_equal "10, 8, 6", club.season_points_ladder_text(0)

    club.season_points_base_ladder_text = "5, 4, 3"
    club.season_points_tier_multipliers_text = "1, 1.5, 2, 2.5"
    assert_equal "5, 4, 3", club.season_points_base_ladder_text
    assert_equal "1, 1.5, 2, 2.5", club.season_points_tier_multipliers_text
  end

  # FIX 1 regression: a band that fails to parse used to shift every later
  # band down one slot via `parsed.compact`, so the re-rendered form showed
  # the wrong ladder under the wrong band's label.
  test "a rejected band leaves the other three bands' text intact on re-render, with no shift" do
    club = create(:club)
    club.season_points_ladders_text = ["10, 8, 6", "12,10,8", "14, 12, 10", "16, 14, 12"]

    club.season_points_ladders_text = ["10, 8, 6", "12,1O,8", "14, 12, 10", "16, 14, 12"]

    assert_not club.valid?
    assert_equal "10, 8, 6",    club.season_points_ladder_text(0)
    assert_equal "12,1O,8",     club.season_points_ladder_text(1)
    assert_equal "14, 12, 10",  club.season_points_ladder_text(2)
    assert_equal "16, 14, 12",  club.season_points_ladder_text(3)
  end

  # FIX 1 regression: reproduces the full two-submit sequence from the code
  # review. Because the re-render no longer shifts bands, retyping only the
  # broken band and resubmitting the rest exactly as shown must save each
  # ladder against its ORIGINAL band — never swap a ladder into a
  # neighbouring band.
  test "retyping only the broken band and resubmitting the rest cannot swap a ladder into the wrong band" do
    club = create(:club)
    club.season_points_ladders_text = ["10, 8, 6", "12, 10, 8", "14, 12, 10", "16, 14, 12"]
    club.save!

    # First submit: band index 1 has a typo.
    club.season_points_ladders_text = ["10, 8, 6", "12,1O,8", "14, 12, 10", "16, 14, 12"]
    assert_not club.valid?

    # Admin retypes band 1 correctly and resubmits exactly what the
    # re-rendered form showed for the other three bands.
    club.season_points_ladders_text = [
      club.season_points_ladder_text(0),
      "12, 10, 8",
      club.season_points_ladder_text(2),
      club.season_points_ladder_text(3)
    ]

    assert club.valid?, club.errors.full_messages.join(", ")
    assert_equal [[10.0, 8.0, 6.0], [12.0, 10.0, 8.0], [14.0, 12.0, 10.0], [16.0, 14.0, 12.0]],
                 club.season_points_ladders
  end

  # FIX 4: labels and sample field sizes are derived from SEASON_POINTS_BANDS
  # in one place, so the admin editor, its preview table, and the member
  # explainer can't drift out of sync.
  test "season_points_bands derives labels and top-of-band samples from SEASON_POINTS_BANDS" do
    assert_equal [
      { label: "1–9", sample: 9 },
      { label: "10–19", sample: 19 },
      { label: "20–29", sample: 29 },
      { label: "30+", sample: 30 }
    ], Club.season_points_bands
  end

  test "a parse failure stashes the raw base-ladder and multiplier text and keeps the saved values; reload clears the flags" do
    club = create(:club)
    club.season_points_base_ladder_text = "3, 2, x"
    assert_equal "3, 2, x", club.season_points_base_ladder_text, "re-render echoes what was typed"
    assert_equal [3, 2, 1], club.season_points_base_ladder, "the saved ladder is not replaced by []"
    club.season_points_tier_multipliers_text = "1, 1.5, 2, 2.S"
    assert_equal "1, 1.5, 2, 2.S", club.season_points_tier_multipliers_text
    assert_equal [1, 2, 3, 3], club.season_points_tier_multipliers
    assert_not club.valid?

    club.reload
    assert club.valid?, "reload must clear the parse-failure flags: #{club.errors.full_messages.join(', ')}"
    assert_equal "3, 2, 1", club.season_points_base_ladder_text
  end

  test "a later valid write to the jsonb column clears a stale parse-failure flag" do
    club = create(:club)
    club.season_points_base_ladder_text = "3,x"
    club.season_points_base_ladder = [3, 2, 1]
    assert club.valid?, club.errors.full_messages.join(", ")
    club.season_points_ladders_text = ["3,x", "6, 4, 2", "9, 6, 3", "9, 6, 3"]
    club.season_points_ladders = [[3, 2, 1], [6, 4, 2], [9, 6, 3], [9, 6, 3]]
    assert club.valid?, club.errors.full_messages.join(", ")
  end

  test "a non-finite amount is a validation error, not a null in jsonb" do
    club = create(:club)
    club.season_points_base_ladder_text = "9" * 400
    assert_not club.valid?, "400 nines to_f is Infinity"
    assert_equal [3, 2, 1], club.season_points_base_ladder
    club.reload
    club.season_points_base_ladder = [Float::INFINITY, 1]
    assert_not club.valid?
  end

  test "amounts are stored to two decimals and every text reader uses the shared formatter" do
    club = create(:club)
    club.season_points_base_ladder_text = "3.333, 2, 1"
    assert_equal [3.33, 2.0, 1.0], club.season_points_base_ladder
    assert_equal "3.33, 2, 1", club.season_points_base_ladder_text
    club.season_points_base_ladder = [3.333, 2]  # e.g. written via update_column
    assert_equal "3.33, 2", club.season_points_base_ladder_text
  end

  test "effective_season_points_bands clips the first band to the minimum entry count and drops bands below it" do
    club = create(:club, season_points_min_entries: 5)
    assert_equal ["5–9", "10–19", "20–29", "30+"], club.effective_season_points_bands.map { |b| b[:label] }
    assert_equal [9, 19, 29, 30], club.effective_season_points_bands.map { |b| b[:sample] }
    club.season_points_min_entries = 12
    assert_equal ["12–19", "20–29", "30+"], club.effective_season_points_bands.map { |b| b[:label] }
    club.season_points_min_entries = 1
    assert_equal Club.season_points_bands, club.effective_season_points_bands
  end
end
