module OrganizerActions
  module TournamentTemplates
    extend ActiveSupport::Concern

    # Shared by Admin::TournamentTemplatesController and
    # Organizers::TournamentTemplatesController — the two namespaces differ only in
    # layout and in which path helpers their redirects use (the *_path hooks
    # on each BaseController).

    included do
      include ::TemplateParams

      before_action :load_template, only: [:edit, :update, :destroy, :clone]

      # Kernel#clone means AbstractController::Base#action_methods drops :clone
      # unless it is defined *directly* on the controller class — it subtracts
      # every public method inherited from ActionController::Base, then adds back
      # only public_instance_methods(false). Moving the body into this concern
      # therefore un-routes the action, and with
      # raise_on_missing_callback_actions on, the :clone in the before_action
      # :only list above 404s EVERY action on the controller. Re-declare it on
      # the class so `super` reaches the implementation below.
      def clone = super
    end

    def index
      all = current_club.tournament_templates.order(:name).to_a
      # A pair is one league night, so show it once: drop the partner of any
      # template already in the list.
      seen = []
      @templates = all.reject do |template|
        hide = template.paired? && seen.include?(template.paired_template_id)
        seen << template.id
        hide
      end
    end

    def new
      @template = current_club.tournament_templates.new
      3.times { @template.tournament_template_scoring_slots.build }
    end

    def create
      @template = current_club.tournament_templates.new(template_params)
      if @template.save
        redirect_to templates_index_path
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @template.tournament_template_scoring_slots.build
    end

    def destroy
      @template.destroy
      redirect_to templates_index_path, notice: "Template deleted."
    end

    def update
      if @template.update(template_params)
        redirect_to templates_index_path
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def clone
      ::TournamentTemplates::Clone.call(
        template: @template,
        starts_at: params[:starts_at],
        ends_at: params[:ends_at],
        season_tag: @template.season_tag
      )
      redirect_to tournaments_index_path, notice: "Cloned."
    end

    private

    def load_template
      @template = current_club.tournament_templates.find(params[:id])
    end
  end
end
