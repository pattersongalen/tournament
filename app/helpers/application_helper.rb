module ApplicationHelper
  # The species list (alphabetical), loaded once per request. Use in views that
  # render species in a loop (scoring-slot rows, fish-train cars) so each row
  # reuses one query instead of re-running Species.order(:name).
  def ordered_species
    @ordered_species ||= Species.order(:name).to_a
  end

  def tournament_window(tournament)
    starts_at = tournament.starts_at
    ends_at   = tournament.ends_at
    return nil if starts_at.blank?

    if ends_at.blank?
      format_tournament_moment(starts_at)
    elsif starts_at.to_date == ends_at.to_date
      "#{format_tournament_moment(starts_at)} – #{ends_at.strftime("%-l:%M %p")}"
    else
      "#{format_tournament_moment(starts_at)} – #{format_tournament_moment(ends_at)}"
    end
  end

  # The base_ladder scheme rounds multiplier results to 2 dp (see
  # Tournaments::PointsScale#scaled_base_ladder), so a night can genuinely
  # pay 3.75 points. Formatting at 1 dp silently truncated those to 3.8,
  # which no longer summed to a member's own total on the standings page.
  # 2-dp-with-trim is a superset of the old 1-dp-with-trim output for every
  # value that only ever had at most 1 decimal place, so this doesn't change
  # how whole numbers or halves render. Mirrors Club#format_points_amount,
  # which does the same job for ladder text fields.
  def format_season_points(n)
    SeasonPoints::FormatAmount.call(n)
  end

  BANNER_STRIP_CLASSES = {
    "info"  => "bg-yellow-500/20 border-yellow-500/40 text-yellow-200",
    "good"  => "bg-emerald-500/20 border-emerald-500/40 text-emerald-200",
    "alert" => "bg-red-500/20 border-red-500/40 text-red-200",
  }.freeze

  def banner_strip_classes(style)
    BANNER_STRIP_CLASSES.fetch(style.to_s, BANNER_STRIP_CLASSES["info"])
  end

  private

  def format_tournament_moment(time)
    fmt = time.year == Time.current.year ? "%b %-d · %-l:%M %p" : "%b %-d, %Y · %-l:%M %p"
    time.strftime(fmt)
  end
end
