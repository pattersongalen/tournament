require "test_helper"

class NoticeAcknowledgmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @member = create(:user, club: @club, role: :member)
    @notice = create(:club_notice, club: @club, title: "First",
                     starts_on: Date.current - 1, ends_on: Date.current + 3)
    create(:club_notice_recipient, club_notice: @notice, user: @member)
  end

  test "acknowledging records the member, the notice, today's date and the time" do
    sign_in_as(@member)

    freeze_time do
      assert_difference -> { ClubNoticeAcknowledgment.count }, 1 do
        post notice_acknowledgment_path(@notice), as: :turbo_stream
      end

      ack = ClubNoticeAcknowledgment.last
      assert_equal @notice.id, ack.club_notice_id
      assert_equal @member.id, ack.user_id
      assert_equal Date.current, ack.acknowledged_on
      assert_equal Time.current, ack.created_at
    end
  end

  test "the acknowledgment is recorded against the local date, not the UTC date" do
    sign_in_as(@member)
    Time.use_zone("Saskatchewan") do
      @notice.update!(starts_on: Date.new(2026, 10, 1), ends_on: Date.new(2026, 10, 10))
      travel_to Time.zone.local(2026, 10, 5, 23, 30) do
        post notice_acknowledgment_path(@notice), as: :turbo_stream
      end
    end
    assert_equal Date.new(2026, 10, 5), ClubNoticeAcknowledgment.last.acknowledged_on
  end

  test "with no other notice due, the stream removes the popup" do
    sign_in_as(@member)
    post notice_acknowledgment_path(@notice), as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action=remove][target=notice-popup]", 1
  end

  test "with another notice due, the stream swaps it in" do
    second = create(:club_notice, club: @club, title: "Second",
                    starts_on: Date.current, ends_on: Date.current + 3)
    create(:club_notice_recipient, club_notice: second, user: @member)

    sign_in_as(@member)
    post notice_acknowledgment_path(@notice), as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=replace][target=notice-popup]", 1
    assert_includes response.body, "Second"
    assert_includes response.body, notice_acknowledgment_path(second)
  end

  test "a second acknowledgment the same day succeeds and adds no row" do
    sign_in_as(@member)
    post notice_acknowledgment_path(@notice), as: :turbo_stream

    assert_no_difference -> { ClubNoticeAcknowledgment.count } do
      post notice_acknowledgment_path(@notice), as: :turbo_stream
    end
    assert_response :success
  end

  test "the HTML fallback redirects back to the page the member was on" do
    sign_in_as(@member)
    post notice_acknowledgment_path(@notice), headers: { "HTTP_REFERER" => catches_url }

    assert_redirected_to catches_url
    assert_equal 1, ClubNoticeAcknowledgment.count
  end

  test "acknowledging a notice the member may not acknowledge is a 404 and records nothing" do
    other_club = create(:club)
    {
      "not a recipient" => -> {
        n = create(:club_notice, club: @club, starts_on: Date.current, ends_on: Date.current)
        n
      },
      "notice not started yet" => -> {
        n = create(:club_notice, club: @club, starts_on: Date.current + 1, ends_on: Date.current + 2)
        create(:club_notice_recipient, club_notice: n, user: @member)
        n
      },
      "notice already ended" => -> {
        n = create(:club_notice, club: @club, starts_on: Date.current - 3, ends_on: Date.current - 1)
        create(:club_notice_recipient, club_notice: n, user: @member)
        n
      },
      "notice in another club" => -> {
        n = create(:club_notice, club: other_club, starts_on: Date.current, ends_on: Date.current)
        create(:club_notice_recipient, club_notice: n, user: @member)
        n
      }
    }.each do |label, build_notice|
      target = build_notice.call
      sign_in_as(@member)

      assert_no_difference -> { ClubNoticeAcknowledgment.count }, label do
        post notice_acknowledgment_path(target), as: :turbo_stream
      end
      assert_response :not_found, label
      # The member may be looking at a stale popup (notice ended, deleted or
      # un-sent while it was open). The 404 carries a stream that swaps the
      # stale popup for the notice that IS due (the one from setup), so they
      # are not dropped on an error page.
      assert_select "turbo-stream[action=replace][target=notice-popup]", { count: 1 }, label
      assert_includes response.body, notice_acknowledgment_path(@notice), label
    end
  end

  test "a stale popup with nothing else due is cleared by the 404's stream" do
    sign_in_as(@member)
    @notice.update!(starts_on: Date.current - 3, ends_on: Date.current - 1)

    post notice_acknowledgment_path(@notice), as: :turbo_stream

    assert_response :not_found
    assert_select "turbo-stream[action=remove][target=notice-popup]", 1
    assert_equal 0, ClubNoticeAcknowledgment.count
  end

  test "the HTML fallback for a notice the member may not acknowledge stays a plain 404" do
    sign_in_as(@member)
    @notice.update!(starts_on: Date.current - 3, ends_on: Date.current - 1)

    post notice_acknowledgment_path(@notice)

    assert_response :not_found
  end

  test "a notice id that does not exist is a 404" do
    sign_in_as(@member)
    post notice_acknowledgment_path(notice_id: 0), as: :turbo_stream
    assert_response :not_found
  end

  test "a signed-out visitor is sent to sign in and nothing is recorded" do
    assert_no_difference -> { ClubNoticeAcknowledgment.count } do
      post notice_acknowledgment_path(@notice)
    end
    assert_redirected_to new_session_path
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
