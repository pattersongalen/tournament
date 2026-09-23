require "test_helper"

class Tournaments::CatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @walleye = create(:species, club: @club)
    @member = create(:user, club: @club, name: "Member M", role: :member)
    @other  = create(:user, club: @club, name: "Other O", role: :member)

    @tournament = create(:tournament, club: @club,
                         starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                         blind_leaderboard: false)
    create(:scoring_slot, tournament: @tournament, species: @walleye, slot_count: 1)

    entry = create(:tournament_entry, tournament: @tournament, name: "Other Boat")
    create(:tournament_entry_member, tournament_entry: entry, user: @other)

    @catch = create(:catch, user: @other, species: @walleye, length_inches: 22.5,
                            captured_at_device: 30.minutes.ago)
    create(:catch_placement, catch: @catch, tournament: @tournament,
                              tournament_entry: entry, species: @walleye, slot_index: 0)
  end

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  test "signed-in member sees photo, species, length, angler, date for non-blind tournament with active placement" do
    sign_in_as(@member)

    get tournament_catch_path(@tournament, @catch)

    assert_response :ok
    body = @response.body
    assert_match %r{<img[^>]*src=["'][^"']*active_storage[^"']*}, body, "should include an Active Storage image"
    assert_match @walleye.name, body
    assert_match "22.5", body, "length in inches should be present"
    assert_match @other.name, body, "angler name should be present"
    refute_match "Notes (private)", body, "no notes field on the modal"
    refute_match "GPS:", body, "no GPS coordinates on the modal"
  end

  test "modal shows both the reference photo and the angler's original, labelled, to a regular member" do
    @catch.reference_photo.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample_walleye.jpg")),
      filename: "reference.jpg", content_type: "image/jpeg"
    )
    sign_in_as(@member)

    get tournament_catch_path(@tournament, @catch)

    assert_response :ok
    body = @response.body
    assert_select "img", minimum: 2
    assert_match "Reference photo", body, "members should see the admin reference photo labelled"
    assert_match "Original photo", body, "members should still see the angler's original labelled"
  end

  test "a blind tournament's catch modal is 404 while active, opens after ends_at" do
    blind = create(:tournament, club: @club,
                   starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                   blind_leaderboard: true)
    create(:scoring_slot, tournament: blind, species: @walleye, slot_count: 1)
    blind_entry = create(:tournament_entry, tournament: blind, name: "Other Blind")
    create(:tournament_entry_member, tournament_entry: blind_entry, user: @other)
    blind_catch = create(:catch, user: @other, species: @walleye, length_inches: 18.0,
                                  captured_at_device: 15.minutes.ago)
    create(:catch_placement, catch: blind_catch, tournament: blind,
                              tournament_entry: blind_entry, species: @walleye, slot_index: 0)

    sign_in_as(@member)
    get tournament_catch_path(blind, blind_catch)
    assert_response :not_found, "active blind tournament: 404 even though the member would otherwise have access"

    ended_blind = create(:tournament, club: @club,
                         starts_at: 2.hours.ago, ends_at: 1.hour.ago,
                         blind_leaderboard: true)
    create(:scoring_slot, tournament: ended_blind, species: @walleye, slot_count: 1)
    e = create(:tournament_entry, tournament: ended_blind, name: "Ended Blind Entry")
    create(:tournament_entry_member, tournament_entry: e, user: @other)
    c = create(:catch, user: @other, species: @walleye, length_inches: 19.0,
                       captured_at_device: 90.minutes.ago)
    create(:catch_placement, catch: c, tournament: ended_blind,
                              tournament_entry: e, species: @walleye, slot_index: 0)

    get tournament_catch_path(ended_blind, c)
    assert_response :ok, "ended blind tournament: gate opens after ends_at"
    body = @response.body
    assert_match %r{<img[^>]*src=["'][^"']*active_storage[^"']*}, body, "should include the photo"
    assert_match @walleye.name, body
    assert_match "19&quot; / 48.26 cm", body
    assert_match @other.name, body
  end

  test "returns 404 for a catch with no active placement in this tournament, or for a member of a different club" do
    {
      "no active placement in this tournament" => -> {
        other_tournament = create(:tournament, club: @club,
                                  starts_at: 1.hour.ago, ends_at: 1.hour.from_now,
                                  blind_leaderboard: false)
        create(:scoring_slot, tournament: other_tournament, species: @walleye, slot_count: 1)
        sign_in_as(@member)
        get tournament_catch_path(other_tournament, @catch)
      },
      "member of a different club" => -> {
        other_club = create(:club)
        create(:species, club: other_club)
        outsider = create(:user, club: other_club, name: "Outsider X", role: :member)
        sign_in_as(outsider)
        get tournament_catch_path(@tournament, @catch)
      }
    }.each do |label, block|
      block.call
      assert_response :not_found, label
    end
  end

  # Downgraded from test/system/tournament_catch_photo_test.rb: "member sees fish as
  # plain text (not a link) on a blind tournament leaderboard" and "organizer link
  # still goes to full /catches/:id (no Turbo Frame)".
  test "leaderboard photo link targets: organizer gets the full catch page, an active-blind member's own fish gets no link" do
    organizer = create(:user, club: @club, name: "Org O", role: :organizer)
    sign_in_as(organizer)

    get tournament_path(@tournament)

    assert_response :success
    assert_select "a[href=?]", catch_path(@catch, t: @tournament.id)
    assert_select "#leaderboard a[data-turbo-frame]", false,
      "organizer should link straight to /catches/:id, not the framed tournament_catch_path"

    blind = create(:tournament, club: @club,
                   starts_at: 1.hour.ago, ends_at: 1.hour.from_now, blind_leaderboard: true)
    create(:scoring_slot, tournament: blind, species: @walleye, slot_count: 1)
    entry = create(:tournament_entry, tournament: blind, name: "My Boat")
    create(:tournament_entry_member, tournament_entry: entry, user: @member)
    my_catch = create(:catch, user: @member, species: @walleye, length_inches: 19.0,
                              captured_at_device: 30.minutes.ago)
    create(:catch_placement, catch: my_catch, tournament: blind,
                              tournament_entry: entry, species: @walleye, slot_index: 0)

    sign_in_as(@member)
    get tournament_path(blind)

    assert_response :success
    assert_match(/#{Regexp.escape(@walleye.name)}.*19/, response.body)
    assert_select "a[href=?]", tournament_catch_path(blind, my_catch), false,
      "an active blind tournament should render the member's own fish as plain text, not a link"
  end

  test "entrants_only tournament: 404 for a non-entered member while active, 200 for an entered member, 200 for anyone once ended" do
    {
      "active, not entered" => -> {
        @tournament.update!(entrants_only_leaderboard: true)
        sign_in_as(@member)
        get tournament_catch_path(@tournament, @catch)
        assert_response :not_found, "active, not entered"
      },
      "active, entered" => -> {
        @tournament.update!(entrants_only_leaderboard: true)
        sign_in_as(@other)
        get tournament_catch_path(@tournament, @catch)
        assert_response :ok, "active, entered"
      },
      "ended, not entered" => -> {
        @tournament.update!(starts_at: 2.hours.ago, ends_at: 10.minutes.ago,
                            entrants_only_leaderboard: true)
        sign_in_as(@member)
        get tournament_catch_path(@tournament, @catch)
        assert_response :ok, "ended, not entered"
      }
    }.each { |_label, block| block.call }
  end
end
