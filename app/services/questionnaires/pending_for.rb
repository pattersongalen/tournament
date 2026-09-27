module Questionnaires
  # The questionnaires a member should be prompted for on the home page.
  # One query narrows to the member's own entries in recent season-points
  # tournaments that are unanswered and undismissed; leaderboards are built
  # only for those, to check the boat is currently in the top three.
  class PendingFor
    WINDOW = 14.days

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
        hit = eligible_for(entry.tournament).find { |e| e[:entry].id == entry.id }
        { tournament: entry.tournament, entry: entry, place: hit[:place] } if hit
      end
    end

    # This runs on the home page, which holds the Log Catch button. A
    # leaderboard that fails to build costs the member a card, never the page.
    def self.eligible_for(tournament)
      EligibleEntries.call(tournament: tournament)
    rescue StandardError => e
      ::Rails.logger.error("questionnaire eligibility failed for tournament #{tournament.id}: #{e.class}: #{e.message}")
      []
    end
    private_class_method :eligible_for

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
