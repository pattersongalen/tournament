# The flash for a catch edit that went through Catches::ApplyJudgeAction's
# manual_override. Shared by the organizer/admin catch editor and the judge
# override form so the wording can't drift between them.
module CatchUpdateNotice
  extend ActiveSupport::Concern

  private

  # A tag added after the draw saves but earns no ticket (the pool closed at
  # the draw); say so rather than let "Catch updated." imply one was issued.
  def catch_updated_notice(result)
    return "Catch updated." unless result[:ticket_withheld]
    "Tag saved. The draw already ran, so no ticket was issued for this catch."
  end

  # The correction flows (reinstate, GPS fix, geofence override) re-place the
  # catch; after the draw that only re-issues a ticket the draw drew from. A
  # fish the draw never saw (a DQ undone after it) comes back with no ticket,
  # and the judge must hear that rather than a bare redirect. nil when there
  # is nothing to say, so the redirect sets no flash.
  def ticket_withheld_notice(result)
    return nil unless result[:ticket_withheld]
    "Change applied. The draw already ran and this fish was not in it, so no ticket was issued."
  end
end
