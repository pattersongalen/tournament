# A member tapped "Not now" on a boat's home page questionnaire card. It hides
# the card for that member only; teammates still see it.
class EntryQuestionnaireDismissal < ApplicationRecord
  belongs_to :tournament_entry
  belongs_to :user
end
