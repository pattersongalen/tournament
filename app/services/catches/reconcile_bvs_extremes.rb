module Catches
  class ReconcileBvsExtremes
    # Re-derives the BvS active placements (biggest + smallest by current
    # length_inches) for one (entry, species) from scratch. Use after any
    # non-incremental change to the eligible-catch set: DQ, manual length/species
    # edit, member drop. PromoteBackup assumes "promote the
    # largest" semantics, which is wrong when the freed slot was holding the
    # smaller extreme — for BvS we have to look at the whole catch set.
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

        # Select biggest then smallest via the shared SlotRanking ordering (earliest
        # captured_at_device wins a same-length tie). The incremental PlaceInSlots BvS
        # branch re-selects over the same candidate set with the same key, so the two
        # paths keep the identical pair.
        biggest  = by_length(eligible, desc: true).first
        remaining = eligible - [biggest]
        if remaining.empty?
          activate_placement!(biggest, slot_index: 0)
        else
          smallest = by_length(remaining, desc: false).first
          activate_placement!(biggest, slot_index: 0)
          activate_placement!(smallest, slot_index: 1)
        end
      end
    end
  end
end
