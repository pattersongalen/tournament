require "test_helper"
require_relative "../support/questionnaire_helpers"

class QuestionnairePagesTest < ActionDispatch::IntegrationTest
  include QuestionnaireHelpers

  setup do
    @club = asking_club
    @tournament = season_tournament(club: @club)
    @first  = add_boat(@tournament, length: 30, members: 2, name: "First Boat")
    @second = add_boat(@tournament, length: 28, name: "Second Boat")
    @third  = add_boat(@tournament, length: 26, name: "Third Boat")
    @fourth = add_boat(@tournament, length: 24, name: "Fourth Boat")
    @me = @first.users.order(:id).first
    @lure, @bait, @depth = @club.questions.active.ordered.to_a
  end

  def answer(entry, user, pairs)
    Questionnaires::SaveAnswers.call(
      entry: entry, user: user, answers: pairs.to_h { |question, body| [question.id.to_s, body] }
    )
  end

  # --- Home page card -------------------------------------------------------

  test "a top-3 member sees the card with their place, an Answer link and a Not now button" do
    sign_in_as(@me)
    get root_path

    assert_response :success
    assert_select "#questionnaire-card-#{@first.id}" do
      assert_select "h2", text: "You placed 1st in Wednesday Main"
      assert_select "p", text: "Tell the club what worked."
      assert_select "a[href=?]", edit_tournament_entry_questionnaire_path(@tournament, @first), text: "Answer"
      assert_select "form[action=?]", tournament_entry_questionnaire_dismissal_path(@tournament, @first)
      assert_select "button", text: "Not now"
    end
  end

  test "the card sits above the Log Catch button" do
    sign_in_as(@me)
    get root_path

    assert_operator response.body.index("questionnaire-card-#{@first.id}"), :<,
                    response.body.index("Log Catch")
  end

  test "no card when nothing is pending" do
    {
      "4th place"        => -> { sign_in_as(@fourth.users.first) },
      "already answered" => -> { answer(@first, @me, @lure => "Jig"); sign_in_as(@me) },
      "dismissed"        => -> {
        create(:entry_questionnaire_dismissal, tournament_entry: @first, user: @me)
        sign_in_as(@me)
      }
    }.each do |label, arrange|
      arrange.call
      get root_path
      assert_response :success, label
      assert_select "[id^=questionnaire-card-]", { count: 0 }, label
      EntryQuestionnaire.delete_all
      EntryQuestionnaireDismissal.delete_all
    end
  end

  test "a teammate still sees the card after this member dismisses it" do
    create(:entry_questionnaire_dismissal, tournament_entry: @first, user: @me)
    sign_in_as(@first.users.order(:id).last)
    get root_path

    assert_select "#questionnaire-card-#{@first.id}", 1
  end

  # --- What worked section --------------------------------------------------

  test "the section lists the top three in order with answers, or the empty state" do
    answer(@first, @me, @lure => "Jig", @depth => "18 ft")
    sign_in_as(@fourth.users.first)
    get tournament_path(@tournament)

    assert_response :success
    assert_select "#what-worked h2", text: "What worked"
    assert_select "#what-worked [data-place]", 3
    assert_select "#what-worked [data-place='1']", text: /First Boat/
    assert_select "#what-worked [data-place='1']", text: /Lure used:\s*Jig/
    assert_select "#what-worked [data-place='1']", text: /Depth:\s*18 ft/
    assert_select "#what-worked [data-place='1']", text: /Answered by #{Regexp.escape(@me.name)}/
    assert_select "#what-worked [data-place='2']", text: /No answers yet\./
    assert_select "#what-worked", text: /Fourth Boat/, count: 0
  end

  test "answers appear in question order, not the order they were saved" do
    answer(@first, @me, @depth => "18 ft", @lure => "Jig")
    sign_in_as(@me)
    get tournament_path(@tournament)

    section = css_select("#what-worked [data-place='1']").first.text
    assert_operator section.index("Lure used"), :<, section.index("Depth")
  end

  test "the section is outside the leaderboard element and not inside a turbo-frame" do
    sign_in_as(@me)
    get tournament_path(@tournament)

    assert_select "#leaderboard #what-worked", 0
    assert_select "turbo-frame #what-worked", 0
  end

  test "Answer and Edit links show only to people who may answer for that boat" do
    answer(@second, @second.users.first, @lure => "Spoon")

    sign_in_as(@me)
    get tournament_path(@tournament)
    assert_select "#what-worked a[href=?]", edit_tournament_entry_questionnaire_path(@tournament, @first), text: "Answer"
    assert_select "#what-worked a[href=?]", edit_tournament_entry_questionnaire_path(@tournament, @second), 0

    sign_in_as(@second.users.first)
    get tournament_path(@tournament)
    assert_select "#what-worked a[href=?]", edit_tournament_entry_questionnaire_path(@tournament, @second), text: "Edit answers"

    sign_in_as(create(:user, club: @club, role: :organizer))
    get tournament_path(@tournament)
    assert_select "#what-worked a", 3
  end

  test "the section is not rendered when the tournament does not ask or nobody scored" do
    sign_in_as(@me)
    {
      "season points off" => -> { @tournament.update_columns(awards_season_points: false) },
      "still running"     => -> { @tournament.update_columns(ends_at: 1.hour.from_now) },
      "nobody scored"     => -> { CatchPlacement.where(tournament_id: @tournament.id).update_all(active: false) }
    }.each do |label, arrange|
      arrange.call
      get tournament_path(@tournament)
      assert_response :success, label
      assert_select "#what-worked", { count: 0 }, label

      @tournament.update_columns(awards_season_points: true, ends_at: 1.day.ago)
      CatchPlacement.where(tournament_id: @tournament.id).update_all(active: true)
    end
  end

  test "a boat that dropped out of the top 3 no longer shows its answers" do
    answer(@third, @third.users.first, @lure => "Secret crankbait")
    disqualify(@third)
    sign_in_as(@me)
    get tournament_path(@tournament)

    assert_not_includes response.body, "Secret crankbait"
    assert_select "#what-worked [data-place='3']", text: /Fourth Boat/
  end

  test "an answer to a question retired later is still shown" do
    answer(@first, @me, @depth => "18 ft")
    @depth.update!(retired_at: Time.current)
    sign_in_as(@me)
    get tournament_path(@tournament)

    assert_select "#what-worked [data-place='1']", text: /Depth:\s*18 ft/
  end

  # Review Focus 3.
  test "markup in an answer or a prompt is shown as text" do
    @lure.update!(prompt: "<b>Lure</b>")
    answer(@first, @me, @lure => "<script>alert(1)</script>")
    sign_in_as(@me)

    get tournament_path(@tournament)
    assert_select "#what-worked script", 0
    assert_select "#what-worked b", 0
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_includes response.body, "&lt;b&gt;Lure&lt;/b&gt;"

    get edit_tournament_entry_questionnaire_path(@tournament, @first)
    assert_select "label b", 0
    assert_includes response.body, "&lt;b&gt;Lure&lt;/b&gt;"
  end

  test "the site-admin cross-club view shows the answers without answer links" do
    answer(@first, @me, @lure => "Jig")
    admin = create(:user, club: create(:club), admin: true)
    sign_in_as(admin)
    get admin_club_tournament_path(@club, @tournament)

    assert_response :success
    assert_select "#what-worked [data-place='1']", text: /Lure used:\s*Jig/
    assert_select "#what-worked a", 0
  end

  test "the section costs a fixed number of questionnaire queries" do
    [@first, @second, @third].each { |entry| answer(entry, entry.users.first, @lure => "Jig") }
    sign_in_as(@me)

    queries = count_queries("entry_questionnaire") { get tournament_path(@tournament) }

    assert_operator queries, :<=, 3, "questionnaires and answers load in a fixed number of queries"
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
