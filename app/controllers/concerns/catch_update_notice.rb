# The flash for a catch change that went through Catches::ApplyJudgeAction.
# Shared by the organizer/admin catch editor, the judge override form, the
# judge review decisions and the judge correction flows so the wording can't
# drift between them.
module CatchUpdateNotice
  extend ActiveSupport::Concern

  private

  # `saved` is the flash for a plain success ("Catch updated."); the
  # correction and review flows pass nothing and redirect with no flash
  # when there is nothing to say. What the edit did to the tag and to the
  # draw is appended so the organizer never reads a bare success and
  # assumes a ticket: a species change away from Tagged Walleye drops the
  # tag, a re-placement after the draw for a fish the draw never saw earns
  # no ticket there, a re-issued ticket the winner did not follow may sit
  # under a draw that ran without the fish, and retiring the drawn winner's
  # ticket voids the draw.
  def catch_change_notice(result, saved: nil)
    notes = []
    if result[:tag_dropped].present?
      notes << "Tag #{result[:tag_dropped]} was dropped: only a Tagged Walleye carries one."
    end
    withheld_in = Array(result[:tickets_withheld_in])
    if withheld_in.any?
      notes << "The #{'draw'.pluralize(withheld_in.size)} in #{withheld_in.to_sentence} already ran and " \
               "this fish was not in #{withheld_in.size == 1 ? 'it' : 'them'}, so no ticket was issued there."
    end
    if result[:ticket_reissued]
      notes << "Its draw ticket was re-issued. If the draw was re-run while this fish held no ticket, " \
               "that draw did not include it: re-draw to put it in."
    end
    if result[:draw_voided]
      notes << "This fish was the drawn winner and no longer holds a ticket, so the draw is void until an organizer re-draws."
    end
    return saved if notes.empty?
    [saved, *notes].compact.join(" ")
  end
end
