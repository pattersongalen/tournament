require "test_helper"

class Admin::Clubs::QuestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create(:user, club: create(:club, name: "Admin Home FC"), admin: true)
    @club = create(:club, name: "Target FC")
    @lure, @bait, @depth = @club.questions.active.ordered.to_a
  end

  def active_prompts
    @club.questions.active.ordered.pluck(:prompt)
  end

  test "only a site admin can reach any question action" do
    organizer = create(:user, club: @club, role: :organizer)
    member = create(:user, club: @club, role: :member)
    deputy = create(:user, club: @club, role: :member)
    upcoming = create(:tournament, club: @club, starts_at: 2.days.from_now, ends_at: 3.days.from_now)
    create(:tournament_deputy, tournament: upcoming, user: deputy, granted_by_user: organizer)

    { "organizer" => organizer, "member" => member, "deputy" => deputy }.each do |label, user|
      sign_in_as(user)

      get admin_club_questions_path(@club)
      assert_response :forbidden, "#{label}: index"
      post admin_club_questions_path(@club), params: { club_question: { prompt: "Water temp" } }
      assert_response :forbidden, "#{label}: create"
      patch admin_club_question_path(@club, @lure), params: { club_question: { prompt: "Hacked" } }
      assert_response :forbidden, "#{label}: update"
      patch retire_admin_club_question_path(@club, @lure)
      assert_response :forbidden, "#{label}: retire"
      patch restore_admin_club_question_path(@club, @lure)
      assert_response :forbidden, "#{label}: restore"
      patch move_admin_club_question_path(@club, @lure), params: { direction: "down" }
      assert_response :forbidden, "#{label}: move"

      assert_equal ["Lure used", "Bait used", "Depth"], active_prompts, "#{label}: nothing changed"
    end
  end

  test "the page lists active questions in order and retired ones separately" do
    @depth.update!(retired_at: Time.current)
    sign_in_as(@admin)
    get admin_club_questions_path(@club)

    assert_response :success
    assert_select "#active-questions [data-question]", 2
    # Active prompts live in the rename boxes' values, not in text nodes.
    assert_equal ["Lure used", "Bait used"],
                 css_select("#active-questions input[name='club_question[prompt]']").map { |i| i["value"] }
    assert_select "#retired-questions", text: /Depth/
  end

  test "adding a question puts it at the end" do
    sign_in_as(@admin)
    post admin_club_questions_path(@club), params: { club_question: { prompt: "  Water temp " } }

    assert_redirected_to admin_club_questions_path(@club)
    assert_equal ["Lure used", "Bait used", "Depth", "Water temp"], active_prompts
  end

  test "renaming keeps the question's place and its answers" do
    questionnaire = create(:entry_questionnaire, tournament: create(:tournament, club: @club))
    create(:entry_questionnaire_answer, entry_questionnaire: questionnaire, club_question: @bait, body: "Minnow")
    sign_in_as(@admin)

    patch admin_club_question_path(@club, @bait), params: { club_question: { prompt: "Live bait" } }

    assert_redirected_to admin_club_questions_path(@club)
    assert_equal ["Lure used", "Live bait", "Depth"], active_prompts
    assert_equal "Minnow", EntryQuestionnaireAnswer.find_by!(club_question_id: @bait.id).body
  end

  test "invalid prompts re-render the page as 422 and change nothing" do
    sign_in_as(@admin)
    {
      "blank"         => "",
      "too long"      => "x" * 81,
      "duplicate"     => "lure used",
      "not a string"  => ["a"]
    }.each do |label, prompt|
      post admin_club_questions_path(@club), params: { club_question: { prompt: prompt } }
      assert_response :unprocessable_entity, "#{label}: create"

      patch admin_club_question_path(@club, @bait), params: { club_question: { prompt: prompt } }
      assert_response :unprocessable_entity, "#{label}: update"

      assert_equal ["Lure used", "Bait used", "Depth"], active_prompts, label
    end
  end

  test "a missing club_question parameter is a 422" do
    sign_in_as(@admin)
    post admin_club_questions_path(@club)
    assert_response :unprocessable_entity
  end

  test "retiring hides a question and keeps its answers; restoring puts it at the end" do
    questionnaire = create(:entry_questionnaire, tournament: create(:tournament, club: @club))
    create(:entry_questionnaire_answer, entry_questionnaire: questionnaire, club_question: @lure, body: "Jig")
    sign_in_as(@admin)

    patch retire_admin_club_question_path(@club, @lure)
    assert_redirected_to admin_club_questions_path(@club)
    assert_equal ["Bait used", "Depth"], active_prompts
    assert_equal 1, EntryQuestionnaireAnswer.where(club_question_id: @lure.id).count

    patch restore_admin_club_question_path(@club, @lure)
    assert_redirected_to admin_club_questions_path(@club)
    assert_equal ["Bait used", "Depth", "Lure used"], active_prompts
  end

  test "restoring a question whose prompt is now taken is refused with a message" do
    @lure.update!(retired_at: Time.current)
    @club.questions.create!(prompt: "Lure used", position: 99)
    sign_in_as(@admin)

    patch restore_admin_club_question_path(@club, @lure)

    assert_redirected_to admin_club_questions_path(@club)
    assert_match "already on the list", flash[:alert]
    assert @lure.reload.retired?
  end

  test "retiring the last active question is allowed" do
    sign_in_as(@admin)
    [@lure, @bait, @depth].each { |q| patch retire_admin_club_question_path(@club, q) }

    assert_empty active_prompts
    get admin_club_questions_path(@club)
    assert_response :success
    assert_includes response.body, "No questions. Nobody is asked until you add or restore one."
  end

  test "moving a question up or down swaps it with its neighbour" do
    sign_in_as(@admin)

    patch move_admin_club_question_path(@club, @depth), params: { direction: "up" }
    assert_redirected_to admin_club_questions_path(@club)
    assert_equal ["Lure used", "Depth", "Bait used"], active_prompts

    patch move_admin_club_question_path(@club, @lure), params: { direction: "down" }
    assert_equal ["Depth", "Lure used", "Bait used"], active_prompts
  end

  # Review Focus 5.
  test "moving past either end, or with an unknown direction, changes nothing" do
    sign_in_as(@admin)
    [
      [@lure, "up"], [@depth, "down"], [@bait, "sideways"], [@bait, nil], [@bait, ["up"]]
    ].each do |question, direction|
      patch move_admin_club_question_path(@club, question), params: { direction: direction }
      assert_redirected_to admin_club_questions_path(@club), direction.inspect
      assert_equal ["Lure used", "Bait used", "Depth"], active_prompts, direction.inspect
    end
  end

  test "moving ignores retired questions between neighbours" do
    @bait.update!(retired_at: Time.current)
    sign_in_as(@admin)

    patch move_admin_club_question_path(@club, @depth), params: { direction: "up" }

    assert_equal ["Depth", "Lure used"], active_prompts
  end

  test "a question cannot be reached through another club's URL" do
    other = create(:club)
    sign_in_as(@admin)

    patch admin_club_question_path(other, @lure), params: { club_question: { prompt: "Hacked" } }

    assert_response :not_found
    assert_equal "Lure used", @lure.reload.prompt
  end

  test "the club page links to the question list" do
    sign_in_as(@admin)
    get admin_club_path(@club)
    assert_select "a[href=?]", admin_club_questions_path(@club)
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
