# test/models/tournament_bingo_test.rb
require "test_helper"

class TournamentBingoTest < ActiveSupport::TestCase
  setup { create_bingo_species! }

  def club = @club ||= Club.create!(name: "Test Club")

  def build_bingo(**attrs)
    Tournament.new(
      club: club, name: "Bingo Night", mode: :solo, format: :bingo,
      starts_at: 1.hour.from_now, ends_at: 4.hours.from_now, **attrs
    )
  end

  test "creating a bingo tournament auto-assigns a valid random layout" do
    t = build_bingo
    assert t.save, t.errors.full_messages.to_sentence
    assert_equal 25, t.bingo_layout.size
    assert_equal "free", t.bingo_layout[12]
    assert_equal Catches::Bingo::Tasks.keys.sort, (t.bingo_layout - ["free"]).sort
  end

  test "a malformed layout is rejected" do
    t = build_bingo
    t.bingo_layout = ["free"] * 25
    assert_not t.valid?
    assert t.errors[:bingo_layout].any?
  end

  test "layout is locked once the tournament has started" do
    t = build_bingo(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
    t.save!(validate: false)
    t.bingo_layout = Catches::Bingo::Tasks.random_layout
    assert_not t.valid?
    assert t.errors[:bingo_layout].any?
  end

  test "non-bingo tournaments do not get a layout" do
    t = Tournament.create!(club: club, name: "Std", mode: :solo, format: :standard,
                           starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    assert_nil t.bingo_layout
  end

  test "switching an existing unstarted tournament to bingo assigns a layout on update" do
    t = Tournament.create!(club: club, name: "Std", mode: :solo, format: :standard,
                           starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    assert_nil t.bingo_layout
    assert t.update(format: :bingo), t.errors.full_messages.to_sentence
    assert t.format_bingo?
    assert_equal 25, t.bingo_layout.size
    assert_equal "free", t.bingo_layout[12]
  end

  test "switching to bingo after start is rejected with the format error, not a bingo_layout error" do
    t = Tournament.create!(club: club, name: "Std", mode: :solo, format: :standard,
                           starts_at: 1.hour.ago, ends_at: 4.hours.from_now)
    t.format = :bingo

    assert_not t.valid?
    assert_includes t.errors[:format], "can't be changed once the tournament has started"
    assert_empty t.errors[:bingo_layout],
                 "the auto-assigned layout must not surface a misleading bingo_layout error"
  end

  test "bingo tournament with blind_leaderboard true is invalid, false is valid" do
    invalid = build_bingo(blind_leaderboard: true)
    assert_not invalid.valid?
    assert invalid.errors[:blind_leaderboard].any?

    valid = build_bingo(blind_leaderboard: false)
    assert valid.valid?, valid.errors.full_messages.to_sentence
  end

  test "bingo is rejected when a referenced species is missing" do
    Species.where("lower(name) = ?", "pike").delete_all
    t = build_bingo
    assert_not t.valid?
    assert(t.errors[:base].any? { |m| m.include?("Pike") },
           "expected a base error naming the missing Pike species, got #{t.errors[:base].inspect}")
  end

  test "editing an existing bingo tournament stays allowed after a canonical species is renamed" do
    t = build_bingo
    t.save!
    # A global species rename later makes the card unfillable, but that can't be
    # fixed by editing the tournament — blocking an unrelated edit just strands it.
    Species.where("lower(name) = ?", "pike").update_all(name: "Northern Pike")

    assert t.update(name: "Renamed Bingo Night"),
           "an unrelated edit must not be blocked by a since-renamed species: #{t.errors.full_messages.inspect}"
    assert_equal "Renamed Bingo Night", t.reload.name
  end

  test "switching a started tournament to bingo does not re-run the species presence check" do
    # bingo_species_present must not fire on a format change that format_locked_after_start
    # already rejects — only the single format error should surface.
    Species.where("lower(name) = ?", "pike").delete_all
    t = Tournament.create!(club: club, name: "Std", mode: :solo, format: :standard,
                           starts_at: 1.hour.ago, ends_at: 4.hours.from_now)
    t.format = :bingo
    assert_not t.valid?
    assert_empty t.errors[:base],
                 "a since-missing species must not pile a base error onto the blocked format switch"
  end
end
