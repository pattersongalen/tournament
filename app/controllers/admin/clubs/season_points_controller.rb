class Admin::Clubs::SeasonPointsController < Admin::Clubs::BaseController
  def edit
    @preview_club = @foreign_club
  end

  def update
    @foreign_club.assign_attributes(season_points_params)
    if @foreign_club.save
      redirect_to admin_club_path(@foreign_club), notice: "Season points updated."
    else
      render_edit_with_saved_preview
    end
  rescue ArgumentError
    # An out-of-range scheme (the radios are bypassable) raises on enum
    # assignment before any validation runs. Nothing is persisted; re-render.
    @foreign_club.errors.add(:season_points_scheme, "isn't a scheme we know")
    render_edit_with_saved_preview
  end

  private

  # The "What the saved settings pay" table must read the SAVED record, not
  # the invalid in-memory one: a blank minimum used to 500 the 422 re-render
  # (Integer <=> nil inside PointsScale), a blank attendance value 500'd
  # format("%.2f", nil), and junk ladder text made the preview show "0, 0, 0"
  # under a heading that says "saved".
  def render_edit_with_saved_preview
    @preview_club = Club.find(@foreign_club.id)
    render :edit, status: :unprocessable_entity
  end

  def season_points_params
    params.require(:club).permit(
      :season_points_scheme,
      :season_points_attendance,
      :season_points_min_entries,
      :season_points_base_ladder_text,
      :season_points_tier_multipliers_text,
      season_points_ladders_text: []
    )
  end
end
