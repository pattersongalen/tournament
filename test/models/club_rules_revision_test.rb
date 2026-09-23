require "test_helper"

class ClubRulesRevisionTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
  end

  test "is valid with body, season, edited_by_user, and club; requires body" do
    rev = build(:club_rules_revision, club: @club, edited_by_user: @user)
    assert rev.valid?, rev.errors.full_messages.inspect

    blank = build(:club_rules_revision, club: @club, edited_by_user: @user, body: nil)
    assert_not blank.valid?
    assert_includes blank.errors[:body], "can't be blank"
  end

  test "season enum exposes prefix predicates; body is an Action Text rich-text association" do
    rev = create(:club_rules_revision, club: @club, edited_by_user: @user, season: :ice,
                                       body: "<h1>Hello</h1>")
    assert rev.season_ice?
    assert_not rev.season_open_water?
    assert_kind_of ActionText::RichText, rev.body
    assert_includes rev.body.to_s, "<h1>Hello</h1>"
  end

  test "latest_for returns the most recent revision, scoped per club and per season" do
    other_club = create(:club)
    other_user = create(:user, club: other_club)
    create(:club_rules_revision, club: other_club, edited_by_user: other_user, season: :open_water)
    assert_nil ClubRulesRevision.latest_for(club: @club, season: :open_water),
               "scoped per club: another club's revision must not leak in"

    older = create(:club_rules_revision, club: @club, edited_by_user: @user,
                                         season: :open_water, body: "old",
                                         created_at: 2.days.ago)
    newer = create(:club_rules_revision, club: @club, edited_by_user: @user,
                                         season: :open_water, body: "new",
                                         created_at: 1.day.ago)

    assert_equal newer, ClubRulesRevision.latest_for(club: @club, season: :open_water)
    assert_not_equal older, ClubRulesRevision.latest_for(club: @club, season: :open_water)

    assert_nil ClubRulesRevision.latest_for(club: @club, season: :ice),
               "scoped per season: an open_water revision must not satisfy an ice lookup"
  end
end
