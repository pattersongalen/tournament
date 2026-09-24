module Catches
  class PlaceInSlots
    # How long after placed_at another run of the same catch is assumed to be a
    # concurrent duplicate still in flight rather than a retry of one that died.
    # Comfortably longer than the seconds a racing POST takes, comfortably
    # shorter than the 90s floor deferRetry imposes before a client retries.
    IN_FLIGHT_WINDOW = 30.seconds

    def self.call(catch:, broadcast: true, club: nil, tournaments: nil, rows: nil)
      new(catch: catch, broadcast: broadcast, club: club, tournaments: tournaments, rows: rows).call
    end

    def initialize(catch:, broadcast: true, club: nil, tournaments: nil, rows: nil)
      @catch = catch
      @broadcast = broadcast
      # [{ tournament:, entry: }] already resolved by the caller (ApplyJudgeAction
      # resolves the same set to lock its entries first). Saves re-running
      # ActiveForUser under the row locks; the club/tournament scopes below
      # still apply to it.
      @rows = rows
      # When set (organizer/admin catch editor), only place into this club's
      # tournaments so a per-club edit never reshuffles another club's baskets.
      @club = club
      # When set, only place into these tournaments: the late-entrant backfill
      # passes the one tournament it sweeps (never touching other tournaments
      # the user was active in during the same window), and a science-tag edit
      # passes every tagged tournament the catch reaches, in one run. An empty
      # list places nowhere — it is a scope, not an absence of one.
      @only_tournament_ids = tournaments&.map(&:id)
    end

    def call
      created, bumped = [], []
      affected_tournaments = Set.new
      # Bingo only: the entry whose card this catch changes, keyed by tournament id,
      # so we rebroadcast just that angler's card rather than everyone's.
      bingo_changed_entry_ids = Hash.new { |h, k| h[k] = [] }

      # One outer transaction so all locks acquired here are released atomically.
      # Without it, two boats submitting catches for the same (entry, species) at
      # the same instant could both observe `size < slot_count` and both create
      # placements at the same slot_index, corrupting the leaderboard.
      ActiveRecord::Base.transaction do
        @catch.lock!  # serialize with ApplyJudgeAction on the same catch
        return { created: [], bumped: [], affected_tournaments: [], submitter: @catch.user } if @catch.disqualified?

        # Tournament ids where this catch already holds an active placement.
        # A concurrent duplicate POST's dedup-reconcile can race the original
        # request's still-uncommitted placement run; the @catch.lock! above
        # serializes us behind it, and skipping already-placed tournaments
        # makes the second run a no-op instead of a double-place (the
        # append-only formats create one placement per run). Scoped to ACTIVE
        # placements: judge reinstate/correction flows deactivate before
        # re-placing and must still re-place.
        already_placed_ids = CatchPlacement
          .where(catch_id: @catch.id, active: true)
          .distinct.pluck(:tournament_id).to_set

        rows = (@rows || Tournaments::ActiveForUser.with_entries(user: @catch.user, at: @catch.captured_at_device))
          .sort_by { |r| r[:entry].id }  # stable lock order across concurrent calls
        rows = rows.select { |r| r[:tournament].club_id == @club.id } if @club
        rows = rows.select { |r| @only_tournament_ids.include?(r[:tournament].id) } if @only_tournament_ids

        rows.each do |row|
          tournament = row[:tournament]
          entry      = row[:entry]
          next if already_placed_ids.include?(tournament.id)

          # Bingo keeps no placements — a card is derived on read. Just flag the
          # tournament so the post-commit block rebuilds & rebroadcasts it. A
          # geofence-excluded catch never fills a square (EvaluateCard drops it),
          # so don't flag/rebroadcast a card that can't have changed.
          if tournament.format_bingo?
            next unless @catch.geofence_eligible_for?(tournament)
            # already_placed_ids can never match a bingo tournament, so it
            # can't stop a duplicate concurrent POST of one client_uuid
            # (recover "Re-submit" racing a background drain) from running this
            # branch twice — the lock above only serializes the second run
            # behind the first, it doesn't cancel it, and
            # placements_evaluated_at is deliberately written last, after the
            # broadcast, so it is still NULL at this point. Without placed_at
            # the repeat re-broadcasts every entrant's card and re-fires the
            # took-the-lead push for a single fish.
            #
            # Only the first-placement path is guarded: the judge flows
            # re-place a catch on purpose after deactivating or reinstating it,
            # and pass broadcast: false to broadcast the rebuilt card
            # themselves.
            #
            # Bounded by IN_FLIGHT_WINDOW so the guard can't also swallow the
            # API's crash-recovery re-run. That path (serialize_existing, gated
            # on a nil placements_evaluated_at) is the SAME entry point as the
            # concurrent duplicate, so the only thing separating them is age:
            # the racing run placed this catch milliseconds ago and is about to
            # broadcast, while a crashed one placed it and died — its client
            # can't be back sooner than deferRetry's 90s floor. Skipping the
            # crashed case left every entrant's card a square stale for the
            # rest of the night, since bingo derives cards on read and nothing
            # else rebroadcasts them.
            next if @broadcast && @catch.placed_at.present? && @catch.placed_at > IN_FLIGHT_WINDOW.ago
            affected_tournaments << tournament
            bingo_changed_entry_ids[tournament.id] << entry.id
            next
          end

          slot       = tournament.scoring_slots.find_by(species_id: @catch.species_id)
          next if slot.nil?
          next unless @catch.geofence_eligible_for?(tournament)

          entry.lock!  # serialize with PromoteBackup, ReconcileStandard, other PlaceInSlots

          # Tournaments::ActiveForUser ran before the entry row lock was held, so a
          # concurrent DropMemberFromEntry could have removed the user from this entry
          # between resolution and lock acquisition. Re-verify membership now.
          next unless entry.tournament_entry_members.exists?(user_id: @catch.user_id)

          # Progressive Length re-derives its whole ladder in
          # ReconcileProgressiveLength and never reads active_placements, so skip
          # the per-species load for it rather than querying and discarding it.
          active_placements =
            if tournament.format_progressive_length?
              []
            else
              entry.catch_placements
                .where(species_id: @catch.species_id, active: true)
                .includes(:catch).order(:slot_index).to_a
            end

          if tournament.format_hidden_length? || tournament.format_beat_the_average? || tournament.format_random_bag?
            # Hidden Length / Beat the Average / Random Bag: every catch is kept;
            # the winning catch(es) are selected at reveal time. No bumping,
            # slot_count irrelevant. Use max(active slot_index)+1 (not size) so a
            # deactivated middle placement (e.g. judge DQ) doesn't make the next
            # index collide with an existing active row under
            # idx_active_placements_uniq_per_slot.
            next_index = active_placements.empty? ? 0 : active_placements.map(&:slot_index).max + 1
            created << CatchPlacement.create!(
              catch: @catch, tournament: tournament, tournament_entry: entry,
              species: @catch.species, slot_index: next_index, active: true
            )
            affected_tournaments << tournament
          elsif tournament.format_tagged?
            # Tagged: every catch with a tag earns a fresh placement (= one ticket in
            # the draw). Mirrors Hidden Length — no bumping, slot_count irrelevant.
            # Belt-and-suspenders skip if tag_number is blank; the Catch model
            # validates presence for Tagged Walleye, so this only fires if a non-
            # Tagged-Walleye species somehow slots into a tagged tournament.
            next if @catch.tag_number.blank?
            # The draw pool closes when the winner is drawn. A catch arriving
            # after that (a late offline sync, a science tag filled in from the
            # photo the next day) keeps its tag but earns no ticket: it was
            # never in the draw, and a fresh row would list it on the
            # leaderboard as if it had been. A catch that held a ticket WHEN
            # THE DRAW RAN was in the draw, so a post-draw re-placement (the
            # judge flows deactivate before re-placing: a GPS fix, a geofence
            # override, a DQ undone by reinstate) re-issues its ticket rather
            # than stripping it — the drawn winner's row must survive a
            # correction to the winning fish. Tournaments::DrawTaggedWinner
            # stamps in_draw_pool on the rows it drew from; a fish with no
            # stamped row (a pre-draw DQ reinstated the next day) was not in
            # the draw, and a fresh row would list a fish the draw never saw.
            in_pool = tournament.drawn_at.present? &&
              CatchPlacement.where(catch_id: @catch.id, tournament_id: tournament.id, in_draw_pool: true).exists?
            next if tournament.drawn_at.present? && !in_pool
            next_index = active_placements.empty? ? 0 : active_placements.map(&:slot_index).max + 1
            ticket = CatchPlacement.create!(
              catch: @catch, tournament: tournament, tournament_entry: entry,
              species: @catch.species, slot_index: next_index, active: true,
              in_draw_pool: in_pool
            )
            created << ticket
            # The re-issued ticket may be the drawn winner's: point the
            # tournament's recorded winner at the live row, not the retired
            # one, so anything trusting the FK sees an active ticket. One
            # guarded UPDATE against the current DB value rather than the
            # possibly stale `tournament` loaded before the locks.
            if in_pool
              ::Tournament.where(id: tournament.id)
                          .where(drawn_winning_placement_id: CatchPlacement.where(catch_id: @catch.id).select(:id))
                          .update_all(drawn_winning_placement_id: ticket.id)
            end
            affected_tournaments << tournament
          elsif tournament.format_biggest_vs_smallest?
            # Biggest vs Smallest: keep at most 2 placements per (entry, species) — the
            # current biggest and current smallest. A new catch only matters if it's
            # MORE extreme than one of them. The previously-extreme placement is now
            # in the middle and gets dropped; the new catch reuses its slot_index.
            if active_placements.size < 2
              next_index = first_free_slot(active_placements, 2)
              created << CatchPlacement.create!(
                catch: @catch, tournament: tournament, tournament_entry: entry,
                species: @catch.species, slot_index: next_index, active: true
              )
              affected_tournaments << tournament
            else
              # Re-select the surviving biggest+smallest over {both incumbents + the
              # new catch} using the SAME procedure ReconcileBvsExtremes runs (biggest
              # by rank_key desc, then smallest by rank_key asc over the rest). Because
              # the two incumbents are already the extremes of everything seen so far,
              # this trio contains the true biggest and smallest, so the incremental
              # basket matches a whole-basket reconcile exactly — including the
              # equal-length tie case where "keep the earliest-captured" decides which
              # of two same-length twins survives.
              candidates = active_placements.map(&:catch) + [@catch]
              biggest = candidates.min_by { |c| rank_key(c, desc: true) }
              smallest = (candidates - [biggest]).min_by { |c| rank_key(c, desc: false) }
              keep_ids = [biggest.id, smallest.id]

              if keep_ids.include?(@catch.id)
                # @catch displaces the one incumbent that is no longer an extreme; it
                # reuses that placement's slot_index so we never collide with
                # idx_active_placements_uniq_per_slot.
                dropped = active_placements.find { |p| !keep_ids.include?(p.catch_id) }
                dropped.update!(active: false)
                bumped << dropped if score_changing_bump?(dropped)
                created << CatchPlacement.create!(
                  catch: @catch, tournament: tournament, tournament_entry: entry,
                  species: @catch.species, slot_index: dropped.slot_index, active: true
                )
                affected_tournaments << tournament
              else
                # Catch length is in [min, max] — no placement, no bump.
              end
            end
          elsif tournament.format_fish_train?
            # Fish Train: the train is a sequence of *groups* of consecutive
            # same-species cars. e.g. train [P, W, K, W, W] = 4 groups —
            # {P:1}, {W:1}, {K:1}, {W:2}. Within a group the slots behave like
            # Standard top-N: catches fill empty slots, then the smallest in
            # the group is replaced once it's full. Lock fires at GROUP
            # boundaries, not slot boundaries — catching the next group's
            # species advances and permanently locks the previous group.
            #
            # When a new catch bumps the smallest in a full group, the
            # surviving placements shift to the lower slots (in catch order,
            # oldest first) and the new catch lands in the highest slot of
            # the group. "Fill forward" — newest fish at the highest slot.
            #
            # Judge DQ semantics: deactivating a placement in a past group
            # leaves a permanent hole — a later same-species catch is neither
            # the current group's species nor the next group's species, so it
            # no-ops. A DQ in the *current* group is implicitly re-fillable
            # because group_placements is recomputed on each new catch. This
            # matches BvS: the state machine is append-only; the angler
            # recovers by catching forward, not back.
            all_active = entry.catch_placements
              .where(active: true)
              .includes(:catch).order(:slot_index).to_a
            train = tournament.train_cars
            groups = []
            train.each_with_index do |sp_id, idx|
              if groups.last && groups.last[:species_id] == sp_id
                groups.last[:slot_indices] << idx
              else
                groups << { species_id: sp_id, slot_indices: [idx] }
              end
            end

            current_group_idx = if all_active.empty?
              -1
            else
              groups.index { |g| g[:slot_indices].include?(all_active.last.slot_index) }
            end
            current_group = current_group_idx >= 0 ? groups[current_group_idx] : nil
            next_group    = groups[(current_group_idx >= 0 ? current_group_idx : -1) + 1]

            if current_group && @catch.species_id == current_group[:species_id]
              # Same-species as current group — fill empty slot or replace smallest.
              group_slots = current_group[:slot_indices]
              group_placements = all_active.select { |p| group_slots.include?(p.slot_index) }
              if group_placements.size < group_slots.size
                empty_slot = (group_slots - group_placements.map(&:slot_index)).min
                created << CatchPlacement.create!(
                  catch: @catch, tournament: tournament, tournament_entry: entry,
                  species: @catch.species, slot_index: empty_slot, active: true
                )
                affected_tournaments << tournament
              else
                smallest = group_placements.min_by { |p| p.catch.length_inches }
                if @catch.length_inches > smallest.catch.length_inches
                  smallest.update!(active: false)
                  bumped << smallest
                  survivors = (group_placements - [smallest]).sort_by(&:created_at)
                  # Two-pass shift via unique negative sentinels so survivors
                  # can cross paths (e.g. a 3-car group where the smallest is
                  # in the middle and an older survivor must move past a
                  # newer one). The idx_active_placements_uniq_per_slot index
                  # would reject the intermediate state of a single-pass shift.
                  moves = []
                  survivors.each_with_index do |sp, i|
                    target = group_slots[i]
                    next if sp.slot_index == target
                    moves << [sp, target]
                    sp.update!(slot_index: -(sp.id + 1))
                  end
                  moves.each { |sp, target| sp.update!(slot_index: target) }
                  created << CatchPlacement.create!(
                    catch: @catch, tournament: tournament, tournament_entry: entry,
                    species: @catch.species, slot_index: group_slots.last, active: true
                  )
                  affected_tournaments << tournament
                end
                # else: catch ≤ smallest, no-op
              end
            elsif next_group && @catch.species_id == next_group[:species_id]
              # Advance to next group — fill its first slot.
              created << CatchPlacement.create!(
                catch: @catch, tournament: tournament, tournament_entry: entry,
                species: @catch.species, slot_index: next_group[:slot_indices].first, active: true
              )
              affected_tournaments << tournament
            end
            # else: off-train species, locked-previous-group species, or
            # skip-ahead — no-op
          elsif tournament.format_progressive_length?
            # Progressive Length has no incremental branch. The ladder is a pure
            # function of the entry's eligible catches in CAPTURE order, so we
            # re-derive it — which is the only way a late-syncing offline catch
            # (captured earlier than fish already on the ladder) lands at its true
            # rung. Live placement and a later judge reconcile therefore run the
            # exact same code and cannot disagree.
            res = ReconcileProgressiveLength.call(
              tournament: tournament, entry: entry, species: @catch.species
            )
            created.concat(res[:created])
            bumped.concat(res[:bumped])
            # A dink that doesn't beat the top rung changes nothing — don't
            # rebroadcast a leaderboard that didn't move.
            affected_tournaments << tournament if res[:created].any? || res[:bumped].any?
          elsif tournament.format_smallest_fish?
            # Smallest Fish: inverse of Standard. Fill empty slots the same way,
            # but once the basket is full a new catch only matters if it's SMALLER
            # than the current largest placement, which it then bumps.
            if active_placements.size < slot.slot_count
              next_index = first_free_slot(active_placements, slot.slot_count)
              created << CatchPlacement.create!(
                catch: @catch, tournament: tournament, tournament_entry: entry,
                species: @catch.species, slot_index: next_index, active: true
              )
              affected_tournaments << tournament
            else
              worst = worst_placement(active_placements, desc: false)
              if outranks?(worst, desc: false)
                worst.update!(active: false)
                bumped << worst if score_changing_bump?(worst)
                created << CatchPlacement.create!(
                  catch: @catch, tournament: tournament, tournament_entry: entry,
                  species: @catch.species, slot_index: worst.slot_index, active: true
                )
                affected_tournaments << tournament
              end
            end
          elsif tournament.format_pro_walleye?
            # Pro Walleye (Sask slot limit): a BASKET_SIZE (5) fish basket in which
            # at most BIG_CAP (2) fish may be over 55 cm; the rest are 55 cm and
            # under. Score is total length, and an over fish always outmeasures any
            # under fish, so the basket always prefers to hold up to 2 overs and
            # fill the remaining slots with the largest unders. slot_index is a
            # plain 0–4 basket position with no class meaning — class is derived
            # from length. A later judge length-edit crossing 55 cm is reconciled
            # by ReconcileProWalleye.
            #
            # place! reuses a bumped placement's slot_index, or takes the lowest
            # free 0–4 slot when the basket has room.
            place = lambda do |reuse_index|
              index = reuse_index || first_free_slot(active_placements, ProWalleye::BASKET_SIZE)
              created << CatchPlacement.create!(
                catch: @catch, tournament: tournament, tournament_entry: entry,
                species: @catch.species, slot_index: index, active: true
              )
              affected_tournaments << tournament
            end
            overs  = active_placements.select { |p| ProWalleye.big?(p.catch.length_inches) }
            unders = active_placements - overs
            if ProWalleye.big?(@catch.length_inches)
              if overs.size < ProWalleye::BIG_CAP
                # Room for another over. Fill an empty slot, or (basket full) bump
                # the smallest under — an over always beats it. A full basket with
                # overs < cap always still holds an under to bump.
                if active_placements.size < ProWalleye::BASKET_SIZE
                  place.call(nil)
                else
                  # An over always outmeasures any under, so it always claims the
                  # slot — drop the under a reconcile would drop (worst by rank).
                  victim = worst_placement(unders, desc: true)
                  victim.update!(active: false)
                  bumped << victim
                  place.call(victim.slot_index)
                end
              else
                # Over cap already met — only a better over can displace the
                # worst current over.
                worst_over = worst_placement(overs, desc: true)
                if outranks?(worst_over, desc: true)
                  worst_over.update!(active: false)
                  bumped << worst_over if score_changing_bump?(worst_over)
                  place.call(worst_over.slot_index)
                end
              end
            else
              # Under fish: fill any open basket slot, else displace the worst
              # under if this one outranks it. It never displaces an over.
              if active_placements.size < ProWalleye::BASKET_SIZE
                place.call(nil)
              else
                worst_under = worst_placement(unders, desc: true)
                if worst_under && outranks?(worst_under, desc: true)
                  worst_under.update!(active: false)
                  bumped << worst_under if score_changing_bump?(worst_under)
                  place.call(worst_under.slot_index)
                end
              end
            end
          elsif active_placements.size < slot.slot_count
            next_index = first_free_slot(active_placements, slot.slot_count)
            created << CatchPlacement.create!(
              catch: @catch, tournament: tournament, tournament_entry: entry,
              species: @catch.species, slot_index: next_index, active: true
            )
            affected_tournaments << tournament
          else
            worst = worst_placement(active_placements, desc: true)
            if outranks?(worst, desc: true)
              worst.update!(active: false)
              bumped << worst if score_changing_bump?(worst)
              created << CatchPlacement.create!(
                catch: @catch, tournament: tournament, tournament_entry: entry,
                species: @catch.species, slot_index: worst.slot_index, active: true
              )
              affected_tournaments << tournament
            end
          end
        end

        # Stamped inside the transaction so it commits atomically with the
        # placements above — that is the whole point of it existing alongside
        # placements_evaluated_at, which is written after the broadcast and so
        # is still NULL while a duplicate request is racing this run.
        @catch.update_column(:placed_at, Time.current) if @catch.placed_at.nil?
      end

      # Broadcasts and job enqueues happen AFTER our transaction commits so other
      # DB connections (and Solid Queue workers) see the new state when they
      # rebuild the leaderboard or process push notifications.
      #
      # When `broadcast: false`, the caller is running us inside its own outer
      # transaction (which would still be open here, so a broadcast now would
      # leak pre-commit state to other DB connections) and will issue its own
      # broadcast after its outer transaction commits. We skip both the leaderboard
      # rebroadcast and the notification dispatch in that case.
      result = { created: created, bumped: bumped, affected_tournaments: affected_tournaments.to_a, submitter: @catch.user }

      if @broadcast
        # Build each affected leaderboard once and share it with both the
        # broadcast and the took-the-lead detection, which otherwise each rebuild
        # the same (expensive) leaderboard per affected tournament.
        leaderboards = affected_tournaments.to_h { |t| [t.id, Leaderboards::Build.call(tournament: t)] }
        affected_tournaments.each do |t|
          Placements::BroadcastLeaderboard.call(
            tournament: t, leaderboard: leaderboards[t.id],
            changed_entry_ids: bingo_changed_entry_ids[t.id].presence
          )
        end

        # Bingo keeps no placements, so DetectNotifications can't spot a lead change
        # from result[:created]. Detect it here (where @catch is in scope): the
        # submitter's card is now the leader AND this catch stamped a new square.
        result[:bingo_lead] = bingo_lead_notifications(affected_tournaments, leaderboards, bingo_changed_entry_ids)

        Placements::DetectNotifications.call(result: result, leaderboards: leaderboards).each do |n|
          DeliverPushNotificationJob.perform_later(
            user_id: n[:user].id,
            title: n[:title],
            body: n[:body],
            url: n[:url],
            tournament_id: n[:tournament].id
          )
        end
      end

      result
    end

    private

    # For each affected bingo tournament, a took-the-lead event for the submitter
    # when their (now-changed) card is the leader and this catch stamped at least
    # one new square. Only the submitter's own card changed this run, so no other
    # entry can have taken the lead. Returns [{ tournament:, entry: }].
    def bingo_lead_notifications(tournaments, leaderboards, changed_entry_ids)
      tournaments.select(&:format_bingo?).filter_map do |t|
        entry_id = changed_entry_ids.fetch(t.id, []).first
        next unless entry_id

        board = leaderboards[t.id]
        leader = board&.first
        next unless leader && leader[:entry].id == entry_id

        before = bingo_result_without_catch(t, leader[:entry], leader[:catches])
        # squares_count is monotonic in catches, so a positive delta means @catch
        # stamped a new square.
        next unless leader[:result].squares_count > before.squares_count

        # Taking the lead, not merely holding it. Only the submitter's card
        # changed this run, so compare their pre-catch headline score against the
        # rest of the (unchanged) field: if they were already strictly ahead of
        # everyone, this square only extends a lead they held — no push.
        # Otherwise (tied for, or behind, the lead before) they've just taken it.
        # An exact tie broken only by entry id is NOT a held lead, so the first
        # angler to stamp a square from an all-even start still gets the push.
        others = board.reject { |r| r[:entry].id == entry_id }
        led_before = others.all? { |r| (bingo_headline(before) <=> bingo_headline(r[:result])) > 0 }
        next if led_before

        { tournament: t, entry: leader[:entry] }
      end
    end

    # The headline ranking score for a bingo card — blackout, then lines, then
    # squares, higher-is-better — mirroring the leading terms of
    # Rankers::Bingo#sort_key. Reach-time tiebreaks are intentionally omitted:
    # two cards level on all three still read as "tied for the lead" here, which
    # only ever errs toward an extra took-the-lead push in that rare exact tie,
    # never toward spamming an established leader.
    def bingo_headline(result)
      [result.blackout ? 1 : 0, result.lines_count, result.squares_count]
    end

    # The submitter's card as it stood before this catch — re-derived from the
    # entry's catches minus @catch — so we can tell whether @catch newly filled a
    # square (square count is monotonic in catches, so a positive delta == stamped).
    # `lites` are the CatchLites the leaderboard build already loaded for this
    # entry, so we re-evaluate in memory without re-querying the catch window.
    def bingo_result_without_catch(tournament, entry, lites)
      Catches::Bingo::EvaluateCard.call(
        tournament: tournament, entry: entry,
        catches: (lites || []).reject { |c| c.id == @catch.id }
      )
    end

    # The lowest 0-based slot index in [0, count) not already held by an active
    # placement — where a newly placed catch lands when the basket has room.
    def first_free_slot(active_placements, count)
      (0...count).find { |i| active_placements.none? { |p| p.slot_index == i } }
    end

    # Ranking key mirroring SlotPlacement#by_length, so an incremental bump keeps
    # and drops exactly the catches a whole-basket reconcile would. desc: true
    # ranks largest-best; a SMALLER key is better. The captured_at_device-asc then
    # id tiebreak encodes "first-to-set wins" — the same order the Reconcile*
    # classes use — so the two paths agree on which of several equal-length
    # catches holds a slot. Keeping them in sync is pinned by
    # PlaceReconcileConsistencyTest.
    def rank_key(catch_record, desc:)
      SlotRanking.key(catch_record, desc: desc)
    end

    # The active placement a reconcile would drop first: the worst by rank_key.
    def worst_placement(placements, desc:)
      placements.max_by { |p| rank_key(p.catch, desc: desc) }
    end

    # Whether @catch outranks (would displace) placement under rank_key — i.e. a
    # reconcile of the current basket plus @catch would keep @catch and drop
    # placement. Strictly better, so an exact tie (same length, capture, id) is a
    # no-op, matching "first-to-set wins".
    def outranks?(placement, desc:)
      (rank_key(@catch, desc: desc) <=> rank_key(placement.catch, desc: desc)) < 0
    end

    # A full basket bumps the incumbent @catch beats. When the two are the SAME
    # length the swap is score-neutral — outranks? still fires (the tiebreak keeps
    # the earliest-captured of two equal fish, matching a reconcile), so the credited
    # fish moves but the basket's total doesn't. Only such a swap should count as a
    # "bump" for notification purposes; otherwise a teammate's equal-length offline
    # catch sends a misleading "you were bumped from a slot" push despite no score
    # change. The DB swap and rebroadcast still happen (the earliest_catch_at
    # tiebreak can shift); only the push is suppressed.
    def score_changing_bump?(placement)
      @catch.length_inches != placement.catch.length_inches
    end
  end
end
