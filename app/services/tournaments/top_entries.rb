module Tournaments
  # Ranked, qualified leaderboard rows, capped at `limit`. The limit is the
  # length of the season points ladder — full_field's ladder is as long as the
  # field, so this can't be hard-coded at 3 the way TopThree was.
  class TopEntries
    def self.call(tournament:, limit:)
      rows = ::Leaderboards::Build.call(tournament: tournament)
      ::Leaderboards::QualifiedRows.call(tournament: tournament, rows: rows).first(limit)
    end
  end
end
