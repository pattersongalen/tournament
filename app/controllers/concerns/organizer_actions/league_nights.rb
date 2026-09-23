module OrganizerActions
  module LeagueNights
    extend ActiveSupport::Concern

    # Shared by Admin::LeagueNightsController and
    # Organizers::LeagueNightsController — the two namespaces differ only in
    # layout and in which path helpers their redirects use (the *_path hooks
    # on each BaseController).

    included do
      include ::LeagueNightParams

      before_action :load_template
    end

    def new
      @occurrence = ::LeagueNights::NextOccurrence.call(template: @template, on: requested_date)
      @formats = schedulable_formats
    end

    def create
      # Resolved against the date being SUBMITTED, not the template's next
      # occurrence — see LeagueNightParams#submitted_date. This is what makes a
      # backdated repair see the half that already exists.
      occurrence = ::LeagueNights::NextOccurrence.call(template: @template, on: submitted_date)
      if occurrence.fully_scheduled?
        redirect_to templates_index_path,
                    alert: "That week is already scheduled." and return
      end

      # A half-scheduled night is the one place creating a single tournament is
      # legitimate: repairing a night that already ran with only one of its two
      # tournaments (2026-08-06 was a Main with no Side). Whichever half is
      # missing becomes the "main" of the call, so Schedule builds exactly one and
      # leaves the tournament that already exists untouched.
      #
      # Guarded on the pair still being there: partially_scheduled? is XOR on
      # presence, so an UNPAIRED template reports "half done" the moment anything
      # exists for its week, when in fact nothing is missing. load_template turns
      # unpaired templates away before this runs — the guard keeps the create path
      # from depending on that staying true.
      repairing = occurrence.partially_scheduled? && @template.paired_template.present?
      args =
        if repairing
          missing = occurrence.existing_main.present? ? :side : :main
          { main_template: missing == :side ? @template.paired_template : @template,
            side_template: nil, main: column_params(missing), side: nil }
        else
          { main_template: @template, side_template: @template.paired_template,
            main: column_params(:main), side: column_params(:side) }
        end

      if (rejected = unschedulable_format(args))
        return render_new_with_error(format_rejection_message(rejected))
      end

      tournaments = ::LeagueNights::Schedule.call(
        starts_at: league_night_params[:starts_at],
        ends_at: league_night_params[:ends_at],
        **args
      )
      flash_message =
        if repairing
          link_repaired_half(tournaments.first, occurrence.existing_main || occurrence.existing_side)
        else
          { notice: "League night scheduled." }
        end
      redirect_to tournament_edit_path(tournaments.first), **flash_message
    rescue ActiveRecord::RecordInvalid => e
      render_new_with_error(e.message)
    end

    private

    # Schedule only mints a link_group_id when it builds a pair, so a repaired
    # half comes out unlinked — no shared roster, no shared boats, which is the
    # point of a league-night pair. Join it to the half that already exists.
    #
    # Argument order is load-bearing and Join itself doesn't say so: the NEWLY
    # created tournament goes in as `tournament:`. Join's first back-fill pass
    # iterates `tournament`'s entries (it has none yet — a no-op) and its second
    # iterates `other`'s, mirroring that roster across; because
    # Tournament#linked_tournaments excludes self, every broadcast from that pass
    # targets the new tournament alone. Reversed, the second pass would fire one
    # synchronous Placements::BroadcastLeaderboard per entry at the tournament
    # that already finished.
    #
    # notify: false — a repair is an administrative back-fill, not an entry
    # event, and DeliverPushNotificationJob has no started/ended guard.
    #
    # Deliberately NOT wrapped in one transaction with Schedule: SyncEntry
    # broadcasts and enqueues after ITS transaction commits, and an enclosing
    # transaction would make that block non-outermost, firing both before the
    # real commit — the phantom-row case SyncEntry's own comment exists to
    # prevent. Rescued separately for the same reason: the tournament is already
    # committed, so letting a raise fall through to #create's rescue would render
    # 422 for a create that succeeded, and the retry would then hit
    # fully_scheduled? and dead-end on "That week is already scheduled."
    def link_repaired_half(created, existing)
      ::TournamentLinks::Join.call(tournament: created, other: existing, notify: false)
      { notice: "League night scheduled." }
    rescue ActiveRecord::RecordInvalid
      # alert:, not notice: — the tournament exists but the pair is half-made, so
      # this belongs in the failure channel rather than the green success flash.
      { alert: "Created, but couldn't link it to the existing tournament — link them from the tournament page." }
    end

    # Both failure paths come back here. @submitted carries the operator's own
    # choices into the re-render: rebuilding @occurrence alone hands back a
    # pristine form, throwing away every format, species, count and time just
    # picked and leaving only the error text behind.
    def render_new_with_error(message)
      # Same date the submission was resolved against, so a failed repair
      # re-renders as a repair rather than reverting to the next occurrence.
      @occurrence = ::LeagueNights::NextOccurrence.call(template: @template, on: submitted_date)
      @formats = schedulable_formats
      @submitted = submitted_values
      @error = message
      render :new, status: :unprocessable_entity
    end

    def load_template
      @template = current_club.tournament_templates.find(params[:tournament_template_id])
      # paired_template rather than paired?: the latter only reads the raw id, and
      # everything downstream here dereferences the record itself.
      return if @template.paired_template.present?
      redirect_to templates_index_path,
                  alert: "That template isn't paired with another one."
    end
  end
end
