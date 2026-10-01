module Questionnaires
  # Saves a boat's answers. Only the club's ACTIVE questions are read from the
  # submission; anything else in it is ignored, and answers already given to
  # questions that were retired since are left alone.
  class SaveAnswers
    Result = Struct.new(:ok, :questionnaire, :error, keyword_init: true)

    def self.call(entry:, user:, answers:)
      answers = {} unless answers.is_a?(Hash)
      questions = entry.tournament.club.questions.active.ordered.to_a
      cleaned = questions.to_h do |question|
        value = answers[question.id.to_s]
        [question, value.is_a?(String) ? value.strip : ""]
      end

      if cleaned.values.any? { |body| body.length > ::EntryQuestionnaireAnswer::BODY_MAX }
        return Result.new(ok: false, error: "Answers can be up to #{::EntryQuestionnaireAnswer::BODY_MAX} characters.")
      end
      if cleaned.values.all?(&:blank?)
        return Result.new(ok: false, error: "Fill in at least one answer.")
      end

      questionnaire = nil
      ::EntryQuestionnaire.transaction do
        # create_or_find_by!: two teammates submitting at once both land on
        # the unique index; the loser edits the winner's questionnaire.
        questionnaire = ::EntryQuestionnaire.create_or_find_by!(tournament_entry_id: entry.id) do |q|
          q.tournament_id = entry.tournament_id
          q.submitted_by_user = user
        end
        # This UPDATE also takes the questionnaire's row lock until commit, so
        # a teammate saving at the same moment waits here and then reads the
        # answer rows this save wrote. Keep it ahead of the answer writes.
        questionnaire.update!(updated_by_user: user, updated_at: Time.current)

        cleaned.each do |question, body|
          scope = questionnaire.answers.where(club_question_id: question.id)
          if body.blank?
            scope.delete_all
          else
            answer = scope.first_or_initialize
            answer.update!(body: body)
          end
        end
      end

      Result.new(ok: true, questionnaire: questionnaire)
    end
  end
end
