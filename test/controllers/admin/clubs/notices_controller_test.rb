require "test_helper"

class Admin::Clubs::NoticesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @home_club = create(:club, name: "Admin Home FC")
    @admin     = create(:user, club: @home_club, admin: true)

    @club  = create(:club, name: "Target FC")
    @alice = create(:user, club: @club, role: :member, name: "Alice")
    @bob   = create(:user, club: @club, role: :member, name: "Bob")
  end

  def valid_params(overrides = {})
    {
      club_notice: {
        title: "Dues are due", message: "Pay by Friday.",
        starts_on: "2026-10-01", ends_on: "2026-10-10"
      }.merge(overrides)
    }
  end

  test "only a site admin can reach any notice action" do
    notice = create(:club_notice, club: @club)
    organizer = create(:user, club: @club, role: :organizer)
    member    = create(:user, club: @club, role: :member)
    tournament = create(:tournament, club: @club, starts_at: 2.days.from_now, ends_at: 3.days.from_now)
    deputy = create(:user, club: @club, role: :member)
    create(:tournament_deputy, tournament: tournament, user: deputy, granted_by_user: organizer)

    { "organizer" => organizer, "member" => member, "deputy" => deputy }.each do |label, user|
      sign_in_as(user)

      get admin_club_notices_path(@club)
      assert_response :forbidden, "#{label}: index"
      get new_admin_club_notice_path(@club)
      assert_response :forbidden, "#{label}: new"
      get admin_club_notice_path(@club, notice)
      assert_response :forbidden, "#{label}: show"
      get edit_admin_club_notice_path(@club, notice)
      assert_response :forbidden, "#{label}: edit"

      assert_no_difference -> { ClubNotice.count }, "#{label}: create" do
        post admin_club_notices_path(@club), params: valid_params
      end
      assert_response :forbidden, "#{label}: create"

      patch admin_club_notice_path(@club, notice), params: valid_params(title: "Hacked")
      assert_response :forbidden, "#{label}: update"
      assert_not_equal "Hacked", notice.reload.title, "#{label}: update"

      assert_no_difference -> { ClubNotice.count }, "#{label}: destroy" do
        delete admin_club_notice_path(@club, notice)
      end
      assert_response :forbidden, "#{label}: destroy"
    end
  end

  test "create saves the notice, its creator and only the selected members" do
    sign_in_as(@admin)

    assert_difference -> { ClubNotice.count }, 1 do
      post admin_club_notices_path(@club), params: valid_params.merge(member_ids: [@alice.id])
    end

    notice = ClubNotice.last
    assert_redirected_to admin_club_notice_path(@club, notice)
    assert_equal @club.id, notice.club_id
    assert_equal "Dues are due", notice.title
    assert_equal "Pay by Friday.", notice.message
    assert_equal Date.new(2026, 10, 1), notice.starts_on
    assert_equal Date.new(2026, 10, 10), notice.ends_on
    assert_equal @admin.id, notice.created_by_user_id
    assert_equal [@alice.id], notice.recipients.pluck(:user_id)
  end

  test "create with no members selected saves a notice with no recipients" do
    sign_in_as(@admin)
    post admin_club_notices_path(@club), params: valid_params

    assert_equal 0, ClubNotice.last.recipients.count
  end

  test "update changes the fields and replaces the recipient list" do
    notice = create(:club_notice, club: @club, title: "Old")
    create(:club_notice_recipient, club_notice: notice, user: @alice)
    sign_in_as(@admin)

    patch admin_club_notice_path(@club, notice),
          params: valid_params(title: "New").merge(member_ids: [@bob.id])

    assert_redirected_to admin_club_notice_path(@club, notice)
    assert_equal "New", notice.reload.title
    assert_equal [@bob.id], notice.recipients.pluck(:user_id)
  end

  # The form cannot offer a deactivated member, so an edit must not read their
  # missing checkbox as "remove": they are due again once reactivated.
  test "update keeps a recipient who is deactivated at the time of the edit" do
    notice = create(:club_notice, club: @club, title: "Old")
    gone = create(:user, club: @club, role: :member, name: "Gone Gary")
    create(:club_notice_recipient, club_notice: notice, user: @alice)
    create(:club_notice_recipient, club_notice: notice, user: gone)
    gone.update!(deactivated_at: Time.current)
    sign_in_as(@admin)

    patch admin_club_notice_path(@club, notice),
          params: valid_params(title: "New").merge(member_ids: [@alice.id])

    assert_equal "New", notice.reload.title
    assert_equal [@alice.id, gone.id].sort, notice.recipients.pluck(:user_id).sort
  end

  test "removing a recipient keeps the acknowledgments they already made" do
    notice = create(:club_notice, club: @club)
    create(:club_notice_recipient, club_notice: notice, user: @alice)
    create(:club_notice_acknowledgment, club_notice: notice, user: @alice,
           acknowledged_on: Date.new(2026, 10, 2))
    sign_in_as(@admin)

    patch admin_club_notice_path(@club, notice), params: valid_params.merge(member_ids: [@bob.id])

    assert_equal 1, notice.acknowledgments.where(user_id: @alice.id).count
  end

  test "invalid input re-renders the form as 422 and saves nothing" do
    sign_in_as(@admin)
    {
      "blank title"       => { title: "" },
      "blank message"     => { message: "" },
      "title too long"    => { title: "x" * 121 },
      "message too long"  => { message: "x" * 2001 },
      "end before start"  => { starts_on: "2026-10-10", ends_on: "2026-10-01" },
      # Review Focus 3: garbled and blank dates must be a 422, never a 500.
      "garbled start"     => { starts_on: "banana" },
      "blank end"         => { ends_on: "" },
      "impossible date"   => { starts_on: "2026-02-31" }
    }.each do |label, overrides|
      assert_no_difference -> { ClubNotice.count }, label do
        post admin_club_notices_path(@club), params: valid_params(overrides).merge(member_ids: [@alice.id])
      end
      assert_response :unprocessable_entity, label
      assert_equal 0, ClubNoticeRecipient.count, "#{label}: no recipients saved"
    end
  end

  test "a failed update changes neither the notice nor its recipients" do
    notice = create(:club_notice, club: @club, title: "Original")
    create(:club_notice_recipient, club_notice: notice, user: @alice)
    sign_in_as(@admin)

    patch admin_club_notice_path(@club, notice),
          params: valid_params(title: "").merge(member_ids: [@bob.id])

    assert_response :unprocessable_entity
    assert_equal "Original", notice.reload.title
    assert_equal [@alice.id], notice.recipients.pluck(:user_id)
  end

  test "a failed submit re-renders with the members the admin had checked" do
    sign_in_as(@admin)
    post admin_club_notices_path(@club), params: valid_params(title: "").merge(member_ids: [@bob.id])

    assert_select "input[type=checkbox][value='#{@bob.id}'][checked]", 1
    assert_select "input[type=checkbox][value='#{@alice.id}'][checked]", 0
  end

  # Review Focus 2: ids the form never offered must not become recipients.
  test "member ids from another club or a deactivated member are ignored" do
    outsider = create(:user, club: @home_club, role: :member)
    gone = create(:user, club: @club, role: :member, deactivated_at: Time.current)
    sign_in_as(@admin)

    post admin_club_notices_path(@club),
         params: valid_params.merge(member_ids: [@alice.id, outsider.id, gone.id, 0, "banana"])

    assert_equal [@alice.id], ClubNotice.last.recipients.pluck(:user_id)
  end

  test "the form lists only this club's active members" do
    create(:user, club: @home_club, role: :member, name: "Other Club Olga")
    create(:user, club: @club, role: :member, name: "Gone Gary", deactivated_at: Time.current)
    sign_in_as(@admin)

    get new_admin_club_notice_path(@club)

    assert_response :success
    assert_includes response.body, "Alice"
    assert_includes response.body, "Bob"
    assert_not_includes response.body, "Other Club Olga"
    assert_not_includes response.body, "Gone Gary"
  end

  test "index lists this club's notices with status and today's acknowledgment count" do
    active = create(:club_notice, club: @club, title: "Active one",
                    starts_on: Date.current - 1, ends_on: Date.current + 1)
    create(:club_notice, club: @club, title: "Upcoming one",
           starts_on: Date.current + 5, ends_on: Date.current + 6)
    create(:club_notice, club: @club, title: "Ended one",
           starts_on: Date.current - 9, ends_on: Date.current - 8)
    create(:club_notice, club: @home_club, title: "Other club notice")
    create(:club_notice_recipient, club_notice: active, user: @alice)
    create(:club_notice_recipient, club_notice: active, user: @bob)
    create(:club_notice_acknowledgment, club_notice: active, user: @alice, acknowledged_on: Date.current)
    create(:club_notice_acknowledgment, club_notice: active, user: @bob, acknowledged_on: Date.current - 1)

    sign_in_as(@admin)
    get admin_club_notices_path(@club)

    assert_response :success
    assert_includes response.body, "Active one"
    assert_includes response.body, "Upcoming one"
    assert_includes response.body, "Ended one"
    assert_not_includes response.body, "Other club notice"
    assert_includes response.body, "1 of 2 acknowledged today"
  end

  # A deactivated member is never shown the popup, so counting them would
  # leave the admin chasing an acknowledgment that cannot happen.
  test "index leaves deactivated recipients out of both sides of the count" do
    active = create(:club_notice, club: @club, title: "Active one",
                    starts_on: Date.current - 1, ends_on: Date.current + 1)
    gone = create(:user, club: @club, role: :member, name: "Gone Gary")
    [@alice, @bob, gone].each { |user| create(:club_notice_recipient, club_notice: active, user: user) }
    create(:club_notice_acknowledgment, club_notice: active, user: @alice, acknowledged_on: Date.current)
    create(:club_notice_acknowledgment, club_notice: active, user: gone, acknowledged_on: Date.current)
    gone.update!(deactivated_at: Time.current)

    sign_in_as(@admin)
    get admin_club_notices_path(@club)

    assert_includes response.body, "1 of 2 acknowledged today"
  end

  test "show lists each recipient's acknowledgments and former recipients separately" do
    notice = create(:club_notice, club: @club, title: "Shown")
    create(:club_notice_recipient, club_notice: notice, user: @alice)
    create(:club_notice_acknowledgment, club_notice: notice, user: @alice,
           acknowledged_on: Date.new(2026, 10, 2))
    create(:club_notice_acknowledgment, club_notice: notice, user: @bob,
           acknowledged_on: Date.new(2026, 10, 3))

    sign_in_as(@admin)
    get admin_club_notice_path(@club, notice)

    assert_response :success
    assert_select "#notice-recipients", text: /Alice/
    assert_select "#notice-recipients", text: /Oct 2, 2026/
    assert_select "#notice-former-recipients", text: /Bob/
    assert_select "#notice-former-recipients", text: /Oct 3, 2026/
  end

  test "destroy deletes the notice with its recipients and acknowledgments" do
    notice = create(:club_notice, club: @club)
    create(:club_notice_recipient, club_notice: notice, user: @alice)
    create(:club_notice_acknowledgment, club_notice: notice, user: @alice)
    sign_in_as(@admin)

    assert_difference -> { ClubNotice.count }, -1 do
      delete admin_club_notice_path(@club, notice)
    end

    assert_redirected_to admin_club_notices_path(@club)
    assert_equal 0, ClubNoticeRecipient.count
    assert_equal 0, ClubNoticeAcknowledgment.count
  end

  test "a notice cannot be reached through another club's URL" do
    notice = create(:club_notice, club: @home_club)
    sign_in_as(@admin)

    get admin_club_notice_path(@club, notice)
    assert_response :not_found
  end

  test "the club page links to notices" do
    sign_in_as(@admin)
    get admin_club_path(@club)
    assert_select "a[href=?]", admin_club_notices_path(@club)
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
