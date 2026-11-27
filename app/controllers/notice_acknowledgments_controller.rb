# Records that a member acknowledged a notice today. Posted by the blocking
# popup (shared/_notice_popup). A member can only acknowledge a notice that
# was sent to them, in their current club, on a day it is active.
class NoticeAcknowledgmentsController < ApplicationController
  before_action :require_sign_in!

  # A popup can outlive its notice: the notice ended, was deleted, or was
  # un-sent while the popup sat open. Still a 404, but the Turbo Stream body
  # clears the stale popup (or shows the next due notice) so the member is
  # not dropped on an error page for pressing the only button they had.
  rescue_from ActiveRecord::RecordNotFound do
    raise unless request.format.turbo_stream?
    @next_notice = Notices::DueFor.call(user: current_user, club: current_club).first
    render :create, status: :not_found
  end

  def create
    club_notice = acknowledgeable_notices.find(params[:notice_id])

    # create_or_find_by!: a double tap lands on the unique index. It runs the
    # insert in its own savepoint, so the second tap finds the first tap's row
    # instead of raising.
    ClubNoticeAcknowledgment.create_or_find_by!(
      club_notice: club_notice, user: current_user, acknowledged_on: Date.current
    )

    respond_to do |format|
      format.turbo_stream do
        @next_notice = Notices::DueFor.call(user: current_user, club: current_club).first
      end
      format.html { redirect_back fallback_location: root_path }
    end
  end

  private

  def acknowledgeable_notices
    return ClubNotice.none unless current_club

    ClubNotice.where(club_id: current_club.id)
              .active_on(Date.current)
              .where(id: ClubNoticeRecipient.where(user_id: current_user.id).select(:club_notice_id))
  end
end
