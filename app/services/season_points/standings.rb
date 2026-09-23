module SeasonPoints
  class Standings
    def self.call(club:, season_tag:)
      return [] if season_tag.nil?

      # `club.tournaments.where(...)` returns an AssociationRelation, which
      # sets the inverse association on every record it loads — so each
      # tournament's `.club` below (called via SeasonPointsAwarded) is
      # already populated and free. That's load-bearing: swapping this for
      # `Tournament.where(club_id: ...)`, adding an `.unscope`, or a `.select`
      # that drops the association would silently turn `tournament.club`
      # into a per-tournament query again — no error, just a slow standings
      # page. The N+1 guard test below is what catches that regression.
      tournaments = club.tournaments
        .where(awards_season_points: true, season_tag: season_tag)
        .where("ends_at < ?", ::Time.current)
        .to_a
      return [] if tournaments.empty?

      tournament_ids = tournaments.map(&:id)

      # Batch-preload everything SeasonPointsAwarded/Leaderboards::Build need,
      # grouped by tournament_id, so the per-tournament loop issues no queries
      # (mirrors Tournaments::WinnersFor). Without this, each tournament ran a
      # full leaderboard build plus an angler-count and member pluck of its own.
      entries_by_tid = ::TournamentEntry
        .where(tournament_id: tournament_ids)
        .includes(:users)
        .group_by(&:tournament_id)

      placements_by_tid = ::CatchPlacement.active
        .where(tournament_id: tournament_ids)
        .includes(catch: [:species, :user, :logged_by_user, { judge_actions: :judge_user }])
        .group_by(&:tournament_id)

      capacity_by_tid = ::ScoringSlot
        .where(tournament_id: tournament_ids)
        .group(:tournament_id)
        .sum(:slot_count)

      member_ids_by_tid = ::TournamentEntryMember
        .joins(:tournament_entry)
        .where(tournament_entries: { tournament_id: tournament_ids })
        .distinct
        .pluck("tournament_entries.tournament_id", :user_id)
        .each_with_object(Hash.new { |h, k| h[k] = [] }) { |(tid, uid), h| h[tid] << uid }

      # Resolve the bingo species ids once (same for every bingo tournament)
      # rather than re-querying them inside each per-tournament build.
      bingo_species_ids = ::Catches::Bingo::EvaluateCard.species_id_map if tournaments.any?(&:format_bingo?)

      totals = Hash.new(0)
      breakdowns = Hash.new { |h, k| h[k] = [] }

      tournaments.each do |t|
        rows = ::Leaderboards::Build.call(
          tournament: t,
          entries: entries_by_tid[t.id] || [],
          placements: placements_by_tid[t.id] || [],
          total_capacity: capacity_by_tid[t.id] || 0,
          bingo_species_ids: bingo_species_ids
        )
        entry_count = (entries_by_tid[t.id] || []).count { |e| e.users.any? }
        # Ask for the scale first: full_field's ladder is as long as the field,
        # so the number of ranked rows to keep isn't a constant 3 any more.
        scale = ::Tournaments::PointsScale.call(club: club, entry_count: entry_count)
        top_entries = if scale
          ::Leaderboards::QualifiedRows.call(tournament: t, rows: rows).first(scale.length)
        else
          []
        end
        awards = ::Tournaments::SeasonPointsAwarded.call(
          tournament: t,
          top_entries: top_entries,
          member_ids: member_ids_by_tid[t.id] || [],
          entry_count: entry_count,
          scale: scale
        )
        awards.each do |user_id, points|
          totals[user_id] += points
          breakdowns[user_id] << { tournament_id: t.id, tournament_name: t.name, points: points }
        end
      end

      users_by_id = ::User.where(id: totals.keys).index_by(&:id)
      rows = totals.map do |user_id, points|
        {
          user: users_by_id[user_id],
          points: points,
          breakdown: breakdowns[user_id]
        }
      end
      rows.sort_by { |r| [-r[:points], r[:user].name.downcase] }
    end
  end
end
