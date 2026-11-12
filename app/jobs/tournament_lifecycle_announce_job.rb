class TournamentLifecycleAnnounceJob < ApplicationJob
  queue_as :default

  def perform(tournament_id:, kind:)
    tournament = Tournament.find(tournament_id)

    if kind == "ended"
      return if tournament.lifecycle_ended_announced_at.present?
      return if tournament.ends_at && tournament.ends_at > Time.current
    end

    if kind == "ended" && tournament.format_hidden_length?
      Tournaments::RollHiddenLengthTarget.call(tournament: tournament)
      # Broadcast lives here, not in the service: if it raises, the stamp below
      # never runs, so the next retry re-broadcasts (the roll itself short-circuits).
      Placements::BroadcastLeaderboard.call(tournament: tournament)
    end

    # Stamp here — after the (idempotent) HL roll commits and its broadcast
    # succeeds, but before the push enqueue loop and BroadcastReveal — so a
    # transient failure in either of those does not cause a retry to re-push
    # the body or re-broadcast reveal.
    if kind == "ended"
      tournament.update_columns(lifecycle_ended_announced_at: Time.current)
    end

    body = if kind == "ended" && tournament.format_hidden_length?
      "Target was #{format("%.2f", tournament.hidden_length_target)}\" — see final standings."
    elsif kind == "ended" && tournament.format_beat_the_average?
      avg = Leaderboards::Rankers::BeatTheAverage.average_for(tournament)
      if avg
        "The average was #{format("%.2f", avg)}\" — see who landed closest."
      else
        "#{tournament.name} has ended — no fish were logged."
      end
    elsif kind == "ended" && tournament.blind_leaderboard?
      "Results are in, GO CHECK YOUR STANDINGS"
    elsif kind == "ended"
      "#{tournament.name} has ended."
    else
      "#{tournament.name} just started."
    end

    tournament.tournament_entries.includes(:users).each do |entry|
      entry.users.each do |user|
        DeliverPushNotificationJob.perform_later(
          user_id: user.id, title: tournament.name, body: body,
          url: "/tournaments/#{tournament.id}", tournament_id: tournament.id
        )
      end
    end

    if kind == "ended" && tournament.blind_leaderboard?
      Leaderboards::BroadcastReveal.call(tournament: tournament)
    end

    # The top three are asked what worked. Last, and rescued: it builds a
    # whole leaderboard, and by now the stamp above means a retry returns
    # early, so a failure here must not take the reveal broadcast with it.
    if kind == "ended"
      begin
        Questionnaires::EligibleEntries.call(tournament: tournament).each do |item|
          item[:entry].users.merge(User.active).each do |user|
            DeliverPushNotificationJob.perform_later(
              user_id: user.id, title: tournament.name,
              body: "You placed #{item[:place].ordinalize}. Tell the club what worked.",
              url: "/tournaments/#{tournament.id}/entries/#{item[:entry].id}/questionnaire/edit",
              tournament_id: tournament.id
            )
          end
        end
      rescue StandardError => e
        Rails.logger.error("questionnaire push failed for tournament #{tournament.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
