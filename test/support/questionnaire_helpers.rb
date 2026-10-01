# Shared setup for the top-3 questionnaire tests.
module QuestionnaireHelpers
  # A club that has been asking for a month. A factory club starts asking
  # "now", so a tournament that ended yesterday would be before its start.
  def asking_club
    club = create(:club)
    club.update!(questionnaires_start_at: 30.days.ago)
    club
  end

  def questionnaire_species
    @questionnaire_species ||= create(:species)
  end

  # A one-slot tournament. `ended` in the future makes it still running.
  def season_tournament(club:, ended: 1.day.ago, awards: true, name: "Wednesday Main")
    # Team mode: solo tournaments refuse a boat with more than one angler.
    tournament = create(:tournament, club: club, name: name, awards_season_points: awards,
                        mode: :team, starts_at: ended - 4.hours, ends_at: ended)
    create(:scoring_slot, tournament: tournament, species: questionnaire_species, slot_count: 1)
    tournament
  end

  # A boat with `members` anglers. `length: nil` means no scoring catch.
  # Longer fish rank higher in the standard format.
  def add_boat(tournament, length:, members: 1, name: nil)
    users = Array.new(members) { create(:user, club: tournament.club) }
    entry = create(:tournament_entry, tournament: tournament, name: name)
    users.each { |u| create(:tournament_entry_member, tournament_entry: entry, user: u) }
    if length
      caught = create(:catch, user: users.first, species: questionnaire_species,
                      length_inches: length, captured_at_device: tournament.ends_at - 1.hour)
      create(:catch_placement, catch: caught, tournament: tournament, tournament_entry: entry,
             species: questionnaire_species, slot_index: 0)
    end
    entry
  end

  # What a disqualification does to the standings: the placement goes inactive.
  def disqualify(entry)
    CatchPlacement.where(tournament_entry_id: entry.id).update_all(active: false)
  end
end
