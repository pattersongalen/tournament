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
      winning_placement = ActiveRecord::Base.transaction do
        @tournament.lock!
        raise WrongFormatError, "tournament format is not 'tagged'"                  unless @tournament.format_tagged?
        raise NotEndedError,    "tournament has not yet ended"                       unless @tournament.ended?
        raise AlreadyDrawnError, "already drawn (pass force: true to redraw)" if @tournament.drawn_at.present? && !@force

        eligible = @tournament.catch_placements
                              .where(active: true)
                              .includes(catch: :user)
                              .to_a
        raise NoEligibleCatchesError, "no tagged catches to draw from" if eligible.empty?

        # SecureRandom (CSPRNG) rather than Array#sample (MT19937) so the draw
        # outcome can't be predicted by anyone who's seen previous Ruby PRNG output.
        winner = eligible[SecureRandom.random_number(eligible.size)]
        # Record the pool as a fact on the rows drawn from. PlaceInSlots reads
        # it to decide whether a post-draw re-placement re-issues a ticket
        # (the fish was in the draw) or earns none (it was not). A forced
        # re-draw runs over the tickets active NOW, so the flag means "in the
        # most recent draw": clear it before stamping.
        @tournament.catch_placements.where(in_draw_pool: true).update_all(in_draw_pool: false)
        CatchPlacement.where(id: eligible.map(&:id)).update_all(in_draw_pool: true)
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
