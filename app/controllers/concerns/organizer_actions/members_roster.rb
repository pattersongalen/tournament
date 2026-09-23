module OrganizerActions
  module MembersRoster
    extend ActiveSupport::Concern

    # Shared by Admin::MembersController#index and
    # Organizers::MembersController#index: the club roster plus the "Main
    # nights" column. "Main nights" is the current season only, counted from
    # kickoff (see SeasonPoints::ParticipationCounts); defining it once keeps
    # the phone and laptop members pages from drifting apart.

    private

    def load_members_roster
      @users = current_club.members.includes(:club_memberships).order(:deactivated_at, :name)
      @season_tag = SeasonPoints::CurrentSeasonTag.call(club: current_club)
      @main_nights = SeasonPoints::ParticipationCounts.call(club: current_club, season_tag: @season_tag)
    end
  end
end
