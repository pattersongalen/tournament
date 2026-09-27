# The top-3 questionnaire form. One questionnaire per boat; `edit`/`update`
# serve both the first submission and later edits.
class EntryQuestionnairesController < ApplicationController
  before_action :require_sign_in!
  before_action :load_and_authorize

  def edit
    prepare_form(typed: saved_answers)
  end

  def update
    result = Questionnaires::SaveAnswers.call(entry: @entry, user: current_user, answers: submitted_answers)
    if result.ok
      redirect_to tournament_path(@tournament), notice: "Thanks. Your answers are on the tournament page."
    else
      @error = result.error
      prepare_form(typed: submitted_answers)
      render :edit, status: :unprocessable_entity
    end
  end

  private

  # 404 rather than 403 throughout: a member has no business learning which
  # boats exist in a tournament they cannot answer for.
  def load_and_authorize
    raise ActiveRecord::RecordNotFound unless current_club

    @tournament = current_club.tournaments.find(params[:tournament_id])
    @entry = @tournament.tournament_entries.find(params[:entry_id])
    raise ActiveRecord::RecordNotFound unless Questionnaires::EligibleEntries.asks?(@tournament)

    @questionnaire = @entry.questionnaire
    @place = Questionnaires::EligibleEntries.call(tournament: @tournament)
                                            .find { |e| e[:entry].id == @entry.id }&.dig(:place)

    on_boat = @entry.tournament_entry_members.exists?(user_id: current_user.id)
    staff = current_user.admin? || current_user.organizer_in?(current_club)
    allowed = (on_boat || staff) && (@place.present? || @questionnaire.present?)
    raise ActiveRecord::RecordNotFound unless allowed
  end

  # Only string values keyed by question id survive; any other shape is
  # treated as "nothing submitted".
  def submitted_answers
    raw = params[:answers]
    return {} unless raw.respond_to?(:to_unsafe_h)

    raw.to_unsafe_h.select { |_, value| value.is_a?(String) }
  end

  def saved_answers
    return {} unless @questionnaire

    @questionnaire.answers.pluck(:club_question_id, :body).to_h { |id, body| [id.to_s, body] }
  end

  def prepare_form(typed:)
    @questions = current_club.questions.active.ordered.to_a
    @typed = typed
    @retired_answers =
      if @questionnaire
        @questionnaire.answers.joins(:club_question)
                      .merge(ClubQuestion.retired.ordered)
                      .pluck("club_questions.prompt", :body)
      else
        []
      end
  end
end
