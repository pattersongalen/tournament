module Catches
  # Re-derives a Progressive Length entry's whole ladder from its eligible
  # catches. Unlike the other formats there is no separate incremental path:
  # PlaceInSlots calls this service too, so live placement and a later judge-edit
  # reconcile run identical code and cannot disagree. See ProgressiveLength::Ladder
  # for why capture order (not arrival order) is the source of truth.
  #
  # Returns { created:, bumped: } so PlaceInSlots can feed DetectNotifications.
  # ReconcileBasket ignores the return value.
  class ReconcileProgressiveLength
    include SlotPlacement

    def self.call(tournament:, entry:, species:, exclude_catch_id: nil)
      new(tournament: tournament, entry: entry, species: species, exclude_catch_id: exclude_catch_id).call
    end

    def initialize(tournament:, entry:, species:, exclude_catch_id: nil)
      @tournament, @entry, @species = tournament, entry, species
      @exclude_catch_id = exclude_catch_id
    end

    def call
      ::ActiveRecord::Base.transaction do
        @entry.lock!  # serialize with PlaceInSlots / the other reconcilers

        before = @entry.catch_placements
                       .where(species_id: @species.id, active: true)
                       .includes(:catch).to_a
        before_catch_ids = before.map(&:catch_id)

        # Clear the basket BEFORE re-activating. idx_active_placements_uniq_per_slot
        # is partial (active = true), so with no active rows the renumbering below
        # cannot collide — a late small fish inserting at rung 0 shifts every rung
        # up one without any sentinel dance.
        @entry.catch_placements
              .where(species_id: @species.id, active: true)
              .deactivate_all

        rungs = ProgressiveLength::Ladder.call(eligible_catches)
        placements = rungs.each_with_index.map do |catch_record, slot_index|
          activate_placement!(catch_record, slot_index: slot_index)
        end

        rung_catch_ids = rungs.map(&:id)
        {
          created: placements.reject { |p| before_catch_ids.include?(p.catch_id) },
          bumped:  before.reject { |p| rung_catch_ids.include?(p.catch_id) }
        }
      end
    end
  end
end
