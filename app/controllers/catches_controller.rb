class CatchesController < ApplicationController
  include CatchHistoryFiltering
  include CatchUpdateNotice

  before_action :require_sign_in!
  before_action :require_site_admin!, only: :reference_photo

  def index
    @selected_start, @selected_end = resolve_date_range
    @month_start = Catches::ApplyFilters.parse_date(params[:month_nav]) || (@selected_start || Date.current).beginning_of_month
    @month_start = @month_start.beginning_of_month
    @species_filter_id = params[:species].presence&.to_i
    @lake_filter_key   = Geofence::Lakes.normalize_key(params[:lake])
    @sort = params[:sort].presence&.to_sym || :newest
    @month_of_year_active = month_of_year_param

    # :catch_placements is preloaded so visible_flags_for -> can_review_catch?
    # (which walks placements to find tournament_ids) doesn't N+1 for staff
    # viewers when any rendered catch carries the possible_duplicate flag.
    # :judge_actions is preloaded so latest_approver (called per row to decide
    # the status badge) consumes the eager-load instead of re-querying per catch.
    base = current_user.catches.includes(:species, :catch_placements, :judge_actions, photo_attachment: :blob, reference_photo_attachment: :blob)
    filter_params = effective_filter_params
    filtered = Catches::ApplyFilters.call(scope: base, params: filter_params)
    @catches = sort_catches(filtered)
    @counts_by_date = counts_by_date(current_user.catches, @month_start)
    @available_species = Species.order(:name)
  end

  def map
    @selected_start, @selected_end = resolve_date_range
    @month_start = Catches::ApplyFilters.parse_date(params[:month_nav]) || (@selected_start || Date.current).beginning_of_month
    @month_start = @month_start.beginning_of_month
    @species_filter_id = params[:species].presence&.to_i
    @lake_filter_key   = Geofence::Lakes.normalize_key(params[:lake])
    @available_species = Species.order(:name)
    @month_of_year_active = month_of_year_param

    base = current_user.catches.includes(:species, photo_attachment: :blob, reference_photo_attachment: :blob)
    @catches = Catches::ApplyFilters.call(scope: base, params: effective_filter_params).order(captured_at_device: :desc)
    @counts_by_date = counts_by_date(current_user.catches, @month_start)

    @map_points = @catches.filter_map do |c|
      next unless c.latitude && c.longitude
      {
        lat: c.latitude.to_f,
        lng: c.longitude.to_f,
        popup: render_to_string(partial: "catches/map_popup", locals: { catch: c }, formats: [:html])
      }
    end
  end

  def show
    @catch = Catch.where(user_id: current_club.members.select(:id))
                  .find(params[:id])
    head :forbidden and return unless authorized_to_view?(@catch)
    @action_tournament = resolve_action_tournament(@catch)
  end

  # Site admins can add/replace a catch's reference photo from the catch detail
  # page itself — independent of any tournament, so catches that were never
  # placed (more than half of them) can be corrected too. The reference photo is
  # a property of the catch, not of a placement; ApplyJudgeAction's
  # add_reference_photo path never touches the tournament, so we pass nil.
  def reference_photo
    catch_record = Catch.where(user_id: current_club.members.select(:id)).find(params[:id])
    # Both entry points (the catch detail page and the judge review page) post
    # here; redirect_back returns the admin to whichever they came from.
    if params[:photo].blank?
      redirect_back(fallback_location: catch_path(catch_record), alert: "Choose a photo to add.") and return
    end

    Catches::ApplyJudgeAction.call(
      tournament: nil, catch: catch_record, judge: current_user,
      action: :add_reference_photo, note: params[:note], photo: params[:photo]
    )
    redirect_back fallback_location: catch_path(catch_record), notice: "Reference photo added."
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: catch_path(catch_record),
                  alert: "Couldn't add reference photo: #{e.record.errors.full_messages.to_sentence}"
  end

  def select_teammate
    @teammates = Tournaments::TeammatesAcross.call(user: current_user, club: current_club)
    redirect_to(select_species_catches_path) and return if @teammates.empty?
  end

  def select_species
    @teammate_user_id = params[:teammate_user_id].presence
    @species = Species.in_log_order
  end

  def new
    @teammate = resolve_teammate_or_redirect
    return if performed?
    @selected_species = Species.find_by(id: params[:species_id]) if params[:species_id].present?
    angler = @teammate || current_user
    @catch = angler.catches.build(captured_at_device: Time.current,
                                  client_uuid: SecureRandom.uuid)
    # Species list, caps, and the tagged-species id are derived in the shared
    # _form_fields partial (so the offline shell, which renders it with no
    # controller, stays self-contained).
  end

  def create
    teammate = resolve_teammate_or_redirect
    return if performed?
    angler = teammate || current_user
    @catch = angler.catches.build(catch_params)
    @catch.logged_by_user_id = current_user.id if teammate

    if teammate && !shares_entry_at?(teammate, @catch.captured_at_device)
      @catch.errors.add(:base, "You and this teammate aren't on the same entry in any active tournament.")
      @teammate = teammate
      render :new, status: :unprocessable_entity
      return
    end

    @catch.flags = Catches::ComputeFlags.call(@catch)
    @catch.lake  = Catches::DetectLake.call(@catch)
    @catch.status = @catch.flags.empty? ? :synced : :needs_review
    @catch.synced_at = Time.current

    if @catch.save && @catch.photo.attached?
      placements = Catches::RunPlacementPipeline.call(catch: @catch)
      notice = teammate ? "Catch logged for #{teammate.name}." : "Catch logged."
      # A tagged catch that arrives after the draw keeps its tag but earns no
      # ticket; the shared notice says so in the same words the judge and
      # organizer flows use, rather than letting it look like a normal entry.
      redirect_to root_path, notice: catch_change_notice({ ticket_withheld: placements[:withheld].any? }, saved: notice)
    else
      @catch.errors.add(:photo, "is required") unless @catch.photo.attached?
      @teammate = teammate
      render :new, status: :unprocessable_entity
    end
  end

  def update
    catch_record = current_user.catches.find(params[:id])
    if catch_record.update(catch_note_params)
      redirect_to catch_record, notice: "Notes saved"
    else
      @catch = catch_record
      @action_tournament = resolve_action_tournament(@catch)
      flash.now[:alert] = catch_record.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  private

  def resolve_teammate_or_redirect
    id = params[:teammate_user_id].presence
    return nil unless id
    teammate = current_club.members.find_by(id: id)
    unless teammate
      redirect_to new_catch_path, alert: "Teammate not found."
      return nil
    end
    teammate
  end

  def shares_entry_at?(teammate, at)
    Tournaments::SharedEntryAt.call(
      user_a: current_user, user_b: teammate, club: current_club, at: at || Time.current
    ).present?
  end

  def authorized_to_view?(catch_record)
    return true if catch_record.user_id == current_user.id
    return true if catch_record.logged_by_user_id == current_user.id
    return true if current_user.admin?
    return true if current_user.organizer_in?(current_club)
    catch_tournament_ids = catch_record.catch_placements.pluck(:tournament_id).uniq
    (judged_tournament_ids & catch_tournament_ids).any?
  end

  # Tournament to act in (DQ / length edit) from this catch's show page.
  # Prefer ?t= when supplied and the user has authority there; otherwise
  # the first placement the user can act on. Returns nil if none.
  def resolve_action_tournament(catch_record)
    candidate_ids = catch_record.catch_placements.pluck(:tournament_id).uniq
    return nil if candidate_ids.empty?
    tournaments = current_club.tournaments.where(id: candidate_ids)
    preferred = tournaments.find_by(id: params[:t])
    [preferred, *tournaments].compact.find { |t| can_act_on?(t) }
  end

  def can_act_on?(tournament)
    return true if tournament.friendly? && current_user.organizer_in?(current_club)
    TournamentJudge.exists?(tournament: tournament, user: current_user)
  end

  def catch_note_params
    params.require(:catch).permit(:note)
  end

  def catch_params
    params.require(:catch).permit(
      :species_id, :length_inches, :length_unit, :captured_at_device, :captured_at_gps,
      :latitude, :longitude, :gps_accuracy_m, :app_build, :client_uuid, :photo, :note,
      :tag_number, :weight_text
    )
  end

  def default_date_range
    today = Date.current
    if current_user.catches.where(captured_at_device: today.beginning_of_day..today.end_of_day).exists?
      [today, today]
    elsif (latest = current_user.catches.maximum(:captured_at_device))
      d = latest.to_date
      [d, d]
    else
      [nil, nil]
    end
  end
end
