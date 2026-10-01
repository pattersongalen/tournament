# One question on a club's top-3 questionnaire. Questions are never deleted:
# retiring one hides it from new forms and keeps the answers already given.
class ClubQuestion < ApplicationRecord
  PROMPT_MAX = 80
  DEFAULT_PROMPTS = ["Lure used", "Bait used", "Depth"].freeze

  belongs_to :club

  before_validation { self.prompt = prompt.to_s.strip }

  validates :prompt, presence: true, length: { maximum: PROMPT_MAX }
  validates :position, presence: true
  validate :prompt_unique_among_active

  scope :active, -> { where(retired_at: nil) }
  scope :retired, -> { where.not(retired_at: nil) }
  scope :ordered, -> { order(:position, :id) }

  def retired?
    retired_at.present?
  end

  private

  def prompt_unique_among_active
    return if retired? || prompt.blank? || club_id.nil?

    clash = ClubQuestion.active.where(club_id: club_id)
                        .where("LOWER(prompt) = ?", prompt.downcase)
                        .where.not(id: id)
                        .exists?
    errors.add(:prompt, "is already on the list") if clash
  end
end
