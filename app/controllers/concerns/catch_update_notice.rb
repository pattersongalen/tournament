# The flash for a catch change that went through Catches::ApplyJudgeAction.
# Shared by the organizer/admin catch editor, the judge override form, the
# judge review decisions and the judge correction flows so the wording can't
# drift between them.
module CatchUpdateNotice
  extend ActiveSupport::Concern

  private

  # `saved` is the flash for a plain success ("Catch updated."); the
  # correction and review flows pass nothing and redirect with no flash
  # when there is nothing to say. The draw's two consequences are appended
  # so the organizer never reads a bare success and assumes a ticket:
  # a re-placement after the draw for a fish the draw never saw earns no
  # ticket, and retiring the drawn winner's ticket voids the draw.
  def catch_change_notice(result, saved: nil)
    notes = []
    notes << "The draw already ran and this fish was not in it, so no ticket was issued." if result[:ticket_withheld]
    notes << "This fish was the drawn winner and no longer holds a ticket, so the draw is void until an organizer re-draws." if result[:draw_voided]
    return saved if notes.empty?
    [saved, *notes].compact.join(" ")
  end
end
