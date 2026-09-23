require "test_helper"

class Admin::RulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @member = create(:user, club: @club, role: :member)
  end

  test "index requires organizer role" do
    sign_in_as(@member)
    get admin_rules_path
    assert_response :forbidden
  end

  test "organizer can view the index" do
    sign_in_as(@organizer)
    get admin_rules_path
    assert_response :success
  end

  test "set_active_season flips the club's active season" do
    sign_in_as(@organizer)
    assert @club.reload.active_rules_season_open_water?

    post set_active_season_admin_rules_path, params: { season: "ice" }
    assert_redirected_to admin_rules_path
    assert @club.reload.active_rules_season_ice?
  end

  test "set_active_season rejects unknown season values" do
    sign_in_as(@organizer)
    post set_active_season_admin_rules_path, params: { season: "summer" }
    assert_response :unprocessable_entity
    assert @club.reload.active_rules_season_open_water?
  end

  test "new renders the form for the requested season" do
    sign_in_as(@organizer)
    get new_admin_rule_path(season: "ice")
    assert_response :success
    assert_match "Ice rules", response.body
  end

  test "create appends a new revision with the submitter as editor" do
    sign_in_as(@organizer)
    assert_difference "ClubRulesRevision.count", 1 do
      post admin_rules_path, params: {
        club_rules_revision: { season: "open_water", body: "<h1>Hello</h1>" }
      }
    end
    rev = ClubRulesRevision.order(:id).last
    assert_equal @organizer, rev.edited_by_user
    assert_equal @club, rev.club
    assert rev.season_open_water?
    assert_includes rev.body.to_s, "<h1>Hello</h1>"
    assert_redirected_to admin_rules_path
  end

  test "create rejects unknown season values" do
    sign_in_as(@organizer)
    assert_no_difference "ClubRulesRevision.count" do
      post admin_rules_path, params: {
        club_rules_revision: { season: "summer", body: "<div>x</div>" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create with another club's club_id param still scopes to current_club" do
    other_club = create(:club)
    sign_in_as(@organizer)
    post admin_rules_path, params: {
      club_rules_revision: { club_id: other_club.id, season: "open_water", body: "<div>hi</div>" }
    }
    rev = ClubRulesRevision.order(:id).last
    assert_equal @club, rev.club, "must ignore client-provided club_id"
  end

  test "create rejects blank body" do
    sign_in_as(@organizer)
    assert_no_difference "ClubRulesRevision.count" do
      post admin_rules_path, params: {
        club_rules_revision: { season: "open_water", body: "" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create does not modify any prior revision" do
    prior = create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                         season: :open_water, body: "<div>ORIGINAL</div>")
    sign_in_as(@organizer)
    post admin_rules_path, params: {
      club_rules_revision: { season: "open_water", body: "<div>REPLACEMENT</div>" }
    }
    assert_includes prior.reload.body.to_s, "ORIGINAL"
  end

  test "history lists revisions for the requested season most recent first" do
    older = create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                         season: :open_water, body: "<div>OLDER</div>",
                                         created_at: 2.days.ago)
    newer = create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                         season: :open_water, body: "<div>NEWER</div>",
                                         created_at: 1.day.ago)
    unrelated = create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                             season: :ice, body: "<div>ICE</div>")
    sign_in_as(@organizer)
    get history_admin_rules_path(season: "open_water")
    assert_response :success
    body = response.body
    assert_match "NEWER", body
    assert_match "OLDER", body
    assert_no_match "ICE", body
    assert body.index("NEWER") < body.index("OLDER"), "newer should appear before older"
  end

  test "show renders a single past revision" do
    rev = create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                       season: :open_water, body: "<h1>Specific revision body</h1>")
    sign_in_as(@organizer)
    get admin_rule_path(rev)
    assert_response :success
    assert_match "Specific revision body", response.body
  end

  test "show 404s for a revision in another club" do
    other_club = create(:club)
    other_user = create(:user, club: other_club)
    rev = create(:club_rules_revision, club: other_club, edited_by_user: other_user,
                                       season: :open_water, body: "<div>x</div>")
    sign_in_as(@organizer)
    get admin_rule_path(rev)
    assert_response :not_found
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
