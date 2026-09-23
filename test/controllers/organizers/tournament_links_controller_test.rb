require "test_helper"

class Organizers::TournamentLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @club = create(:club)
    @organizer = create(:user, club: @club, role: :organizer)
    @member = create(:user, club: @club, name: "Kurtis Sanguin", role: :member)
    @main = create(:tournament, club: @club, mode: :team, name: "Main",
                   starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    @side = create(:tournament, club: @club, mode: :team, name: "Side",
                   starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    sign_in_as(@organizer)
  end

  test "linking puts both tournaments in one group" do
    post link_organizers_tournament_path(@main), params: { linked_tournament_id: @side.id }
    assert_equal @main.reload.link_group_id, @side.reload.link_group_id
    assert @main.link_group_id.present?
    assert_equal [@side], @main.linked_tournaments
  end

  test "linking back-fills entries that already exist on either side" do
    existing = create(:tournament_entry, tournament: @main, name: "Majestic Red")
    existing.tournament_entry_members.create!(user: @member)

    post link_organizers_tournament_path(@main), params: { linked_tournament_id: @side.id }

    mirrored = @side.tournament_entries.sole
    assert_equal "Majestic Red", mirrored.name
    assert_equal [@member], mirrored.users
  end

  test "a solo tournament can't be linked" do
    solo = create(:tournament, club: @club, mode: :solo,
                  starts_at: 1.hour.from_now, ends_at: 4.hours.from_now)
    post link_organizers_tournament_path(@main), params: { linked_tournament_id: solo.id }
    assert_nil @main.reload.link_group_id
    assert_equal "Only team tournaments can be linked.", flash[:alert]
  end

  test "unlinking clears the group without deleting entries" do
    post link_organizers_tournament_path(@main), params: { linked_tournament_id: @side.id }
    create(:tournament_entry, tournament: @side, name: "Stratos")

    delete link_organizers_tournament_path(@main)

    assert_nil @main.reload.link_group_id
    assert_nil @side.reload.link_group_id
    assert_equal 1, @side.tournament_entries.count
  end

  test "members are forbidden" do
    sign_in_as(@member)
    post link_organizers_tournament_path(@main), params: { linked_tournament_id: @side.id }
    assert_response :forbidden
  end

  test "a link attempt that hits a back-fill RecordInvalid redirects with an alert instead of raising" do
    # The member judges the Side tournament, so back-filling their crewed Main
    # entry into Side via TournamentEntryMember validation is rejected — the
    # link action must catch that and redirect rather than 500.
    create(:tournament_judge, tournament: @side, user: @member)
    entry = create(:tournament_entry, tournament: @main, name: "Majestic Red")
    entry.tournament_entry_members.create!(user: @member)

    post link_organizers_tournament_path(@main), params: { linked_tournament_id: @side.id }

    assert_response :redirect
    assert flash[:alert].present?
    # The whole join must roll back, not just the failed sync — the pair is
    # left unlinked and the sibling gets no half-mirrored entry.
    assert_nil @main.reload.link_group_id
    assert_nil @side.reload.link_group_id
    assert_equal 0, @side.tournament_entries.count
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end

  test "a linked tournament's edit page links to the partner's edit page" do
    TournamentLinks::Join.call(tournament: @main, other: @side)
    get edit_organizers_tournament_path(@main)
    assert_response :success
    assert_select "a[href=?]", edit_organizers_tournament_path(@side), text: /Side/
  end
end
