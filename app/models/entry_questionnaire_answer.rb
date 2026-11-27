class EntryQuestionnaireAnswer < ApplicationRecord
  BODY_MAX = 200

  belongs_to :entry_questionnaire
  belongs_to :club_question

  validates :body, presence: true, length: { maximum: BODY_MAX }
end
