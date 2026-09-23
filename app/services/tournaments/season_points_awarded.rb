module Tournaments
  class SeasonPointsAwarded
    # `top_entries`, `member_ids`, and `entry_count` can be injected by batch
    # callers (e.g. SeasonPoints::Standings) that already preloaded them, so
    # this service doesn't re-query per tournament. Left nil, each is computed
    # on demand.
    #
    # Field size is the ENTRY count — boats/teams, not anglers — for both the
    # tier bands and the full-field ladder. Only entries with at least one
    # member count: an entry created before anyone was added, or one whose
    # last member was removed, is not a competing team and must not lift a
    # 2-team night over the club's minimum.
    #
    # The ladder is sized from the entry count but handed only to entries that
    # actually scored (QualifiedRows drops blanked entries), so under
    # full_field an 8-boat night with 5 scoring boats pays 8/7/6/5/4 and
    # leaves the bottom three rungs unclaimed.
    #
    # `scale:` can be injected too (Standings already asked PointsScale for it
    # to size `top_entries`), so the ladder isn't derived twice per tournament.
    # nil is a real answer ("too few entries"), so the default is a sentinel.
    def self.call(tournament:, top_entries: nil, member_ids: nil, entry_count: nil, scale: :compute)
      return {} unless tournament.awards_season_points?
      return {} unless tournament.ended?

      club = tournament.club
      member_ids ||= member_ids_for(tournament)
      entry_count ||= tournament.tournament_entries.joins(:tournament_entry_members).distinct.count
      scale = ::Tournaments::PointsScale.call(club: club, entry_count: entry_count) if scale == :compute

      awards = {}
      if scale
        placers = top_entries ||
                  ::Tournaments::TopEntries.call(tournament: tournament, limit: scale.length)
        placers.each_with_index do |row, idx|
          points = scale[idx]
          next unless points
          row[:entry].users.each { |u| awards[u.id] = (awards[u.id] || 0) + points }
        end
      end

      member_ids.each { |uid| awards[uid] = (awards[uid] || 0) + club.season_points_attendance }

      awards
    end

    def self.member_ids_for(tournament)
      ::TournamentEntryMember
        .joins(:tournament_entry)
        .where(tournament_entries: { tournament_id: tournament.id })
        .distinct
        .pluck(:user_id)
    end
    private_class_method :member_ids_for
  end
end
