module OrganizerActions
  module TournamentEntries
    extend ActiveSupport::Concern

    # Shared by Admin::TournamentEntriesController and
    # Organizers::TournamentEntriesController — the two namespaces differ only in
    # layout and in which path helpers their redirects use (the *_path hooks
    # on each BaseController).

    included do
      before_action :load_tournament
    end

    def create
      user_ids = Array(params.dig(:tournament_entry, :member_user_ids)).map(&:to_i).reject(&:zero?).uniq
      name = params.dig(:tournament_entry, :name)
      valid_ids = current_club.members.active.where(id: user_ids).pluck(:id)
      if valid_ids.size != user_ids.size
        redirect_to tournament_edit_path(@tournament), alert: "One or more selected members are unavailable." and return
      end

      created_entry_ids = []
      ::Tournament.transaction do
        if @tournament.mode_solo?
          valid_ids.each do |uid|
            entry = @tournament.tournament_entries.create!
            entry.tournament_entry_members.create!(user_id: uid)
            created_entry_ids << entry.id
          end
        else
          entry = @tournament.tournament_entries.create!(name: name)
          valid_ids.each { |uid| entry.tournament_entry_members.create!(user_id: uid) }
          created_entry_ids << entry.id
        end

        # Linked tournaments (the Wednesday Main + Side pair) share one roster:
        # mirror each new entry across the group. Solo entries have neither a boat
        # nor a name, so SyncEntry no-ops on them.
        #
        # Inside the transaction: SyncEntry can legitimately reject (a crew
        # member who judges the sibling), and outside it the local entries would
        # stay committed while the rescue below tells the organizer the add
        # failed — leaving entries on this side only, permanently out of sync
        # with the pair, and skipping the pushes and the broadcast besides.
        # SyncEntry defers its own frames to the outermost commit, so wrapping
        # it costs nothing.
        ::TournamentEntry.where(id: created_entry_ids).each do |created|
          ::TournamentLinks::SyncEntry.call(entry: created)
        end

        # Adds are forward-only by default. With the admin-only backfill flag set,
        # replay the new entrants' already-logged in-window catches now — before the
        # broadcast below, so it reflects the backfilled standings. The sweep skips
        # already-placed catches, so on-time entrants are no-ops.
        if @tournament.backfill_late_entrants?
          ::Tournaments::BackfillEntrantCatches.call(
            tournament: @tournament, users: ::User.where(id: valid_ids).to_a
          )
        end
      end

      valid_ids.each do |uid|
        ::DeliverPushNotificationJob.perform_later(
          user_id: uid,
          title: @tournament.name,
          body: "You've been entered into #{@tournament.name}.",
          url: "/tournaments/#{@tournament.id}",
          tournament_id: @tournament.id
        )
      end

      # Only the new entries' cards changed (bingo); leave existing anglers' cards alone.
      ::Placements::BroadcastLeaderboard.call(tournament: @tournament, changed_entry_ids: created_entry_ids)

      added = @tournament.mode_solo? ? valid_ids.size : 1
      redirect_to tournament_edit_path(@tournament),
                  notice: added == 1 ? "Entry added." : "#{added} entries added."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to tournament_edit_path(@tournament), alert: e.message
    end

    def update
      entry = @tournament.tournament_entries.find(params[:id])
      renamed = false
      # Inside the transaction, and before the broadcast, for the reason spelled
      # out in #create: SyncEntry can legitimately reject (it may have to mint a
      # fresh counterpart, and a crew member who judges the sibling — or is
      # already in another entry there — refuses it). Renaming first and
      # broadcasting first would put the new name on the wire and leave it
      # committed on this side alone, while the rescue below tells the organizer
      # the rename failed and the pair sits out of sync with nothing to repair it.
      ::Tournament.transaction do
        renamed = entry.update(name: params.dig(:tournament_entry, :name).to_s.strip.presence)
        ::TournamentLinks::SyncEntry.call(entry: entry) if renamed
      end

      if renamed
        # A rename only affects the leaderboard row, not the bingo card grids.
        ::Placements::BroadcastLeaderboard.call(tournament: @tournament, changed_entry_ids: [entry.id])
        redirect_to tournament_edit_path(@tournament), notice: "Entry renamed."
      else
        redirect_to tournament_edit_path(@tournament), alert: entry.errors.full_messages.to_sentence
      end
    rescue ActiveRecord::RecordInvalid => e
      redirect_to tournament_edit_path(@tournament), alert: e.message
    end

    def destroy
      entry = @tournament.tournament_entries.find(params[:id])
      entry_id = entry.id
      # One transaction, as in #create: RemoveEntry hard-destroys the counterpart
      # entries and cascades their catch_placements, so a failure between it and
      # the local destroy would leave the Side entry and its placements gone while
      # the Main entry survived — and the flash still said "Entry removed".
      # destroy!, not destroy, so that failure actually reaches the rescue instead
      # of being swallowed as a falsy return. RemoveEntry defers its sibling
      # broadcasts to this transaction's commit.
      ::Tournament.transaction do
        ::TournamentLinks::RemoveEntry.call(entry: entry)
        entry.destroy!
      end
      # The removed entry drops off the leaderboard; sibling cards are untouched.
      ::Placements::BroadcastLeaderboard.call(tournament: @tournament, changed_entry_ids: [entry_id])
      redirect_to tournament_edit_path(@tournament), notice: "Entry removed."
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
      redirect_to tournament_edit_path(@tournament), alert: e.message
    end

    private

    def load_tournament
      @tournament = current_club.tournaments.find(params[:tournament_id])
    end
  end
end
