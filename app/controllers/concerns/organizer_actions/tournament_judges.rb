module OrganizerActions
  module TournamentJudges
    extend ActiveSupport::Concern

    # Shared by Admin::TournamentJudgesController and
    # Organizers::TournamentJudgesController — the two namespaces differ only in
    # layout and in which path helpers their redirects use (the *_path hooks
    # on each BaseController).

    included do
      before_action :load_tournament
    end

    def create
      user = current_club.members.active.find(params.dig(:tournament_judge, :user_id))
      @tournament.tournament_judges.find_or_create_by(user: user)
      redirect_to tournament_edit_path(@tournament), notice: "Judge added."
    rescue ActiveRecord::RecordNotFound
      redirect_to tournament_edit_path(@tournament), alert: "Pick a member first."
    end

    def destroy
      judge = @tournament.tournament_judges.find(params[:id])
      judge.destroy
      redirect_to tournament_edit_path(@tournament), notice: "Judge removed."
    end

    private

    def load_tournament
      @tournament = current_club.tournaments.find(params[:tournament_id])
    end
  end
end
