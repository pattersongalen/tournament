module OrganizerActions
  module MembersRoster
    extend ActiveSupport::Concern

    # Shared by Admin::MembersController and Organizers::MembersController:
    # the club roster (#index) and the Attendance sub page (#attendance).
    # Defining both once keeps the phone and laptop members pages from
    # drifting apart.

    private

    def load_members_roster
      @users = current_club.members.includes(:club_memberships).order(:deactivated_at, :name)
    end

    # Active members with their league-night Main count for the current season
    # (see SeasonPoints::ParticipationCounts), most nights first, ties by name.
    # Members with zero nights stay in the list so it doubles as a "who hasn't
    # fished yet" view; deactivated members are left off. The view re-sorts and
    # filters client-side, but the server order is what a no-JS render and the
    # controller tests see. @rows is nil when the club has no season at all.
    def load_attendance
      @season_tag = SeasonPoints::CurrentSeasonTag.call(club: current_club)
      return if @season_tag.nil?

      counts = SeasonPoints::ParticipationCounts.call(club: current_club, season_tag: @season_tag)
      @rows = current_club.members.active.map { |u| [u, counts.fetch(u.id, 0)] }
      @rows.sort_by! { |user, nights| [-nights, user.name.downcase] }
    end
  end
end
