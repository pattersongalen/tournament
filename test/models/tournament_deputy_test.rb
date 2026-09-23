require "test_helper"

class TournamentDeputyTest < ActiveSupport::TestCase
  setup do
    @club      = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @member    = create(:user, club: @club, role: :member)
    @upcoming  = create(:tournament, club: @club, starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
  end

  test "a user can only be deputized once per tournament" do
    create(:tournament_deputy, tournament: @upcoming, user: @member, granted_by_user: @organizer)
    dup = TournamentDeputy.new(tournament: @upcoming, user: @member, granted_by_user: @organizer)
    assert_not dup.valid?
  end

  test "an entrant CAN be a deputy, unlike a judge" do
    entry = create(:tournament_entry, tournament: @upcoming)
    create(:tournament_entry_member, tournament_entry: entry, user: @member)
    d = TournamentDeputy.new(tournament: @upcoming, user: @member, granted_by_user: @organizer)
    assert d.valid?, "a deputy is expected to compete in the tournament they set up"
  end

  test "live scope includes grants on not-yet-started tournaments" do
    d = create(:tournament_deputy, tournament: @upcoming, user: @member, granted_by_user: @organizer)
    assert_includes TournamentDeputy.live, d
  end

  test "live scope excludes grants on started tournaments" do
    started = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    d = create(:tournament_deputy, tournament: started, user: @member, granted_by_user: @organizer)
    assert_not_includes TournamentDeputy.live, d
  end

  test "tournament exposes deputy_users" do
    create(:tournament_deputy, tournament: @upcoming, user: @member, granted_by_user: @organizer)
    assert_equal [@member], @upcoming.reload.deputy_users.to_a
  end
end
