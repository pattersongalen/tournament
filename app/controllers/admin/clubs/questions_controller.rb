# Site-admin management of a club's top-3 questionnaire questions (see
# ClubQuestion). Questions are retired, never deleted, so answers already
# given stay readable. The site-admin gate and @foreign_club come from
# Admin::Clubs::BaseController.
class Admin::Clubs::QuestionsController < Admin::Clubs::BaseController
  before_action :set_question, only: [:update, :retire, :restore, :move]

  def index
    load_lists
    @new_question = @foreign_club.questions.new
  end

  def create
    @new_question = @foreign_club.questions.new(prompt: submitted_prompt, position: next_position)
    if @new_question.save
      redirect_to admin_club_questions_path(@foreign_club), notice: "Question added."
    else
      load_lists
      render :index, status: :unprocessable_entity
    end
  end

  def update
    if @question.update(prompt: submitted_prompt)
      redirect_to admin_club_questions_path(@foreign_club), notice: "Question renamed."
    else
      @failed_question = @question
      load_lists
      @new_question = @foreign_club.questions.new
      render :index, status: :unprocessable_entity
    end
  end

  def retire
    @question.update_columns(retired_at: Time.current, updated_at: Time.current)
    redirect_to admin_club_questions_path(@foreign_club), notice: "Question retired. Its answers are kept."
  end

  def restore
    @question.assign_attributes(retired_at: nil, position: next_position)
    if @question.save
      redirect_to admin_club_questions_path(@foreign_club), notice: "Question restored."
    else
      redirect_to admin_club_questions_path(@foreign_club),
                  alert: "Can't restore: #{@question.errors.full_messages.to_sentence.downcase}."
    end
  end

  # Swaps the question with its active neighbour and renumbers the whole
  # active list, so gaps or ties in `position` heal on any move.
  def move
    step = { "up" => -1, "down" => 1 }[params[:direction].is_a?(String) ? params[:direction] : nil]
    list = @foreign_club.questions.active.ordered.to_a
    from = list.index(@question)
    to = from && step ? from + step : nil

    if to && to.between?(0, list.size - 1)
      list[from], list[to] = list[to], list[from]
      ClubQuestion.transaction do
        list.each_with_index { |question, index| question.update_columns(position: index + 1) }
      end
    end
    redirect_to admin_club_questions_path(@foreign_club)
  end

  private

  def set_question
    @question = @foreign_club.questions.find(params[:id])
  end

  def submitted_prompt
    value = params.dig(:club_question, :prompt) if params[:club_question].respond_to?(:dig)
    value.is_a?(String) ? value : ""
  end

  def next_position
    (@foreign_club.questions.maximum(:position) || 0) + 1
  end

  def load_lists
    @active_questions = @foreign_club.questions.active.ordered.to_a
    @retired_questions = @foreign_club.questions.retired.order(:prompt).to_a
  end
end
