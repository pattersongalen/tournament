module OrganizerActions
  module TournamentDeputies
    extend ActiveSupport::Concern

    # Shared by Admin::TournamentDeputiesController and
    # Organizers::TournamentDeputiesController — the two namespaces differ only in
    # layout and in which path helpers their redirects use (the *_path hooks
    # on each BaseController).

    included do
      # Granting a deputy is a privilege-granting action, so it needs a *permanent*
      # organizer. Without this, a deputy could deputize themselves onto a
      # far-future tournament and make the temporary badge permanent.
      before_action :require_permanent_organizer!
      before_action :load_tournament
    end

    def create
      user = current_club.members.active.find(params.dig(:tournament_deputy, :user_id))
      @tournament.tournament_deputies.find_or_create_by(user: user) do |deputy|
        deputy.granted_by_user = current_user
      end
      redirect_to tournament_edit_path(@tournament), notice: "Deputy added."
    rescue ActiveRecord::RecordNotFound
      redirect_to tournament_edit_path(@tournament), alert: "Pick a member first."
    end

    def destroy
      deputy = @tournament.tournament_deputies.find(params[:id])
      deputy.destroy
      redirect_to tournament_edit_path(@tournament), notice: "Deputy removed."
    end

    private

    def load_tournament
      @tournament = current_club.tournaments.find(params[:tournament_id])
    end
  end
end
