require "application_system_test_case"

class NoticePopupSystemTest < ApplicationSystemTestCase
  setup do
    @club = create(:club)
    @member = create(:user, club: @club)
    create(:species, name: "Walleye")

    @first = create(:club_notice, club: @club, title: "First notice", message: "Read me first.",
                    starts_on: Date.current - 1, ends_on: Date.current + 3)
    @second = create(:club_notice, club: @club, title: "Second notice", message: "Then read me.",
                     starts_on: Date.current, ends_on: Date.current + 3)
    create(:club_notice_recipient, club_notice: @first, user: @member)
    create(:club_notice_recipient, club_notice: @second, user: @member)
  end

  test "the popup blocks the page until each due notice is acknowledged, then stays away" do
    sign_in_as(@member)
    visit root_path

    within "#notice-popup" do
      assert_text "First notice"
      assert_text "Read me first."
    end
    assert page.has_css?("body.overflow-hidden"), "page scroll is locked behind the popup"

    # Escape must not close it.
    find("body").send_keys(:escape)
    assert page.has_css?("#notice-popup", wait: 1), "Escape must not dismiss the popup"

    # The page behind is covered: the element at the Log Catch link's position
    # belongs to the popup, so a tap there cannot reach the link.
    covered = page.evaluate_script(<<~JS)
      (function () {
        var link = Array.from(document.querySelectorAll("a")).find(function (a) {
          return a.textContent.trim() === "Log Catch";
        });
        var r = link.getBoundingClientRect();
        var top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        return !!top.closest("#notice-popup");
      })()
    JS
    assert covered, "the popup must cover the page behind it"

    click_button "I acknowledge"

    # The second notice takes its place without a page load.
    within "#notice-popup" do
      assert_text "Second notice"
    end
    assert page.has_css?("body.overflow-hidden"), "still locked while the second notice shows"

    click_button "I acknowledge"

    assert page.has_no_css?("#notice-popup", wait: 5)
    assert page.has_no_css?("body.overflow-hidden"), "page scroll is released once no notice is left"
    assert_equal 2, ClubNoticeAcknowledgment.where(user: @member, acknowledged_on: Date.current).count

    # A reload does not bring either notice back today.
    visit root_path
    assert_text "Log Catch"
    assert page.has_no_css?("#notice-popup")
  end

  test "acknowledging a popup whose notice was deleted meanwhile clears it and keeps the page" do
    @second.destroy!
    sign_in_as(@member)
    visit root_path
    assert page.has_css?("#notice-popup")

    @first.destroy!
    click_button "I acknowledge"

    assert page.has_no_css?("#notice-popup", wait: 5)
    assert_text "Log Catch"
    assert page.has_no_css?("body.overflow-hidden")
  end

  test "the Log Catch flow is never interrupted, and the popup waits on the next page" do
    sign_in_as(@member)

    visit select_species_catches_path
    assert page.has_no_css?("#notice-popup"), "species step: no popup"

    visit new_catch_path
    assert page.has_no_css?("#notice-popup"), "catch form: no popup"

    visit catches_path
    assert page.has_css?("#notice-popup"), "the next ordinary page shows it"
  end

  # Review Focus 5: a maximum-length message on a phone-sized screen. The
  # message scrolls inside the card; the button must stay on screen and work.
  test "a 2000-character message leaves the acknowledge button reachable on a phone" do
    @second.destroy!
    @first.update!(message: ("All members must read this carefully. " * 60).first(2000))
    page.driver.resize(375, 667)

    sign_in_as(@member)
    visit root_path

    on_screen = page.evaluate_script(<<~JS)
      (function () {
        var b = document.querySelector("#notice-popup button");
        var r = b.getBoundingClientRect();
        return r.top >= 0 && r.bottom <= window.innerHeight;
      })()
    JS
    assert on_screen, "the button must be inside the viewport without scrolling"

    click_button "I acknowledge"
    assert page.has_no_css?("#notice-popup", wait: 5)
  end
end
