require "test_helper"

class NoticePopupTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club, name: "Notice Club")
    @member = create(:user, club: @club, role: :member, name: "Notice Ned")
    @notice = create(:club_notice, club: @club, title: "Dues are due",
                     message: "Pay the treasurer\nby Friday.",
                     starts_on: Date.current, ends_on: Date.current + 3)
    create(:club_notice_recipient, club_notice: @notice, user: @member)
    create(:species, name: "Walleye")
  end

  test "a due recipient gets the popup on the home page, with the acknowledge form" do
    sign_in_as(@member)
    get root_path

    assert_response :success
    assert_select "#notice-popup[role=dialog][aria-modal=true][data-turbo-temporary]", 1
    assert_select "#notice-popup h2", text: "Dues are due"
    assert_select "#notice-popup p.whitespace-pre-line", text: /Pay the treasurer\s+by Friday\./
    assert_select "#notice-popup form[action=?][method=post]", notice_acknowledgment_path(@notice)
    assert_select "#notice-popup button", text: "I acknowledge"
  end

  test "the popup has no close control other than the acknowledge button" do
    sign_in_as(@member)
    get root_path

    assert_select "#notice-popup button", 1
    assert_select "#notice-popup a", 0
  end

  test "no popup when the member is not due" do
    {
      "not a recipient" => -> {
        outsider = create(:user, club: @club, role: :member)
        sign_in_as(outsider)
      },
      "already acknowledged today" => -> {
        create(:club_notice_acknowledgment, club_notice: @notice, user: @member,
               acknowledged_on: Date.current)
        sign_in_as(@member)
      },
      "notice has ended" => -> {
        @notice.update!(starts_on: Date.current - 5, ends_on: Date.current - 1)
        sign_in_as(@member)
      }
    }.each do |label, arrange|
      arrange.call
      get root_path
      assert_response :success, label
      assert_select "#notice-popup", { count: 0 }, label
      # Reset for the next case.
      ClubNoticeAcknowledgment.delete_all
      @notice.update!(starts_on: Date.current, ends_on: Date.current + 3)
    end
  end

  test "the Log Catch flow never shows the popup" do
    sign_in_as(@member)

    get select_species_catches_path
    assert_response :success
    assert_select "#notice-popup", { count: 0 }, "select_species"

    get new_catch_path
    assert_response :success
    assert_select "#notice-popup", { count: 0 }, "new"
  end

  test "the teammate chooser never shows the popup" do
    tournament = create(:tournament, club: @club, mode: :team)
    entry = create(:tournament_entry, tournament: tournament)
    create(:tournament_entry_member, tournament_entry: entry, user: @member)
    mate = create(:user, club: @club, name: "Boatmate")
    create(:tournament_entry_member, tournament_entry: entry, user: mate)

    sign_in_as(@member)
    get select_teammate_catches_path

    assert_response :success
    assert_select "#notice-popup", { count: 0 }
  end

  test "a failed catch submission re-renders the form without the popup" do
    sign_in_as(@member)
    post catches_path, params: { catch: { length_inches: "" } }

    assert_response :unprocessable_entity
    assert_select "#notice-popup", { count: 0 }
  end

  test "the admin layout shows the popup too" do
    organizer = create(:user, club: @club, role: :organizer)
    create(:club_notice_recipient, club_notice: @notice, user: organizer)

    sign_in_as(organizer)
    get admin_root_path

    assert_response :success
    assert_select "#notice-popup", 1
  end

  test "a signed-out visitor never gets the popup" do
    get new_session_path
    assert_response :success
    assert_select "#notice-popup", { count: 0 }
  end

  # Review Focus 4: the message is plain text. Markup must render as text.
  test "markup in the title and message is escaped" do
    @notice.update!(title: "<b>Bold</b>", message: "<script>alert(1)</script>")
    sign_in_as(@member)
    get root_path

    assert_select "#notice-popup script", 0
    assert_select "#notice-popup b", 0
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
