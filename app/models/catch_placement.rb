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
  # way update! would so the audit trail records when the row was retired (a
  # plain update_all leaves the stamp at creation time). Nothing scores off
  # the stamp: whether a tagged ticket was in the draw is recorded on
  # in_draw_pool by Tournaments::DrawTaggedWinner.
  def self.deactivate_all
    update_all(active: false, updated_at: ::Time.current)
  end
end
