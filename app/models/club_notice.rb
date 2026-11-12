# A notice a site admin posts to chosen members of a club. Recipients must
# acknowledge it in a blocking popup once per local day, from starts_on
# through ends_on (both inclusive). Notices::DueFor decides who is due.
class ClubNotice < ApplicationRecord
  TITLE_MAX = 120
  MESSAGE_MAX = 2000

  belongs_to :club
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :recipients, class_name: "ClubNoticeRecipient", dependent: :delete_all
  has_many :recipient_users, through: :recipients, source: :user
  has_many :acknowledgments, class_name: "ClubNoticeAcknowledgment", dependent: :delete_all

  validates :title, presence: true, length: { maximum: TITLE_MAX }
  validates :message, presence: true, length: { maximum: MESSAGE_MAX }
  validates :starts_on, :ends_on, presence: true
  validate :ends_on_not_before_starts_on

  scope :active_on, ->(date) { where(starts_on: ..date, ends_on: date..) }

  def status(on: Date.current)
    return :upcoming if on < starts_on
    return :ended if on > ends_on
    :active
  end

  private

  def ends_on_not_before_starts_on
    return if starts_on.blank? || ends_on.blank?
    errors.add(:ends_on, "must be on or after the start date") if ends_on < starts_on
  end
end
