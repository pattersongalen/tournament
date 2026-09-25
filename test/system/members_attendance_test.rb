require "application_system_test_case"

class MembersAttendanceTest < ApplicationSystemTestCase
  ROW = "[data-role='member']".freeze

  setup do
    @club = create(:club, name: "Test Anglers")
    @organizer = create(:user, club: @club, role: :organizer, name: "Organizer One")
    @anna = create(:user, club: @club, role: :member, name: "Anna Angler")
    @bob  = create(:user, club: @club, role: :member, name: "Bob Boater")
    2.times do |i|
      night = create(:tournament, club: @club, mode: :team, awards_season_points: true, season_tag: "Wed 2026",
                                  starts_at: (i + 1).weeks.ago, ends_at: (i + 1).weeks.ago + 3.hours)
      entry = create(:tournament_entry, tournament: night)
      create(:tournament_entry_member, tournament_entry: entry, user: @bob)
      create(:tournament_entry_member, tournament_entry: entry, user: @anna) if i.zero?
    end

    token = SignInToken.issue!(user: @organizer)
    visit consume_session_path(token: token.token)
    visit attendance_organizers_members_path
  end

  def visible_names
    page.all(ROW, visible: true).map { |row| row["data-name"] }
  end

  test "the sort toggle reorders the list and the filter narrows it by name" do
    assert page.has_css?(ROW, count: 3, wait: 5)
    assert_equal ["Bob Boater", "Anna Angler", "Organizer One"], visible_names, "default: most nights first"

    click_button "Name"
    assert_equal ["Anna Angler", "Bob Boater", "Organizer One"], visible_names
    assert page.has_css?("button[aria-pressed=true]", text: "Name")
    assert page.has_css?("button[aria-pressed=false]", text: "Nights")

    click_button "Nights"
    assert_equal ["Bob Boater", "Anna Angler", "Organizer One"], visible_names

    fill_in "Find a member", with: "bo"
    assert page.has_css?(ROW, count: 1, visible: true, wait: 5)
    assert_equal ["Bob Boater"], visible_names

    # An empty fill_in clears the value without an input event under Cuprite,
    # so clear it the way a keyboard does.
    find_field("Find a member").send_keys([:control, "a"], :backspace)
    assert page.has_css?(ROW, count: 3, visible: true, wait: 5)
  end
end
