module OrganizerActions
  module Boats
    extend ActiveSupport::Concern

    # Shared by Admin::BoatsController and
    # Organizers::BoatsController — the two namespaces differ only in
    # layout and in which path helpers their redirects use (the *_path hooks
    # on each BaseController).

    def index
      @boats = current_club.boats.includes(:captain).active.alphabetical
      @retired_boats = current_club.boats.includes(:captain).where(active: false).alphabetical
      # One grouped query for the whole Retired section, so the Delete confirm can
      # name how many entries it would unlink without a count per row. Finished
      # tournaments only: the confirm calls these "past entries", and #purge
      # refuses outright while any of them is still live.
      @retired_entry_counts = ::TournamentEntry.in_finished_tournaments
                                               .where(boat_id: @retired_boats.map(&:id))
                                               .group(:boat_id).count
    end

    def enter
      tournament = current_club.tournaments.find(params[:tournament_id])
      unless tournament.mode_team?
        redirect_to tournament_edit_path(tournament), alert: "Boats are for team tournaments." and return
      end
      boat = current_club.boats.find(params[:id])
      # The picker lists active boats only, but the page is a snapshot: one
      # organizer can retire a boat while another still has the row on screen.
      # Without this the tap enters the retired boat, going around the very
      # Restore flow the retired_boat_named branch in #create steers people into.
      unless boat.active?
        redirect_to boats_index_path,
                    alert: "#{boat.name} is retired. Restore it on the Boats screen to enter it." and return
      end
      ::Boats::Enter.call(tournament: tournament, boat: boat)
      redirect_to tournament_edit_path(tournament), notice: "#{boat.name} entered."
    rescue ActiveRecord::RecordInvalid, ::Boats::Enter::InactiveCrew => e
      redirect_to tournament_edit_path(tournament), alert: e.message
    end

    def create
      tournament = current_club.tournaments.find(params[:tournament_id])
      unless tournament.mode_team?
        redirect_to tournament_edit_path(tournament), alert: "Boats are for team tournaments." and return
      end
      name = params.dig(:boat, :name)

      if (match = ::Boats::NearMatch.call(club: current_club, name: name))
        if tournament.tournament_entries.exists?(boat_id: match.id)
          redirect_to tournament_edit_path(tournament), alert: "#{match.name} is already entered." and return
        end
        redirect_to tournament_edit_path(tournament),
                    alert: "Did you mean #{match.name}? Tap it in the list to enter it." and return
      end

      boat = current_club.boats.new(name: name, captain_user_id: params.dig(:boat, :captain_user_id))
      if boat.save
        ::Boats::Enter.call(tournament: tournament, boat: boat)
        redirect_to tournament_edit_path(tournament), notice: "#{boat.name} entered."
      elsif (retired = retired_boat_named(name))
        redirect_to boats_index_path,
                    alert: "#{retired.name} is retired. Restore it on the Boats screen to enter it."
      else
        redirect_to tournament_edit_path(tournament), alert: boat.errors.full_messages.to_sentence
      end
    rescue ActiveRecord::RecordInvalid, ::Boats::Enter::InactiveCrew => e
      redirect_to tournament_edit_path(tournament), alert: e.message
    end

    def update
      boat = current_club.boats.find(params[:id])
      # #create refuses a near-match; a rename must too. The name index is unique
      # on exact lower(name) only, so renaming "Big Tiller" to "Team Majestic Red"
      # while "Magestic Red" is active saves fine and recreates the very
      # duplicate-spelling split this feature exists to prevent — and leaves
      # NearMatch.call picking whichever of the two `detect` reaches first.
      if (match = ::Boats::NearMatch.call(club: current_club, name: params.dig(:boat, :name), except: boat))
        redirect_to boats_index_path,
                    alert: "#{match.name} is already a boat. Rename or retire it first." and return
      end
      if boat.update(name: params.dig(:boat, :name), captain_user_id: params.dig(:boat, :captain_user_id))
        ::Boats::RenameEntries.call(boat: boat)
        redirect_to boats_index_path, notice: "Boat updated."
      else
        redirect_to boats_index_path, alert: boat.errors.full_messages.to_sentence
      end
    rescue ActiveRecord::RecordInvalid => e
      redirect_to boats_index_path, alert: e.message
    end

    def destroy
      boat = current_club.boats.find(params[:id])
      boat.update!(active: false)
      redirect_to boats_index_path, notice: "#{boat.name} retired."
    end

    def restore
      boat = current_club.boats.find(params[:id])
      boat.update!(active: true)
      redirect_to boats_index_path, notice: "#{boat.name} restored."
    end

    # #destroy above retires; this is the real delete. It mirrors
    # Admin::MembersController#purge — a boat must be retired first, so a row
    # still live in the picker can't be destroyed by one stray tap, and the
    # Retired section is the only place the button renders.
    #
    # tournament_entries is dependent: :nullify, so history survives: past
    # leaderboards rank off the entry and its own name column and never read
    # boat_id. What the club loses is the boat-keyed machinery — the rename
    # cascade, "same as last week", and the [tournament_id, boat_id] guard.
    def purge
      boat = current_club.boats.find(params[:id])
      if boat.active?
        redirect_to boats_index_path, alert: "Retire #{boat.name} before deleting it."
      elsif ::TournamentEntry.in_unfinished_tournaments.exists?(boat_id: boat.id)
        redirect_to boats_index_path,
                    alert: "#{boat.name} is still entered in a tournament that hasn't ended. " \
                           "Remove the entry first, or delete the boat once the tournament is over."
      else
        name = boat.name
        boat.destroy!
        redirect_to boats_index_path, notice: "#{name} permanently deleted."
      end
    end

    private

    # Boat name uniqueness spans retired boats (both Boat#name_unique_in_club
    # and index_boats_on_club_id_and_lower_name do), but the picker and
    # Boats::NearMatch cover only active ones. So retiring "Majestic Red" and
    # then typing it again in "+ New boat…" fails the save with a bare "is
    # already a boat in this club" for a boat that is nowhere on screen — a dead
    # end mid-league-night. Name where the fix actually is instead.
    def retired_boat_named(name)
      key = name.to_s.strip.downcase
      return nil if key.blank?
      current_club.boats.where(active: false).detect { |boat| boat.name.downcase == key }
    end
  end
end
