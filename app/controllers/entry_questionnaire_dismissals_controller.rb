# "Not now" on a home page questionnaire card. Hides the card for the member
# who tapped it; their teammates still see it.
class EntryQuestionnaireDismissalsController < ApplicationController
  before_action :require_sign_in!

  def create
    raise ActiveRecord::RecordNotFound unless current_club

    tournament = current_club.tournaments.find(params[:tournament_id])
    entry = tournament.tournament_entries.find(params[:entry_id])
    raise ActiveRecord::RecordNotFound unless entry.tournament_entry_members.exists?(user_id: current_user.id)

    # create_or_find_by!: a double tap lands on the unique index.
    EntryQuestionnaireDismissal.create_or_find_by!(tournament_entry_id: entry.id, user_id: current_user.id)
    redirect_to root_path
  end
end
