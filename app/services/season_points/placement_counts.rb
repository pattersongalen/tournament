module SeasonPoints
  # Completed Main-night podium finishes, credited to every member of a boat.
  # Rebuild from current qualified standings so corrections/DQs are reflected.
  class PlacementCounts
    def self.call(club:, season_tag:)
      tournaments = Tournaments.call(club: club, season_tag: season_tag)
                               .includes(:drawn_winning_placement).to_a
      return {} if tournaments.empty?

      ids = tournaments.map(&:id)
      entries = ::TournamentEntry.where(tournament_id: ids).includes(:users).group_by(&:tournament_id)
      placements = ::CatchPlacement.active.where(tournament_id: ids)
        .includes(catch: [:species, :user, :logged_by_user, { judge_actions: :judge_user }])
        .group_by(&:tournament_id)
      capacities = ::ScoringSlot.where(tournament_id: ids).group(:tournament_id).sum(:slot_count)
      bingo_species_ids = ::Catches::Bingo::EvaluateCard.species_id_map if tournaments.any?(&:format_bingo?)
      counts = Hash.new { |h, id| h[id] = [0, 0, 0] }

      tournaments.each do |tournament|
        next if tournament.format_hidden_length? && tournament.hidden_length_target.nil?

        tournament_entries = entries.fetch(tournament.id, [])
        tickets = placements.fetch(tournament.id, [])
        if tournament.format_tagged?
          # Ticket counts are not finishing positions. Only the valid drawn
          # winner earns a first; this format has no second or third place.
          drawn = tournament.drawn_winning_placement
          ticket = tickets.find { |p| p.catch_id == drawn.catch_id } if drawn
          winner = tournament_entries.find { |entry| entry.id == ticket.tournament_entry_id } if ticket
          podium = winner ? [winner] : []
        else
          rows = ::Leaderboards::Build.call(
            tournament: tournament, entries: tournament_entries, placements: tickets,
            total_capacity: capacities.fetch(tournament.id, 0), bingo_species_ids: bingo_species_ids
          )
          podium = ::Leaderboards::QualifiedRows.call(tournament: tournament, rows: rows)
            .map { |row| row[:entry] }.uniq(&:id).first(3)
        end

        credited = {}
        podium.each_with_index do |entry, place|
          entry.users.each do |user|
            next if credited[user.id]

            counts[user.id][place] += 1
            credited[user.id] = true
          end
        end
      end
      counts
    end
  end
end
