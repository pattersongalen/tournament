module SeasonPoints
  class CurrentSeasonTag
    # The season currently in play: the tag of the most recently STARTED
    # points-eligible tournament. Scheduling next season's first night ahead of
    # time must not flip every standings / roster view to an empty new season
    # while this one is still being fished, so future nights only decide the
    # tag when nothing has started yet (a brand-new club, or the off-season
    # before a first-ever league night).
    def self.call(club:, now: ::Time.current)
      eligible = club.tournaments
        .where(awards_season_points: true)
        .where.not(season_tag: nil)

      eligible.where("starts_at <= ?", now).order(starts_at: :desc).pick(:season_tag) ||
        eligible.order(starts_at: :asc).pick(:season_tag)
    end
  end
end
