class Admin::BaseController < ApplicationController
  layout "admin"
  before_action :require_sign_in!
  before_action :require_organizer!
  # Everything under /admin shows member data — whole namespace opts out
  # (see ApplicationController.disable_turbo_snapshot_cache!).
  disable_turbo_snapshot_cache!

  private

  # Hooks used by the OrganizerActions::* concerns shared with /organizers.
  # Named by where they point, not by namespace, so one concern body can serve
  # both the laptop (/admin) and mobile (/organizers) sides.
  def boats_index_path = admin_boats_path
  def tournaments_index_path = admin_tournaments_path
  def templates_index_path = admin_tournament_templates_path
  def tournament_edit_path(tournament) = edit_admin_tournament_path(tournament)

  def require_organizer!
    head :forbidden unless current_user&.organizer_in?(current_club)
  end
end
