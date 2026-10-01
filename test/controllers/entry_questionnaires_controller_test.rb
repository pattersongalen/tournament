require "test_helper"
require_relative "../support/questionnaire_helpers"

class EntryQuestionnairesControllerTest < ActionDispatch::IntegrationTest
  include QuestionnaireHelpers

  setup do
    @club = asking_club
    @tournament = season_tournament(club: @club)
    @first  = add_boat(@tournament, length: 30, members: 2, name: "First Boat")
    @second = add_boat(@tournament, length: 28)
    @third  = add_boat(@tournament, length: 26)
    @fourth = add_boat(@tournament, length: 24)
    @me = @first.users.order(:id).first
    @lure, @bait, @depth = @club.questions.active.ordered.to_a
  end

  def answers(lure: "Jig", bait: "", depth: "")
    { answers: { @lure.id.to_s => lure, @bait.id.to_s => bait, @depth.id.to_s => depth } }
  end

  test "a member of a top-3 boat sees the form with one box per active question" do
    sign_in_as(@me)
    get edit_tournament_entry_questionnaire_path(@tournament, @first)

    assert_response :success
    assert_select "h1", text: /Wednesday Main/
    assert_includes response.body, "1st"
    [@lure, @bait, @depth].each do |question|
      assert_select "label", text: question.prompt
      assert_select "input[name=?][maxlength='200']", "answers[#{question.id}]"
    end
  end

  test "a retired question is not offered" do
    @depth.update!(retired_at: Time.current)
    sign_in_as(@me)
    get edit_tournament_entry_questionnaire_path(@tournament, @first)

    assert_select "input[name=?]", "answers[#{@depth.id}]", 0
  end

  test "submitting saves the answers and returns to the tournament page" do
    sign_in_as(@me)
    patch tournament_entry_questionnaire_path(@tournament, @first), params: answers(lure: "Jig", depth: "18 ft")

    assert_redirected_to tournament_path(@tournament)
    assert_equal "Thanks. Your answers are on the tournament page.", flash[:notice]
    assert_equal({ @lure.id => "Jig", @depth.id => "18 ft" },
                 @first.reload.questionnaire.answers.pluck(:club_question_id, :body).to_h)
  end

  test "editing shows the saved answers, and a retired question's answer read-only" do
    sign_in_as(@me)
    patch tournament_entry_questionnaire_path(@tournament, @first), params: answers(lure: "Jig", depth: "18 ft")
    @depth.update!(retired_at: Time.current)

    get edit_tournament_entry_questionnaire_path(@tournament, @first)

    assert_select "input[name=?][value='Jig']", "answers[#{@lure.id}]"
    assert_select "input[name=?]", "answers[#{@depth.id}]", 0
    assert_select "#retired-answers", text: /Depth/
    assert_select "#retired-answers", text: /18 ft/
  end

  test "invalid submissions re-render the form as 422 with what was typed" do
    sign_in_as(@me)
    {
      "all blank" => [answers(lure: "", bait: " "), "Fill in at least one answer."],
      "too long"  => [answers(lure: "x" * 201), "up to 200 characters"]
    }.each do |label, (params, message)|
      patch tournament_entry_questionnaire_path(@tournament, @first), params: params

      assert_response :unprocessable_entity, label
      assert_includes response.body, message, label
      assert_nil @first.reload.questionnaire, label
    end
  end

  # Review Focus 1.
  test "an answers parameter of the wrong shape is a 422, never a 500" do
    sign_in_as(@me)
    [
      { answers: "just a string" },
      { answers: ["a", "b"] },
      { answers: { @lure.id.to_s => { nested: "hash" } } },
      {}
    ].each do |params|
      patch tournament_entry_questionnaire_path(@tournament, @first), params: params
      assert_response :unprocessable_entity, params.inspect
    end
  end

  test "who may open and submit the form" do
    outsider = create(:user, club: @club, role: :member)
    organizer = create(:user, club: @club, role: :organizer)
    site_admin = create(:user, club: @club, role: :member, admin: true)
    deputy = create(:user, club: @club, role: :member)
    upcoming = create(:tournament, club: @club, starts_at: 2.days.from_now, ends_at: 3.days.from_now)
    create(:tournament_deputy, tournament: upcoming, user: deputy, granted_by_user: organizer)
    fourth_member = @fourth.users.first
    rival = @second.users.first

    cases = {
      "member of the top-3 boat"                 => [@me,           @first,  :success],
      "teammate on the top-3 boat"               => [@first.users.order(:id).last, @first, :success],
      "member of another top-3 boat"             => [rival,         @first,  :not_found],
      "member with no boat"                      => [outsider,      @first,  :not_found],
      "member of the 4th boat, own boat"         => [fourth_member, @fourth, :not_asked],
      "organizer, eligible boat"                 => [organizer,     @first,  :success],
      "deputy, eligible boat"                    => [deputy,        @first,  :success],
      "site admin, eligible boat"                => [site_admin,    @first,  :success],
      "organizer, boat outside the top 3"        => [organizer,     @fourth, :not_asked]
    }

    cases.each do |label, (user, entry, expected)|
      sign_in_as(user)
      get edit_tournament_entry_questionnaire_path(@tournament, entry)
      if expected == :not_asked
        assert_redirected_to tournament_path(@tournament), "#{label}: edit"
      else
        assert_response expected, "#{label}: edit"
      end

      patch tournament_entry_questionnaire_path(@tournament, entry), params: answers
      case expected
      when :success
        assert_redirected_to tournament_path(@tournament), "#{label}: update"
        assert_equal 1, EntryQuestionnaire.count, "#{label}: update saves"
      when :not_asked
        assert_redirected_to tournament_path(@tournament), "#{label}: update"
        assert_equal 0, EntryQuestionnaire.count, "#{label}: update saves nothing"
      else
        assert_response :not_found, "#{label}: update"
      end
      EntryQuestionnaire.delete_all
    end
  end

  # The "You placed 3rd" push is sent once, when the tournament ends. A catch
  # that syncs afterwards can move the boat out, and its link must still land
  # somewhere that explains why.
  test "a boat pushed out of the top 3 before answering is sent to the tournament page with a reason" do
    third_member = @third.users.first
    sign_in_as(third_member)
    get edit_tournament_entry_questionnaire_path(@tournament, @third)
    assert_response :success

    add_boat(@tournament, length: 27)

    get edit_tournament_entry_questionnaire_path(@tournament, @third)
    assert_redirected_to tournament_path(@tournament)
    assert_match(/not in the top three/, flash[:notice])
  end

  test "a boat that dropped out of the top 3 may still edit answers it already gave" do
    sign_in_as(@me)
    patch tournament_entry_questionnaire_path(@tournament, @first), params: answers(lure: "Jig")
    disqualify(@first)

    get edit_tournament_entry_questionnaire_path(@tournament, @first)
    assert_response :success

    patch tournament_entry_questionnaire_path(@tournament, @first), params: answers(lure: "Spoon")
    assert_redirected_to tournament_path(@tournament)
    assert_equal ["Spoon"], @first.reload.questionnaire.answers.pluck(:body)
  end

  test "a tournament that does not ask is a 404" do
    sign_in_as(@me)
    {
      "season points off" => -> { @tournament.update_columns(awards_season_points: false) },
      "still running"     => -> { @tournament.update_columns(ends_at: 1.hour.from_now) },
      "before the start"  => -> { @club.update!(questionnaires_start_at: Time.current) }
    }.each do |label, arrange|
      arrange.call
      get edit_tournament_entry_questionnaire_path(@tournament, @first)
      assert_response :not_found, label

      @tournament.update_columns(awards_season_points: true, ends_at: 1.day.ago)
      @club.update!(questionnaires_start_at: 30.days.ago)
    end
  end

  test "an entry from another tournament, or a tournament from another club, is a 404" do
    other_tournament = season_tournament(club: @club, name: "Other")
    other_entry = add_boat(other_tournament, length: 30)
    foreign_tournament = season_tournament(club: asking_club, name: "Foreign")
    foreign_entry = add_boat(foreign_tournament, length: 30)

    sign_in_as(@me)
    get edit_tournament_entry_questionnaire_path(@tournament, other_entry)
    assert_response :not_found
    get edit_tournament_entry_questionnaire_path(foreign_tournament, foreign_entry)
    assert_response :not_found
  end

  test "a signed-out visitor is sent to sign in" do
    get edit_tournament_entry_questionnaire_path(@tournament, @first)
    assert_redirected_to new_session_path
  end

  test "Not now records a dismissal for that member only, and twice is harmless" do
    sign_in_as(@me)

    assert_difference -> { EntryQuestionnaireDismissal.count }, 1 do
      post tournament_entry_questionnaire_dismissal_path(@tournament, @first)
    end
    assert_redirected_to root_path

    assert_no_difference -> { EntryQuestionnaireDismissal.count } do
      post tournament_entry_questionnaire_dismissal_path(@tournament, @first)
    end
    assert_redirected_to root_path
    assert_equal [@me.id], EntryQuestionnaireDismissal.where(tournament_entry_id: @first.id).pluck(:user_id)
  end

  test "only a member of the boat can dismiss its card" do
    organizer = create(:user, club: @club, role: :organizer)
    sign_in_as(organizer)

    assert_no_difference -> { EntryQuestionnaireDismissal.count } do
      post tournament_entry_questionnaire_dismissal_path(@tournament, @first)
    end
    assert_response :not_found
  end

  private

  def sign_in_as(user)
    token = SignInToken.issue!(user: user)
    get consume_session_path(token: token.token)
  end
end
