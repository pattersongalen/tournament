module Questionnaires
  # The boats a tournament asks "what worked": its current top three, worked
  # out from the standings every time rather than stored, so a
  # disqualification or a late sync after the end changes who is asked.
  class EligibleEntries
    LIMIT = 3

    def self.call(tournament:, rows: nil)
      return [] unless asks?(tournament)

      rows ||= ::Leaderboards::Build.call(tournament: tournament)
      # Some formats rank one row per FISH (big fish season; hidden length
      # until its roll). A boat places once, by its best row.
      ::Leaderboards::QualifiedRows.call(tournament: tournament, rows: rows)
                                   .uniq { |row| row[:entry].id }
                                   .first(LIMIT)
                                   .each_with_index
                                   .map { |row, index| { entry: row[:entry], place: index + 1 } }
    end

    # Season-points tournaments only, once ended, and only those that ended
    # after the club started asking (so nothing from before the feature
    # shipped). A club with every question retired asks nobody.
    def self.asks?(tournament)
      return false unless tournament.awards_season_points? && tournament.ended?
      # Hidden length has no standings until the ended job rolls the target.
      return false if tournament.format_hidden_length? && tournament.hidden_length_target.nil?

      start = tournament.club.questionnaires_start_at
      return false if start.nil? || tournament.ends_at <= start

      tournament.club.questions.active.exists?
    end
  end
end
