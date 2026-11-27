module Notices
  # The notices a member must acknowledge today: active on the day, sent to
  # this member, and not yet acknowledged by them for that day. Oldest start
  # date first, so a member with several sees them in a stable order.
  class DueFor
    def self.call(user:, club:, on: Date.current)
      return ::ClubNotice.none if user.nil? || club.nil? || user.deactivated?

      sent_to_user = ::ClubNoticeRecipient.where(user_id: user.id).select(:club_notice_id)
      acknowledged = ::ClubNoticeAcknowledgment
                       .where(user_id: user.id, acknowledged_on: on)
                       .select(:club_notice_id)

      ::ClubNotice.where(club_id: club.id)
                  .active_on(on)
                  .where(id: sent_to_user)
                  .where.not(id: acknowledged)
                  .order(:starts_on, :id)
    end
  end
end
