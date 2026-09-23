module OrganizerActions
  module TournamentLinks
    extend ActiveSupport::Concern

    # Shared by Admin::TournamentLinksController and
    # Organizers::TournamentLinksController — the two namespaces differ only in
    # layout and in which path helpers their redirects use (the *_path hooks
    # on each BaseController).

    included do
      before_action :load_tournament
    end

    def create
      other = current_club.tournaments.find_by(id: params[:linked_tournament_id])
      if other.nil?
        redirect_to tournament_edit_path(@tournament), alert: "Pick a tournament to link with." and return
      end
      unless @tournament.mode_team? && other.mode_team?
        redirect_to tournament_edit_path(@tournament), alert: "Only team tournaments can be linked." and return
      end

      ::TournamentLinks::Join.call(tournament: @tournament, other: other)
      redirect_to tournament_edit_path(@tournament),
                  notice: "Linked with #{other.name}. Entries are now shared."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to tournament_edit_path(@tournament), alert: e.message
    end

    def destroy
      ::TournamentLinks::Leave.call(tournament: @tournament)
      redirect_to tournament_edit_path(@tournament), notice: "Unlinked."
    end

    private

    def load_tournament
      @tournament = current_club.tournaments.find(params[:id])
    end
  end
end
