require "test_helper"

class Notices::DueForTest < ActiveSupport::TestCase
  STARTS = Date.new(2026, 10, 1)
  ENDS   = Date.new(2026, 10, 10)

  DAYS = {
    before_start: Date.new(2026, 9, 30),
    on_start:     STARTS,
    mid_range:    Date.new(2026, 10, 5),
    on_end:       ENDS,
    after_end:    Date.new(2026, 10, 11)
  }.freeze

  # The spec's state table. One row per case; `due` is the expected result.
  ROWS = [
    { n: 1,  day: :before_start, recipient: true,  ack_today: false, ack_yesterday: false, active: true,  other_club: false, due: false },
    { n: 2,  day: :on_start,     recipient: true,  ack_today: false, ack_yesterday: false, active: true,  other_club: false, due: true  },
    { n: 3,  day: :mid_range,    recipient: true,  ack_today: false, ack_yesterday: false, active: true,  other_club: false, due: true  },
    { n: 4,  day: :on_end,       recipient: true,  ack_today: false, ack_yesterday: false, active: true,  other_club: false, due: true  },
    { n: 5,  day: :after_end,    recipient: true,  ack_today: false, ack_yesterday: false, active: true,  other_club: false, due: false },
    { n: 6,  day: :mid_range,    recipient: false, ack_today: false, ack_yesterday: false, active: true,  other_club: false, due: false },
    { n: 7,  day: :mid_range,    recipient: true,  ack_today: true,  ack_yesterday: false, active: true,  other_club: false, due: false },
    { n: 8,  day: :mid_range,    recipient: true,  ack_today: false, ack_yesterday: true,  active: true,  other_club: false, due: true  },
    { n: 9,  day: :mid_range,    recipient: true,  ack_today: false, ack_yesterday: false, active: false, other_club: false, due: false },
    { n: 10, day: :mid_range,    recipient: true,  ack_today: false, ack_yesterday: false, active: true,  other_club: true,  due: false }
  ].freeze

  test "state table: a notice is due only when every condition holds" do
    ROWS.each do |row|
      club = create(:club)
      user = create(:user, club: club)
      notice_club = row[:other_club] ? create(:club) : club
      notice = create(:club_notice, club: notice_club, starts_on: STARTS, ends_on: ENDS)
      day = DAYS.fetch(row[:day])

      create(:club_notice_recipient, club_notice: notice, user: user) if row[:recipient]
      if row[:ack_today]
        create(:club_notice_acknowledgment, club_notice: notice, user: user, acknowledged_on: day)
      end
      if row[:ack_yesterday]
        create(:club_notice_acknowledgment, club_notice: notice, user: user, acknowledged_on: day - 1)
      end
      user.update!(deactivated_at: Time.current) unless row[:active]

      due = Notices::DueFor.call(user: user, club: club, on: day).to_a

      assert_equal row[:due], due.include?(notice), "row #{row[:n]}: #{row.inspect}"
    end
  end

  test "another member's acknowledgment does not clear the notice for this member" do
    club = create(:club)
    user = create(:user, club: club)
    other = create(:user, club: club)
    notice = create(:club_notice, club: club, starts_on: STARTS, ends_on: ENDS)
    create(:club_notice_recipient, club_notice: notice, user: user)
    create(:club_notice_recipient, club_notice: notice, user: other)
    create(:club_notice_acknowledgment, club_notice: notice, user: other,
           acknowledged_on: DAYS[:mid_range])

    assert_includes Notices::DueFor.call(user: user, club: club, on: DAYS[:mid_range]), notice
  end

  test "several due notices come back oldest start date first, then by id" do
    club = create(:club)
    user = create(:user, club: club)
    later   = create(:club_notice, club: club, starts_on: Date.new(2026, 10, 4), ends_on: ENDS)
    earlier = create(:club_notice, club: club, starts_on: Date.new(2026, 10, 2), ends_on: ENDS)
    same_a  = create(:club_notice, club: club, starts_on: Date.new(2026, 10, 3), ends_on: ENDS)
    same_b  = create(:club_notice, club: club, starts_on: Date.new(2026, 10, 3), ends_on: ENDS)
    [later, earlier, same_a, same_b].each do |n|
      create(:club_notice_recipient, club_notice: n, user: user)
    end

    due = Notices::DueFor.call(user: user, club: club, on: DAYS[:mid_range]).to_a

    assert_equal [earlier, same_a, same_b, later], due
  end

  test "a nil user or nil club returns nothing" do
    club = create(:club)
    user = create(:user, club: club)
    assert_empty Notices::DueFor.call(user: nil, club: club)
    assert_empty Notices::DueFor.call(user: user, club: nil)
  end

  # Review Focus 1: the day rolls over at LOCAL midnight. At 11:30 pm local in
  # a zone behind UTC, the UTC date is already tomorrow; the acknowledgment
  # must still count for the local day, and the notice must come due again
  # just after local midnight.
  test "default date follows the app time zone across local midnight" do
    club = create(:club)
    user = create(:user, club: club)
    notice = create(:club_notice, club: club, starts_on: STARTS, ends_on: ENDS)
    create(:club_notice_recipient, club_notice: notice, user: user)

    # Pinned to a zone behind UTC: in UTC the local and UTC dates never
    # diverge and this test could not tell Date.current from Date.today.
    Time.use_zone("Saskatchewan") do
      travel_to Time.zone.local(2026, 10, 5, 23, 30) do
        assert_equal Date.new(2026, 10, 6), Time.current.utc.to_date, "UTC is already tomorrow"
        assert_equal Date.new(2026, 10, 5), Date.current
        assert_includes Notices::DueFor.call(user: user, club: club), notice,
                        "11:30 pm local on the 5th: due, judged by the local date"
        create(:club_notice_acknowledgment, club_notice: notice, user: user,
               acknowledged_on: Date.new(2026, 10, 6))
        assert_includes Notices::DueFor.call(user: user, club: club), notice,
                        "an acknowledgment for the UTC date does not cover the local day"
        create(:club_notice_acknowledgment, club_notice: notice, user: user,
               acknowledged_on: Date.current)
        assert_empty Notices::DueFor.call(user: user, club: club),
                     "acknowledged at 11:30 pm local: not due for the rest of that local day"
      end

      ClubNoticeAcknowledgment.where(acknowledged_on: Date.new(2026, 10, 6)).delete_all
      travel_to Time.zone.local(2026, 10, 6, 0, 10) do
        assert_includes Notices::DueFor.call(user: user, club: club), notice,
                        "ten past local midnight: due again"
      end
    end
  end
end
