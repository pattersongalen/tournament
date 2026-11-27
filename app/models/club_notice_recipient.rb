class ClubNoticeRecipient < ApplicationRecord
  belongs_to :club_notice
  belongs_to :user
end
