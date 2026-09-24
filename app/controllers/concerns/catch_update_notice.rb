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
end
