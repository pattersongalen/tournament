module SeasonPoints
  # How many league-night Mains each member has fished this season, keyed by
  # user id. "Main" means a tournament that awards season points (the selector
  # shared with the standings via SeasonPoints::Tournaments.eligible), so it
  # needs no name matching and survives renames.
  #
  # Unlike the standings, which only count a night once it has ENDED, a night
  # counts here as soon as it has started: the members page is a roster view
  # ("who is fishing tonight"), so during a league night it reads one higher
  # than the standings page and the 3-entry placement-points minimum. A member
  # in two entries of one night is still one night.
  class ParticipationCounts
    def self.call(club:, season_tag:, now: ::Time.current)
      return {} if season_tag.nil?

      ::TournamentEntryMember
        .joins(tournament_entry: :tournament)
        .merge(::SeasonPoints::Tournaments.eligible(club: club, season_tag: season_tag))
        .where("tournaments.starts_at <= ?", now)
        .group(:user_id)
        .distinct
        .count("tournament_entries.tournament_id")
    end
  end
end
