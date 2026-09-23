require "test_helper"

class RulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @member = create(:user, club: @club, role: :member)
    @organizer = create(:user, club: @club, role: :organizer)
  end

  test "shows the active season's latest revision body, switching with the club's active season" do
    {
      "default (open water) season shows the open-water body" => -> (label) {
        create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                     season: :open_water, body: "<h1>Open water</h1><ul><li>No live bait</li></ul>")
        sign_in_as(@member)
        get rules_path
        assert_response :success, label
        assert_match "Open water", response.body, label
        assert_match "No live bait", response.body, label
      },
      "active_rules_season: ice shows the ice body, not open water" => -> (label) {
        create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                     season: :open_water, body: "<div>OPEN WATER BODY</div>")
        create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                     season: :ice, body: "<div>ICE BODY</div>")
        @club.update!(active_rules_season: :ice)
        sign_in_as(@member)
        get rules_path
        assert_match "ICE BODY", response.body, label
        assert_no_match "OPEN WATER BODY", response.body, label
      }
    }.each do |label, block|
      @club = create(:club)
      @member = create(:user, club: @club, role: :member)
      @organizer = create(:user, club: @club, role: :organizer)
      block.call(label)
    end
  end

  test "shows empty-state when no revision exists for active season" do
    sign_in_as(@member)
    get rules_path
    assert_response :success
    assert_match "No rules published yet.", response.body
  end

  test "shows the editor name only for organizer viewers" do
    create(:club_rules_revision, club: @club, edited_by_user: @organizer,
                                 season: :open_water, body: "<div>rules</div>")
    sign_in_as(@organizer)
    get rules_path
    assert_match @organizer.name, response.body

    sign_in_as(@member)
    get rules_path
    assert_no_match @organizer.name, response.body
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
