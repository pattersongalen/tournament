module Tournaments
  # The one dispatch point for season point amounts. Two different counts
  # feed it, and they must not be conflated:
  #
  #   entry_count  — boats/teams that competed. Gates whether placement
  #                  points are paid at all (season_points_min_entries) and
  #                  sizes the full_field ladder (one rung per boat).
  #   angler_count — distinct people who fished. Picks the tier band for the
  #                  tiered_ladders / base_ladder schemes, so a 5-boat night
  #                  with 13 anglers aboard pays the 10–19 ladder.
  #
  # Returns the per-place amounts — [9, 6, 3], [8, 7, 6, 5, 4, 3, 2, 1],
  # whatever the club set — or nil when the field was too small to pay
  # placement points at all.
  #
  # Callers ask for the scale FIRST, then request exactly scale.length ranked
  # rows, because full_field's ladder is as long as the field.
  class PointsScale
    def self.call(club:, entry_count:, angler_count:)
      return nil if entry_count.to_i < club.season_points_min_entries
      return entry_count.to_i.downto(1).to_a if club.season_points_scheme_full_field?

      ladder_for(club: club, angler_count: angler_count)
    end

    # The band ladder for an angler count with no minimum-entries gate: what
    # the "how points work" explainer and the admin preview show per band,
    # where there is no field to gate on. Nil under full_field, whose ladder
    # is sized by the entry count rather than an angler band — callers show
    # that scheme in prose instead of a band table.
    def self.ladder_for(club:, angler_count:)
      case club.season_points_scheme
      when "tiered_ladders" then tiered_ladder(club, angler_count)
      when "base_ladder"    then scaled_base_ladder(club, angler_count)
      end
    end

    # base_ladder and full_field already return guaranteed numerics (a
    # rounded Float and an Integer range respectively); normalise this
    # branch the same way so the contract is uniform. Validation coerces
    # with #to_f, so a jsonb ladder written directly (update_column, a
    # legacy row, anything that skips validation) can hold Strings — map
    # them here rather than let a String reach SeasonPointsAwarded's `+`.
    def self.tiered_ladder(club, angler_count)
      club.season_points_ladders[band_index(angler_count)]&.map { |amount| amount.to_f }
    end
    private_class_method :tiered_ladder

    def self.band_index(angler_count)
      ::Club::SEASON_POINTS_BANDS.index { |band| band.cover?(angler_count.to_i) } ||
        ::Club::SEASON_POINTS_BANDS.size - 1
    end
    private_class_method :band_index

    def self.scaled_base_ladder(club, angler_count)
      multiplier = club.season_points_tier_multipliers[band_index(angler_count)].to_f
      club.season_points_base_ladder.map { |amount| (amount.to_f * multiplier).round(2) }
    end
    private_class_method :scaled_base_ladder
  end
end
