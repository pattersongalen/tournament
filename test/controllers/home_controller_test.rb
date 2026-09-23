require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "renders home when signed in" do
    user = create(:user, name: "Joe")
    post session_path, params: { email: user.email }
    token = SignInToken.last
    get consume_session_path(token: token.token)
    get root_path
    assert_response :success
    assert_select "h1", ENV.fetch("APP_NAME", "Tournament")
    assert_match "Joe", response.body
  end

  test "notifications Enable button defaults to non-blue (JS swaps it on when subscribed)" do
    user = create(:user)
    post session_path, params: { email: user.email }
    get consume_session_path(token: SignInToken.last.token)
    get root_path
    assert_response :success
    assert_select "button[data-action~=?]", "push-register#enable" do |btns|
      assert_not btns.first["class"].to_s.include?("bg-blue"),
                 "Enable button should default to non-blue; the JS controller flips it to blue when the subscription is active"
    end
  end

  test "deactivated user with an existing session is signed out on next request" do
    user = create(:user)
    post session_path, params: { email: user.email }
    get consume_session_path(token: SignInToken.last.token)
    assert_equal user.id, session[:user_id]

    user.update!(deactivated_at: Time.current)
    get root_path
    assert_redirected_to new_session_path
    assert_nil session[:user_id]
  end

  test "home page Rules button reflects the active season's rules revision" do
    {
      "no revision for the active season hides the button" => -> {
        club = create(:club)
        member = create(:user, club: club, role: :member)
        sign_in_as(member)
        get root_path
        assert_response :success
        assert_no_match %r{Rules \(}, response.body, "no revision for the active season hides the button"
      },
      "active-season revision exists shows its date" => -> {
        club = create(:club)
        member = create(:user, club: club, role: :member)
        organizer = create(:user, club: club, role: :organizer)
        create(:club_rules_revision, club: club, edited_by_user: organizer,
                                     season: :open_water, body: "<div>x</div>",
                                     created_at: Time.zone.local(2026, 5, 9, 10))
        sign_in_as(member)
        get root_path
        assert_response :success
        assert_match "Rules (updated May 9, 2026)", response.body, "active-season revision exists shows its date"
        assert_match rules_path, response.body, "active-season revision exists shows its date"
      },
      "changing the active season swaps the shown revision" => -> {
        club = create(:club)
        member = create(:user, club: club, role: :member)
        organizer = create(:user, club: club, role: :organizer)
        create(:club_rules_revision, club: club, edited_by_user: organizer,
                                     season: :open_water, body: "<div>ow</div>",
                                     created_at: Time.zone.local(2026, 5, 9, 10))
        create(:club_rules_revision, club: club, edited_by_user: organizer,
                                     season: :ice, body: "<div>ice</div>",
                                     created_at: Time.zone.local(2026, 1, 1, 10))
        club.update!(active_rules_season: :ice)
        sign_in_as(member)
        get root_path
        assert_match "Rules (updated Jan 1, 2026)", response.body, "changing the active season swaps the shown revision"
      }
    }.each { |_label, block| block.call }
  end

  test "home leaderboard hint appears once per entrants-only tournament, absent when none are locked" do
    {
      "two locked tournaments show the hint twice" => -> (label) {
        club = create(:club)
        member = create(:user, club: club, role: :member)
        create(:tournament, club: club, entrants_only_leaderboard: true)
        create(:tournament, club: club, entrants_only_leaderboard: true)
        sign_in_as(member)
        get root_path
        assert_response :success, label
        assert_select "span",
                      { text: "Ask an organizer to add you to see the leaderboard.", count: 2 }, label
      },
      "a visible tournament shows no hint" => -> (label) {
        club = create(:club)
        member = create(:user, club: club, role: :member)
        create(:tournament, club: club, entrants_only_leaderboard: false)
        sign_in_as(member)
        get root_path
        assert_response :success, label
        assert_not_includes @response.body, "Ask an organizer to add you to see the leaderboard.", label
      }
    }.each { |label, block| block.call(label) }
  end

  test "home routes 'Log Catch' to the teammate chooser for a team member, straight to the form for a solo-only member" do
    {
      "team member" => -> (label) {
        member = create(:user, club: @club, role: :member)
        team_tournament_with_mate_for(member, name: "Team Cup")
        sign_in_as(member)
        get root_path
        assert_response :success, label
        assert_select "a[href=?]", select_teammate_catches_path, { text: "Log Catch" }, label
        assert_no_match "Log for teammate", response.body, label
      },
      "solo-only member" => -> (label) {
        member = create(:user, club: @club, role: :member)
        t = create(:tournament, club: @club, mode: :solo,
                                starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
        entry = create(:tournament_entry, tournament: t)
        create(:tournament_entry_member, tournament_entry: entry, user: member)
        sign_in_as(member)
        get root_path
        assert_response :success, label
        assert_select "a[href=?]", select_species_catches_path, { text: "Log Catch" }, label
        assert_no_match "Log for teammate", response.body, label
      }
    }.each { |label, block| block.call(label) }
  end

  # Downgraded from test/system/merch_button_test.rb (4 system tests -> 1 table test):
  # the Merch button only renders for a present, http(s) MERCH_URL.
  test "Merch button renders only for a present http(s) MERCH_URL" do
    original_merch_url = ENV["MERCH_URL"]
    sign_in_as(@member)

    {
      "present https URL"    => ["https://example.test/merch", true],
      "unset"                => [nil, false],
      "blank string"         => ["", false],
      "non-http(s) scheme"   => ["javascript:alert(1)", false],
    }.each do |label, (value, expect_link)|
      if value.nil?
        ENV.delete("MERCH_URL")
      else
        ENV["MERCH_URL"] = value
      end

      get root_path

      assert_response :success
      rendered = css_select("a").any? { |a| a.text.strip == "Merch" }
      assert_equal expect_link, rendered, "#{label}: Merch link rendered? expected #{expect_link}"

      if expect_link
        assert_select "a[href='#{value}'][target='_blank'][rel~='noopener'][rel~='noreferrer']",
          { text: "Merch" }, "#{label}: Merch link should target the configured URL in a new tab with noopener noreferrer"
      end
    end
  ensure
    if original_merch_url.nil?
      ENV.delete("MERCH_URL")
    else
      ENV["MERCH_URL"] = original_merch_url
    end
  end

  # Downgraded from test/system/season_points_test.rb "shows top 5 with correct points
  # for a 10-angler solo tournament" (home_controller_test.rb#L118's Merch test sits
  # between this and the current-season gate below; season_points_test.rb #1 "no
  # standings section when no points-eligible tournaments" is covered by the gate
  # itself: SeasonPoints::CurrentSeasonTag.call returning nil, proven by
  # test/services/season_points/current_season_tag_test.rb, means home/index.html.erb
  # never renders this partial at all — see the `<% if current_tag %>` guard).
  test "home page season standings shows the top 5 of the current season, with a link to full standings" do
    walleye = create(:species, club: @club)
    t = create(:tournament, club: @club, mode: :solo, awards_season_points: true,
               season_tag: "Wednesday 2026", starts_at: 5.hours.ago, ends_at: 1.hour.ago,
               name: "League Night")
    create(:scoring_slot, tournament: t, species: walleye, slot_count: 2)
    [["Angler One", 26], ["Angler Two", 24], ["Angler Three", 22],
     ["Angler Four", 20], ["Angler Five", 18], ["Angler Six", 16]].each do |name, length|
      u = create(:user, club: @club, name: name)
      e = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: e, user: u)
      Catches::PlaceInSlots.call(catch: create(:catch, user: u, species: walleye,
                                 length_inches: length, captured_at_device: 2.hours.ago))
    end

    sign_in_as(@member)
    get root_path

    assert_response :success
    assert_match "Wednesday 2026 League Night Standings", response.body
    assert_select "ol li", 5, "the partial truncates to standings.first(5) even with 6 ranked anglers"
    assert_select "a[href=?]", season_points_path, text: "Full standings →"
  end

  test "the club banner renders the admin's line breaks" do
    club = create(:club, banner_message: "  Ice is off the lake\nWeigh-in moves to 7pm  ",
                         banner_style: :alert)
    user = create(:user, club: club)
    user.club_memberships.find_by!(club: club).update!(show_banner: true)
    sign_in_as(user)

    get root_path

    assert_response :success
    banner = css_select("p#club-banner").first
    assert_not_nil banner
    assert_includes banner["class"], "whitespace-pre-line",
                    "without this the browser collapses the newline into a single space"
    assert_equal "Ice is off the lake\nWeigh-in moves to 7pm", banner.text,
                 "the <p> and the ERB output must stay adjacent and the message stripped, " \
                 "or pre-line renders stray blank lines around it"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  def team_tournament_with_mate_for(user, name:)
    t = create(:tournament, club: @club, name: name, mode: :team,
                            starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    create(:tournament_entry_member, tournament_entry: entry, user: create(:user, club: @club))
    t
  end

  def setup
    @club = create(:club)
    @member = create(:user, club: @club, role: :member)
  end
end
