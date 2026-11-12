module Questionnaires
  # Rows for the "What worked" section on a finished tournament's page: the
  # current top three, each with its answers in question order. A boat that
  # has dropped out of the top three is simply not in the list, so its
  # answers stop showing without being deleted.
  class WhatWorked
    def self.call(tournament:, rows:, viewer:, club:)
      eligible = EligibleEntries.call(tournament: tournament, rows: rows)
      return [] if eligible.empty?

      entry_ids = eligible.map { |e| e[:entry].id }
      questionnaires = ::EntryQuestionnaire
                         .where(tournament_entry_id: entry_ids)
                         .includes(:updated_by_user, answers: :club_question)
                         .index_by(&:tournament_entry_id)
      staff = club.present? && viewer.present? && (viewer.admin? || viewer.organizer_in?(club))
      own_entry_ids =
        if club.present? && viewer.present?
          ::TournamentEntryMember.where(tournament_entry_id: entry_ids, user_id: viewer.id)
                                 .pluck(:tournament_entry_id).to_set
        else
          Set.new
        end

      eligible.map do |item|
        questionnaire = questionnaires[item[:entry].id]
        answers = (questionnaire&.answers || [])
                    .sort_by { |a| [a.club_question.position, a.club_question.id] }
                    .map { |a| [a.club_question.prompt, a.body] }
        {
          entry: item[:entry],
          place: item[:place],
          answers: answers,
          answered_by: questionnaire&.updated_by_user&.name,
          answered: questionnaire.present?,
          can_answer: staff || own_entry_ids.include?(item[:entry].id)
        }
      end
    end
  end
end
