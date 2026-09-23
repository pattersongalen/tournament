module SeasonPoints
  # How many league-night Mains each member has fished this season, keyed by
  # user id. "Main" is the same rule season standings use — a tournament that
  # awards season points — so it needs no name matching and survives renames.
  # A tournament counts once it has started (tonight's night counts as soon as
  # it kicks off), and a member in two entries of one night is still one night.
  class ParticipationCounts
    def self.call(club:, season_tag:, now: ::Time.current)
      return {} if season_tag.nil?

      ::TournamentEntryMember
        .joins(tournament_entry: :tournament)
        .where(tournaments: { club_id: club.id, awards_season_points: true, season_tag: season_tag })
        .where("tournaments.starts_at <= ?", now)
        .group(:user_id)
        .distinct
        .count("tournament_entries.tournament_id")
    end
  end
end
