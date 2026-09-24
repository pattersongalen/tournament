# Adds a per-catch detail page and length/species edit to the organizers/ and
# admin/ catch controllers. Both surfaces are organizer-gated (see their base
# controllers) and scoped to the current club's members. Edits delegate to
# Catches::ApplyJudgeAction with tournament: nil and club: current_club — the
# manual_override path re-places/rebalances the catch across this club's
# tournaments (the acting organizer's authority is per-club) and writes a
# JudgeAction audit row.
module CatchDetailEditing
  extend ActiveSupport::Concern
  include LengthParamParsing

  included do
    before_action :load_editable_catch, only: [:show, :update]

    # A bad length/species edit (e.g. length below a species floor) surfaces as
    # RecordInvalid out of ApplyJudgeAction; redirect back to the catch with the
    # validation message instead of a raw 500. Mirrors Judges::BaseController.
    rescue_from ActiveRecord::RecordInvalid do |error|
      raise error unless @catch
      redirect_to url_for(action: :show, id: @catch.id),
                  alert: "Couldn't apply that change: #{error.record.errors.full_messages.to_sentence}"
    end
  end

  def show
  end

  def update
    result = Catches::ApplyJudgeAction.call(
      tournament: nil, catch: @catch, judge: current_user, action: :manual_override,
      note: params[:note],
      length_inches: resolved_length_inches(@catch),
      length_unit: resolved_length_unit,
      species_id: params[:species_id].presence&.to_i,
      tag_number: params[:tag_number],
      club: current_club
    )
    redirect_to url_for(action: :show, id: @catch.id), notice: catch_updated_notice(result)
  end

  private

  # A tag added after the draw saves but earns no ticket (the pool closed at
  # the draw); say so rather than let "Catch updated." imply one was issued.
  def catch_updated_notice(result)
    return "Catch updated." unless result[:ticket_withheld]
    "Tag saved. The draw already ran, so no ticket was issued for this catch."
  end

  # Only catches owned by a member of the current club are editable; anything
  # else raises RecordNotFound (→ 404).
  def load_editable_catch
    @catch = Catch.where(user_id: current_club.members.select(:id))
                  .includes(:user, :species, :catch_placements)
                  .find(params[:id])
  end
end
