module Tournaments
  # Replays already-logged catches for late-entered users into `tournament`.
  #
  # Entry adds are forward-only by default (see the tournament-entry
  # controllers): a catch logged inside the tournament window before the
  # angler was entered never places. When the tournament's admin-only
  # `backfill_late_entrants` flag is set, this service lifts that restriction:
  # it re-runs PlaceInSlots over the targeted users' in-window catches in
  # original capture order, so baskets end up exactly as if the angler had
  # been entered from the start (capture order matters for the order-sensitive
  # formats — Fish Train, Biggest vs Smallest). PlaceInSlots stays the
  # authority on eligibility (window, DQ, geofence, judge exclusion,
  # already-placed); the query below is only a pre-filter. Fish Train gets one
  # more pre-filter beyond that (see reject_stale_fish_train_rejects below): it
  # is the one non-monotone format, so a live-rejected catch with no placement
  # row must not be re-offered against the train's final state.
  #
  # Pushes are deliberately suppressed (broadcast: false): replaying a night
  # of catches must not spray stale bumped/took-the-lead notifications. The
  # leaderboard is rebroadcast once at the end instead.
  #
  # users: nil sweeps every current entrant (the admin toggle-on path);
  # an array of User records targets just those (the add-time paths).
  # Returns the number of catches that changed this tournament.
  class BackfillEntrantCatches
    def self.call(tournament:, users: nil)
      user_ids =
        if users
          users.map(&:id)
        else
          ::TournamentEntryMember
            .joins(:tournament_entry)
            .where(tournament_entries: { tournament_id: tournament.id })
            .distinct.pluck(:user_id)
        end
      return 0 if user_ids.empty?

      already_placed = ::CatchPlacement
        .where(tournament_id: tournament.id, active: true)
        .select(:catch_id)

      candidates = ::Catch
        .where(user_id: user_ids)
        .where.not(status: :disqualified)
        .where.not(id: already_placed)
        .where(captured_at_device: tournament.starts_at..tournament.ends_at)
        .order(:captured_at_device, :id)
        .to_a

      candidates = reject_stale_fish_train_rejects(tournament, candidates) if tournament.format_fish_train?

      placed = 0
      candidates.each do |catch_record|
        result = ::Catches::PlaceInSlots.call(
          catch: catch_record, broadcast: false, tournaments: [tournament]
        )
        placed += 1 if result[:affected_tournaments].any?
      end

      # Deferred to the outermost commit: SyncEntry backfills a sibling from
      # inside its transaction, so firing here would broadcast placements a
      # later sibling's raise can still roll back. Runs immediately when
      # there is no outer transaction.
      if placed.positive?
        ::ActiveRecord.after_all_transactions_commit do
          ::Placements::BroadcastLeaderboard.call(tournament: tournament)
        end
      end
      placed
    end

    # Fish Train is the one non-monotone format (see place_in_slots.rb): a catch
    # a live submission rejected (e.g. it was the NEXT group's species, offered
    # too early) leaves no placement row, so the plain candidate query above
    # can't tell "live-rejected" apart from "never seen." Re-offering it here
    # would evaluate it against the train's FINAL state rather than the state it
    # actually faced, letting it wrongly place and advance the train with a car
    # never legitimately earned.
    #
    # Fix: for an entry with active placements in this tournament, only replay
    # candidates strictly after (captured_at_device, id) of that entry's newest
    # active placement — the same ordering live placement uses. Everything up to
    # and including that catch was already live-evaluated against exactly the
    # train state it faced (the placed ones are excluded upstream as
    # already-placed; the rejected ones re-reject identically), so only the tail
    # is safe to replay. An entry with no active placements has no cutoff — a
    # late entrant's full history replays faithfully in capture order.
    def self.reject_stale_fish_train_rejects(tournament, candidates)
      cutoffs = ::CatchPlacement
        .where(tournament_id: tournament.id, active: true)
        .includes(:catch)
        .group_by(&:tournament_entry_id)
        .transform_values { |placements| placements.max_by { |p| [p.catch.captured_at_device, p.catch.id] } }
      return candidates if cutoffs.empty?

      entry_id_by_user_id = ::TournamentEntryMember
        .joins(:tournament_entry)
        .where(tournament_entries: { tournament_id: tournament.id })
        .pluck(:user_id, :tournament_entry_id).to_h

      candidates.reject do |catch_record|
        cutoff = cutoffs[entry_id_by_user_id[catch_record.user_id]]
        next false unless cutoff

        candidate_key = [catch_record.captured_at_device, catch_record.id]
        cutoff_key = [cutoff.catch.captured_at_device, cutoff.catch.id]
        (candidate_key <=> cutoff_key) <= 0
      end
    end
    private_class_method :reject_stale_fish_train_rejects
  end
end
