class TournamentEntry < ApplicationRecord
  belongs_to :tournament
  belongs_to :boat, optional: true
  has_many :tournament_entry_members, dependent: :destroy
  has_many :users, through: :tournament_entry_members
  has_many :catch_placements, dependent: :destroy
  has_one :questionnaire, class_name: "EntryQuestionnaire", dependent: :destroy
  has_many :questionnaire_dismissals, class_name: "EntryQuestionnaireDismissal", dependent: :delete_all

  # Deleting a boat nullifies its entries, which is only safe once the
  # tournament is over: on a live or upcoming one it drops the entry out of
  # every single-entry guard (Boats::Enter, the partial unique index, the
  # picker's filter) and lets the same crew be entered twice. ends_at is
  # required, but the NULL guard matches the defensive checks elsewhere.
  scope :in_finished_tournaments, -> {
    joins(:tournament).where(tournaments: { ends_at: ..Time.current })
  }
  scope :in_unfinished_tournaments, -> {
    joins(:tournament).where("tournaments.ends_at IS NULL OR tournaments.ends_at > ?", Time.current)
  }

  def display_name
    name.presence || users.pluck(:name).join(" + ")
  end
end
