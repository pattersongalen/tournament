module Catches
  class ReconcileProWalleye
    # Re-derives the Pro Walleye basket for one (entry, species) from scratch: the
    # 2 largest catches >55 cm, then the largest catches ≤55 cm to fill the rest of
    # the 5-fish basket (so up to 5 unders when there are no overs). By current
    # length_inches. Use after any non-incremental change to the eligible-catch
    # set: DQ, manual length/species edit, member drop. PromoteBackup
    # assume a single "promote the largest" basket with no over-fish sub-cap, which
    # is wrong here — we re-pick the whole basket under the 2-over rule instead.
    include SlotPlacement

    def self.call(tournament:, entry:, species:, exclude_catch_id: nil)
      new(tournament: tournament, entry: entry, species: species, exclude_catch_id: exclude_catch_id).call
    end

    def initialize(tournament:, entry:, species:, exclude_catch_id: nil)
      @tournament, @entry, @species = tournament, entry, species
      @exclude_catch_id = exclude_catch_id
    end

    def call
      ActiveRecord::Base.transaction do
        @entry.lock!  # serialize with PlaceInSlots / PromoteBackup / ReconcileStandard

        # Deactivate first so we never collide with idx_active_placements_uniq_per_slot
        # when re-activating an inactive row that shares the target slot.
        @entry.catch_placements
              .where(species_id: @species.id, active: true)
              .deactivate_all

        eligible = eligible_catches
        return if eligible.empty?

        overs  = eligible.select { |c| ProWalleye.big?(c.length_inches) }
        unders = eligible.reject { |c| ProWalleye.big?(c.length_inches) }

        # Up to 2 overs, then fill the rest of the 5-fish basket with the largest
        # unders. slot_index is a plain basket position with no class meaning.
        basket = top(overs, ProWalleye::BIG_CAP)
        basket += top(unders, ProWalleye::BASKET_SIZE - basket.size)
        basket.each_with_index do |c, i|
          activate_placement!(c, slot_index: i)
        end
      end
    end

    private

    # The N largest by length (see SlotPlacement#by_length for the tiebreak).
    def top(catches, n)
      by_length(catches, desc: true).first(n)
    end
  end
end
