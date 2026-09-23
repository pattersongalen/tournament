require "test_helper"

class TournamentsControllerTest < ActionDispatch::IntegrationTest
  include LengthHelper

  # Nokogiri's #text keeps the template's literal whitespace, unlike Capybara's.
  # Squeeze it so assertions can be written the way the browser rendered them.
  def leaderboard_rows
    css_select("#leaderboard tbody tr").map { |tr| tr.text.gsub(/\s+/, " ").strip }
  end

  setup do
    @club = create(:club)
    @user = create(:user, club: @club)
    post session_path, params: { email: @user.email }
    get consume_session_path(token: SignInToken.last.token)
  end

  # Helper for the gate tests where the tournament uses entrants_only_leaderboard
  # — adds the test user (or a passed-in user) to a fresh tournament entry.
  def enroll_user_in(tournament, user: @user)
    entry = create(:tournament_entry, tournament: tournament)
    create(:tournament_entry_member, tournament_entry: entry, user: user)
    entry
  end

  test "archived redirects to sign in when not signed in" do
    delete session_path
    get archived_tournaments_path
    assert_redirected_to new_session_path
  end

  # Merges: "returns 200 when signed in", "includes tournaments ended >24h ago,
  # newest first", "excludes tournaments ended within the last 24h", "excludes
  # tournaments with no ends_at".
  test "archived lists tournaments ended more than 24h ago (newest first), excluding recently-ended and open-ended ones" do
    older = create(:tournament, club: @club, name: "Older", starts_at: 6.days.ago, ends_at: 5.days.ago)
    newer = create(:tournament, club: @club, name: "Newer", starts_at: 2.days.ago, ends_at: 26.hours.ago)
    create(:tournament, club: @club, name: "RecentlyEnded", starts_at: 4.hours.ago, ends_at: 2.hours.ago)
    # Legacy NULL-ends_at row: bypass the now-required ends_at validation.
    build(:tournament, club: @club, name: "OpenEnded", ends_at: nil).save!(validate: false)

    get archived_tournaments_path
    assert_response :success
    assert_match "Older", response.body
    assert_match "Newer", response.body
    assert response.body.index("Newer") < response.body.index("Older"),
      "Newer (more recent ends_at) should appear before Older"
    assert_no_match "RecentlyEnded", response.body, "ended within the last 24h should be excluded"
    assert_no_match "OpenEnded", response.body, "no ends_at should be excluded"
  end

  test "archived is scoped to the current user's club" do
    other_club = create(:club)
    create(:tournament, club: other_club, name: "OtherClubTourney", starts_at: 6.days.ago, ends_at: 5.days.ago)
    get archived_tournaments_path
    assert_no_match "OtherClubTourney", response.body
  end

  # Merges: "renders the winner's display_name for tournaments with a placed
  # catch", "omits the winner suffix when a tournament has no placed catches".
  test "archived shows the winner's display_name only for tournaments with a placed catch" do
    species = create(:species, club: @club)
    t = create(:tournament, club: @club, name: "BigFishNight",
               starts_at: 6.days.ago, ends_at: 5.days.ago)
    create(:scoring_slot, tournament: t, species: species, slot_count: 1)
    angler = create(:user, club: @club, name: "Galen Patterson")
    entry = create(:tournament_entry, tournament: t)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)
    catch_record = create(:catch, user: angler, species: species, length_inches: 22.5,
                                  captured_at_device: 5.days.ago - 1.hour)
    create(:catch_placement, catch: catch_record, tournament: t,
                              tournament_entry: entry, species: species, slot_index: 0)
    create(:tournament, club: @club, name: "EmptyTourney", starts_at: 6.days.ago, ends_at: 5.days.ago)

    get archived_tournaments_path
    assert_response :success

    rows = css_select("li").map(&:text)
    winner_row = rows.find { |r| r.include?("BigFishNight") }
    empty_row  = rows.find { |r| r.include?("EmptyTourney") }
    assert_not_nil winner_row, "BigFishNight row not found"
    assert_not_nil empty_row, "EmptyTourney row not found"
    assert_match "Galen Patterson", winner_row, "placed-catch tournament should show the winner"
    assert_match "winner", winner_row
    assert_no_match "winner", empty_row, "tournament with no placed catches should omit the winner suffix"
  end

  test "archived does not render the season_tag on rows" do
    create(:tournament, club: @club, name: "TaggedTourney",
           starts_at: 6.days.ago, ends_at: 5.days.ago, season_tag: "Spring 2026")
    get archived_tournaments_path
    assert_response :success
    assert_match "TaggedTourney", response.body
    assert_no_match "Spring 2026", response.body
  end

  test "index shows the leaderboard hint only on locked entrants-only rows" do
    create(:tournament, club: @club, name: "Closed Active", entrants_only_leaderboard: true)
    create(:tournament, club: @club, name: "Open Active")
    get tournaments_path
    assert_response :success

    rows = css_select("li").map(&:text)
    closed_row = rows.find { |r| r.include?("Closed Active") }
    open_row   = rows.find { |r| r.include?("Open Active") }
    assert_not_nil closed_row, "Closed Active row not found"
    assert_not_nil open_row, "Open Active row not found"
    assert_match "Ask an organizer to add you", closed_row, "locked entrants-only row should show the hint"
    assert_no_match "Ask an organizer to add you", open_row, "open row should not show the hint"
  end

  # Downgraded from test/system/season_filter_test.rb.
  test "index renders a season filter link that emits ?season= for each season tag" do
    create(:tournament, club: @club, name: "OW Wed", season_tag: "Open Water 2026")
    create(:tournament, club: @club, name: "Ice Friday", season_tag: "Ice 2026/27")

    get tournaments_path

    assert_response :success
    assert_select "a[href=?]", tournaments_path(season: "Open Water 2026"), text: "Open Water 2026"
    assert_select "a[href=?]", tournaments_path(season: "Ice 2026/27"), text: "Ice 2026/27"

    # Exercise the link's target, not just its href: params[:season] actually filters
    # tournaments_controller.rb's scope (`scope.where(season_tag: params[:season])`).
    get tournaments_path(season: "Open Water 2026")
    assert_response :success
    assert_match "OW Wed", response.body
    assert_no_match "Ice Friday", response.body
  end

  test "archived renders a clickable link (no hint) for an ended entrants-only tournament" do
    tournament = create(:tournament, club: @club, name: "Closed Archive",
           starts_at: 6.days.ago, ends_at: 5.days.ago, entrants_only_leaderboard: true)
    get archived_tournaments_path
    assert_response :success
    assert_match "Closed Archive", response.body
    assert_no_match "Ask an organizer to add you", response.body
    assert_select "a[href=?]", tournament_path(tournament)
  end

  test "show with entrants_only_leaderboard on: non-entered member is redirected with a flash" do
    tournament = create(:tournament, club: @club, name: "Closed Doors", entrants_only_leaderboard: true)
    get tournament_path(tournament)
    assert_redirected_to root_path
    follow_redirect!
    assert_match(/Ask an organizer to add you/, flash[:alert].to_s)
  end

  test "show with entrants_only_leaderboard on: non-entered member is allowed after the tournament ends" do
    tournament = create(:tournament, club: @club, starts_at: 2.hours.ago, ends_at: 1.hour.ago,
                                     entrants_only_leaderboard: true)
    get tournament_path(tournament)
    assert_response :success
  end

  test "show with entrants_only_leaderboard on: signed-out visitor is still blocked after the tournament ends" do
    tournament = create(:tournament, club: @club, starts_at: 2.hours.ago, ends_at: 1.hour.ago,
                                     entrants_only_leaderboard: true)
    delete session_path
    get tournament_path(tournament)
    assert_redirected_to new_session_path
  end

  # Merges: entered member, assigned judge, club organizer, site admin — all
  # allowed through the entrants-only gate despite (for the latter three) not
  # being entered.
  test "show with entrants_only_leaderboard on: entered member, judge, organizer and site admin are all allowed" do
    tournament = create(:tournament, club: @club, entrants_only_leaderboard: true)
    {
      "entered member" => -> { enroll_user_in(tournament) },
      "assigned judge (not entered)" => -> {
        judge = create(:user, club: @club, name: "Hon. Judge", role: :member)
        create(:tournament_judge, tournament: tournament, user: judge)
        post session_path, params: { email: judge.email }
        get consume_session_path(token: SignInToken.last.token)
      },
      "club organizer (not entered)" => -> {
        organizer = create(:user, club: @club, name: "Org", role: :organizer)
        post session_path, params: { email: organizer.email }
        get consume_session_path(token: SignInToken.last.token)
      },
      "site admin (not entered)" => -> {
        admin = create(:user, club: @club, name: "Site Admin", role: :member, admin: true)
        post session_path, params: { email: admin.email }
        get consume_session_path(token: SignInToken.last.token)
      }
    }.each do |label, setup|
      setup.call
      get tournament_path(tournament)
      assert_response :success, "#{label} should be allowed"
    end
  end

  test "show with entrants_only_leaderboard off (default): any signed-in club member can view" do
    tournament = create(:tournament, club: @club, name: "Open Doors")
    get tournament_path(tournament)
    assert_response :success
  end

  test "show renders the ends label and date/time on the same line, date right-aligned" do
    ends_at = Time.zone.local(2026, 6, 15, 18, 30)
    tournament = create(:tournament, club: @club, starts_at: ends_at - 4.hours, ends_at: ends_at)
    get tournament_path(tournament)
    assert_response :success
    assert_select "[class~='justify-between']" do
      assert_select "*", text: /Ends|Ended/
      assert_select "*", text: /Jun 15, 2026 ·\s+6:30 PM/
    end
  end

  # Merges: "shows a green check beside an approved fish (no 'Approved by' tag
  # here)" and "does not render approved markers for unreviewed fish" — one
  # tournament with an approved catch and an unreviewed catch shows exactly
  # one check.
  test "show: approved check renders only for the judge-approved catch, never an 'Approved by' tag" do
    tournament = create(:tournament, club: @club)
    species = create(:species, club: @club)
    create(:scoring_slot, tournament: tournament, species: species, slot_count: 2)
    entry = create(:tournament_entry, tournament: tournament, name: "Team Reel Deal")
    create(:tournament_entry_member, tournament_entry: entry, user: @user)
    approved_catch = create(:catch, user: @user, species: species, length_inches: 18.5,
                                    captured_at_device: 20.minutes.ago)
    unreviewed_catch = create(:catch, user: @user, species: species, length_inches: 15.0,
                                      captured_at_device: 10.minutes.ago)
    create(:catch_placement, catch: approved_catch, tournament: tournament,
                              tournament_entry: entry, species: species, slot_index: 0)
    create(:catch_placement, catch: unreviewed_catch, tournament: tournament,
                              tournament_entry: entry, species: species, slot_index: 1)
    judge = create(:user, club: @club, name: "Judge Judy")
    create(:judge_action, judge_user: judge, catch: approved_catch, action: :approve)

    get tournament_path(tournament)
    assert_response :success
    assert_select "[data-test=approved-check]", count: 1
    assert_no_match "Approved by", response.body
  end

  test "biggest_vs_smallest: green check appears beside each approved extreme independently" do
    species = create(:species, club: @club)
    tournament = build(:tournament, club: @club, format: :biggest_vs_smallest, mode: :solo,
                       starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    tournament.scoring_slots.build(species: species, slot_count: 1)
    tournament.save!
    entry = create(:tournament_entry, tournament: tournament, name: "Team Reel Deal")
    create(:tournament_entry_member, tournament_entry: entry, user: @user)

    biggest = create(:catch, user: @user, species: species, length_inches: 22.0,
                     captured_at_device: 40.minutes.ago)
    smallest = create(:catch, user: @user, species: species, length_inches: 11.0,
                      captured_at_device: 30.minutes.ago)
    Catches::PlaceInSlots.call(catch: biggest)
    Catches::PlaceInSlots.call(catch: smallest)

    # Approve only the biggest — its check should show, the smallest's should not.
    judge = create(:user, club: @club, name: "Judge Judy")
    create(:judge_action, judge_user: judge, catch: biggest, action: :approve)

    get tournament_path(tournament)
    assert_response :success
    assert_select "[data-test=approved-check]", count: 1
  end

  # Merges: "entered angler sees own entry's fish, others blanked" and
  # "entered angler subscribes to entry stream and reveal".
  test "blind+active show page: entered angler sees own fish (others blanked) and subscribes to entry+reveal streams" do
    species = create(:species, club: @club)
    t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
               blind_leaderboard: true)
    create(:scoring_slot, tournament: t, species: species, slot_count: 1)

    my_entry = create(:tournament_entry, tournament: t, name: "My Entry")
    create(:tournament_entry_member, tournament_entry: my_entry, user: @user)
    my_catch = create(:catch, user: @user, species: species, length_inches: 22.5)
    create(:catch_placement, catch: my_catch, tournament: t,
                              tournament_entry: my_entry, species: species, slot_index: 0)

    other_user = create(:user, club: @club, name: "Other Angler")
    other_entry = create(:tournament_entry, tournament: t, name: "Other Entry")
    create(:tournament_entry_member, tournament_entry: other_entry, user: other_user)
    other_catch = create(:catch, user: other_user, species: species, length_inches: 28.0)
    create(:catch_placement, catch: other_catch, tournament: t,
                              tournament_entry: other_entry, species: species, slot_index: 0)

    get tournament_path(t)
    assert_response :success

    # Both entry names are visible in the leaderboard
    assert_match "My Entry", response.body
    assert_match "Other Entry", response.body

    # My length appears, but the other angler's length does not
    assert_match "22.5", response.body
    assert_no_match "28.0", response.body

    # Banner is rendered, AND lives inside the #leaderboard wrapper so a
    # reveal-stream replace (which targets id="leaderboard") sweeps the banner
    # away alongside the table.
    assert_match(/Blind leaderboard/i, response.body)
    assert_select "#leaderboard #blind-leaderboard-banner"

    # Subscribed to own entry's stream and the reveal stream, not :full.
    assert_match Turbo::StreamsChannel.signed_stream_name("tournament:#{t.id}:leaderboard:entry:#{my_entry.id}"), response.body
    assert_match Turbo::StreamsChannel.signed_stream_name("tournament:#{t.id}:leaderboard:reveal"), response.body
    assert_no_match Regexp.new(Regexp.escape(Turbo::StreamsChannel.signed_stream_name("tournament:#{t.id}:leaderboard:full"))), response.body
  end

  # Merges: "non-entered, non-organizer member sees only entry names, totals
  # dashed" and "non-entered member subscribes only to reveal".
  test "blind+active show page: non-entered member sees names only and subscribes only to reveal" do
    member = create(:user, club: @club, name: "Bystander", role: :member)
    post session_path, params: { email: member.email }
    get consume_session_path(token: SignInToken.last.token)

    species = create(:species, club: @club)
    t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
               blind_leaderboard: true)
    create(:scoring_slot, tournament: t, species: species, slot_count: 1)

    competitor = create(:user, club: @club, name: "Competitor")
    entry = create(:tournament_entry, tournament: t, name: "Sole Entry")
    create(:tournament_entry_member, tournament_entry: entry, user: competitor)
    catch_record = create(:catch, user: competitor, species: species, length_inches: 31.25)
    create(:catch_placement, catch: catch_record, tournament: t,
                              tournament_entry: entry, species: species, slot_index: 0)

    get tournament_path(t)
    assert_response :success
    assert_match "Sole Entry", response.body
    assert_no_match "31.25", response.body

    assert_match Turbo::StreamsChannel.signed_stream_name("tournament:#{t.id}:leaderboard:reveal"), response.body
    assert_no_match Regexp.new(Regexp.escape(Turbo::StreamsChannel.signed_stream_name("tournament:#{t.id}:leaderboard:full"))), response.body
    # No entry-stream subscription. We match the un-signed-name prefix encoded into the signed token's payload.
    # Since signed names don't surface plaintext, fall back to: any entry-stream signed name would change per entry id;
    # easiest invariant — assert there's no signed turbo-cable-stream-source that decodes to an entry stream.
    sources = response.body.scan(/signed-stream-name="([^"]+)"/).flatten
    decoded_names = sources.map do |signed|
      Turbo::StreamsChannel.send(:verifier).verified(signed) rescue nil
    end.compact
    assert decoded_names.none? { |n| n.start_with?("tournament:#{t.id}:leaderboard:entry:") },
      "Expected no entry-stream subscription, got: #{decoded_names.inspect}"
  end

  test "blind+active show page: judge sees full data" do
    judge = create(:user, club: @club, name: "Judge", role: :member)
    species = create(:species, club: @club)
    t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
               blind_leaderboard: true)
    create(:scoring_slot, tournament: t, species: species, slot_count: 1)
    create(:tournament_judge, tournament: t, user: judge)

    competitor = create(:user, club: @club, name: "Competitor")
    entry = create(:tournament_entry, tournament: t, name: "Some Entry")
    create(:tournament_entry_member, tournament_entry: entry, user: competitor)
    catch_record = create(:catch, user: competitor, species: species, length_inches: 31.25)
    create(:catch_placement, catch: catch_record, tournament: t,
                              tournament_entry: entry, species: species, slot_index: 0)

    post session_path, params: { email: judge.email }
    get consume_session_path(token: SignInToken.last.token)

    get tournament_path(t)
    assert_response :success
    assert_match "31.25", response.body
    assert_no_match "blind-leaderboard-banner", response.body
  end

  test "ended blind tournament show page: every viewer sees full leaderboard" do
    species = create(:species, club: @club)
    t = create(:tournament, club: @club, starts_at: 2.hours.ago, ends_at: 1.hour.ago,
               blind_leaderboard: true)
    create(:scoring_slot, tournament: t, species: species, slot_count: 1)

    competitor = create(:user, club: @club, name: "Competitor")
    entry = create(:tournament_entry, tournament: t, name: "Winning Entry")
    create(:tournament_entry_member, tournament_entry: entry, user: competitor)
    catch_record = create(:catch, user: competitor, species: species, length_inches: 31.25)
    create(:catch_placement, catch: catch_record, tournament: t,
                              tournament_entry: entry, species: species, slot_index: 0)

    get tournament_path(t)
    assert_response :success
    assert_match "31.25", response.body
    assert_no_match "blind-leaderboard-banner", response.body
  end

  test "non-blind tournament: every viewer subscribes to :full" do
    t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
               blind_leaderboard: false)
    get tournament_path(t)
    assert_response :success
    assert_match Turbo::StreamsChannel.signed_stream_name("tournament:#{t.id}:leaderboard:full"), response.body
    assert_no_match Regexp.new(Regexp.escape(Turbo::StreamsChannel.signed_stream_name("tournament:#{t.id}:leaderboard:reveal"))), response.body
  end

  # Merges: "ended solo tournament with entries renders angler count footer",
  # "active tournament does not render the participation footer", "ended
  # tournament with zero entries does not render participation footer".
  test "show: participation footer renders only for an ended tournament with entries" do
    species = create(:species, club: @club)

    ended_with_entries = create(:tournament, club: @club, mode: :solo,
               starts_at: 2.hours.ago, ends_at: 1.hour.ago)
    create(:scoring_slot, tournament: ended_with_entries, species: species, slot_count: 1)
    3.times do
      angler = create(:user, club: @club)
      entry  = create(:tournament_entry, tournament: ended_with_entries)
      create(:tournament_entry_member, tournament_entry: entry, user: angler)
    end
    get tournament_path(ended_with_entries)
    assert_response :success
    assert_match "3 anglers", response.body, "ended tournament with entries should show the footer"
    assert_no_match "team", response.body

    active = create(:tournament, club: @club, mode: :solo,
               starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    create(:scoring_slot, tournament: active, species: species, slot_count: 1)
    3.times do
      angler = create(:user, club: @club)
      entry  = create(:tournament_entry, tournament: active)
      create(:tournament_entry_member, tournament_entry: entry, user: angler)
    end
    get tournament_path(active)
    assert_response :success
    assert_no_match "anglers", response.body, "active tournament should not show the footer"

    ended_zero_entries = create(:tournament, club: @club, mode: :solo,
               starts_at: 2.hours.ago, ends_at: 1.hour.ago)
    create(:scoring_slot, tournament: ended_zero_entries, species: species, slot_count: 1)
    get tournament_path(ended_zero_entries)
    assert_response :success
    assert_no_match "anglers", response.body, "ended tournament with zero entries should not show the footer"
  end

  # Merges: "ended team tournament renders 'N anglers across M teams' footer"
  # and "ended team tournament lists member names under a custom team name".
  test "show: ended team tournament renders the angler/team count and lists member names under the custom team name" do
    species = create(:species, club: @club)
    t = create(:tournament, club: @club, mode: :team,
               starts_at: 2.hours.ago, ends_at: 1.hour.ago)
    create(:scoring_slot, tournament: t, species: species, slot_count: 1)

    # Named team: 2 anglers.
    entry = create(:tournament_entry, tournament: t, name: "Reel Deal")
    create(:tournament_entry_member, tournament_entry: entry,
                                      user: create(:user, club: @club, name: "Alice Angler"))
    create(:tournament_entry_member, tournament_entry: entry,
                                      user: create(:user, club: @club, name: "Bob Bobber"))
    # Second team: 3 anglers — 5 anglers across 2 teams overall.
    team2 = create(:tournament_entry, tournament: t)
    3.times do
      create(:tournament_entry_member, tournament_entry: team2, user: create(:user, club: @club))
    end

    get tournament_path(t)
    assert_response :success
    assert_match "5 anglers across 2 teams", response.body
    assert_match "Reel Deal", response.body
    assert_match "Alice Angler + Bob Bobber", response.body
  end

  # ---------------------------------------------------------------------------
  # Per-format leaderboard rendering.
  #
  # These were browser tests (test/system/<format>_tournament_test.rb) until
  # 2026-08-21. Nothing they asserted needed JS — every one of them seeded
  # catches through Catches::PlaceInSlots and then read the server-rendered
  # leaderboard — so they run here against the HTML instead. The format-select
  # and draft-format-switch behaviour that *did* need JS lives in
  # test/system/tournament_format_select_test.rb and
  # test/system/tournament_format_switch_test.rb.
  # ---------------------------------------------------------------------------

  test "big_fish_season leaderboard renders one row per catch, longest first, under a Length header" do
    walleye  = create(:species, club: @club, name: "Walleye")
    galen    = create(:user, club: @club, name: "Galen Patterson")
    galen_pc = create(:user, club: @club, name: "Galen PC")

    t = build(:tournament, club: @club, name: "Big Walleye Season", mode: :solo,
              format: :big_fish_season, starts_at: 1.hour.ago, ends_at: 1.day.from_now)
    t.save!(validate: false)
    create(:scoring_slot, tournament: t, species: walleye, slot_count: 3)
    t.reload

    enroll_user_in(t, user: galen)
    enroll_user_in(t, user: galen_pc)

    # Galen Patterson: 25", 21", 18". Galen PC: 22".
    [[galen, 25], [galen, 21], [galen, 18], [galen_pc, 22]].each do |angler, length|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: angler, species: walleye, length_inches: length,
                              captured_at_device: 30.minutes.ago)
      )
    end
    # PlaceInSlots silently no-ops when captured_at_device falls outside the
    # tournament window — fail loudly here rather than as a row-count mismatch.
    assert_equal 4, t.catch_placements.active.count

    get tournament_path(t)
    assert_response :success

    assert_select "#leaderboard th", text: "Length"
    assert_select "#leaderboard th", text: "Biggest", count: 0
    assert_select "#leaderboard th", text: "Total", count: 0

    rows = leaderboard_rows
    assert_equal 4, rows.size, "expected one row per placed catch"
    assert_match "Galen Patterson", rows[0]
    assert_match "25.00\"",         rows[0]
    assert_match "Galen PC",        rows[1]
    assert_match "22.00\"",         rows[1]
    assert_match "Galen Patterson", rows[2]
    assert_match "21.00\"",         rows[2]
    assert_match "Galen Patterson", rows[3]
    assert_match "18.00\"",         rows[3]
  end

  test "biggest_vs_smallest leaderboard renders a Spread column ranked by spread" do
    walleye  = create(:species, club: @club, name: "Walleye")
    angler_a = create(:user, club: @club, name: "Angler A")
    angler_b = create(:user, club: @club, name: "Angler B")

    t = build(:tournament, club: @club, name: "BvS Wed", format: :biggest_vs_smallest,
              mode: :solo, starts_at: 30.minutes.ago, ends_at: 30.minutes.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!

    enroll_user_in(t, user: angler_a)
    enroll_user_in(t, user: angler_b)

    # Angler A: 22, 12 -> spread 10. Angler B: 18, 14 -> spread 4.
    [[angler_a, 22, 20], [angler_a, 12, 10], [angler_b, 18, 15], [angler_b, 14, 5]].each do |angler, length, mins|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: angler, species: walleye, length_inches: length,
                              captured_at_device: mins.minutes.ago)
      )
    end

    get tournament_path(t)
    assert_response :success
    assert_select "#leaderboard th", text: "Spread"

    rows = leaderboard_rows
    assert_equal 2, rows.size, "expected 2 per-entry rows"
    assert_match "Angler A", rows.first, "expected Angler A (spread 10) on top"

    # The spread renders via format_length_parts (two separate <div>s), so
    # assert on each part rather than the joined format_length_dual string.
    inches_part, cm_part = format_length_parts(10)
    assert_match inches_part, rows.first
    assert_match cm_part,     rows.first
    assert_match "Biggest",   rows.first
    assert_match "Smallest",  rows.first
    assert_match format_length_dual(22, "inches"), rows.first
    assert_match format_length_dual(12, "inches"), rows.first
  end

  test "fish_train leaderboard renders the cars in order with a current badge on the last one" do
    perch   = create(:species, club: @club, name: "Perch")
    pike    = create(:species, club: @club, name: "Pike")
    walleye = create(:species, club: @club, name: "Walleye")
    angler_a = create(:user, club: @club, name: "Angler A")
    angler_b = create(:user, club: @club, name: "Angler B")

    t = build(:tournament, club: @club, name: "FT Wed", format: :fish_train, mode: :solo,
              starts_at: 30.minutes.ago, ends_at: 30.minutes.from_now,
              train_cars: [perch.id, pike.id, walleye.id, perch.id])
    [perch, pike, walleye].each { |sp| t.scoring_slots.build(species: sp, slot_count: 1) }
    t.save!

    enroll_user_in(t, user: angler_a)
    enroll_user_in(t, user: angler_b)

    # Angler A: full 4-car train, sum 12+22+18+14 = 66.
    # Angler B: stalls at car 1 (perch) — larger perch replaces smaller. Sum 17.
    [
      [angler_a, perch,   12, 25], [angler_a, pike,    22, 20],
      [angler_a, walleye, 18, 15], [angler_a, perch,   14, 10],
      [angler_b, perch,   16, 24], [angler_b, perch,   17, 18]
    ].each do |angler, species, length, mins|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: angler, species: species, length_inches: length,
                              captured_at_device: mins.minutes.ago)
      )
    end

    get tournament_path(t)
    assert_response :success

    rows = leaderboard_rows
    assert_equal 2, rows.size
    assert_match "Angler A", rows.first
    inches_part, cm_part = format_length_parts(66)
    assert_match inches_part, rows.first
    assert_match cm_part,     rows.first
    assert_match "Perch",     rows.first
    assert_match "Pike",      rows.first
    assert_match "Walleye",   rows.first
    assert_match(/current/i, rows.first, "last (most-recent) car should be tagged 'current'")
  end

  test "hidden_length leaderboard renders per-catch rows before the roll and per-entry rows after" do
    walleye  = create(:species, club: @club, name: "Walleye")
    angler_a = create(:user, club: @club, name: "Angler A")
    angler_b = create(:user, club: @club, name: "Angler B")

    t = build(:tournament, club: @club, name: "HL Wed", format: :hidden_length, mode: :solo,
              starts_at: 30.minutes.ago, ends_at: 5.minutes.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!

    enroll_user_in(t, user: angler_a)
    enroll_user_in(t, user: angler_b)

    catches_data = [[angler_a, 22, 20], [angler_a, 17.5, 10], [angler_b, 14, 15], [angler_b, 19, 5]]
    catches_data.each do |angler, length, mins|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: angler, species: walleye, length_inches: length,
                              captured_at_device: mins.minutes.ago)
      )
    end

    get tournament_path(t)
    assert_response :success
    assert_equal 4, leaderboard_rows.size, "expected 4 per-catch rows pre-reveal"
    assert_match "22", leaderboard_rows.first
    assert_match "Target rolls when the tournament ends", response.body

    # Travel past ends_at and run the lifecycle job, which rolls the target.
    t.update_columns(ends_at: 1.minute.ago)
    TournamentLifecycleAnnounceJob.perform_now(tournament_id: t.id, kind: "ended")
    t.reload
    assert_not_nil t.hidden_length_target
    target = t.hidden_length_target

    get tournament_path(t)
    assert_response :success
    assert_match "Target was", response.body
    # Pin to the helper output so a typography change in format_length_dual
    # is caught here rather than silently flipping the substring match.
    assert_select "#hidden-length-banner", text: /#{Regexp.escape(format_length_dual(target))}/

    rows = leaderboard_rows
    assert_equal 2, rows.size, "expected 2 per-entry rows post-reveal"

    # Each angler's qualifying catch is the closest to the target; ties break to
    # the earliest captured_at_device, per club rule.
    expected_winner = catches_data
      .group_by { |angler, _length, _mins| angler }
      .values
      .map { |for_angler| for_angler.min_by { |_a, length, mins| [(length - target.to_f).abs, -mins] } }
      .min_by { |_a, length, mins| [(length - target.to_f).abs, -mins] }
      .first.name
    assert_match expected_winner, rows.first
  end

  test "progressive_length leaderboard ranks by up-sizes and renders the ladder smallest-first" do
    walleye  = create(:species, club: @club, name: "Walleye")
    angler_a = create(:user, club: @club, name: "Angler A")
    angler_b = create(:user, club: @club, name: "Angler B")

    t = build(:tournament, club: @club, name: "Progressive Thu", format: :progressive_length,
              mode: :solo, starts_at: 3.hours.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 1)
    t.save!

    # Angler B's entry is created first so it gets the LOWER id, while Angler A
    # (the correct winner by up-sizes) gets the HIGHER id. That makes the
    # ranker's id-asc tiebreak fight the correct ordering, so a regression that
    # dropped the up-sizes/race/top-rung sort keys surfaces B first and fails.
    enroll_user_in(t, user: angler_b)
    enroll_user_in(t, user: angler_a)

    # Angler A climbs 12 -> 15 -> 18 (2 up-sizes). The 10" is a silent no-op.
    [[12, 150], [10, 140], [15, 120], [18, 100]].each do |length, mins|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: angler_a, species: walleye, length_inches: length,
                              captured_at_device: mins.minutes.ago),
        broadcast: false
      )
    end
    # Angler B climbs 20 -> 22 (1 up-size) — bigger fish, fewer up-sizes.
    [[20, 150], [22, 120]].each do |length, mins|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: angler_b, species: walleye, length_inches: length,
                              captured_at_device: mins.minutes.ago),
        broadcast: false
      )
    end

    get tournament_path(t)
    assert_response :success
    assert_select "#leaderboard th", text: "Up-sizes"
    assert_match "most up-sizes of walleye", response.body
    assert_no_match "Largest walleye", response.body

    rows = leaderboard_rows
    assert_match "Angler A",   rows[0]
    assert_match "2 up-sizes", rows[0]
    assert_match "Angler B",   rows[1]
    assert_match "1 up-size",  rows[1]

    # The ladder renders smallest-first and the 10" no-op never appears.
    assert_no_match(/10"/, rows[0])
    assert_operator rows[0].index('12"'), :<, rows[0].index('15"'),
                    "ladder must render smallest-first: 12\" before 15\""
    assert_operator rows[0].index('15"'), :<, rows[0].index('18"'),
                    "ladder must render smallest-first: 15\" before 18\""
  end

  test "smallest_fish leaderboard ranks by lowest total under the standard Total header" do
    walleye  = create(:species, club: @club, name: "Walleye")
    angler_a = create(:user, club: @club, name: "Angler A")
    angler_b = create(:user, club: @club, name: "Angler B")

    t = build(:tournament, club: @club, name: "Smallest Wed", format: :smallest_fish,
              mode: :solo, starts_at: 30.minutes.ago, ends_at: 30.minutes.from_now)
    t.scoring_slots.build(species: walleye, slot_count: 2)
    t.save!

    enroll_user_in(t, user: angler_a)
    enroll_user_in(t, user: angler_b)

    # Angler A: 12, 10 -> total 22. Angler B: 9, 8 -> total 17 (lower wins).
    [[angler_a, 12, 20], [angler_a, 10, 10], [angler_b, 9, 15], [angler_b, 8, 5]].each do |angler, length, mins|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: angler, species: walleye, length_inches: length,
                              captured_at_device: mins.minutes.ago)
      )
    end

    get tournament_path(t)
    assert_response :success
    assert_select "#leaderboard th", text: "Total"

    rows = leaderboard_rows
    assert_equal 2, rows.size, "expected 2 per-entry rows"
    assert_match "Angler B", rows.first, "expected Angler B (total 17) on top"

    inches_part, cm_part = format_length_parts(17)
    assert_match inches_part, rows.first
    assert_match cm_part,     rows.first
    assert_match format_length_dual(8, "inches"), rows.first
    assert_match format_length_dual(9, "inches"), rows.first
  end

  test "tagged leaderboard renders a ticket count per angler and the drawn winner" do
    tagged = Species.find_or_create_by!(name: "Tagged Walleye")
    angler = create(:user, club: @club, name: "Tagged Angler")

    t = build(:tournament, club: @club, name: "Test Tagged", format: :tagged, mode: :solo,
              starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    t.scoring_slots.build(species: tagged, slot_count: 1)
    t.save!
    enroll_user_in(t, user: angler)

    %w[A0001 A0002].each do |tag|
      Catches::PlaceInSlots.call(
        catch: create(:catch, user: angler, species: tagged, length_inches: 18.0,
                              tag_number: tag, captured_at_device: 30.minutes.ago)
      )
    end

    get tournament_path(t)
    assert_response :success
    rows = leaderboard_rows
    assert_equal 1, rows.size
    assert_match "Tagged Angler", rows.first
    # Scope the ticket count to its own cell — the row also contains "A0002".
    assert_select "#leaderboard tbody tr td.font-mono", text: "2"
    assert_match "A0001", rows.first
    assert_match "A0002", rows.first

    # After the draw, the winner banner renders above the table.
    t.update_columns(starts_at: 2.hours.ago, ends_at: 1.hour.ago)
    Tournaments::DrawTaggedWinner.call(tournament: t.reload, drawn_by: @user)

    get tournament_path(t)
    assert_response :success
    assert_select "#leaderboard", text: /Winner/
    assert_match "Tagged Angler", response.body
  end
end
