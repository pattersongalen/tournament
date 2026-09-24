module Catches
  class ApplyJudgeAction
    class SelfApprovalError < StandardError; end
    class DisqualifyNoteRequired < StandardError; end
    class ForceSlotUnsupported < StandardError; end

    def self.call(tournament:, catch:, judge:, action:, note: nil,
                  length_inches: nil, length_unit: nil, species_id: nil, tag_number: nil,
                  slot_index: nil, entry_id: nil,
                  photo: nil, override_in_lake: nil, override_in_sask: nil, latitude: nil, longitude: nil,
                  club: nil)
      new(tournament: tournament, catch: catch, judge: judge, action: action, note: note,
          length_inches: length_inches, length_unit: length_unit, species_id: species_id,
          tag_number: tag_number, slot_index: slot_index, entry_id: entry_id, photo: photo,
          override_in_lake: override_in_lake, override_in_sask: override_in_sask,
          latitude: latitude, longitude: longitude, club: club).call
    end

    def initialize(tournament:, catch:, judge:, action:, note:, length_inches:, length_unit:, species_id:, slot_index:, entry_id:, photo:, override_in_lake:, override_in_sask:, latitude:, longitude:, tag_number: nil, club: nil)
      @tournament, @catch, @judge, @action, @note = tournament, catch, judge, action.to_sym, note
      @length_inches, @length_unit = length_inches, length_unit
      @species_id, @slot_index, @entry_id = species_id, slot_index, entry_id
      @tag_number = tag_number
      @photo = photo
      @override_in_lake, @override_in_sask = override_in_lake, override_in_sask
      @latitude, @longitude = latitude, longitude
      # When set, the acting user only has authority in this club: reconcile and
      # broadcast are confined to its tournaments so the edit never reshuffles or
      # re-broadcasts another club's baskets. The organizer/admin catch editor
      # passes it with tournament: nil; a judge passes @tournament.club so a
      # per-tournament correction stays within that tournament's club too.
      @club = club
      @snapshot_old_attachment_id = nil
      @notify_owner = false
      @ticket_withheld = false
    end

    def call
      raise SelfApprovalError if @action == :approve && @judge.id == @catch.user_id
      raise DisqualifyNoteRequired if @action == :disqualify && @note.to_s.strip.empty?

      affected_tournaments = []

      ActiveRecord::Base.transaction do
        @catch.lock!  # serialize with PlaceInSlots on the same catch
        before = snapshot
        case @action
        when :approve, :dock_verify
          @catch.update!(status: :synced)
        when :flag
          @catch.update!(status: :needs_review)
        when :disqualify
          lock_entries!(@catch.catch_placements.active.pluck(:tournament_entry_id))
          freed = @catch.catch_placements.active.to_a
          @catch.catch_placements.active.deactivate_all
          @catch.update!(status: :disqualified)
          @notify_owner = true
          # No p.reload: the reconcile services re-query placements from the DB
          # (which already reflects the update_all above) and never read p.active.
          freed.each { |p| Catches::ReconcileFreedSlot.call(placement: p) }
        when :manual_override
          prior_length  = @catch.length_inches
          prior_species = @catch.species_id
          prior_tag     = @catch.tag_number.presence

          length_changed  = @length_inches && @length_inches.to_f != prior_length.to_f
          unit_changed    = @length_unit.present? && @length_unit != @catch.length_unit
          species_changed = @species_id.present? && @species_id != prior_species
          # Science tag. nil means "not on this form" and leaves the tag alone; a
          # submitted value (blank included) is normalized the way the model will
          # store it and compared to the stored tag, so re-saving an unchanged tag
          # is a no-op.
          new_tag     = ::Catch.normalize_tag(@tag_number) unless @tag_number.nil?
          tag_changed = !@tag_number.nil? && new_tag != prior_tag

          # One update! for every edited field so the model's Tagged-Walleye
          # tag-required rule sees the final species/tag pair: a species change
          # away from Tagged Walleye that blanks the tag, or a length fix on a
          # Tagged Walleye stranded with a blank tag, would otherwise be rejected
          # by an intermediate save. Length lands before the rebuild below so
          # PlaceInSlots ranks the catch with its NEW length in the NEW species.
          attrs = {}
          attrs.merge!({ length_inches: @length_inches, length_unit: @length_unit }.compact) if @length_inches && (length_changed || unit_changed)
          attrs[:species_id] = @species_id if species_changed
          attrs[:tag_number] = new_tag if tag_changed
          if attrs.any?
            @catch.update!(attrs)
            @notify_owner = true
          end

          # Only a tagged-format tournament scores the tag, and only its presence:
          # each tagged catch earns one ticket, a blank-tag catch is skipped.
          if species_changed
            # A new species can make the catch newly (in)eligible, so rebuild its
            # placements from scratch. This is also the only way a tag legitimately
            # goes present -> blank: the model rejects a blank tag on Tagged
            # Walleye, and a tagged tournament scores nothing else, so clearing a
            # stray tag on any other species (no species change) can't touch a
            # placement and deliberately skips the rebuild — on an append-only
            # format like Fish Train a needless rebuild would leave a permanent
            # hole and re-append the fish out of capture order.
            deactivate_and_replace!
          elsif tag_changed && prior_tag.nil? && @catch.species.tagged_walleye?
            # blank -> present on a Tagged Walleye: the catch may now qualify for
            # a tagged tournament that skipped it. Re-place into ONLY those
            # tournaments — a full PlaceInSlots run would also revisit every
            # non-tagged tournament the catch is eligible for, and on an
            # append-only format that re-appends a legitimately bumped fish as a
            # fresh arrival. Existing tickets are untouched (PlaceInSlots no-ops
            # where the catch already holds an active placement).
            tagged_rows = reachable_rows.select { |r| r[:tournament].format_tagged? }
            if tagged_rows.any?
              # Lock every entry this edit can touch, not just the tagged ones:
              # a length fix submitted alongside the tag reconciles the other
              # reachable entries below, and locking a tagged entry first would
              # take them out of ascending order against a concurrent
              # PlaceInSlots (a deadlock).
              lock_touched_entries!
              # One run scoped to the list, handed the rows already resolved
              # above so nothing is looked up again under the row locks.
              placed = ::Catches::PlaceInSlots.call(catch: @catch, broadcast: false, club: @club, rows: reachable_rows,
                                                    tournaments: tagged_rows.map { |r| r[:tournament] })
              # PlaceInSlots deliberately mints nothing into a tournament whose
              # draw already ran. The tag still saves, so tell the caller: the
              # organizer otherwise sees "Catch updated." and assumes a ticket.
              ticketed = placed[:created].map(&:tournament_id)
              @ticket_withheld = ::Tournament.where(id: tagged_rows.map { |r| r[:tournament].id })
                                             .where.not(drawn_at: nil).where.not(id: ticketed).exists?
            end
          end
          # present -> present (a typo fix) changes no placement: the ticket a
          # drawn winner rests on stays the same row. A tag added to or cleared
          # from a non-Tagged-Walleye catch is bookkeeping only.

          if @slot_index && @entry_id
            # A forced slot is only durable/meaningful on slot-based formats. On a
            # length-derived or every-catch format it would break the format's
            # invariants and be reverted by the next reconcile, so reject it.
            raise ForceSlotUnsupported unless @tournament.supports_forced_slot?
            @notify_owner = true
            entry = @tournament.tournament_entries.find(@entry_id)
            entry.lock!
            entry.catch_placements
              .where(species: @catch.species, slot_index: @slot_index, active: true)
              .update_all(active: false)
            CatchPlacement.create!(
              catch: @catch, tournament: @tournament, tournament_entry: entry,
              species: @catch.species, slot_index: @slot_index, active: true
            )
          elsif !species_changed && @length_inches && prior_length && @length_inches.to_f != prior_length.to_f
            # A length edit can change which catches make each basket — it can pull
            # in a previously-unplaced backup (e.g. one grown past a slot threshold)
            # or drop a now-smaller fish. So re-derive every tournament the catch is
            # ELIGIBLE for at its capture time, not just the ones where it currently
            # holds a placement. Re-derivation from the whole eligible set is correct
            # for grow and shrink alike (no shrink gating). A species change
            # already rebuilt placements via deactivate_and_replace! with the new
            # length, so skip then. A tag change does NOT: its re-placement only
            # visits tagged tournaments (which don't score length), so a length
            # fix submitted alongside a tag still reconciles here.
            candidate_rows = reachable_rows
            # Which of those tournaments actually score this species? Resolve it in
            # one query rather than a per-row scoring_slots.exists? (an N+1 under the
            # @catch row lock we hold here).
            scored_tournament_ids = ::ScoringSlot
              .where(tournament_id: candidate_rows.map { |r| r[:tournament].id }, species_id: @catch.species_id)
              .distinct.pluck(:tournament_id).to_set
            eligible = candidate_rows.select { |r| scored_tournament_ids.include?(r[:tournament].id) }

            # ActiveForUser drops tournaments where the owner is now also a judge,
            # or whose window no longer covers captured_at_device. A stale placement
            # can still live in one of those, so union in every tournament where the
            # catch currently holds an active placement this edit may rebuild
            # (rebuildable_placements: every one for a judge, the editing club's
            # for a per-club edit — the same set lock_touched_entries! locks).
            # Keyed by entry id, so a tournament in both sets is reconciled once.
            placed = rebuildable_placements.map { |p| { tournament: p.tournament, entry: p.tournament_entry } }

            rows = (eligible + placed).uniq { |r| r[:entry].id }
            rows.sort_by { |r| r[:entry].id }  # stable lock order
              .each do |r|
                Catches::ReconcileBasket.call(tournament: r[:tournament], entry: r[:entry], species: @catch.species)
              end
          end
        when :add_reference_photo
          old_ref_id = @catch.reference_photo.attached? ? @catch.reference_photo.blob.id : nil
          @catch.reference_photo.attach(@photo)
          # A reference photo is just a clearer image for review; it must not
          # silently reopen a disqualified catch. A DQ'd catch has no active
          # placements and can only return to scoring via :reinstate (which
          # refuses anything that isn't currently disqualified) — flipping it to
          # needs_review here would strand it: off the leaderboard, un-reinstatable.
          # Leave a disqualified catch disqualified; for any other status, queue
          # it for a judge to re-review with the new photo. update! runs either
          # way so the reference_photo validation still rejects a bad upload.
          new_status = @catch.disqualified? ? @catch.status : :needs_review
          @catch.update!(status: new_status)
          set_ivars_for_snapshot(old_ref_id: old_ref_id)
        when :geofence_override
          @catch.update!(override_in_lake: @override_in_lake, override_in_sask: @override_in_sask)
          recompute_flags!
          deactivate_and_replace!
        when :correct_location
          @catch.update!(latitude: @latitude, longitude: @longitude)
          recompute_flags!
          deactivate_and_replace!
        when :reinstate
          prior_dq = ::JudgeAction.where(catch_id: @catch.id, action: ::JudgeAction.actions[:disqualify])
                                  .order(:created_at).last
          restored_status = prior_dq&.before_state&.dig("status") || "synced"
          # A DQ'd catch has no active placements to free; just lock the entries
          # PlaceInSlots will iterate before re-placing.
          lock_entries!(reachable_entry_ids)
          @catch.update!(status: restored_status)
          @notify_owner = true
          # Hand over the rows resolved for the locks above rather than have
          # PlaceInSlots run ActiveForUser again while holding them.
          placed = ::Catches::PlaceInSlots.call(catch: @catch, broadcast: false, club: @club, rows: reachable_rows)
          repoint_drawn_winners!(placed[:created])
        end
        after = snapshot

        JudgeAction.create!(
          judge_user: @judge, catch: @catch, action: @action, note: @note,
          before_state: before, after_state: after
        )

        affected_tournaments = @catch.catch_placements.includes(:tournament).map(&:tournament).uniq
        # Bingo keeps no placements, so its tournaments never appear above. Union in
        # every bingo tournament this catch is eligible for at its capture time so the
        # card/leaderboard re-derive (and re-broadcast) after this edit.
        bingo_tournaments = ::Tournament.format_bingo
          .joins(tournament_entries: :tournament_entry_members)
          .where(tournament_entry_members: { user_id: @catch.user_id })
          .where("starts_at <= :at AND (ends_at IS NULL OR ends_at >= :at)", at: @catch.captured_at_device)
          .distinct.to_a
        affected_tournaments = (affected_tournaments + bingo_tournaments).uniq
        # A per-club editor edit only re-broadcasts its own club's leaderboards.
        affected_tournaments.select! { |t| t.club_id == @club.id } if @club
      end

      # Broadcast AFTER the transaction commits so other DB connections see the
      # new state when they rebuild the leaderboard.
      affected_tournaments.each do |t|
        Placements::BroadcastLeaderboard.call(tournament: t, changed_entry_ids: bingo_changed_entry_ids(t))
      end

      # @notify_owner is only set by tournament-scoped actions (disqualify,
      # manual_override, reinstate); the guard keeps the @tournament derefs below
      # safe even though add_reference_photo intentionally passes tournament: nil.
      if @notify_owner && @tournament && @judge.id != @catch.user_id
        DeliverPushNotificationJob.perform_later(
          user_id: @catch.user_id,
          title: @tournament.name,
          body: notification_body,
          url: "/tournaments/#{@tournament.id}",
          tournament_id: @tournament.id
        )
      end

      # ticket_withheld: a manual_override tag add reached a tagged tournament
      # whose draw had already run, so the tag saved but no ticket was issued.
      { ticket_withheld: @ticket_withheld }
    end

    private

    # For a bingo tournament, the only card this edit changes is the one the catch's
    # owner belongs to — return its entry id(s) so BroadcastLeaderboard rebroadcasts
    # just that card. nil for non-bingo (the arg is ignored there).
    def bingo_changed_entry_ids(tournament)
      return nil unless tournament.format_bingo?
      tournament.tournament_entries
        .joins(:tournament_entry_members)
        .where(tournament_entry_members: { user_id: @catch.user_id })
        .pluck(:id)
        .presence
    end

    def notification_body
      species_name = @catch.species&.name
      case @action
      when :disqualify      then "A judge disqualified your #{species_name} catch."
      when :manual_override then "A judge adjusted your #{species_name} catch."
      when :reinstate       then "A judge reinstated your #{species_name} catch."
      end
    end

    def set_ivars_for_snapshot(old_ref_id:)
      @snapshot_old_attachment_id = old_ref_id
    end

    # Re-derive the persisted flags column after a location/override change.
    # ComputeFlags.recompute preserves out-of-band flags (e.g. imported_photo)
    # it doesn't own, so we never have to maintain a carry-over list here.
    def recompute_flags!
      @catch.update!(flags: ::Catches::ComputeFlags.recompute(@catch))
    end

    # Lock the given entry ids in ascending order. Consistent ordering keeps
    # concurrent PlaceInSlots / other judge actions from deadlocking with us.
    def lock_entries!(entry_ids)
      entry_ids.uniq.sort.each { |id| TournamentEntry.lock.find(id) }
    end

    # Entries PlaceInSlots will iterate when re-placing this catch at its
    # captured_at_device — must be locked alongside the entries it currently
    # occupies, or a concurrent PlaceInSlots could grab an intermediate id we
    # later need while holding one we're waiting on.
    def reachable_entry_ids
      reachable_rows.map { |row| row[:entry].id }
    end

    # [{ tournament:, entry: }] rows PlaceInSlots would iterate for this catch,
    # narrowed to the editing club when one is set (mirrors PlaceInSlots' own
    # club filter so a per-club edit never places into another club's event).
    # Memoized: the set depends only on the catch's owner, capture time and the
    # editing club, none of which change during a call, and the branches above
    # would otherwise repeat its two queries under the @catch row lock.
    def reachable_rows
      @reachable_rows ||= begin
        rows = ::Tournaments::ActiveForUser.with_entries(user: @catch.user, at: @catch.captured_at_device)
        rows = rows.select { |r| r[:tournament].club_id == @club.id } if @club
        rows
      end
    end

    # The catch's active placements this edit may rebuild: every one for a judge
    # action (no @club), only the editing club's for a per-club editor edit.
    # Loaded once, with the entry and tournament each caller reads: it feeds
    # the entry locks, the freed-slot reconcile and the length reconcile, all
    # under the @catch row lock, and the set can't change between them (the
    # catch lock serializes every writer of its placements). A tag edit that
    # mints a ticket in between adds only tagged rows, which the length
    # reconcile treats as a no-op anyway.
    def rebuildable_placements
      @rebuildable_placements ||= begin
        active = @catch.catch_placements.active
        active = active.joins(:tournament).where(tournaments: { club_id: @club.id }) if @club
        active.includes(tournament_entry: :tournament).to_a
      end
    end

    # Lock, in one ascending pass, every entry a re-placement can touch: the
    # ones the catch currently occupies plus the ones PlaceInSlots will iterate.
    # Taking them all up front keeps later per-entry locks (ReconcileBasket,
    # PlaceInSlots) re-locks of rows already held, so the order can't invert.
    def lock_touched_entries!
      lock_entries!(rebuildable_placements.map(&:tournament_entry_id) + reachable_entry_ids)
    end

    # Drop the catch's active placements, promote backups into the freed slots,
    # then re-place the catch under its current state. A changed location,
    # override, or species can make the catch newly (in)eligible, so placements
    # are rebuilt from scratch. Used by geofence_override, correct_location, and
    # the species-change branch of manual_override.
    def deactivate_and_replace!
      lock_touched_entries!
      freed = rebuildable_placements
      CatchPlacement.where(id: freed.map(&:id)).deactivate_all
      freed.each { |p| ::Catches::ReconcileFreedSlot.call(placement: p) }
      # lock_touched_entries! already resolved reachable_rows; hand them over
      # rather than have PlaceInSlots look them up again under the locks.
      placed = ::Catches::PlaceInSlots.call(catch: @catch, broadcast: false, club: @club, rows: reachable_rows)
      repoint_drawn_winners!(placed[:created])
    end

    # A ticket re-issued by the flows above may be the drawn winner's (the
    # retired row was in the draw, so PlaceInSlots minted a replacement). Keep
    # the tournament's recorded winner on the live row. The write belongs to
    # the judge flows, the only callers that retire and replace a ticket, not
    # to PlaceInSlots, which the API sync and the backfill also run.
    def repoint_drawn_winners!(created)
      created.each do |ticket|
        ticket.tournament.repoint_drawn_winner!(ticket) if ticket.in_draw_pool?
      end
    end

    def snapshot
      # Use the loaded association rather than a fresh find_by: snapshot runs for
      # both before/after states, and Rails resets @catch.species when species_id
      # changes, so this still reflects the right species on each side of an edit.
      {
        "status"            => @catch.status,
        "length_inches"     => @catch.length_inches.to_s,
        "length_unit"       => @catch.length_unit,
        "species_id"        => @catch.species_id,
        "species_name"      => @catch.species&.name,
        "tag_number"        => @catch.tag_number,
        "active_placements" => @catch.catch_placements.where(active: true).pluck(:tournament_entry_id, :slot_index),
        "photo_attached"    => @catch.photo.attached?,
        "reference_photo_attached" => @catch.reference_photo.attached?,
        "reference_photo_blob_id" => @catch.reference_photo.attached? ? @catch.reference_photo.blob.id : nil,
        "reference_photo_prev_blob_id" => @snapshot_old_attachment_id,
        "latitude"          => @catch.latitude&.to_s,
        "longitude"         => @catch.longitude&.to_s,
        "override_in_lake"  => @catch.override_in_lake,
        "override_in_sask"  => @catch.override_in_sask,
      }
    end
  end
end
