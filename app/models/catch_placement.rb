class CatchPlacement < ApplicationRecord
  belongs_to :catch
  belongs_to :tournament
  belongs_to :tournament_entry
  belongs_to :species

  # Only active placements compete for a slot. Deactivated rows are kept as an
  # audit trail (e.g. after a judge changes a catch's species), so they must NOT
  # reserve their (entry, species, slot) — otherwise re-placing a catch under a
  # species it previously held collides with its own tombstone row.
  # Mirrors the partial DB index idx_active_placements_uniq_per_slot
  # (tournament_entry_id, species_id, slot_index) WHERE active.
  validates :slot_index, presence: true,
            uniqueness: { scope: [:tournament_entry_id, :species_id],
                          conditions: -> { where(active: true) },
                          if: :active? }

  scope :active, -> { where(active: true) }

  # Retire every row in the relation in one statement, stamping updated_at the
  # way update! would. A plain update_all leaves the stamp at creation time,
  # and updated_at is how PlaceInSlots tells a tagged ticket pulled BEFORE the
  # draw (not in the pool) from one pulled after it (in the pool, may be
  # re-issued). Use this, not update_all(active: false), wherever a ticket can
  # be retired.
  def self.deactivate_all
    update_all(active: false, updated_at: ::Time.current)
  end
end
