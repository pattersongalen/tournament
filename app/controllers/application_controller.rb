class ApplicationController < ActionController::Base
  include Authentication
  allow_browser versions: :modern

  before_action :touch_last_seen
  helper_method :tournament_leaderboard_visible?, :judged_tournament_ids, :due_notice

  # Shared club laptop: after sign-out, Back must not replay member emails /
  # live sign-in codes from Turbo's snapshot cache (restoration visits never
  # hit the server). Controllers showing that data call this; both layouts
  # honor the flag (shared/turbo_snapshot_cache_meta). Scoped opt-in rather
  # than app-wide so normal member pages keep instant back-nav.
  def self.disable_turbo_snapshot_cache!
    before_action { @disable_turbo_snapshot_cache = true }
  end

  # The daily notice popup (shared/_notice_popup) must never interrupt someone
  # with a fish on the bump board. Controllers on the Log Catch path call this
  # to keep their pages clear of it; both layouts honor the flag via due_notice.
  def self.skip_notice_popup!(**options)
    before_action(**options) { @skip_notice_popup = true }
  end

  private

  # The first notice this member still has to acknowledge today, or nil.
  # Memoized: the layout asks once per request.
  def due_notice
    return nil if @skip_notice_popup
    return @due_notice if defined?(@due_notice)
    @due_notice = Notices::DueFor.call(user: current_user, club: current_club).first
  end

  def tournament_leaderboard_visible?(tournament)
    return false unless current_user && tournament
    return true unless tournament.entrants_only_leaderboard?
    # The entrants-only restriction only applies while the tournament is
    # running; once it ends the leaderboard opens to every signed-in member.
    return true if tournament.ended?
    return true if current_user.admin?
    return true if organizer_club_ids.include?(tournament.club_id)
    return true if judged_tournament_ids.include?(tournament.id)
    entered_tournament_ids.include?(tournament.id)
  end

  # The three helpers below are request-memoized so rendering a list of
  # tournaments (home, index, archived, season points) costs at most one
  # query each instead of three per row. They are only built when an
  # entrants-only tournament is actually encountered, so a page with none
  # still issues zero extra queries.
  def organizer_club_ids
    @organizer_club_ids ||=
      current_user.club_memberships.active.where(role: :organizer).pluck(:club_id).to_set
  end

  def judged_tournament_ids
    @judged_tournament_ids ||=
      TournamentJudge.where(user_id: current_user.id).pluck(:tournament_id).to_set
  end

  def entered_tournament_ids
    @entered_tournament_ids ||=
      TournamentEntryMember.joins(:tournament_entry)
        .where(user_id: current_user.id)
        .pluck("tournament_entries.tournament_id").to_set
  end

  def touch_last_seen
    Diagnostics::RecordVisit.call(
      user:       current_user,
      user_agent: request.user_agent,
      app_build:  cookies[:app_build]
    )
  end
end
