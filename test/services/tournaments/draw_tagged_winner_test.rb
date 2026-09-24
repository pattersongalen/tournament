require "test_helper"

module Tournaments
  class DrawTaggedWinnerTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @club = create(:club)
      @tagged = Species.find_or_create_by!(name: "Tagged Walleye")
      @user = create(:user, club: @club)
      @organizer = create(:user, club: @club, role: :organizer)
      @t = build(:tournament, club: @club, format: :tagged, mode: :solo,
                 starts_at: 2.hours.ago, ends_at: 1.hour.ago)
      @t.scoring_slots.build(species: @tagged, slot_count: 1)
      @t.save!
      @entry = create(:tournament_entry, tournament: @t)
      create(:tournament_entry_member, tournament_entry: @entry, user: @user)
    end

    test "picks one active placement and writes draw columns" do
      placement = Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 90.minutes.ago)
      )[:created].first

      result = Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)

      @t.reload
      assert_equal placement.id, @t.drawn_winning_placement_id
      assert_not_nil @t.drawn_at
      assert_equal @organizer.id, @t.drawn_by_user_id
      assert_equal placement.id, result.id
    end

    test "raises NoEligibleCatchesError when there are no active placements" do
      assert_raises(Tournaments::DrawTaggedWinner::NoEligibleCatchesError) do
        Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      end
    end

    test "raises WrongFormatError if tournament format is not tagged" do
      standard = create(:tournament, club: @club, format: :standard, mode: :solo,
                        starts_at: 2.hours.ago, ends_at: 1.hour.ago)
      assert_raises(Tournaments::DrawTaggedWinner::WrongFormatError) do
        Tournaments::DrawTaggedWinner.call(tournament: standard, drawn_by: @organizer)
      end
    end

    test "raises NotEndedError if tournament has not yet ended" do
      @t.update_columns(starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 30.minutes.ago)
      )
      assert_raises(Tournaments::DrawTaggedWinner::NotEndedError) do
        Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      end
    end

    test "refuses a second draw without force" do
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 90.minutes.ago)
      )
      Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      assert_raises(Tournaments::DrawTaggedWinner::AlreadyDrawnError) do
        Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      end
    end

    test "force: true overwrites a previous draw" do
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 90.minutes.ago)
      )
      first = Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      first_drawn_at = @t.reload.drawn_at

      travel 1.second do
        second = Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer, force: true)
        @t.reload
        assert_not_equal first_drawn_at, @t.drawn_at
        assert_kind_of CatchPlacement, second
      end
    end

    test "stamps every active ticket as the drawn pool and leaves retired rows out" do
      live = Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 90.minutes.ago)
      )[:created].first
      retired = Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 17.0,
                      tag_number: "A002", captured_at_device: 80.minutes.ago)
      )[:created].first
      CatchPlacement.where(id: retired.id).deactivate_all

      Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)

      assert live.reload.in_draw_pool, "an active ticket is in the pool the draw ran over"
      assert_not retired.reload.in_draw_pool, "a ticket pulled before the draw was never in the pool"
    end

    test "draws from Tournament#draw_pool, the scope the re-draw button reads" do
      ticket = Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 90.minutes.ago)
      )[:created].first
      assert_equal [ticket.id], @t.draw_pool.pluck(:id)
      assert @t.tickets_remain?

      CatchPlacement.where(id: ticket.id).deactivate_all
      assert_empty @t.draw_pool
      assert_not @t.tickets_remain?, "the views offer no re-draw the service would refuse"
      assert_raises(DrawTaggedWinner::NoEligibleCatchesError) do
        DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      end
    end

    test "serializes on the tournament's entries, the lock every ticket writer holds" do
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 90.minutes.ago)
      )
      locks = []
      probe = ->(_name, _start, _finish, _id, payload) do
        sql = payload[:sql].to_s
        locks << sql if sql.include?("FOR UPDATE")
      end
      ActiveSupport::Notifications.subscribed(probe, "sql.active_record") do
        Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      end

      entries_lock    = locks.index { |sql| sql.include?('"tournament_entries"') }
      tournament_lock = locks.index { |sql| sql.include?('FROM "tournaments"') }
      assert entries_lock,
             "the draw must take the entry locks PlaceInSlots and the judge flows take before writing a ticket"
      assert tournament_lock,
             "the draw must also lock the tournament row: a ticket for an entry created after the entry pass " \
             "(a late entrant) reads drawn_at under that row's key-share lock, and only this lock makes it wait"
      assert tournament_lock > entries_lock,
             "entries first, then the tournament row: the order every writer uses, so nothing inverts"
    end

    test "a forced re-draw re-stamps the pool from the tickets active now" do
      first = Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 90.minutes.ago)
      )[:created].first
      second = Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 17.0,
                      tag_number: "A002", captured_at_device: 80.minutes.ago)
      )[:created].first
      Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      assert first.reload.in_draw_pool && second.reload.in_draw_pool

      # The first fish is pulled after the draw; the re-draw runs over what is left.
      CatchPlacement.where(id: first.id).deactivate_all
      Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer, force: true)

      assert_not first.reload.in_draw_pool, "a ticket pulled before the re-draw is out of the new pool"
      assert second.reload.in_draw_pool
      assert_equal second.id, @t.reload.drawn_winning_placement_id
    end

    test "enqueues a push notification to the winner" do
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: @user, species: @tagged, length_inches: 18.0,
                      tag_number: "A001", captured_at_device: 90.minutes.ago)
      )
      assert_enqueued_with(job: DeliverPushNotificationJob) do
        Tournaments::DrawTaggedWinner.call(tournament: @t, drawn_by: @organizer)
      end
    end
  end
end
