class Judges::ManualOverridesController < Judges::BaseController
  include LengthParamParsing

  before_action :load_catch!

  def new
  end

  def create
    Catches::ApplyJudgeAction.call(
      tournament: @tournament, catch: @catch, judge: current_user, action: :manual_override,
      note: params[:note],
      length_inches: resolved_length_inches(@catch),
      length_unit: resolved_length_unit,
      species_id: params[:species_id].presence&.to_i,
      tag_number: params[:tag_number],
      slot_index: params[:slot_index].presence&.to_i,
      entry_id: params[:entry_id].presence&.to_i,
      # A judge is assigned to a specific tournament; confine reconcile and
      # broadcast to that tournament's club so a correction never reshuffles or
      # re-broadcasts another club's leaderboards (matches the organizer editor).
      club: @tournament.club
    )
    redirect_to judges_tournament_catch_path(tournament_id: @tournament.id, id: @catch.id)
  rescue Catches::ApplyJudgeAction::ForceSlotUnsupported
    redirect_to judges_tournament_catch_path(tournament_id: @tournament.id, id: @catch.id),
                alert: "Forcing a catch into a slot isn't supported for this tournament format."
  end
end
