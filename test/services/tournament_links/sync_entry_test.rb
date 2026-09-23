require "test_helper"

class TournamentLinks::SyncEntryTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    group = SecureRandom.uuid
    @main = create(:tournament, club: @club, mode: :team, name: "Main", link_group_id: group)
    @side = create(:tournament, club: @club, mode: :team, name: "Side", link_group_id: group)
    @kurtis = create(:user, club: @club, name: "Kurtis Sanguin")
    @nate = create(:user, club: @club, name: "Nate Rosengren")
    @boat = create(:boat, club: @club, name: "Majestic Red", captain: @kurtis)
  end

  test "creates the counterpart entry in the linked tournament" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)

    counterparts = TournamentLinks::SyncEntry.call(entry: entry)

    assert_equal 1, counterparts.size
    mirrored = counterparts.first
    assert_equal @side, mirrored.tournament
    assert_equal "Majestic Red", mirrored.name
    assert_equal @boat, mirrored.boat
    assert_equal [@kurtis], mirrored.users
  end

  test "is idempotent - a second call creates nothing new" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)
    TournamentLinks::SyncEntry.call(entry: entry)

    assert_no_difference "TournamentEntry.count" do
      TournamentLinks::SyncEntry.call(entry: entry)
    end
  end

  test "brings a rename across to the counterpart, boat-anchored and boat-less" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)
    TournamentLinks::SyncEntry.call(entry: entry)

    entry.update!(name: "Majestic Red II")
    mirrored = TournamentLinks::SyncEntry.call(entry: entry).first

    assert_equal "Majestic Red II", mirrored.name, "boat-anchored rename"

    # The boat-anchored rename above short-circuits through the boat_id
    # match, so it never exercises the name-history path a boat-less entry
    # has to use. Today's UI has no boat picker yet, so every entry created
    # through the entry controllers is exactly this boat-less shape.
    boatless = create(:tournament_entry, tournament: @main, name: "Team Loos")
    boatless.tournament_entry_members.create!(user: @nate)
    TournamentLinks::SyncEntry.call(entry: boatless)

    boatless.update!(name: "Team Loos II")
    mirrored_boatless = TournamentLinks::SyncEntry.call(entry: boatless).first

    assert_equal "Team Loos II", mirrored_boatless.name, "boat-less rename"
    assert_equal 2, @side.tournament_entries.count
  end

  test "adds and removes crew on the counterpart" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)
    TournamentLinks::SyncEntry.call(entry: entry)

    entry.tournament_entry_members.create!(user: @nate)
    mirrored = TournamentLinks::SyncEntry.call(entry: entry).first
    assert_equal [@kurtis, @nate].sort_by(&:id), mirrored.users.sort_by(&:id)

    entry.tournament_entry_members.find_by(user: @nate).destroy!
    mirrored = TournamentLinks::SyncEntry.call(entry: entry).first
    assert_equal [@kurtis], mirrored.users
  end

  test "matches an existing counterpart by name when there is no boat" do
    entry = create(:tournament_entry, tournament: @main, name: "Team Loos")
    entry.tournament_entry_members.create!(user: @kurtis)
    existing = create(:tournament_entry, tournament: @side, name: "team loos ")

    assert_no_difference "TournamentEntry.count" do
      TournamentLinks::SyncEntry.call(entry: entry)
    end
    assert_equal [@kurtis], existing.reload.users
  end

  test "blanking a boat-less entry's name carries the blank to the counterpart instead of orphaning it, and renaming back finds the same counterpart" do
    entry = create(:tournament_entry, tournament: @main, name: "Team Loos")
    entry.tournament_entry_members.create!(user: @kurtis)
    TournamentLinks::SyncEntry.call(entry: entry)

    entry.update!(name: nil)
    mirrored = TournamentLinks::SyncEntry.call(entry: entry).first

    assert_nil mirrored.name
    assert_equal 1, @side.tournament_entries.count
    assert_equal [@kurtis], mirrored.reload.users

    entry.update!(name: "Team Loos Reborn")
    mirrored = TournamentLinks::SyncEntry.call(entry: entry).first

    assert_equal "Team Loos Reborn", mirrored.name
    assert_equal 1, @side.tournament_entries.count
    assert_equal [@kurtis], mirrored.users
  end

  test "does not adopt a blank-named sibling entry via partial crew overlap" do
    # A crew member can only ever be entered once per tournament, so a member
    # genuinely shared with an unrelated blank-named sibling entry (Nate here)
    # would make going through the full sync a legitimate double-booking
    # conflict, unrelated to matching. Test the matching rule directly:
    # exact-set equality must not treat "shares one member" as a match.
    unrelated = create(:tournament_entry, tournament: @side)
    other_member = create(:user, club: @club, name: "Other Member")
    unrelated.tournament_entry_members.create!(user: @nate)
    unrelated.tournament_entry_members.create!(user: other_member)

    entry = create(:tournament_entry, tournament: @main)
    entry.tournament_entry_members.create!(user: @kurtis)
    entry.tournament_entry_members.create!(user: @nate)

    match = TournamentLinks::Counterpart.find(entry: entry, sibling: @side, allow_crew_match: true)

    assert_nil match, "a single overlapping member must not be enough to adopt someone else's entry"
    assert_equal [@nate, other_member].sort_by(&:id), unrelated.reload.users.sort_by(&:id),
                 "the unrelated entry's members must be untouched since it was never adopted"
  end

  test "does nothing for an unlinked tournament" do
    solo_club_tournament = create(:tournament, club: @club, mode: :team)
    entry = create(:tournament_entry, tournament: solo_club_tournament, name: "Stratos")
    assert_empty TournamentLinks::SyncEntry.call(entry: entry)
  end

  test "does nothing for an entry with no boat and no name" do
    entry = create(:tournament_entry, tournament: @main)
    entry.tournament_entry_members.create!(user: @kurtis)
    assert_empty TournamentLinks::SyncEntry.call(entry: entry)
  end

  test "backfills catches when the sibling allows late entrants, for a newly created counterpart and for crew added to an already-mirrored one" do
    @side.update!(backfill_late_entrants: true)
    walleye = create(:species, name: "Walleye")
    create(:scoring_slot, tournament: @side, species: walleye, slot_count: 2)
    already_logged = create(:catch, user: @kurtis, species: walleye,
                            length_inches: 20, captured_at_device: 30.minutes.ago)

    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)

    mirrored = TournamentLinks::SyncEntry.call(entry: entry).first

    assert CatchPlacement.exists?(
      catch_id: already_logged.id, tournament_id: @side.id,
      tournament_entry_id: mirrored.id, active: true
    ), "Kurtis's already-logged catch should be backfilled into the new counterpart"

    nate_catch = create(:catch, user: @nate, species: walleye,
                        length_inches: 18, captured_at_device: 30.minutes.ago)
    entry.tournament_entry_members.create!(user: @nate)
    mirrored = TournamentLinks::SyncEntry.call(entry: entry).first

    assert CatchPlacement.exists?(
      catch_id: nate_catch.id, tournament_id: @side.id,
      tournament_entry_id: mirrored.id, active: true
    ), "Nate's catch, logged before he joined the Side's mirrored entry, should backfill on sync"
  end

  test "does not clear the counterpart's boat when the source entry has none, but still overwrites it when the source has one" do
    # Side's entry came from the boat picker (boat_id set); Main's entry is a
    # hand-typed same-named entry with no boat of its own. Syncing from the
    # boat-less Main entry must not wipe Side's boat_id — that would let the
    # boat reappear in Side's picker and a second tap create a duplicate
    # entry for it.
    side_entry = create(:tournament_entry, tournament: @side, name: "Majestic Red", boat: @boat)
    side_entry.tournament_entry_members.create!(user: @kurtis)

    main_entry = create(:tournament_entry, tournament: @main, name: "Majestic Red")
    main_entry.tournament_entry_members.create!(user: @kurtis)

    TournamentLinks::SyncEntry.call(entry: main_entry)

    assert_equal @boat.id, side_entry.reload.boat_id, "boat-less source must not clear the counterpart's boat"

    other_boat = create(:boat, club: @club, name: "Other Boat", captain: @nate)
    side_entry.update!(boat: other_boat)
    main_entry.update!(boat: @boat)

    TournamentLinks::SyncEntry.call(entry: main_entry)

    assert_equal @boat.id, side_entry.reload.boat_id, "a boat on the source must still overwrite the counterpart's boat"
  end

  test "enqueues a push for a member newly mirrored onto the sibling entry, and only for the newly added member when crew is added later" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)

    calls = []
    with_class_method_stub(DeliverPushNotificationJob, :perform_later, ->(**kwargs) { calls << kwargs }) do
      TournamentLinks::SyncEntry.call(entry: entry)
    end

    assert_equal 1, calls.size
    assert_equal @kurtis.id, calls.first[:user_id]
    assert_equal @side.id, calls.first[:tournament_id]
    assert_includes calls.first[:body], @side.name
    assert_equal "/tournaments/#{@side.id}", calls.first[:url]

    entry.tournament_entry_members.create!(user: @nate)

    calls = []
    with_class_method_stub(DeliverPushNotificationJob, :perform_later, ->(**kwargs) { calls << kwargs }) do
      TournamentLinks::SyncEntry.call(entry: entry)
    end

    assert_equal 1, calls.size, "only the newly added crew member should be notified, not the whole crew"
    assert_equal @nate.id, calls.first[:user_id]
  end

  # notify: false is the administrative back-fill mode. Repairing a
  # half-scheduled league night mirrors a roster onto a tournament for a night
  # that may already be over, and DeliverPushNotificationJob has no
  # started/ended guard — so the push has to be suppressible. The mirroring
  # itself and the leaderboard broadcast are display/state, not an alert, and
  # must still happen.
  test "notify: false suppresses the push but still mirrors and broadcasts" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)

    calls = []
    broadcasts = nil
    with_class_method_stub(DeliverPushNotificationJob, :perform_later, ->(**kwargs) { calls << kwargs }) do
      broadcasts = with_broadcast_spy { TournamentLinks::SyncEntry.call(entry: entry, notify: false) }
    end

    assert_empty calls
    assert_includes broadcasts, @side.id
    counterpart = @side.tournament_entries.find_by(name: "Majestic Red")
    assert_not_nil counterpart
    assert_equal [@kurtis.id], counterpart.tournament_entry_members.pluck(:user_id)
  end

  test "does not enqueue a push on a rename-only resync or an idempotent no-op resync" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)
    TournamentLinks::SyncEntry.call(entry: entry)

    calls = []
    with_class_method_stub(DeliverPushNotificationJob, :perform_later, ->(**kwargs) { calls << kwargs }) do
      TournamentLinks::SyncEntry.call(entry: entry)
    end
    assert_empty calls, "an idempotent no-op resync must not notify anyone"

    entry.update!(name: "Majestic Red II")

    calls = []
    with_class_method_stub(DeliverPushNotificationJob, :perform_later, ->(**kwargs) { calls << kwargs }) do
      TournamentLinks::SyncEntry.call(entry: entry)
    end
    assert_empty calls, "a rename with no crew change must not re-notify anyone already aboard"
  end

  test "with prune: false, does not remove crew present on the counterpart but missing from the source; prune: true (the default) still removes it" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)

    # Side's counterpart already carries Nate — a crew member Main doesn't
    # have. A prune: false sync (used by Join's back-fill) must leave Nate in
    # place rather than dropping him and his placements.
    side_entry = create(:tournament_entry, tournament: @side, name: "Majestic Red", boat: @boat)
    side_entry.tournament_entry_members.create!(user: @nate)

    TournamentLinks::SyncEntry.call(entry: entry, prune: false)

    assert_equal [@kurtis, @nate].sort_by(&:id), side_entry.reload.users.sort_by(&:id), "prune: false keeps Nate"

    TournamentLinks::SyncEntry.call(entry: entry)

    assert_equal [@kurtis], side_entry.reload.users, "prune: true (default) removes Nate"
  end

  test "broadcasts once per sibling after a successful sync" do
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)

    broadcast_calls = 0
    original = Placements::BroadcastLeaderboard.method(:call)
    Placements::BroadcastLeaderboard.define_singleton_method(:call) do |**kwargs|
      broadcast_calls += 1
      original.call(**kwargs)
    end
    begin
      TournamentLinks::SyncEntry.call(entry: entry)
      assert_equal 1, broadcast_calls, "exactly one sibling (Side) should be broadcast to, exactly once"
    ensure
      Placements::BroadcastLeaderboard.define_singleton_method(:call, original)
    end
  end

  test "rolls back the whole sync and broadcasts nothing when a later sibling raises" do
    third = create(:tournament, club: @club, mode: :team, name: "Third", link_group_id: @main.link_group_id)
    # Nate judges Third (not Side), so mirroring him into a Third counterpart
    # raises TournamentEntryMember's user_not_a_judge validation. Side has no
    # such conflict — if broadcasting happened inside the transaction (the
    # round-1 bug), Side's counterpart would already have gone out over Turbo
    # Streams by the time Third's raise rolls the whole write back.
    create(:tournament_judge, tournament: third, user: @nate)

    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red", boat: @boat)
    entry.tournament_entry_members.create!(user: @kurtis)
    entry.tournament_entry_members.create!(user: @nate)

    # Force a deterministic processing order (Side first, then Third) so this
    # test doesn't depend on the row order of an unordered SQL query.
    side, third_sibling = @side, third
    @main.define_singleton_method(:linked_tournaments) { [side, third_sibling] }

    broadcast_calls = 0
    original = Placements::BroadcastLeaderboard.method(:call)
    Placements::BroadcastLeaderboard.define_singleton_method(:call) do |**kwargs|
      broadcast_calls += 1
      original.call(**kwargs)
    end
    begin
      assert_no_difference [ "TournamentEntry.count", "TournamentEntryMember.count" ] do
        assert_raises(ActiveRecord::RecordInvalid) do
          TournamentLinks::SyncEntry.call(entry: entry)
        end
      end
      assert_equal 0, broadcast_calls, "a rolled-back sync must not have broadcast Side's phantom row"
    ensure
      Placements::BroadcastLeaderboard.define_singleton_method(:call, original)
    end
    assert_empty @side.tournament_entries.reload
    assert_empty third.tournament_entries.reload
  end
end
