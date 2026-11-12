require "test_helper"
require_relative "../../support/questionnaire_helpers"

class Questionnaires::SaveAnswersTest < ActiveSupport::TestCase
  include QuestionnaireHelpers

  setup do
    @club = asking_club
    @tournament = season_tournament(club: @club)
    @entry = add_boat(@tournament, length: 30, members: 2)
    @me, @mate = @entry.users.order(:id).to_a
    @lure, @bait, @depth = @club.questions.active.ordered.to_a
  end

  # Callers write save("12" => "Jig"); Ruby passes a braceless hash as
  # keywords, so the string-keyed pairs arrive in **pairs.
  def save(answers = {}, user: @me, **pairs)
    Questionnaires::SaveAnswers.call(entry: @entry, user: user, answers: answers.merge(pairs))
  end

  test "the first save creates the questionnaire, stores stripped answers and records the submitter" do
    result = save(@lure.id.to_s => "  Jig  ", @bait.id.to_s => "Minnow", @depth.id.to_s => "")

    assert result.ok
    questionnaire = @entry.reload.questionnaire
    assert_equal @tournament.id, questionnaire.tournament_id
    assert_equal @me.id, questionnaire.submitted_by_user_id
    assert_equal @me.id, questionnaire.updated_by_user_id
    assert_equal({ @lure.id => "Jig", @bait.id => "Minnow" },
                 questionnaire.answers.pluck(:club_question_id, :body).to_h)
  end

  test "a teammate's later save edits the same questionnaire and keeps the first submitter" do
    save(@lure.id.to_s => "Jig")

    result = save({ @lure.id.to_s => "Spoon", @depth.id.to_s => "18 ft" }, user: @mate)

    assert result.ok
    assert_equal 1, EntryQuestionnaire.where(tournament_entry_id: @entry.id).count
    questionnaire = @entry.reload.questionnaire
    assert_equal @me.id, questionnaire.submitted_by_user_id
    assert_equal @mate.id, questionnaire.updated_by_user_id
    assert_equal({ @lure.id => "Spoon", @depth.id => "18 ft" },
                 questionnaire.answers.pluck(:club_question_id, :body).to_h)
  end

  test "clearing a box on edit deletes that answer" do
    save(@lure.id.to_s => "Jig", @bait.id.to_s => "Minnow")

    save(@lure.id.to_s => "Jig", @bait.id.to_s => "   ")

    assert_equal [@lure.id], @entry.reload.questionnaire.answers.pluck(:club_question_id)
  end

  test "all answers blank is refused and stores nothing" do
    result = save(@lure.id.to_s => "", @bait.id.to_s => "  ")

    assert_not result.ok
    assert_equal "Fill in at least one answer.", result.error
    assert_nil @entry.reload.questionnaire
  end

  test "an answer over 200 characters is refused and stores nothing" do
    result = save(@lure.id.to_s => "x" * 201, @bait.id.to_s => "Minnow")

    assert_not result.ok
    assert_match "200", result.error
    assert_nil @entry.reload.questionnaire
  end

  test "exactly 200 characters is accepted" do
    assert save(@lure.id.to_s => "x" * 200).ok
  end

  # Review Focus 2.
  test "answers for another club's question or a retired question are ignored" do
    foreign = create(:club).questions.first
    @depth.update!(retired_at: Time.current)

    result = save(@lure.id.to_s => "Jig", foreign.id.to_s => "Sneaky", @depth.id.to_s => "18 ft")

    assert result.ok
    assert_equal [@lure.id], @entry.reload.questionnaire.answers.pluck(:club_question_id)
  end

  test "only ignored questions answered counts as all blank" do
    foreign = create(:club).questions.first

    result = save(foreign.id.to_s => "Sneaky")

    assert_not result.ok
    assert_nil @entry.reload.questionnaire
  end

  test "an existing answer to a question retired later is kept when the boat edits" do
    save(@lure.id.to_s => "Jig", @depth.id.to_s => "18 ft")
    @depth.update!(retired_at: Time.current)

    save(@lure.id.to_s => "Spoon")

    assert_equal({ @lure.id => "Spoon", @depth.id => "18 ft" },
                 @entry.reload.questionnaire.answers.pluck(:club_question_id, :body).to_h)
  end

  # Review Focus 1: values that are not strings are treated as blank.
  test "non-string answer values are treated as blank" do
    result = save(@lure.id.to_s => ["Jig"], @bait.id.to_s => { "x" => "y" }, @depth.id.to_s => nil)

    assert_not result.ok
    assert_equal "Fill in at least one answer.", result.error
  end

  test "a first save that loses the race to a teammate edits the winner's questionnaire" do
    existing = create(:entry_questionnaire, tournament: @tournament, tournament_entry: @entry,
                      submitted_by_user: @mate, updated_by_user: @mate)
    # The teammate's row already exists, so this save's insert hits the unique
    # index exactly as the loser of a simultaneous submit would.
    result = save(@lure.id.to_s => "Jig")

    assert result.ok
    assert_equal existing.id, result.questionnaire.id
    assert_equal 1, EntryQuestionnaire.where(tournament_entry_id: @entry.id).count
  end
end
