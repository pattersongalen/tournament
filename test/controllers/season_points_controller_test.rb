require "test_helper"

class SeasonPointsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @member = create(:user, club: @club)
  end

  def sign_in_member!
    token = SignInToken.issue!(user: @member)
    get consume_session_path(token: token.token)
  end

  test "show renders an empty state when no points-eligible tournaments" do
    sign_in_member!
    get season_points_path
    assert_response :success
    assert_match(/No season-points tournaments configured/i, response.body)
  end

  test "tournaments action renders an empty state when none ended" do
    sign_in_member!
    get season_points_tournaments_path
    assert_response :success
  end

  test "tournaments action links an ended entrants-only row instead of showing the hint" do
    sign_in_member!
    t = create(:tournament, club: @club, name: "Locked League Night",
           awards_season_points: true, season_tag: "Spring 2026",
           starts_at: 6.days.ago, ends_at: 5.days.ago,
           entrants_only_leaderboard: true)
    get season_points_tournaments_path
    assert_response :success
    assert_match "Locked League Night", response.body
    assert_no_match "Ask an organizer to add you", response.body
    assert_select "a[href=?]", tournament_path(t)
  end

  # Downgraded from test/system/season_points_test.rb "view full standings page shows
  # all entered anglers including 0.5 attendance bonus". Club defaults: min_entries 3,
  # attendance 0.5, tiered_ladders band 1..9 => [3, 2, 1]. 4 solo entries (a 4th
  # catch-less angler included) => placers get ladder + 0.5 attendance, the catch-less
  # angler gets the 0.5 attendance bonus only.
  test "standings page renders ranked rows, longest length first, with points and the attendance-only row" do
    walleye = create(:species, club: @club)
    t = create(:tournament, club: @club, mode: :solo, awards_season_points: true,
               season_tag: "Wednesday 2026", starts_at: 5.hours.ago, ends_at: 1.hour.ago,
               name: "League Night")
    create(:scoring_slot, tournament: t, species: walleye, slot_count: 2)
    [["Angler One", 24], ["Angler Two", 20], ["Angler Three", 18]].each do |name, length|
      u = create(:user, club: @club, name: name)
      e = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: e, user: u)
      Catches::PlaceInSlots.call(catch: create(:catch, user: u, species: walleye,
                                 length_inches: length, captured_at_device: 2.hours.ago))
    end
    # A 4th entrant who fished but caught nothing: still earns the attendance bonus,
    # never earns placement points, and must still render its own row.
    no_fish_angler = create(:user, club: @club, name: "Angler Four")
    no_fish_entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: no_fish_entry, user: no_fish_angler)

    sign_in_member!
    get season_points_path

    assert_response :success
    standings_table = css_select("table").first # the "How points are awarded" explainer renders its own table below
    rows = standings_table.css("tbody tr")
    assert_equal 4, rows.size
    assert_match "Angler One", rows[0].text
    assert_match "3.5", rows[0].text, "1st place: 3 placement pts + 0.5 attendance"
    assert_match "Angler Two", rows[1].text
    assert_match "2.5", rows[1].text, "2nd place: 2 placement pts + 0.5 attendance"
    assert_match "Angler Three", rows[2].text
    assert_match "1.5", rows[2].text, "3rd place: 1 placement pt + 0.5 attendance"
    assert_match "Angler Four", rows[3].text
    assert_match "0.5", rows[3].text, "no catch: attendance bonus only, no placement points"
  end

  # Downgraded from test/system/season_points_test.rb "past league nights page lists
  # ended points-eligible tournaments with winner".
  test "past league nights page lists ended tournaments with the winner" do
    walleye = create(:species, club: @club)
    t = create(:tournament, club: @club, mode: :solo, awards_season_points: true,
               season_tag: "Wednesday 2026", starts_at: 1.week.ago - 4.hours, ends_at: 1.week.ago,
               name: "League Night #1")
    create(:scoring_slot, tournament: t, species: walleye, slot_count: 2)
    winner = create(:user, club: @club, name: "Winner")
    e = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: e, user: winner)
    Catches::PlaceInSlots.call(catch: create(:catch, user: winner, species: walleye,
                               length_inches: 25, captured_at_device: t.ends_at - 1.hour))

    sign_in_member!
    get season_points_tournaments_path

    assert_response :success
    assert_match "League Night #1", response.body
    assert_match "Won by: Winner", response.body
    assert_select "a[href=?]", tournament_path(t)
  end

  test "standings page explainer matches the club's scoring scheme" do
    {
      "tiered ladder (default scheme)" => {
        scheme: nil,
        present: [ "How points are awarded", "9, 6, 3" ],
        absent: []
      },
      "full-field scheme has no ladder table" => {
        scheme: :full_field,
        present: [ "every boat that scores" ],
        absent: [ "Boats out" ]
      }
    }.each do |label, row|
      club = create(:club)
      member = create(:user, club: club)
      club.update!(season_points_scheme: row[:scheme]) if row[:scheme]
      create(:tournament, club: club, awards_season_points: true, season_tag: "Spring 2026",
             starts_at: 6.days.ago, ends_at: 5.days.ago)

      token = SignInToken.issue!(user: member)
      get consume_session_path(token: token.token)
      get season_points_path

      assert_response :success, label
      row[:present].each { |text| assert_includes response.body, text, label }
      row[:absent].each { |text| assert_not_includes response.body, text, label }
    end
  end

  # FIX 5 regression: the explainer used to sample a fixed mid-band size (6)
  # for the 1–9 row. With season_points_min_entries raised to 8, that sampled
  # size fell below the minimum and rendered "—", telling members a 1–9 boat
  # night never pays placement points even though an 8- or 9-boat night does.
  # Sampling the TOP of the band (9) fixes it.
  test "standings page explainer shows the band still pays after a raised minimum" do
    @club.update!(season_points_min_entries: 8)
    create(:tournament, club: @club, awards_season_points: true, season_tag: "Spring 2026",
           starts_at: 6.days.ago, ends_at: 5.days.ago)
    sign_in_member!
    get season_points_path
    assert_response :success
    # The band is now labelled from the minimum ("8–9", not "1–9") — see
    # Club#effective_season_points_bands — and must still show its ladder.
    row = Nokogiri::HTML(response.body).css("tr").find { |tr| tr.text.include?("8–9") }
    assert row, "expected an 8–9 row in the explainer table"
    assert_not_includes row.text, "—"
    assert_match "3, 2, 1", row.text
  end

  test "standings page reports a customised attendance value and minimum" do
    @club.update!(season_points_attendance: 1, season_points_min_entries: 5)
    create(:tournament, club: @club, awards_season_points: true, season_tag: "Spring 2026",
           starts_at: 6.days.ago, ends_at: 5.days.ago)
    sign_in_member!
    get season_points_path
    assert_response :success
    assert_includes response.body, "1 points"
    assert_includes response.body, "5 entries"
  end

  test "standings page explainer labels the first band from the club's minimum and shows the attendance-only range" do
    @club.update!(season_points_min_entries: 5)
    create(:tournament, club: @club, awards_season_points: true, season_tag: "Spring 2026",
           starts_at: 6.days.ago, ends_at: 5.days.ago)
    sign_in_member!
    get season_points_path
    assert_response :success
    assert_includes response.body, "5–9", "first band starts at the minimum"
    assert_not_includes response.body, "1–9", "the unclipped label would promise points a 4-boat night never pays"
    assert_includes response.body, "1–4", "the attendance-only range is spelled out"
  end
end
