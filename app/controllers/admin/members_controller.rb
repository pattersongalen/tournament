class Admin::MembersController < Admin::BaseController
  before_action :require_site_admin!, only: [:edit, :update, :destroy, :reactivate, :purge]
  before_action :require_permanent_organizer!, only: [:role]

  def index
    @users = current_club.members.includes(:club_memberships).order(:deactivated_at, :name)
    @season_tag = SeasonPoints::CurrentSeasonTag.call(club: current_club)
    @main_nights = SeasonPoints::ParticipationCounts.call(club: current_club, season_tag: @season_tag)
    # Members with any catch FK (logged by them, or logged *for* them by a
    # teammate) can't be purged — mirror MembersController#purge's guard so the
    # Delete button only shows when the destroy! would actually succeed.
    member_ids = @users.map(&:id)
    @member_ids_with_catches = (
      Catch.where(user_id: member_ids).distinct.pluck(:user_id) +
      Catch.where(logged_by_user_id: member_ids).distinct.pluck(:logged_by_user_id)
    ).to_set
  end

  def new
    @user = User.new
  end

  def edit
    @user = current_club.members.find(params[:id])
  end

  def update
    @user = current_club.members.find(params[:id])
    if @user.update(edit_params)
      redirect_to admin_members_path, notice: "#{@user.name} updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def create
    @user = User.new(user_params.except(:role))
    role_for_membership = user_params[:role].presence || "member"
    saved = false
    begin
      ActiveRecord::Base.transaction do
        @user.save!
        ClubMembership.create!(user: @user, club: current_club, role: role_for_membership)
      end
      saved = true
    rescue ActiveRecord::RecordInvalid
      # AR rolled back the user INSERT. If User#save! is what failed, @user.errors
      # is populated and the form will show them. If it was ClubMembership.create!
      # (e.g. a future model validation we haven't anticipated here), @user.errors
      # is empty — surface a generic message so the form isn't silent.
      @user.errors.add(:base, "Couldn't send the invite. Please try again.") if @user.errors.empty?
    end
    if saved
      token = SignInToken.issue!(user: @user, club: current_club, ttl: 7.days, issued_by: current_user)
      InvitationMailer.welcome(token).deliver_later
      redirect_to admin_members_path, notice: "Invite sent."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    user = current_club.members.find(params[:id])
    if user == current_user
      redirect_to admin_members_path, alert: "You can't deactivate yourself."
    else
      user.update!(deactivated_at: Time.current)
      redirect_to admin_members_path, notice: "#{user.name} deactivated."
    end
  end

  # Flip a member between the `member` and `organizer` roles. Deliberately
  # separate from #update, which is site-admin-only and edits name/email: role
  # changes are open to any permanent organizer of the club, and #update's
  # `edit_params` must NOT be widened to include :role.
  def role
    membership = current_club.club_memberships.active.find_by!(user_id: params[:id])
    new_role   = params.dig(:club_membership, :role)

    unless ClubMembership.roles.key?(new_role)
      return redirect_to admin_members_path, alert: "Unknown role."
    end

    if new_role == "member"
      # This guard is what actually preserves "every club keeps >= 1 organizer":
      # the actor must already be a permanent organizer, so demoting anyone
      # *else* always leaves the actor behind.
      if membership.user_id == current_user.id
        return redirect_to admin_members_path, alert: "You can't demote yourself."
      end

      # Defense-in-depth, unreachable while the gate is permanent-organizer-only.
      # It becomes load-bearing if that gate is ever widened.
      if membership.organizer? && current_club.club_memberships.active.organizer.count <= 1
        return redirect_to admin_members_path, alert: "A club must keep at least one organizer."
      end
    end

    membership.update!(role: new_role)
    label = new_role == "organizer" ? "an organizer" : "a member"
    redirect_to admin_members_path, notice: "#{membership.user.name} is now #{label}."
  rescue ActiveRecord::RecordNotFound
    redirect_to admin_members_path, alert: "That member isn't in this club."
  end

  def reactivate
    user = current_club.members.find(params[:id])
    user.update!(deactivated_at: nil)
    redirect_to admin_members_path, notice: "#{user.name} reactivated."
  end

  def purge
    user = current_club.members.find(params[:id])
    if user == current_user
      redirect_to admin_members_path, alert: "You can't delete yourself."
    elsif !user.deactivated?
      redirect_to admin_members_path, alert: "Deactivate #{user.name} before deleting."
    elsif user.catches.exists? || Catch.where(logged_by_user_id: user.id).exists?
      # Also block when the member logged catches *for* a teammate
      # (logged_by_user_id = them, user_id = someone else): those rows aren't in
      # user.catches but still hold a FK to this user, so destroy! would raise.
      redirect_to admin_members_path, alert: "#{user.name} has catch history and can't be deleted."
    else
      user.destroy!
      redirect_to admin_members_path, notice: "#{user.name} permanently deleted."
    end
  rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::DeleteRestrictionError, ActiveRecord::InvalidForeignKey
    # InvalidForeignKey backstops any remaining DB-level reference (e.g. a
    # sign_in_tokens.issued_by_user_id row from an invite this member sent) so a
    # lingering link redirects with a friendly message instead of 500ing.
    redirect_to admin_members_path, alert: "#{user.name} can't be deleted because of linked records."
  end

  def issue_code
    member = current_club.members.active.find(params[:id])
    token = SignInToken.issue_code!(user: member, club: current_club, issued_by: current_user)
    flash[:code] = token.token
    redirect_to code_admin_member_path(member), status: :see_other
  end

  def code
    @member = current_club.members.find(params[:id])
    @code = flash[:code]
    redirect_to admin_members_path and return unless @code
  end

  private

  def user_params
    params.require(:user).permit(:name, :email, :role)
  end

  def edit_params
    params.require(:user).permit(:name, :email)
  end
end
