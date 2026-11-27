module Questionnaires
  # The questionnaires a member should be prompted for on the home page.
  # One query narrows to the member's own entries in recent season-points
  # tournaments that are unanswered and undismissed; only those have their
  # top three looked up, to check the boat is in it.
  class PendingFor
    WINDOW = 14.days
    CACHE_FOR = 5.minutes

    def self.call(user:, club:, now: Time.current)
      return [] if user.nil? || club.nil? || user.deactivated?

      start = club.questionnaires_start_at
      return [] if start.nil?

      entries = candidates(user, club, start, now)
      return [] if entries.empty?

      entries.filter_map do |entry|
        # Every candidate shares this club; hand it over rather than let each
        # tournament load its own copy.
        entry.tournament.club = club
        place = places_for(entry.tournament)[entry.id]
        { tournament: entry.tournament, entry: entry, place: place } if place
      end
    end

    # { entry id => place } for the tournament's top three, kept for
    # CACHE_FOR. Most members finish outside it and get no card to dismiss, so
    # without this every home page load rebuilds each recent leaderboard. The
    # cost is that a change in the standings takes up to CACHE_FOR to reach
    # the card; the form itself always checks the live standings.
    #
    # This runs on the home page, which holds the Log Catch button. A
    # leaderboard that fails to build costs the member a card, never the
    # page, and the failure is not cached.
    def self.places_for(tournament)
      ::Rails.cache.fetch("questionnaires/top_three/#{tournament.id}", expires_in: CACHE_FOR) do
        EligibleEntries.call(tournament: tournament).to_h { |item| [item[:entry].id, item[:place]] }
      end
    rescue StandardError => e
      ::Rails.logger.error("questionnaire eligibility failed for tournament #{tournament.id}: #{e.class}: #{e.message}")
      {}
    end
    private_class_method :places_for

    def self.candidates(user, club, start, now)
      dismissed = ::EntryQuestionnaireDismissal.where(user_id: user.id).select(:tournament_entry_id)

      ::TournamentEntry
        .joins(:tournament, :tournament_entry_members)
        .where(tournament_entry_members: { user_id: user.id })
        .where(tournaments: { club_id: club.id, awards_season_points: true })
        .where("tournaments.ends_at < ? AND tournaments.ends_at >= ? AND tournaments.ends_at > ?",
               now, now - WINDOW, start)
        .where.not(id: ::EntryQuestionnaire.select(:tournament_entry_id))
        .where.not(id: dismissed)
        .preload(:tournament)
        .order("tournaments.ends_at DESC, tournament_entries.id")
        .to_a
    end
    private_class_method :candidates
  end
end
