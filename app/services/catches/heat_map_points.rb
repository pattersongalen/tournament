module Catches
  # The club heat map's points: the EXACT coordinates of the club's catches.
  # This is the one deliberate exception to the coordinate fuzzing used
  # everywhere else, so what leaves this method is coordinates and nothing
  # more — no ids, names, times or lengths — and in shuffled order, so a
  # point's position cannot be matched to when a catch was logged.
  class HeatMapPoints
    def self.call(club:, species_ids:, from:, to:, min_length: nil, max_length: nil)
      return [] if club.nil? || species_ids.empty?

      members = ::ClubMembership.with_active_user
                                .where(club_id: club.id)
                                .select("club_memberships.user_id")

      # captured_at_device holds UTC. Comparing against the local day's first
      # and last instants lets Rails do the zone conversion; no SQL AT TIME ZONE.
      scope = ::Catch.where(user_id: members)
                     .where.not(latitude: nil)
                     .where.not(longitude: nil)
                     .where.not(status: :disqualified)
                     .where(species_id: species_ids)
                     .where(captured_at_device: from.in_time_zone.beginning_of_day..to.in_time_zone.end_of_day)
      scope = scope.where(length_inches: min_length..) if min_length
      scope = scope.where(length_inches: ..max_length) if max_length

      scope.pluck(:latitude, :longitude).map { |lat, lng| [lat.to_f, lng.to_f] }.shuffle
    end
  end
end
