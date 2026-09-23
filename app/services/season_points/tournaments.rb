module SeasonPoints
  class Tournaments
    # Finished, points-awarding tournaments of this season, newest first: the
    # standings' input.
    def self.call(club:, season_tag:)
      eligible(club: club, season_tag: season_tag)
        .where("ends_at < ?", ::Time.current)
        .order(ends_at: :desc)
    end

    # The one definition of "a league-night Main this season": a points-awarding
    # tournament of the club carrying the season tag. Callers add their own time
    # predicate (standings count a night once it has ended, the members roster
    # once it has started) so the two can never disagree on WHICH nights count.
    def self.eligible(club:, season_tag:)
      return ::Tournament.none if season_tag.nil?

      club.tournaments.where(awards_season_points: true, season_tag: season_tag)
    end
  end
end
