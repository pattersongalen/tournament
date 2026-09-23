require "test_helper"

class Judges::CatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    @walleye = create(:species, club: @club)
    create(:scoring_slot, tournament: @t, species: @walleye, slot_count: 1)
    @judge = create(:user, club: @club)
    create(:tournament_judge, tournament: @t, user: @judge)

    angler = create(:user, club: @club)
    entry = create(:tournament_entry, tournament: @t)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)
    @needs_review = create(:catch, user: angler, species: @walleye, length_inches: 20, status: :needs_review)
    @synced       = create(:catch, user: angler, species: @walleye, length_inches: 18, status: :synced)
    Catches::PlaceInSlots.call(catch: @synced)

    sign_in_as(@judge)
  end

  test "index lists all catches with needs_review pinned" do
    get judges_tournament_catches_path(tournament_id: @t.id)
    assert_response :success
    body = response.body
    needs_review_marker = "<td>#{@needs_review.id}</td>"
    synced_marker       = "<td>#{@synced.id}</td>"
    assert_includes body, needs_review_marker
    assert_includes body, synced_marker
    assert body.index(needs_review_marker) < body.index(synced_marker),
           "needs_review should come before synced in the listing"
  end

  test "index eager-loads judge_actions instead of N+1 per row" do
    # Several approved catches, each carrying a judge_action the index renders
    # via latest_approver in the flag_badges partial.
    angler = create(:user, club: @club)
    entry = create(:tournament_entry, tournament: @t)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)
    3.times do |i|
      c = create(:catch, user: angler, species: @walleye, length_inches: 15 + i,
                         status: :synced, flags: ["clock_skew"])
      Catches::PlaceInSlots.call(catch: c)
      create(:judge_action, catch: c, judge_user: @judge, action: :approve)
    end

    judge_action_queries = count_queries(/\bfrom\s+"?judge_actions"?/i) do
      get judges_tournament_catches_path(tournament_id: @t.id)
    end
    assert_response :success
    assert_operator judge_action_queries, :<=, 1,
                    "expected judge_actions to be eager-loaded in one query, got #{judge_action_queries}"
  end

  # Merges: "non-judge sees forbidden", "organizer can review catches in
  # friendly tournament", "organizer cannot review catches in judged
  # tournament unless they are a judge", "organizer from another club cannot
  # review catches", "site admin (not assigned judge) can view the judge
  # catch page". Row 3 flips @t to judged: true — it runs after the
  # friendly-tournament row, and no later row depends on @t being friendly;
  # the site-admin row (5) runs against the now-judged @t, which is fine
  # since require_reviewer! admits site admins regardless of judged/friendly.
  test "access to the judge review pages by role" do
    rows = [
      ["non-judge member",
       -> { sign_in_as(create(:user, club: @club)) },
       -> { judges_tournament_catches_path(tournament_id: @t.id) }, :forbidden],
      ["organizer, friendly tournament",
       -> { sign_in_as(create(:user, club: @club, role: :organizer)) },
       -> { judges_tournament_catches_path(tournament_id: @t.id) }, :success],
      ["organizer, judged tournament (not a judge)",
       -> { @t.update!(judged: true); sign_in_as(create(:user, club: @club, role: :organizer)) },
       -> { judges_tournament_catches_path(tournament_id: @t.id) }, :forbidden],
      ["organizer from another club",
       -> { sign_in_as(create(:user, club: create(:club), role: :organizer)) },
       -> { judges_tournament_catches_path(tournament_id: @t.id) }, :not_found],
      ["site admin (not assigned judge)",
       -> { sign_in_as(create(:user, club: @club, admin: true)) },
       -> { judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id) }, :success]
    ]

    rows.each do |label, setup, path, expected|
      setup.call
      get path.call
      assert_response expected, label
    end
  end

  test "show renders styled action buttons (color-coded by action)" do
    get judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id)
    assert_response :success
    assert_select "button[value=approve][class*='bg-emerald']"
    assert_select "button[value=flag][class*='bg-amber']"
    assert_select "button[value=disqualify][class*='bg-red']"
    assert_select "button[value=dock_verify][class*='bg-']"
  end

  # Merges: "GET show on a catch from another tournament is not found" and
  # "index does not list catches from other tournaments".
  test "catches from another tournament are unreachable: 404 on show, excluded from index" do
    foreign_catch = create_foreign_synced_catch

    get judges_tournament_catch_path(tournament_id: @t.id, id: foreign_catch.id)
    assert_response :not_found

    get judges_tournament_catches_path(tournament_id: @t.id)
    assert_response :success
    assert_not_includes response.body, "<td>#{foreign_catch.id}</td>"
  end

  test "judge page shows the reference photo and the angler's original, both labelled (no longer staff-only)" do
    @needs_review.photo.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample_walleye.jpg")),
      filename: "original.jpg", content_type: "image/jpeg"
    )
    @needs_review.reference_photo.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample_walleye.jpg")),
      filename: "reference.jpg", content_type: "image/jpeg"
    )

    get judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id)
    assert_response :success
    # Both photos are now shown to everyone, each labelled — not staff-only.
    assert_select "img", { minimum: 2 }
    assert_match "Reference photo", response.body
    assert_match "Original photo", response.body
    refute_match(/staff only/i, response.body)
    refute_match(/Original submission/i, response.body)
  end

  # Merges: "judge page reference-photo form posts to the shared catch route
  # (admin)" and "non-admin judge does not see the reference-photo form".
  test "reference-photo form: shown to a site-admin judge, hidden from a non-admin judge" do
    admin = create(:user, club: @club, admin: true)
    create(:tournament_judge, tournament: @t, user: admin)
    sign_in_as(admin)

    get judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id)
    assert_response :success
    # Reference photos are no longer tournament-scoped: the form points at the
    # canonical /catches/:id/reference_photo route (PATCH via _method override).
    assert_select "form[action=?]", reference_photo_catch_path(@needs_review) do
      assert_select "input[name=_method][value=patch]", 1
    end

    sign_in_as(@judge) # a judge, but not a site admin
    get judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id)
    assert_response :success
    assert_select "form[action=?]", reference_photo_catch_path(@needs_review), count: 0
  end

  test "judge can geofence_override an out-of-province catch into the slots" do
    angler = create(:user, club: @club)
    entry = create(:tournament_entry, tournament: @t)
    create(:tournament_entry_member, tournament_entry: entry, user: angler)
    oop = create(:catch, user: angler, species: @walleye, length_inches: 30,
                         latitude: 49.9, longitude: -97.1, status: :needs_review)
    Catches::PlaceInSlots.call(catch: oop)

    patch geofence_override_judges_tournament_catch_path(tournament_id: @t.id, id: oop.id),
          params: { override_in_lake: "1", override_in_sask: "1" }
    assert_redirected_to judges_tournament_catch_path(tournament_id: @t.id, id: oop.id)
    assert_equal 1, oop.reload.catch_placements.active.count
  end

  # Merges: "plain member is forbidden from geofence_override" and "non-admin
  # judge is forbidden from correct_location".
  test "geofence_override forbidden for a plain member; correct_location forbidden for a non-admin judge" do
    member = create(:user, club: @club)
    sign_in_as(member)
    patch geofence_override_judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id),
          params: { override_in_sask: "1" }
    assert_response :forbidden

    sign_in_as(@judge) # a judge, but not a site admin
    patch correct_location_judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id),
          params: { latitude: "53.55", longitude: "-103.65" }
    assert_response :forbidden
  end

  # Merges: "site admin can correct_location even when not an assigned judge"
  # and "GPS editor section is rendered for site admins only".
  test "admin: can correct_location though not an assigned judge, and only admins see the GPS editor" do
    # Non-admin judge: no editor.
    get judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id)
    assert_select "[data-controller='location-edit']", count: 0

    admin = create(:user, club: @club, admin: true)
    sign_in_as(admin) # not an assigned judge
    patch correct_location_judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id),
          params: { latitude: "53.55", longitude: "-103.65" }
    assert_redirected_to judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id)
    assert_in_delta 53.55, @needs_review.reload.latitude.to_f, 0.001

    get judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id)
    assert_select "[data-controller='location-edit']"
    assert_select "input[type=submit][value=?]", "Save corrected location"
  end

  # Merges: "judge can reinstate a disqualified catch", "reinstate on a
  # non-disqualified catch redirects with an alert", "show renders a
  # reinstate button only for disqualified catches".
  test "reinstate: works on a disqualified catch, alerts on a non-disqualified one, button shows only when disqualified" do
    # Button hidden before DQ.
    get judges_tournament_catch_path(tournament_id: @t.id, id: @synced.id)
    assert_select "input[type=submit][value=?]", "Reinstate catch", count: 0

    # Reinstating a non-disqualified catch is a no-op with an alert.
    patch reinstate_judges_tournament_catch_path(tournament_id: @t.id, id: @synced.id)
    assert_redirected_to judges_tournament_catch_path(tournament_id: @t.id, id: @synced.id)
    assert_match(/disqualified/i, flash[:alert])

    # DQ it, then the button shows and a reinstate actually clears it.
    Catches::ApplyJudgeAction.call(tournament: @t, catch: @synced, judge: @judge, action: :disqualify, note: "dq")
    get judges_tournament_catch_path(tournament_id: @t.id, id: @synced.id)
    assert_select "input[type=submit][value=?]", "Reinstate catch"

    patch reinstate_judges_tournament_catch_path(tournament_id: @t.id, id: @synced.id)
    assert_redirected_to judges_tournament_catch_path(tournament_id: @t.id, id: @synced.id)
    assert_not @synced.reload.disqualified?
  end

  # --- Task 7: geofence-override + reinstate UI -------------------------------

  test "show renders the geofence override checkboxes reflecting current state" do
    @needs_review.update!(override_in_sask: true)
    get judges_tournament_catch_path(tournament_id: @t.id, id: @needs_review.id)
    assert_response :success
    assert_select "input[type=checkbox][name=override_in_lake]"
    assert_select "input[type=checkbox][name=override_in_sask][checked=checked]"
  end

  # --- Task 8: admin GPS map editor ------------------------------------------
  # (GPS editor coverage merged above into the "admin: can correct_location…"
  # test.)

  # Merges: "index reaches an entrant's clean catch on a bingo tournament (no
  # placements)", "show reaches an entrant's clean catch on a bingo
  # tournament (no placements)", "index shows review-only flags to a
  # dedicated judge on a bingo tournament". Bingo keeps no CatchPlacement
  # rows, so a clean (unflagged) entrant catch is neither placed nor in the
  # needs_review queue, and the placement-based can_review_catch? check can't
  # connect a dedicated (non-organizer) judge to it — the entrant/window
  # fallback must surface it (and its review-only flags) on both index and show.
  test "bingo tournament: judge reaches an entrant's clean catch (no placements) via index and show, including review-only flags" do
    bingo, judge, clean = bingo_tournament_with_clean_catch
    clean.update!(flags: %w[screenshot_suspect])
    sign_in_as(judge)

    get judges_tournament_catches_path(tournament_id: bingo.id)
    assert_response :success
    assert_includes response.body, "<td>#{clean.id}</td>",
                     "a bingo entrant's clean catch should appear in the judge queue"
    assert_includes response.body, "possible screenshot",
                     "a dedicated judge must see the review-only flag on a bingo entrant's catch"

    get judges_tournament_catch_path(tournament_id: bingo.id, id: clean.id)
    assert_response :success
  end

  private

  # A bingo tournament with an assigned judge and one entrant whose synced,
  # unflagged catch falls inside the window. Returns [tournament, judge, catch].
  def bingo_tournament_with_clean_catch
    create_bingo_species!
    bingo = Tournament.create!(club: @club, name: "Bingo Night", mode: :solo, format: :bingo,
                               starts_at: 2.hours.ago, ends_at: 2.hours.from_now)
    judge = create(:user, club: @club)
    create(:tournament_judge, tournament: bingo, user: judge)
    angler = create(:user, club: @club)
    entry = bingo.tournament_entries.create!
    entry.tournament_entry_members.create!(user: angler)
    clean = create(:catch, user: angler, species: @walleye, length_inches: 15,
                   captured_at_device: 1.hour.ago, status: :synced)
    [bingo, judge, clean]
  end

  def create_foreign_synced_catch
    other_t = create(:tournament, club: @club, starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
    other_angler = create(:user, club: @club)
    other_entry = create(:tournament_entry, tournament: other_t)
    create(:tournament_entry_member, tournament_entry: other_entry, user: other_angler)
    create(:scoring_slot, tournament: other_t, species: @walleye, slot_count: 1)
    foreign_catch = create(:catch, user: other_angler, species: @walleye, length_inches: 21, status: :synced)
    Catches::PlaceInSlots.call(catch: foreign_catch)
    foreign_catch
  end

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
