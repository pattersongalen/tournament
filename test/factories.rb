FactoryBot.define do
  # Factories declared here; each model task adds its own.
  factory :club do
    sequence(:name) { |n| "Club #{n}" }
  end

  factory :user do
    sequence(:name) { |n| "Angler #{n}" }
    sequence(:email) { |n| "angler#{n}@example.com" }

    # Mirror prod state: every user should have at least one ClubMembership so
    # current_club resolves on sign-in. Tests that need a clubless user can
    # pass `club: nil` explicitly.
    transient do
      club { build(:club) }
      role { :member }
    end

    after(:create) do |u, ev|
      next unless ev.club
      ev.club.save! if ev.club.new_record?
      next if u.club_memberships.exists?(club_id: ev.club.id)
      u.club_memberships.create!(club: ev.club, role: ev.role, deactivated_at: u.deactivated_at)
    end
  end

  factory :species do
    sequence(:name) { |n| "Species #{n}" }

    # Accept and ignore club: for backwards compat with tests written when
    # species had a club_id. Species are global after the multi-club refactor.
    transient do
      club { nil }
    end
  end

  factory :tournament do
    association :club
    sequence(:name) { |n| "Tournament #{n}" }
    mode { :solo }
    starts_at { 1.hour.ago }
    ends_at { 1.hour.from_now }
  end

  factory :scoring_slot do
    association :tournament
    association :species
    slot_count { 1 }
  end

  factory :tournament_entry do
    association :tournament
  end

  factory :tournament_entry_member do
    association :tournament_entry
    association :user
  end

  factory :boat do
    association :club
    sequence(:name) { |n| "Boat #{n}" }
    captain { create(:user, club: club) }
  end

  factory :tournament_judge do
    association :tournament
    association :user
  end

  factory :tournament_deputy do
    association :tournament
    association :user
    association :granted_by_user, factory: :user
  end

  factory :catch do
    association :user
    association :species
    length_inches { 18.5 }
    length_unit { "inches" }
    captured_at_device { Time.current }
    status { :synced }
    sequence(:client_uuid) { |n| "client-uuid-#{n}" }

    after(:build) do |c|
      unless c.photo.attached?
        c.photo.attach(
          io: File.open(Rails.root.join("test/fixtures/files/sample_walleye.jpg")),
          filename: "sample_walleye.jpg",
          content_type: "image/jpeg"
        )
      end
    end
  end

  factory :catch_placement do
    association :catch
    association :tournament
    association :tournament_entry
    association :species
    slot_index { 0 }
    active { true }
  end

  factory :push_subscription do
    association :user
    sequence(:endpoint) { |n| "https://example/sub/#{n}" }
    p256dh { "p256dh-key" }
    auth { "auth-key" }
  end

  factory :judge_action do
    association :judge_user, factory: :user
    association :catch
    action { :approve }
  end

  factory :tournament_template do
    association :club
    sequence(:name) { |n| "Template #{n}" }
    mode { :solo }
  end

  factory :club_membership do
    association :user
    association :club
    role { :member }
  end

  factory :club_rules_revision do
    association :club
    association :edited_by_user, factory: :user
    season { :open_water }
    body { "<h1>Rules</h1><div>Be excellent to each other.</div>" }
  end

  factory :club_notice do
    association :club
    sequence(:title) { |n| "Notice #{n}" }
    message { "Please read and acknowledge." }
    starts_on { Date.current }
    ends_on { Date.current + 6 }
  end

  factory :club_notice_recipient do
    association :club_notice
    association :user
  end

  factory :club_notice_acknowledgment do
    association :club_notice
    association :user
    acknowledged_on { Date.current }
  end

  factory :club_question do
    association :club
    sequence(:prompt) { |n| "Question #{n}" }
    sequence(:position) { |n| 100 + n }
  end

  factory :entry_questionnaire do
    tournament { association :tournament }
    tournament_entry { association :tournament_entry, tournament: tournament }
  end

  factory :entry_questionnaire_answer do
    association :entry_questionnaire
    club_question { association :club_question, club: entry_questionnaire.tournament.club }
    body { "Jig and minnow" }
  end

  factory :entry_questionnaire_dismissal do
    association :tournament_entry
    association :user
  end
end
