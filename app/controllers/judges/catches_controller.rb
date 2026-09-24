class Judges::CatchesController < Judges::BaseController
  include CatchUpdateNotice

  REVIEWER_ACTIONS = %i[index show geofence_override correct_location reinstate].freeze

  skip_before_action :require_judge!, only: REVIEWER_ACTIONS
  before_action :require_reviewer!, only: REVIEWER_ACTIONS
  before_action :load_catch!, only: %i[show geofence_override correct_location reinstate]
  before_action :require_site_admin!, only: %i[correct_location]

  def index
    @catches = judgeable_catches
      .joins(:user)
      .order(Arel.sql("CASE WHEN catches.status = #{Catch.statuses[:needs_review]} THEN 0 ELSE 1 END"), captured_at_device: :desc)
  end

  def show
    @actions = @catch.judge_actions.order(:created_at)
  end

  def geofence_override
    result = Catches::ApplyJudgeAction.call(
      tournament: @tournament, catch: @catch, judge: current_user,
      action: :geofence_override, note: params[:note],
      override_in_lake: params[:override_in_lake] == "1",
      override_in_sask: params[:override_in_sask] == "1"
    )
    redirect_to_catch(notice: ticket_withheld_notice(result))
  end

  def correct_location
    result = Catches::ApplyJudgeAction.call(
      tournament: @tournament, catch: @catch, judge: current_user,
      action: :correct_location, note: params[:note],
      latitude: params[:latitude], longitude: params[:longitude]
    )
    redirect_to_catch(notice: ticket_withheld_notice(result))
  end

  def reinstate
    unless @catch.disqualified?
      return redirect_to_catch(alert: "Only a disqualified catch can be reinstated.")
    end
    result = Catches::ApplyJudgeAction.call(
      tournament: @tournament, catch: @catch, judge: current_user, action: :reinstate, note: params[:note]
    )
    redirect_to_catch(notice: ticket_withheld_notice(result))
  end

  private

  def redirect_to_catch(alert: nil, notice: nil)
    redirect_to judges_tournament_catch_path(tournament_id: @tournament.id, id: @catch.id), alert: alert, notice: notice
  end
end
