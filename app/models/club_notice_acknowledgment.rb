# One row per notice, member and local day. Append-only: rows are removed
# only when their notice is deleted.
class ClubNoticeAcknowledgment < ApplicationRecord
  belongs_to :club_notice
  belongs_to :user

  validates :acknowledged_on, presence: true
end
