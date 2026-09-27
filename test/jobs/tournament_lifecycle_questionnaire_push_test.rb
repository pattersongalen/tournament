require "test_helper"
require_relative "../support/questionnaire_helpers"

class TournamentLifecycleQuestionnairePushTest < ActiveJob::TestCase
  include QuestionnaireHelpers
  include ActionCable::TestHelper

  setup do
    @club = asking_club
    @tournament = season_tournament(club: @club, ended: 1.minute.ago)
    @first  = add_boat(@tournament, length: 30, members: 2)
    @second = add_boat(@tournament, length: 28)
    @third  = add_boat(@tournament, length: 26)
    @fourth = add_boat(@tournament, length: 24)
  end

  def questionnaire_pushes(enqueued)
    enqueued.select { |push| push[:body].include?("Tell the club what worked.") }
  end

  test "each member of each top-3 boat gets one questionnaire push with their place and form link" do
    with_push_capture do |enqueued|
      TournamentLifecycleAnnounceJob.perform_now(tournament_id: @tournament.id, kind: "ended")

      pushes = questionnaire_pushes(enqueued)
      expected = [[@first, "1st"], [@second, "2nd"], [@third, "3rd"]].flat_map do |entry, place|
        entry.users.map do |user|
          {
            user_id: user.id, title: "Wednesday Main",
            body: "You placed #{place}. Tell the club what worked.",
            url: "/tournaments/#{@tournament.id}/entries/#{entry.id}/questionnaire/edit",
            tournament_id: @tournament.id
          }
        end
      end

      assert_equal 4, pushes.size
      assert_equal expected.sort_by { |p| p[:user_id] }, pushes.sort_by { |p| p[:user_id] }
      assert_empty pushes.select { |p| @fourth.users.map(&:id).include?(p[:user_id]) }
    end
  end

  test "the ordinary ended push still goes to every entered member" do
    with_push_capture do |enqueued|
      TournamentLifecycleAnnounceJob.perform_now(tournament_id: @tournament.id, kind: "ended")

      ordinary = enqueued - questionnaire_pushes(enqueued)
      assert_equal 5, ordinary.size
      assert ordinary.all? { |p| p[:body] == "Wednesday Main has ended." }
    end
  end

  test "no questionnaire push when the tournament does not ask" do
    {
      "season points off"    => -> { @tournament.update_columns(awards_season_points: false) },
      "no active questions"  => -> { @club.questions.update_all(retired_at: Time.current) },
      "before the start"     => -> { @club.update!(questionnaires_start_at: Time.current) }
    }.each do |label, arrange|
      arrange.call
      with_push_capture do |enqueued|
        TournamentLifecycleAnnounceJob.perform_now(tournament_id: @tournament.id, kind: "ended")
        assert_empty questionnaire_pushes(enqueued), label
      end

      @tournament.update_columns(awards_season_points: true, lifecycle_ended_announced_at: nil)
      @club.questions.update_all(retired_at: nil)
      @club.update!(questionnaires_start_at: 30.days.ago)
    end
  end

  test "the started announcement sends no questionnaire push" do
    with_push_capture do |enqueued|
      TournamentLifecycleAnnounceJob.perform_now(tournament_id: @tournament.id, kind: "started")
      assert_empty questionnaire_pushes(enqueued)
    end
  end

  test "running the ended job again sends nothing more" do
    with_push_capture do |enqueued|
      TournamentLifecycleAnnounceJob.perform_now(tournament_id: @tournament.id, kind: "ended")
      first_run = enqueued.size

      TournamentLifecycleAnnounceJob.perform_now(tournament_id: @tournament.id, kind: "ended")

      assert_equal first_run, enqueued.size
    end
  end

  test "a failure while working out the top three still reveals a blind leaderboard and does not fail the job" do
    @tournament.update_columns(blind_leaderboard: true)
    exploding = ->(**) { raise "boom" }

    with_push_capture do |enqueued|
      with_class_method_stub(Questionnaires::EligibleEntries, :call, exploding) do
        assert_broadcasts("tournament:#{@tournament.id}:leaderboard:reveal", 1) do
          assert_nothing_raised do
            TournamentLifecycleAnnounceJob.perform_now(tournament_id: @tournament.id, kind: "ended")
          end
        end
      end
      assert_equal 5, enqueued.size, "the ordinary ended pushes still went out"
    end
  end

  # Review Focus 4.
  test "a top-3 boat with no members, or only deactivated members, gets no push and raises nothing" do
    @second.tournament_entry_members.delete_all
    @third.users.each { |u| u.update!(deactivated_at: Time.current) }

    with_push_capture do |enqueued|
      assert_nothing_raised do
        TournamentLifecycleAnnounceJob.perform_now(tournament_id: @tournament.id, kind: "ended")
      end

      user_ids = questionnaire_pushes(enqueued).map { |p| p[:user_id] }
      assert_equal @first.users.map(&:id).sort, user_ids.sort
    end
  end

  private

  def with_push_capture
    enqueued = []
    original = DeliverPushNotificationJob.method(:perform_later)
    DeliverPushNotificationJob.define_singleton_method(:perform_later) { |**kwargs| enqueued << kwargs }
    yield enqueued
  ensure
    DeliverPushNotificationJob.define_singleton_method(:perform_later, original)
  end
end
