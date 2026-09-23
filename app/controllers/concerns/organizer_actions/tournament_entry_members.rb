module OrganizerActions
  module TournamentEntryMembers
    extend ActiveSupport::Concern

    # Shared by Admin::TournamentEntryMembersController and
    # Organizers::TournamentEntryMembersController — the two namespaces differ only in
    # layout and in which path helpers their redirects use (the *_path hooks
    # on each BaseController).

    included do
      before_action :load_tournament_and_entry
    end

    def create
      unless @tournament.mode_team?
        return redirect_to tournament_edit_path(@tournament),
                           alert: "Solo entries can't have additional members; create a new entry instead."
      end
      user = current_club.members.active.find_by(id: params[:user_id])
      unless user
        redirect_to tournament_edit_path(@tournament), alert: "Member not found." and return
      end
      # Adds are forward-only by default: catches the user already logged in this
      # tournament's window before being added to the entry are NOT retroactively
      # placed. The admin-only backfill_late_entrants flag lifts that restriction —
      # when set, replay this user's in-window catches immediately after the add.
      #
      # The mirror runs inside the same transaction as the local add. SyncEntry
      # can legitimately reject — a crew member who judges the sibling, or who is
      # already in another entry over there — and without the transaction the
      # local row stays committed while the rescue below tells the organizer the
      # add failed. The member would sit on the Main entry only, permanently out
      # of sync with its pair, with nothing offering a repair.
      ActiveRecord::Base.transaction do
        @entry.tournament_entry_members.create!(user_id: user.id)
        if @tournament.backfill_late_entrants?
          ::Tournaments::BackfillEntrantCatches.call(tournament: @tournament, users: [ user ])
        end
        ::TournamentLinks::SyncEntry.call(entry: @entry)
      end
      redirect_to tournament_edit_path(@tournament), notice: "Added #{user.name}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to tournament_edit_path(@tournament), alert: e.message
    end

    def same_as_last_week
      unless @tournament.mode_team? && @entry.boat
        return redirect_to tournament_edit_path(@tournament),
                           alert: "This entry isn't a saved boat."
      end
      crew = ::Boats::LastCrew.call(boat: @entry.boat, before_tournament: @tournament)
      if crew.empty?
        return redirect_to tournament_edit_path(@tournament),
                           alert: "#{@entry.boat.name} hasn't fished before."
      end

      already = @entry.tournament_entry_members.pluck(:user_id)
      added_users = []
      ActiveRecord::Base.transaction do
        crew.each do |user|
          next if already.include?(user.id)
          # with_active_user, not active: nothing writes club_memberships'
          # own deactivated_at (see ClubMembership), so `active` alone filters
          # nobody out and one tap here would re-add an angler who has left the
          # club — contradicting the per-entry "Add" dropdown on this same
          # screen, which lists current_club.members.active.
          next unless ClubMembership.with_active_user.exists?(club_id: @tournament.club_id, user_id: user.id)
          @entry.tournament_entry_members.create!(user_id: user.id)
          added_users << user
        end
        if @tournament.backfill_late_entrants? && added_users.any?
          ::Tournaments::BackfillEntrantCatches.call(tournament: @tournament, users: added_users)
        end
        # Mirrored inside the transaction for the reason spelled out in #create.
        ::TournamentLinks::SyncEntry.call(entry: @entry)
      end
      redirect_to tournament_edit_path(@tournament),
                  notice: added_users.empty? ? "Same crew already aboard." : "Added #{added_users.size} from last time."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to tournament_edit_path(@tournament), alert: e.message
    end

    def destroy
      unless @tournament.mode_team?
        return redirect_to tournament_edit_path(@tournament),
                           alert: "Solo entries don't have removable members; remove the entry itself."
      end
      member = @entry.tournament_entry_members.find(params[:id])
      name = member.user&.name || "Member"
      # Mirrored inside the transaction for the reason spelled out in #create:
      # the rescue below tells the organizer the removal failed, so it must
      # actually have failed. Otherwise the member is off this entry and still
      # aboard the sibling, with nothing offering a repair.
      ActiveRecord::Base.transaction do
        ::Catches::DropMemberFromEntry.call(entry: @entry, user: member.user)
        ::TournamentLinks::SyncEntry.call(entry: @entry)
      end
      redirect_to tournament_edit_path(@tournament), notice: "Removed #{name}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to tournament_edit_path(@tournament), alert: e.message
    end

    private

    def load_tournament_and_entry
      @tournament = current_club.tournaments.find(params[:tournament_id])
      @entry = @tournament.tournament_entries.find(params[:tournament_entry_id])
    end
  end
end
