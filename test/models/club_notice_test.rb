require "test_helper"

class ClubNoticeTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
  end

  test "a notice with title, message and an ordered date range is valid" do
    notice = build(:club_notice, club: @club,
                   starts_on: Date.new(2026, 10, 1), ends_on: Date.new(2026, 10, 1))
    assert notice.valid?, notice.errors.full_messages.to_sentence
  end

  test "validation rejects each invalid shape" do
    {
      "blank title"            => { title: " " },
      "title over 120"         => { title: "x" * 121 },
      "blank message"          => { message: "" },
      "message over 2000"      => { message: "x" * 2001 },
      "missing start"          => { starts_on: nil },
      "missing end"            => { ends_on: nil },
      "end before start"       => { starts_on: Date.new(2026, 10, 2), ends_on: Date.new(2026, 10, 1) }
    }.each do |label, attrs|
      notice = build(:club_notice, club: @club, **attrs)
      assert_not notice.valid?, "#{label} should be invalid"
    end
  end

  test "status is upcoming before the range, active inside it (both ends inclusive), ended after" do
    notice = build(:club_notice, club: @club,
                   starts_on: Date.new(2026, 10, 1), ends_on: Date.new(2026, 10, 10))
    {
      Date.new(2026, 9, 30)  => :upcoming,
      Date.new(2026, 10, 1)  => :active,
      Date.new(2026, 10, 10) => :active,
      Date.new(2026, 10, 11) => :ended
    }.each do |day, expected|
      assert_equal expected, notice.status(on: day), "status on #{day}"
    end
  end

  test "active_on includes both boundary days and excludes the days outside" do
    notice = create(:club_notice, club: @club,
                    starts_on: Date.new(2026, 10, 1), ends_on: Date.new(2026, 10, 10))
    assert_includes ClubNotice.active_on(Date.new(2026, 10, 1)), notice
    assert_includes ClubNotice.active_on(Date.new(2026, 10, 10)), notice
    assert_not_includes ClubNotice.active_on(Date.new(2026, 9, 30)), notice
    assert_not_includes ClubNotice.active_on(Date.new(2026, 10, 11)), notice
  end

  test "deleting a notice deletes its recipients and acknowledgments" do
    notice = create(:club_notice, club: @club)
    user = create(:user, club: @club)
    create(:club_notice_recipient, club_notice: notice, user: user)
    create(:club_notice_acknowledgment, club_notice: notice, user: user)

    notice.destroy!

    assert_equal 0, ClubNoticeRecipient.where(club_notice_id: notice.id).count
    assert_equal 0, ClubNoticeAcknowledgment.where(club_notice_id: notice.id).count
  end

  test "the database refuses a second acknowledgment for the same notice, user and day" do
    notice = create(:club_notice, club: @club)
    user = create(:user, club: @club)
    create(:club_notice_acknowledgment, club_notice: notice, user: user,
           acknowledged_on: Date.new(2026, 10, 5))

    assert_raises(ActiveRecord::RecordNotUnique) do
      ClubNoticeAcknowledgment.transaction(requires_new: true) do
        ClubNoticeAcknowledgment.insert_all!([{
          club_notice_id: notice.id, user_id: user.id,
          acknowledged_on: Date.new(2026, 10, 5), created_at: Time.current
        }])
      end
    end
  end
end
