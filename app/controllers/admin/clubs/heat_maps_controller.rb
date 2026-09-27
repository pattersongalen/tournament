# Site-admin control of a club's heat map: the on/off switch, and the heat
# layer's display tuning with a live preview on the club's own catches. The
# site-admin gate and @foreign_club come from Admin::Clubs::BaseController.
class Admin::Clubs::HeatMapsController < Admin::Clubs::BaseController
  def edit
    load_preview
  end

  def update
    if @foreign_club.update(heat_map_params)
      redirect_to admin_club_path(@foreign_club), notice: "Heat map settings saved."
    else
      # Keep the messages, drop the rejected values: the sliders and the
      # preview go back to what is saved.
      @errors = @foreign_club.errors.full_messages
      @foreign_club.restore_attributes
      load_preview
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def heat_map_params
    params.require(:club).permit(:heat_map_enabled, *Club::HEAT_MAP_RANGES.keys)
  end

  # The member page's default view: every species, the last 12 months.
  def load_preview
    @points = Catches::HeatMapPoints.call(
      club: @foreign_club,
      species_ids: Species.pluck(:id),
      from: Date.current - Catches::HeatMapFilters::DEFAULT_SPAN,
      to: Date.current
    )
  end
end
