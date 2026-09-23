require "test_helper"

class Organizers::TournamentEntryMembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @a = create(:user, club: @club, name: "Aron", role: :member)
    @b = create(:user, club: @club, name: "Galen", role: :member)
    @c = create(:user, club: @club, name: "Casey", role: :member)
    @member = create(:user, club: @club, name: "Joe", role: :member)
    @teammate = create(:user, club: @club, name: "Curtis", role: :member)
    @team = create(:tournament, club: @club, mode: :team,
                                starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
    sign_in_as(@organizer)
  end

  test "members are forbidden" do
    create_boat1_entry!
    sign_in_as(@a)
    post organizers_tournament_tournament_entry_tournament_entry_members_path(
      tournament_id: @team.id, tournament_entry_id: @entry.id), params: { user_id: @b.id }
    assert_response :forbidden
  end

  test "organizer adds a member to a team entry before tournament starts" do
    create_boat1_entry!
    assert_difference "TournamentEntryMember.count", 1 do
      post organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: @entry.id), params: { user_id: @b.id }
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/Added Galen/, flash[:notice])
    assert_includes @entry.reload.users, @b
  end

  test "organizer removes a member from a team entry before tournament starts" do
    create_boat1_entry!
    create(:tournament_entry_member, tournament_entry: @entry, user: @b)
    member = TournamentEntryMember.find_by(tournament_entry_id: @entry.id, user_id: @b.id)

    assert_difference "TournamentEntryMember.count", -1 do
      delete organizers_tournament_tournament_entry_tournament_entry_member_path(
        tournament_id: @team.id, tournament_entry_id: @entry.id, id: member.id)
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/Removed Galen/, flash[:notice])
  end

  test "organizer removes a member from a team entry after tournament starts and rescores leaderboard" do
    create_boat1_entry!
    create(:tournament_entry_member, tournament_entry: @entry, user: @b)
    @team.update!(starts_at: 1.minute.ago, ends_at: 1.hour.from_now)
    member = TournamentEntryMember.find_by(tournament_entry_id: @entry.id, user_id: @b.id)

    drop_calls = []
    original = ::Catches::DropMemberFromEntry.method(:call)
    ::Catches::DropMemberFromEntry.define_singleton_method(:call) do |entry:, user:|
      drop_calls << [entry.id, user.id]
      entry.tournament_entry_members.find_by(user_id: user.id)&.destroy
    end
    begin
      assert_difference "TournamentEntryMember.count", -1 do
        delete organizers_tournament_tournament_entry_tournament_entry_member_path(
          tournament_id: @team.id, tournament_entry_id: @entry.id, id: member.id)
      end
    ensure
      ::Catches::DropMemberFromEntry.define_singleton_method(:call, original)
    end
    assert_equal [[@entry.id, @b.id]], drop_calls
    assert_match(/Removed Galen/, flash[:notice])
  end

  test "add is rejected on solo tournaments" do
    solo = create(:tournament, club: @club, mode: :solo,
                               starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
    solo_entry = create(:tournament_entry, tournament: solo)
    create(:tournament_entry_member, tournament_entry: solo_entry, user: @a)
    assert_no_difference "TournamentEntryMember.count" do
      post organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: solo.id, tournament_entry_id: solo_entry.id), params: { user_id: @b.id }
    end
    assert_match(/Solo entries can't have additional members/i, flash[:alert])
  end

  test "add rejects user from another club" do
    create_boat1_entry!
    other_club = create(:club)
    foreigner = create(:user, club: other_club)
    assert_no_difference "TournamentEntryMember.count" do
      post organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: @entry.id), params: { user_id: foreigner.id }
    end
    assert_match(/not found/i, flash[:alert])
  end

  test "add rejects when team is at capacity" do
    create_boat1_entry!
    # Fill the team to MAX_TEAM_MEMBERS
    extras = (TournamentEntryMember::MAX_TEAM_MEMBERS - 1).times.map do |i|
      create(:user, club: @club, name: "Extra #{i}")
    end
    extras.each { |u| create(:tournament_entry_member, tournament_entry: @entry, user: u) }
    assert_no_difference "TournamentEntryMember.count" do
      post organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: @entry.id), params: { user_id: @b.id }
    end
    assert_match(/capacity/i, flash[:alert])
  end

  test "add rejects user already in another entry of the same tournament" do
    create_boat1_entry!
    other_entry = create(:tournament_entry, tournament: @team, name: "Boat 2")
    create(:tournament_entry_member, tournament_entry: other_entry, user: @b)
    assert_no_difference "TournamentEntryMember.count" do
      post organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: @entry.id), params: { user_id: @b.id }
    end
    assert_match(/already entered/i, flash[:alert])
  end

  test "adding a member backfills their in-window catches when the flag is on" do
    create_boat1_entry!
    walleye = create(:species, name: "Walleye")
    @team.update!(starts_at: 4.hours.ago, ends_at: 1.hour.ago, backfill_late_entrants: true)
    create(:scoring_slot, tournament: @team, species: walleye, slot_count: 2)
    missed = create(:catch, user: @b, species: walleye,
                    length_inches: 20, captured_at_device: 3.hours.ago)

    post organizers_tournament_tournament_entry_tournament_entry_members_path(
      tournament_id: @team.id, tournament_entry_id: @entry.id), params: { user_id: @b.id }

    assert_equal [missed.id],
                 CatchPlacement.where(tournament: @team, active: true).pluck(:catch_id)
  end

  test "adding a member stays forward-only when the flag is off" do
    create_boat1_entry!
    walleye = create(:species, name: "Walleye")
    @team.update!(starts_at: 4.hours.ago, ends_at: 1.hour.ago)
    create(:scoring_slot, tournament: @team, species: walleye, slot_count: 2)
    create(:catch, user: @b, species: walleye,
           length_inches: 20, captured_at_device: 3.hours.ago)

    post organizers_tournament_tournament_entry_tournament_entry_members_path(
      tournament_id: @team.id, tournament_entry_id: @entry.id), params: { user_id: @b.id }

    assert_empty CatchPlacement.where(tournament: @team)
  end

  test "adding a crew member adds them to the linked tournament's entry too" do
    group = SecureRandom.uuid
    @team.update!(link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, name: "Side",
                  starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, link_group_id: group)
    post organizers_tournament_tournament_entries_path(tournament_id: @team.id),
         params: { tournament_entry: { name: "Majestic Red", member_user_ids: [@member.id] } }
    entry = @team.tournament_entries.sole

    post organizers_tournament_tournament_entry_tournament_entry_members_path(
      tournament_id: @team.id, tournament_entry_id: entry.id
    ), params: { user_id: @teammate.id }

    assert_equal [@member, @teammate].sort_by(&:id),
                 side.tournament_entries.sole.users.sort_by(&:id)
  end

  # A mirror can legitimately reject — here @teammate judges the Side, so
  # TournamentEntryMember's user_not_a_judge validation raises. The organizer
  # is told the add failed, so it must actually have failed: without the
  # transaction the member stays on the Main entry alone, permanently out of
  # sync with the pair and with nothing offering a repair.
  test "a rejected mirror rolls the local add back too" do
    group = SecureRandom.uuid
    @team.update!(link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, name: "Side",
                  starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, link_group_id: group)
    post organizers_tournament_tournament_entries_path(tournament_id: @team.id),
         params: { tournament_entry: { name: "Majestic Red", member_user_ids: [@member.id] } }
    entry = @team.tournament_entries.sole
    create(:tournament_judge, tournament: side, user: @teammate)

    assert_no_difference "TournamentEntryMember.count" do
      post organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: entry.id
      ), params: { user_id: @teammate.id }
    end

    assert_not_nil flash[:alert]
    assert_equal [@member], entry.reload.users
    assert_equal [@member], side.tournament_entries.sole.users
  end

  test "same_as_last_week rejects an entry with no saved boat" do
    entry = create(:tournament_entry, tournament: @team, name: "Ad hoc team")
    create(:tournament_entry_member, tournament_entry: entry, user: @a)

    assert_no_difference "TournamentEntryMember.count" do
      post same_as_last_week_organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: entry.id)
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/isn't a saved boat/i, flash[:alert])
  end

  test "same_as_last_week rejects a boat with no fishing history" do
    boat = create(:boat, club: @club, name: "Team Patterson", captain: @a)
    entry = create(:tournament_entry, tournament: @team, name: "Team Patterson", boat: boat)
    create(:tournament_entry_member, tournament_entry: entry, user: @a)

    assert_no_difference "TournamentEntryMember.count" do
      post same_as_last_week_organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: entry.id)
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/hasn't fished before/i, flash[:alert])
  end

  test "same_as_last_week adds last week's crew to tonight's entry" do
    boat = create(:boat, club: @club, name: "Team Patterson", captain: @a)
    last_week = create(:tournament, club: @club, mode: :team,
                       starts_at: 8.days.ago, ends_at: 8.days.ago + 3.hours)
    old_entry = create(:tournament_entry, tournament: last_week, name: "Team Patterson", boat: boat)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @a)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @b)

    tonight_entry = create(:tournament_entry, tournament: @team, name: "Team Patterson", boat: boat)

    assert_difference "TournamentEntryMember.count", 2 do
      post same_as_last_week_organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: tonight_entry.id)
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/Added 2 from last time/, flash[:notice])
    assert_equal [@a, @b].sort_by(&:id), tonight_entry.reload.users.sort_by(&:id)
  end

  test "same_as_last_week skips a crew member who is no longer an active club member" do
    boat = create(:boat, club: @club, name: "Team Patterson", captain: @a)
    last_week = create(:tournament, club: @club, mode: :team,
                       starts_at: 8.days.ago, ends_at: 8.days.ago + 3.hours)
    old_entry = create(:tournament_entry, tournament: last_week, name: "Team Patterson", boat: boat)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @a)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @b)
    @b.club_memberships.find_by(club: @club).update!(deactivated_at: 1.day.ago)

    tonight_entry = create(:tournament_entry, tournament: @team, name: "Team Patterson", boat: boat)

    assert_difference "TournamentEntryMember.count", 1 do
      post same_as_last_week_organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: tonight_entry.id)
    end
    assert_equal [@a], tonight_entry.reload.users
  end

  # Same case via the path the app actually uses: only users.deactivated_at is
  # written, the membership row is left untouched. The per-entry "Add"
  # dropdown on this same screen lists current_club.members.active, so the two
  # must agree.
  test "same_as_last_week skips a crew member whose account has been deactivated" do
    boat = create(:boat, club: @club, name: "Team Patterson", captain: @a)
    last_week = create(:tournament, club: @club, mode: :team,
                       starts_at: 8.days.ago, ends_at: 8.days.ago + 3.hours)
    old_entry = create(:tournament_entry, tournament: last_week, name: "Team Patterson", boat: boat)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @a)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @b)
    @b.update!(deactivated_at: 1.day.ago)

    tonight_entry = create(:tournament_entry, tournament: @team, name: "Team Patterson", boat: boat)

    assert_difference "TournamentEntryMember.count", 1 do
      post same_as_last_week_organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: tonight_entry.id)
    end
    assert_equal [@a], tonight_entry.reload.users
  end

  test "same_as_last_week backfills in-window catches for the added crew when the flag is on" do
    boat = create(:boat, club: @club, name: "Team Patterson", captain: @a)
    last_week = create(:tournament, club: @club, mode: :team,
                       starts_at: 8.days.ago, ends_at: 8.days.ago + 3.hours)
    old_entry = create(:tournament_entry, tournament: last_week, name: "Team Patterson", boat: boat)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @a)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @b)

    walleye = create(:species, name: "Walleye")
    @team.update!(starts_at: 4.hours.ago, ends_at: 1.hour.ago, backfill_late_entrants: true)
    create(:scoring_slot, tournament: @team, species: walleye, slot_count: 2)
    missed = create(:catch, user: @b, species: walleye,
                    length_inches: 20, captured_at_device: 3.hours.ago)

    tonight_entry = create(:tournament_entry, tournament: @team, name: "Team Patterson", boat: boat)

    post same_as_last_week_organizers_tournament_tournament_entry_tournament_entry_members_path(
      tournament_id: @team.id, tournament_entry_id: tonight_entry.id)

    assert_equal [missed.id],
                 CatchPlacement.where(tournament: @team, active: true).pluck(:catch_id)
  end

  test "same_as_last_week mirrors the added crew into the linked tournament's entry" do
    boat = create(:boat, club: @club, name: "Team Patterson", captain: @a)
    last_week = create(:tournament, club: @club, mode: :team,
                       starts_at: 8.days.ago, ends_at: 8.days.ago + 3.hours)
    old_entry = create(:tournament_entry, tournament: last_week, name: "Team Patterson", boat: boat)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @a)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @b)

    group = SecureRandom.uuid
    @team.update!(link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, name: "Side",
                  starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, link_group_id: group)
    tonight_entry = create(:tournament_entry, tournament: @team, name: "Team Patterson", boat: boat)
    side_entry = create(:tournament_entry, tournament: side, name: "Team Patterson", boat: boat)

    post same_as_last_week_organizers_tournament_tournament_entry_tournament_entry_members_path(
      tournament_id: @team.id, tournament_entry_id: tonight_entry.id)

    assert_equal [@a, @b].sort_by(&:id), side_entry.reload.users.sort_by(&:id)
  end

  # The rescue reports the removal failed, so it has to have failed on both
  # sides: dropping @b here while the mirror is rejected would leave him off
  # this entry and still aboard the sibling, permanently out of sync with the
  # pair and with nothing offering a repair.
  test "removing a member whose sync can't be mirrored rolls the local removal back" do
    create_boat1_entry! # @entry on @team, crew [@a]
    create(:tournament_entry_member, tournament_entry: @entry, user: @b) # crew [@a, @b]

    group = SecureRandom.uuid
    @team.update!(link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, name: "Side",
                  starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, link_group_id: group)
    create(:tournament_judge, tournament: side, user: @a)
    # Side's counterpart is missing @a (a state that predates the judge
    # assignment, or just drifted) -- removing @b will still sync @a across
    # via the crew-add path, and that add trips user_not_a_judge.
    side_counterpart = create(:tournament_entry, tournament: side, name: "Boat 1")
    create(:tournament_entry_member, tournament_entry: side_counterpart, user: @b)

    member = TournamentEntryMember.find_by(tournament_entry_id: @entry.id, user_id: @b.id)

    assert_no_difference "TournamentEntryMember.count" do
      delete organizers_tournament_tournament_entry_tournament_entry_member_path(
        tournament_id: @team.id, tournament_entry_id: @entry.id, id: member.id)
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/judging/i, flash[:alert])
    assert_equal [@a, @b].sort_by(&:id), @entry.reload.users.sort_by(&:id)
    assert_equal [@b], side_counterpart.reload.users
  end

  test "same_as_last_week rolls back the whole refill when one crew member fails validation" do
    boat = create(:boat, club: @club, name: "Team Patterson", captain: @a)
    last_week = create(:tournament, club: @club, mode: :team,
                       starts_at: 8.days.ago, ends_at: 8.days.ago + 3.hours)
    old_entry = create(:tournament_entry, tournament: last_week, name: "Team Patterson", boat: boat)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @a)
    create(:tournament_entry_member, tournament_entry: old_entry, user: @b)

    tonight_entry = create(:tournament_entry, tournament: @team, name: "Team Patterson", boat: boat)
    # @b is already entered on a different boat tonight, so re-adding them to
    # tonight_entry will trip the "already entered in this tournament"
    # validation partway through the crew loop.
    other_entry = create(:tournament_entry, tournament: @team, name: "Other boat")
    create(:tournament_entry_member, tournament_entry: other_entry, user: @b)

    assert_no_difference "TournamentEntryMember.count" do
      post same_as_last_week_organizers_tournament_tournament_entry_tournament_entry_members_path(
        tournament_id: @team.id, tournament_entry_id: tonight_entry.id)
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/already entered/i, flash[:alert])
    assert_empty tonight_entry.reload.users
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  # Most tests need a pre-existing team entry ("Boat 1") to add/remove crew
  # from. Kept out of setup so the linked-tournament test can start @team
  # with zero entries and rely on TournamentEntry.sole after its own POST.
  def create_boat1_entry!
    @entry = create(:tournament_entry, tournament: @team, name: "Boat 1")
    create(:tournament_entry_member, tournament_entry: @entry, user: @a)
  end
end
