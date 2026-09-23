class Organizers::BaseController < ApplicationController
  before_action :require_sign_in!
  before_action :require_organizer!

  private

  # Hooks used by the OrganizerActions::* concerns shared with /admin.
  # Named by where they point, not by namespace, so one concern body can serve
  # both the laptop (/admin) and mobile (/organizers) sides.
  def boats_index_path = organizers_boats_path
  def tournaments_index_path = organizers_tournaments_path
  def templates_index_path = organizers_tournament_templates_path
  def tournament_edit_path(tournament) = edit_organizers_tournament_path(tournament)

  def require_organizer!
    head :forbidden unless current_user&.organizer_in?(current_club)
  end
end
