require "test_helper"

class JudgeActionTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @judge = create(:user, club: @club, role: :organizer)
    @catch = create(:catch, user: create(:user, club: @club),
                    species: create(:species, club: @club))
  end

  test "records action, note, before/after and covers the full action enum" do
    a = JudgeAction.create!(
      judge_user: @judge, catch: @catch, action: :approve,
      note: "looks good", before_state: { status: "needs_review" },
      after_state: { status: "synced" }
    )
    assert a.persisted?
    assert_equal "approve", a.action
    assert_equal "looks good", a.note

    %w[approve flag disqualify manual_override dock_verify
       geofence_override correct_location reinstate].each do |action|
      assert_includes JudgeAction.actions.keys, action, "#{action}: should be a defined enum key"
      record = build(:judge_action, action: action)
      assert record.valid?, "#{action}: should be a valid action"
      assert_equal action, record.action, "#{action}: round-trips through the enum"
    end
  end
end
