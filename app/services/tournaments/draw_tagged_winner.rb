module Tournaments
  class DrawTaggedWinner
    # All draw failures inherit from PreconditionError so the controller can
    # rescue exactly the right things and a future bug (typo'd kwarg, etc.)
    # won't be silently shown to organizers as a flash message.
    class PreconditionError      < StandardError; end
    class WrongFormatError       < PreconditionError; end
    class NotEndedError          < PreconditionError; end
    class AlreadyDrawnError      < PreconditionError; end
    class NoEligibleCatchesError < PreconditionError; end

    def self.call(tournament:, drawn_by:, force: false)
      new(tournament: tournament, drawn_by: drawn_by, force: force).call
    end

    def initialize(tournament:, drawn_by:, force:)
      @tournament = tournament
      @drawn_by = drawn_by
      @force = force
    end

    def call
      # Format and end time are checked before any lock is taken: the entry
      # locks below stall every live PlaceInSlots on this tournament, and a
      # mis-tap on a running or non-tagged tournament would queue those
      # placements behind a lock the raise only rolls back. The format is
      # locked once the tournament starts, so that read is final; the end
      # time can still be pushed out by an edit, so it is read again under
      # the lock below.
      raise WrongFormatError, "tournament format is not 'tagged'" unless @tournament.format_tagged?
      raise NotEndedError,    "tournament has not yet ended"      unless @tournament.ended?

      winning_placement = ActiveRecord::Base.transaction do
        # Serialize on the tournament's entries first, then the tournament
        # row. Every writer of a ticket (PlaceInSlots, the judge flows) holds
        # the entry lock before it inserts or retires a row, so once these are
        # held no ticket on an existing entry can appear or vanish between the
        # snapshot and the stamp below, and a concurrent placement that had to
        # wait for an entry sees this draw when it gets it. An entry created
        # after this pass (a late entrant added while the draw runs) is not
        # held, so PlaceInSlots also reads drawn_at under a key-share lock on
        # the tournament row: the FOR UPDATE taken here conflicts with it,
        # making that ticket wait for the draw and see it. Ascending entry
        # id, then the tournament: the order every writer uses (lock_entries!,
        # then the row-level reads and the winner repoint), so nothing
        # inverts. lock! reloads, so a draw that committed while we waited is
        # seen and a second tap can't draw twice.
        @tournament.tournament_entries.order(:id).lock.pluck(:id)
        @tournament.lock!
        raise NotEndedError,     "tournament has not yet ended" unless @tournament.ended?
        raise AlreadyDrawnError, "already drawn (pass force: true to redraw)" if @tournament.drawn_at.present? && !@force

        eligible = @tournament.draw_pool.includes(catch: :user).to_a
        raise NoEligibleCatchesError, "no tagged catches to draw from" if eligible.empty?

        # SecureRandom (CSPRNG) rather than Array#sample (MT19937) so the draw
        # outcome can't be predicted by anyone who's seen previous Ruby PRNG output.
        winner = eligible[SecureRandom.random_number(eligible.size)]
        # Record the pool as a fact on the rows drawn from. PlaceInSlots reads
        # it to decide whether a post-draw re-placement re-issues a ticket
        # (the fish was in the draw) or earns none (it was not). A forced
        # re-draw runs over the tickets active NOW and stamps them too, but a
        # row an earlier draw stamped keeps its stamp when retired: the stamp
        # means "a draw drew from this fish", not "the latest draw did". A
        # fish DQ'd after the first draw and reinstated after the re-draw
        # would otherwise hold no stamped row, and no re-draw, reinstate or
        # backfill could ever mint it a ticket again (the pool only re-draws
        # over live rows). Re-issued instead, it lands back on the
        # leaderboard for the organizer to re-draw over. Under the locks
        # above the active set IS `eligible`, so one statement over the
        # unstamped live rows keeps the lock-held write short.
        @tournament.catch_placements.active.where(in_draw_pool: false).update_all(in_draw_pool: true)
        @tournament.update!(
          drawn_winning_placement_id: winner.id,
          drawn_at: Time.current,
          drawn_by_user_id: @drawn_by.id
        )
        winner
      end

      # After commit: rebroadcast + notify winner. Outside the transaction so
      # other DB connections see the winner state.
      Placements::BroadcastLeaderboard.call(tournament: @tournament)
      DeliverPushNotificationJob.perform_later(
        user_id: winning_placement.catch.user_id,
        title: "You won the Tagged Walleye draw!",
        body: "Tag #{winning_placement.catch.tag_number} drawn from #{@tournament.name}.",
        url: Rails.application.routes.url_helpers.tournament_path(@tournament),
        tournament_id: @tournament.id
      )

      winning_placement
    end
  end
end
