require "test_helper"

class CatchUpdateNoticeTest < ActiveSupport::TestCase
  include CatchUpdateNotice

  test "a plain success passes through" do
    assert_equal "Catch updated.", catch_change_notice({}, saved: "Catch updated.")
    assert_nil catch_change_notice({})
  end

  test "a withheld ticket names the tournament whose draw had run" do
    notice = catch_change_notice({ tickets_withheld_in: ["Wednesday Main"] }, saved: "Catch updated.")
    assert_match(/\ACatch updated\. The draw in Wednesday Main already ran/, notice)
    assert_match(/no ticket was issued there/, notice)
  end

  test "withheld across two tournaments lists both" do
    notice = catch_change_notice({ tickets_withheld_in: ["Main", "Side"] })
    assert_match(/The draws in Main and Side already ran/, notice)
  end

  test "a dropped tag is reported by number" do
    notice = catch_change_notice({ tag_dropped: "A0001" }, saved: "Catch updated.")
    assert_match(/Tag A0001 was dropped: only a Tagged Walleye carries one\./, notice)
  end

  test "a re-issued ticket the standing draw may not have included tells the organizer to re-draw" do
    notice = catch_change_notice({ ticket_reissued: true })
    assert_match(/draw ticket was re-issued/, notice)
    assert_match(/re-draw/, notice)
  end

  test "a voided draw is still reported" do
    assert_match(/draw is void/, catch_change_notice({ draw_voided: true }))
  end
end
