# Site-admin management of a club's acknowledgment notices (see ClubNotice).
# The site-admin gate and @foreign_club come from Admin::Clubs::BaseController.
class Admin::Clubs::NoticesController < Admin::Clubs::BaseController
  before_action :set_notice, only: [:show, :edit, :update, :destroy]

  def index
    @notices = @foreign_club.notices.order(starts_on: :desc, id: :desc).to_a
    ids = @notices.map(&:id)
    # Both sides count active members only: a deactivated recipient is never
    # shown the popup (Notices::DueFor), so "N of M" could never fill up.
    @recipient_counts = ClubNoticeRecipient.where(club_notice_id: ids)
                                           .joins(:user).merge(User.active)
                                           .group(:club_notice_id).count
    # Counts only acknowledgments from members who are still recipients, so
    # "N of M" can never read higher than M.
    @acknowledged_today_counts = ClubNoticeAcknowledgment
      .where(club_notice_id: ids, acknowledged_on: Date.current)
      .joins("INNER JOIN club_notice_recipients r " \
             "ON r.club_notice_id = club_notice_acknowledgments.club_notice_id " \
             "AND r.user_id = club_notice_acknowledgments.user_id")
      .joins(:user).merge(User.active)
      .group("club_notice_acknowledgments.club_notice_id")
      .count
  end

  def show
    @acknowledgments_by_user_id = @notice.acknowledgments.order(:acknowledged_on).group_by(&:user_id)
    @recipient_users = @notice.recipient_users.order(:name).to_a
    former_ids = @acknowledgments_by_user_id.keys - @recipient_users.map(&:id)
    @former_users = User.where(id: former_ids).order(:name).to_a
  end

  def new
    @notice = @foreign_club.notices.new(starts_on: Date.current, ends_on: Date.current + 6)
    prepare_form(selected: [])
  end

  def edit
    prepare_form(selected: @notice.recipients.pluck(:user_id))
  end

  def create
    @notice = @foreign_club.notices.new(notice_params.merge(created_by_user: current_user))
    if save_with_recipients
      redirect_to admin_club_notice_path(@foreign_club, @notice), notice: "Notice created."
    else
      prepare_form(selected: submitted_member_ids)
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @notice.assign_attributes(notice_params)
    if save_with_recipients
      redirect_to admin_club_notice_path(@foreign_club, @notice), notice: "Notice updated."
    else
      prepare_form(selected: submitted_member_ids)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @notice.destroy!
    redirect_to admin_club_notices_path(@foreign_club), notice: "Notice deleted."
  end

  private

  def set_notice
    @notice = @foreign_club.notices.find(params[:id])
  end

  def notice_params
    params.require(:club_notice).permit(:title, :message, :starts_on, :ends_on)
  end

  def selectable_memberships
    @selectable_memberships ||=
      @foreign_club.club_memberships.with_active_user.includes(:user).order("users.name").to_a
  end

  def submitted_member_ids
    Array(params[:member_ids]).map(&:to_i)
  end

  def prepare_form(selected:)
    @memberships = selectable_memberships
    @selected_user_ids = selected.to_set
  end

  # The notice and its recipient list save together or not at all.
  def save_with_recipients
    ClubNotice.transaction do
      @notice.save!
      sync_recipients
    end
    true
  rescue ActiveRecord::RecordInvalid
    false
  end

  # Only ids the form could have offered (this club's active members) count;
  # anything else in member_ids is dropped. Removal is limited to the same
  # ids: a recipient the form could not offer (deactivated today) has no
  # checkbox to leave ticked, so they stay and are due again if reactivated.
  # Acknowledgments are not touched, so a removed recipient keeps their history.
  def sync_recipients
    offered = selectable_memberships.map(&:user_id)
    wanted = offered & submitted_member_ids
    @notice.recipients.where(user_id: offered - wanted).delete_all
    existing = @notice.recipients.pluck(:user_id)
    (wanted - existing).each { |user_id| @notice.recipients.create!(user_id: user_id) }
  end
end
