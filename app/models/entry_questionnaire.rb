# A boat's answers to the club's top-3 questionnaire for one tournament.
# One per entry; any member of the boat may fill it in or edit it.
class EntryQuestionnaire < ApplicationRecord
  belongs_to :tournament
  belongs_to :tournament_entry
  belongs_to :submitted_by_user, class_name: "User", optional: true
  belongs_to :updated_by_user, class_name: "User", optional: true
  has_many :answers, class_name: "EntryQuestionnaireAnswer", dependent: :delete_all
end
