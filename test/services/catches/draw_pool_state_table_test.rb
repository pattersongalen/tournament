require "test_helper"

module Catches
  # The tagged draw pool as a state table: every combination of draw state,
  # the fish's row when the draw ran, whether it is the recorded winner, and
  # the judge action taken, with the outcome each combination must produce.
  # One row per cell, so a cell nobody has thought about is a blank line
  # here rather than a review finding later. Rows are the spec; the runner
  # below is the only mechanism.
  #
  # Columns:
  #   draw     :none      the draw has not run
  #            :once      the draw ran once
  #            :rerun     the draw ran, this fish was DQ'd, and an organizer
  #                       force re-drew over what was left
  #   at_draw  :active    the fish held a ticket when the (first) draw ran
  #            :retired   the fish was DQ'd before the draw ran
  #            :stranded  the fish had no tag (so no ticket) when it ran
  #   winner   whether the (first) draw's recorded winner is this fish
  #   side     a second, still-open tagged tournament the member is also in
  #   action   :disqualify | :reinstate (a DQ precedes it if none has yet)
  #            :species_change (to plain Walleye) | :tag_add | :correct_location
  # Expected:
  #   ticket   the fish holds an active ticket in the main tournament after
  #   follows  the recorded winner points at that ticket (nil: not applicable)
  #   withheld tickets_withheld_in names the main tournament
  #   reissued ticket_reissued is set
  #   voided   draw_voided is set
  #   dropped  tag_dropped names the tag
  #   flag     the fish carries no_draw_ticket
  ROWS = [
    # draw    at_draw    winner side   action            ticket follows withheld reissued voided dropped flag
    [:none,   :active,   false, false, :reinstate,        true,  nil,    false,   false,   false, false,  false],
    [:none,   :stranded, false, false, :tag_add,          true,  nil,    false,   false,   false, false,  false],
    [:once,   :active,   true,  false, :disqualify,       false, nil,    false,   false,   true,  false,  false],
    [:once,   :active,   true,  false, :reinstate,        true,  true,   false,   false,   false, false,  false],
    [:once,   :active,   false, false, :reinstate,        true,  false,  false,   true,    false, false,  false],
    [:once,   :retired,  false, false, :reinstate,        false, nil,    true,    false,   false, false,  true],
    [:once,   :active,   true,  false, :species_change,   false, nil,    false,   false,   true,  true,   false],
    [:once,   :active,   false, false, :species_change,   false, nil,    false,   false,   false, true,   false],
    [:once,   :stranded, false, false, :tag_add,          false, nil,    true,    false,   false, false,  true],
    [:once,   :stranded, false, true,  :tag_add,          false, nil,    true,    false,   false, false,  false],
    [:once,   :active,   true,  false, :correct_location, true,  true,   false,   false,   false, false,  false],
    [:once,   :active,   false, false, :correct_location, true,  false,  false,   true,    false, false,  false],
    [:rerun,  :active,   true,  false, :reinstate,        true,  false,  false,   true,    false, false,  false],
    [:rerun,  :active,   false, false, :reinstate,        true,  false,  false,   true,    false, false,  false]
  ].freeze

  class DrawPoolStateTableTest < ActiveSupport::TestCase
    setup do
      @club = create(:club)
      @judge = create(:user, club: @club, role: :organizer)
      @user = create(:user, club: @club)
      @tagged = Species.find_or_create_by!(name: "Tagged Walleye")
      @walleye = create(:species, club: @club, name: "Walleye")
    end

    ROWS.each do |draw, at_draw, winner, side, action, ticket, follows, withheld, reissued, voided, dropped, flag|
      test "draw #{draw}, fish #{at_draw}#{' (winner)' if winner}#{' + open side' if side}, #{action}" do
        t = tagged_tournament("Main")
        side_t = tagged_tournament("Side") if side
        other = catch_with_tag("A0002", 100.minutes.ago)
        fish  = catch_with_tag("A0001", 2.hours.ago)
        fish.update_column(:tag_number, nil) if at_draw == :stranded
        Catches::PlaceInSlots.call(catch: other)
        Catches::PlaceInSlots.call(catch: fish)
        disqualify(fish) if at_draw == :retired

        if draw != :none
          Tournaments::DrawTaggedWinner.call(tournament: t.reload, drawn_by: @judge)
          # The draw is random; the table needs a known winner.
          chosen = CatchPlacement.find_by!(tournament: t, catch: winner ? fish : other, active: true)
          t.update_columns(drawn_winning_placement_id: chosen.id)
        end
        if draw == :rerun
          disqualify(fish)
          Tournaments::DrawTaggedWinner.call(tournament: t.reload, drawn_by: @judge, force: true)
        end

        result =
          case action
          when :disqualify
            disqualify(fish)
          when :reinstate
            disqualify(fish) unless fish.reload.disqualified?
            judge(fish, :reinstate, note: "undo")
          when :species_change
            judge(fish, :manual_override, species_id: @walleye.id, tag_number: "A0001", note: "mis-ID")
          when :tag_add
            judge(fish, :manual_override, tag_number: "A0001", note: "from photo")
          when :correct_location
            judge(fish, :correct_location, latitude: fish.latitude, longitude: fish.longitude, note: "gps")
          end

        live = CatchPlacement.find_by(tournament: t, catch: fish, active: true)
        assert_equal ticket, live.present?, "ticket"
        assert_equal live.id, t.reload.drawn_winning_placement_id, "winner follows the ticket" if follows == true
        assert_not_equal live.id, t.reload.drawn_winning_placement_id, "winner stays put" if follows == false
        assert_equal (withheld ? [t.name] : []), result[:tickets_withheld_in], "withheld"
        assert_equal reissued, result[:ticket_reissued], "reissued"
        assert_equal voided, result[:draw_voided], "voided"
        dropped ? assert_equal("A0001", result[:tag_dropped], "dropped") : assert_nil(result[:tag_dropped], "dropped")
        assert_equal flag, fish.reload.flags.include?("no_draw_ticket"), "no_draw_ticket flag"
        if side
          assert CatchPlacement.exists?(tournament: side_t, catch: fish, active: true), "ticket in the open Side"
        end
        if dropped
          assert_equal "A0001", fish.last_known_tag_number, "the dropped tag is still readable for the void banner"
        end
      end
    end

    private

    def tagged_tournament(name)
      t = build(:tournament, club: @club, name: name, format: :tagged, mode: :solo,
                starts_at: 3.hours.ago, ends_at: 1.hour.ago)
      t.scoring_slots.build(species: @tagged, slot_count: 1)
      t.save!
      entry = create(:tournament_entry, tournament: t)
      create(:tournament_entry_member, tournament_entry: entry, user: @user)
      t
    end

    def catch_with_tag(tag, captured_at)
      create(:catch, user: @user, species: @tagged, length_inches: 18.0,
             tag_number: tag, captured_at_device: captured_at)
    end

    def disqualify(fish)
      judge(fish, :disqualify, note: "wrong call")
    end

    def judge(fish, action, **opts)
      Catches::ApplyJudgeAction.call(tournament: nil, catch: fish, judge: @judge, action: action, club: @club, **opts)
    end
  end
end
