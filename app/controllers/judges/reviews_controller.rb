class Judges::ReviewsController < Judges::BaseController
  include CatchUpdateNotice

  before_action :load_catch!

  def create
    result = Catches::ApplyJudgeAction.call(
      tournament: @tournament, catch: @catch, judge: current_user,
      action: params[:action_kind], note: params[:note]
    )
    # nil for an ordinary decision; a DQ of the drawn winner says the draw is void.
    redirect_to judges_tournament_catch_path(tournament_id: @tournament.id, id: @catch.id),
                notice: catch_change_notice(result)
  end
end
