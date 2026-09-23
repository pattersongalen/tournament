require "test_helper"

class Organizers::TournamentEntriesControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @member = create(:user, club: @club, name: "Joe", role: :member)
    @teammate = create(:user, club: @club, name: "Curtis", role: :member)
    # Roster edits are now permitted at any time; tests cover both pre-start and mid-tournament.
    @solo = create(:tournament, club: @club, mode: :solo, starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
    @team = create(:tournament, club: @club, mode: :team, starts_at: 1.hour.from_now, ends_at: 3.hours.from_now)
    sign_in_as(@organizer)
  end

  test "members are forbidden" do
    sign_in_as(@member)
    post organizers_tournament_tournament_entries_path(tournament_id: @solo.id),
         params: { tournament_entry: { member_user_ids: [@member.id] } }
    assert_response :forbidden
  end

  test "organizer creates a solo entry for one user" do
    assert_difference "TournamentEntry.count", 1 do
      post organizers_tournament_tournament_entries_path(tournament_id: @solo.id),
           params: { tournament_entry: { member_user_ids: [@member.id] } }
    end
    entry = TournamentEntry.last
    assert_equal [@member], entry.users
    assert_redirected_to edit_organizers_tournament_path(@solo)
  end

  test "organizer bulk-adds multiple solo entries in one submit" do
    assert_difference "TournamentEntry.count", 2 do
      post organizers_tournament_tournament_entries_path(tournament_id: @solo.id),
           params: { tournament_entry: { member_user_ids: [@member.id, @teammate.id] } }
    end
    new_entries = TournamentEntry.order(:id).last(2)
    # The controller creates one solo entry per member in DB row order (the
    # id list has no ORDER BY), which isn't the param order — so compare the
    # two single-member entries order-independently.
    assert_equal [[@member], [@teammate]].sort_by { |u| u.first.id },
                 new_entries.map(&:users).sort_by { |u| u.first.id }
    assert_equal "2 entries added.", flash[:notice]
  end

  test "organizer creates a team entry with two members and a boat name" do
    assert_difference "TournamentEntry.count", 1 do
      post organizers_tournament_tournament_entries_path(tournament_id: @team.id),
           params: { tournament_entry: { name: "Curtis's Boat", member_user_ids: [@member.id, @teammate.id] } }
    end
    entry = TournamentEntry.last
    assert_equal "Curtis's Boat", entry.name
    assert_equal [@member, @teammate].sort_by(&:id), entry.users.sort_by(&:id)
  end

  test "deactivated members can't be added to a new entry" do
    @member.update!(deactivated_at: Time.current)
    assert_no_difference "TournamentEntry.count" do
      post organizers_tournament_tournament_entries_path(tournament_id: @solo.id),
           params: { tournament_entry: { member_user_ids: [@member.id] } }
    end
    assert_match(/unavailable/i, flash[:alert])
  end

  test "destroying an entry mid-tournament cascades placements and broadcasts the leaderboard" do
    walleye = create(:species, club: @club)
    started = create(:tournament, club: @club, mode: :team, starts_at: 30.minutes.ago, ends_at: 30.minutes.from_now)
    create(:scoring_slot, tournament: started, species: walleye, slot_count: 2)
    entry = create(:tournament_entry, tournament: started, name: "Doomed")
    create(:tournament_entry_member, tournament_entry: entry, user: @member)
    fish = create(:catch, user: @member, species: walleye, length_inches: 18, captured_at_device: 5.minutes.ago)
    Catches::PlaceInSlots.call(catch: fish)
    assert_equal 1, fish.reload.catch_placements.where(active: true).count

    broadcast_calls = with_broadcast_spy do
      assert_difference "TournamentEntry.count", -1 do
        delete organizers_tournament_tournament_entry_path(tournament_id: started.id, id: entry.id)
      end
    end
    assert_equal [started.id], broadcast_calls
    assert_equal 0, CatchPlacement.where(catch_id: fish.id).count, "placements should cascade-destroy with the entry"
  end

  test "organizer renames a team entry before tournament starts" do
    entry = create(:tournament_entry, tournament: @team, name: "Old Boat")
    create(:tournament_entry_member, tournament_entry: entry, user: @member)

    patch organizers_tournament_tournament_entry_path(tournament_id: @team.id, id: entry.id),
          params: { tournament_entry: { name: "New Boat" } }

    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_equal "New Boat", entry.reload.name
  end

  test "rename clears the name when blank submitted" do
    entry = create(:tournament_entry, tournament: @team, name: "Was Named")
    create(:tournament_entry_member, tournament_entry: entry, user: @member)

    patch organizers_tournament_tournament_entry_path(tournament_id: @team.id, id: entry.id),
          params: { tournament_entry: { name: "  " } }
    assert_nil entry.reload.name
  end

  test "organizer destroys an entry" do
    entry = create(:tournament_entry, tournament: @solo)
    create(:tournament_entry_member, tournament_entry: entry, user: @member)

    assert_difference "TournamentEntry.count", -1 do
      delete organizers_tournament_tournament_entry_path(tournament_id: @solo.id, id: entry.id)
    end
    assert_redirected_to edit_organizers_tournament_path(@solo)
  end

  test "solo entry creation enqueues a push to each new member" do
    with_perform_later_capture do |enqueued|
      post organizers_tournament_tournament_entries_path(tournament_id: @solo.id),
           params: { tournament_entry: { member_user_ids: [@member.id, @teammate.id] } }
      assert_equal 2, enqueued.size
      assert_equal [@member.id, @teammate.id].sort, enqueued.map { |e| e[:user_id] }.sort
      assert(enqueued.all? { |e| e[:body].include?("entered into") && e[:body].include?(@solo.name) })
      assert(enqueued.all? { |e| e[:tournament_id] == @solo.id })
    end
  end

  test "team entry creation enqueues a push to each member of the entry" do
    with_perform_later_capture do |enqueued|
      post organizers_tournament_tournament_entries_path(tournament_id: @team.id),
           params: { tournament_entry: { name: "Boat", member_user_ids: [@member.id, @teammate.id] } }
      assert_equal 2, enqueued.size
      assert_equal [@member.id, @teammate.id].sort, enqueued.map { |e| e[:user_id] }.sort
    end
  end

  test "no push enqueued when validation rejects the request" do
    @member.update!(deactivated_at: Time.current)
    with_perform_later_capture do |enqueued|
      post organizers_tournament_tournament_entries_path(tournament_id: @solo.id),
           params: { tournament_entry: { member_user_ids: [@member.id] } }
      assert_empty enqueued
    end
  end

  test "bingo: creating an entry does not rebroadcast existing anglers' cards" do
    create_bingo_species!
    bingo = create(:tournament, club: @club, mode: :solo, format: :bingo,
                   starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    existing = create(:tournament_entry, tournament: bingo)
    create(:tournament_entry_member, tournament_entry: existing, user: @teammate)

    assert_broadcasts("tournament:#{bingo.id}:leaderboard:full", 1) do
      assert_broadcasts("bingo_card:#{bingo.id}:#{existing.id}", 0) do
        post organizers_tournament_tournament_entries_path(tournament_id: bingo.id),
             params: { tournament_entry: { member_user_ids: [@member.id] } }
      end
    end
    new_entry = bingo.tournament_entries.where.not(id: existing.id).sole
    assert_equal [@member], new_entry.users
  end

  test "bingo: destroying an entry does not rebroadcast sibling cards" do
    create_bingo_species!
    bingo = create(:tournament, club: @club, mode: :solo, format: :bingo,
                   starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    doomed = create(:tournament_entry, tournament: bingo)
    create(:tournament_entry_member, tournament_entry: doomed, user: @member)
    sibling = create(:tournament_entry, tournament: bingo)
    create(:tournament_entry_member, tournament_entry: sibling, user: @teammate)

    assert_broadcasts("tournament:#{bingo.id}:leaderboard:full", 1) do
      assert_broadcasts("bingo_card:#{bingo.id}:#{sibling.id}", 0) do
        delete organizers_tournament_tournament_entry_path(tournament_id: bingo.id, id: doomed.id)
      end
    end
  end

  test "creating an entry backfills the user's in-window catches when the flag is on" do
    walleye = create(:species, name: "Walleye")
    tournament = create(:tournament, club: @club, starts_at: 4.hours.ago, ends_at: 1.hour.ago,
                                     backfill_late_entrants: true)
    create(:scoring_slot, tournament: tournament, species: walleye, slot_count: 2)
    member = create(:user, club: @club)
    missed = create(:catch, user: member, species: walleye,
                    length_inches: 20, captured_at_device: 3.hours.ago)

    post organizers_tournament_tournament_entries_path(tournament_id: tournament.id),
         params: { tournament_entry: { member_user_ids: [member.id] } }

    assert_equal [missed.id],
                 CatchPlacement.where(tournament: tournament, active: true).pluck(:catch_id)
  end

  test "creating an entry stays forward-only when the flag is off" do
    walleye = create(:species, name: "Walleye")
    tournament = create(:tournament, club: @club, starts_at: 4.hours.ago, ends_at: 1.hour.ago)
    create(:scoring_slot, tournament: tournament, species: walleye, slot_count: 2)
    member = create(:user, club: @club)
    create(:catch, user: member, species: walleye,
           length_inches: 20, captured_at_device: 3.hours.ago)

    post organizers_tournament_tournament_entries_path(tournament_id: tournament.id),
         params: { tournament_entry: { member_user_ids: [member.id] } }

    assert_empty CatchPlacement.where(tournament: tournament)
  end

  test "creating a team entry mirrors it into the linked tournament" do
    group = SecureRandom.uuid
    @team.update!(link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, name: "Side",
                  starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, link_group_id: group)

    assert_difference "TournamentEntry.count", 2 do
      post organizers_tournament_tournament_entries_path(tournament_id: @team.id),
           params: { tournament_entry: { name: "Majestic Red", member_user_ids: [@member.id] } }
    end

    mirrored = side.tournament_entries.sole
    assert_equal "Majestic Red", mirrored.name
    assert_equal [@member], mirrored.users
  end

  test "removing a team entry removes it from the linked tournament" do
    group = SecureRandom.uuid
    @team.update!(link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, name: "Side",
                  starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, link_group_id: group)
    post organizers_tournament_tournament_entries_path(tournament_id: @team.id),
         params: { tournament_entry: { name: "Majestic Red", member_user_ids: [@member.id] } }
    entry = @team.tournament_entries.sole

    assert_difference "TournamentEntry.count", -2 do
      delete organizers_tournament_tournament_entry_path(tournament_id: @team.id, id: entry.id)
    end
    assert_empty side.tournament_entries.reload
  end

  test "renaming a team entry renames it in the linked tournament" do
    group = SecureRandom.uuid
    @team.update!(link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, name: "Side",
                  starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, link_group_id: group)
    post organizers_tournament_tournament_entries_path(tournament_id: @team.id),
         params: { tournament_entry: { name: "Magestic Red", member_user_ids: [@member.id] } }
    entry = @team.tournament_entries.sole

    patch organizers_tournament_tournament_entry_path(tournament_id: @team.id, id: entry.id),
          params: { tournament_entry: { name: "Majestic Red" } }

    assert_equal "Majestic Red", side.tournament_entries.sole.name
  end

  test "renaming an entry whose sync can't be mirrored redirects with an alert instead of crashing" do
    group = SecureRandom.uuid
    @team.update!(link_group_id: group)
    side = create(:tournament, club: @club, mode: :team, name: "Side",
                  starts_at: 1.hour.from_now, ends_at: 3.hours.from_now, link_group_id: group)
    create(:tournament_judge, tournament: side, user: @teammate)

    entry = create(:tournament_entry, tournament: @team, name: "Old Boat")
    create(:tournament_entry_member, tournament_entry: entry, user: @member)
    create(:tournament_entry_member, tournament_entry: entry, user: @teammate)
    # The Side counterpart is missing @teammate (a state that predates the
    # judge assignment, or just drifted) -- syncing the rename will try to
    # add @teammate to it and trip user_not_a_judge.
    side_counterpart = create(:tournament_entry, tournament: side, name: "Old Boat")
    create(:tournament_entry_member, tournament_entry: side_counterpart, user: @member)

    assert_no_difference "TournamentEntryMember.count" do
      patch organizers_tournament_tournament_entry_path(tournament_id: @team.id, id: entry.id),
            params: { tournament_entry: { name: "New Boat" } }
    end
    assert_redirected_to edit_organizers_tournament_path(@team)
    assert_match(/judging/i, flash[:alert])
    # The alert says the rename failed, so it has to have failed on both sides:
    # committing it locally would leave the pair permanently out of sync, with
    # the new name already broadcast to whoever is watching the leaderboard.
    assert_equal "Old Boat", entry.reload.name
    assert_equal "Old Boat", side_counterpart.reload.name
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  def with_perform_later_capture
    enqueued = []
    klass = DeliverPushNotificationJob
    original = klass.method(:perform_later)
    klass.define_singleton_method(:perform_later) { |**kwargs| enqueued << kwargs }
    yield enqueued
  ensure
    klass.singleton_class.send(:remove_method, :perform_later)
    klass.define_singleton_method(:perform_later, original) if original
  end
end
