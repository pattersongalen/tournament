require "test_helper"

class ClubQuestionTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
  end

  test "a new club starts with the three default questions, in order, and a start time" do
    freeze_time do
      club = create(:club)
      assert_equal ["Lure used", "Bait used", "Depth"], club.questions.active.ordered.pluck(:prompt)
      assert_equal Time.current, club.questionnaires_start_at
    end
  end

  test "validation rejects each invalid prompt" do
    {
      "blank"                         => "  ",
      "over 80 characters"            => "x" * 81,
      "duplicate of an active prompt" => "Lure used",
      "duplicate ignoring case/space" => "  lure USED "
    }.each do |label, prompt|
      question = @club.questions.new(prompt: prompt, position: 9)
      assert_not question.valid?, "#{label} should be invalid"
    end
  end

  test "a prompt may repeat one that is retired, or one in another club" do
    @club.questions.find_by!(prompt: "Depth").update!(retired_at: Time.current)
    assert @club.questions.new(prompt: "Depth", position: 9).valid?

    other = create(:club)
    assert other.questions.new(prompt: "Water temp", position: 9).valid?
    @club.questions.create!(prompt: "Water temp", position: 9)
    assert other.questions.new(prompt: "Water temp", position: 9).valid?
  end

  test "the prompt is stripped before saving" do
    question = @club.questions.create!(prompt: "  Water temp  ", position: 9)
    assert_equal "Water temp", question.prompt
  end

  test "active and retired scopes split on retired_at, ordered sorts by position" do
    depth = @club.questions.find_by!(prompt: "Depth")
    depth.update!(retired_at: Time.current)
    @club.questions.find_by!(prompt: "Lure used").update!(position: 50)

    assert_equal ["Bait used", "Lure used"], @club.questions.active.ordered.pluck(:prompt)
    assert_equal ["Depth"], @club.questions.retired.pluck(:prompt)
    assert depth.retired?
  end

  test "a boat has at most one questionnaire" do
    tournament = create(:tournament, club: @club)
    entry = create(:tournament_entry, tournament: tournament)
    create(:entry_questionnaire, tournament: tournament, tournament_entry: entry)

    assert_raises(ActiveRecord::RecordNotUnique) do
      EntryQuestionnaire.transaction(requires_new: true) do
        EntryQuestionnaire.insert_all!([{
          tournament_id: tournament.id, tournament_entry_id: entry.id,
          created_at: Time.current, updated_at: Time.current
        }])
      end
    end
  end

  test "an answer needs a body of at most 200 characters" do
    questionnaire = create(:entry_questionnaire)
    question = questionnaire.tournament.club.questions.first
    assert_not EntryQuestionnaireAnswer.new(entry_questionnaire: questionnaire, club_question: question, body: "").valid?
    assert_not EntryQuestionnaireAnswer.new(entry_questionnaire: questionnaire, club_question: question, body: "x" * 201).valid?
    assert EntryQuestionnaireAnswer.new(entry_questionnaire: questionnaire, club_question: question, body: "x" * 200).valid?
  end

  test "deleting an entry deletes its questionnaire, answers and dismissals" do
    questionnaire = create(:entry_questionnaire)
    entry = questionnaire.tournament_entry
    question = questionnaire.tournament.club.questions.first
    create(:entry_questionnaire_answer, entry_questionnaire: questionnaire, club_question: question)
    create(:entry_questionnaire_dismissal, tournament_entry: entry,
           user: create(:user, club: questionnaire.tournament.club))

    entry.destroy!

    assert_equal 0, EntryQuestionnaire.where(id: questionnaire.id).count
    assert_equal 0, EntryQuestionnaireAnswer.where(entry_questionnaire_id: questionnaire.id).count
    assert_equal 0, EntryQuestionnaireDismissal.where(tournament_entry_id: entry.id).count
  end
end
