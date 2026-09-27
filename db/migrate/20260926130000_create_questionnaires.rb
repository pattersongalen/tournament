class CreateQuestionnaires < ActiveRecord::Migration[8.0]
  # The top-3 questionnaire: when a season-points tournament ends, its top 3
  # boats are asked what worked. Questions are a per-club list; a boat gives
  # one set of free-text answers. clubs.questionnaires_start_at is the moment
  # a club started asking, so tournaments that ended earlier never ask.
  DEFAULT_PROMPTS = ["Lure used", "Bait used", "Depth"].freeze

  def up
    add_column :clubs, :questionnaires_start_at, :datetime

    create_table :club_questions do |t|
      t.references :club, null: false, foreign_key: true, index: false
      t.string :prompt, null: false, limit: 80
      t.integer :position, null: false
      t.datetime :retired_at
      t.timestamps
    end
    add_index :club_questions, [:club_id, :position]

    create_table :entry_questionnaires do |t|
      t.references :tournament, null: false, foreign_key: { on_delete: :cascade }
      t.references :tournament_entry, null: false, foreign_key: { on_delete: :cascade },
                   index: { unique: true }
      t.references :submitted_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :updated_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    create_table :entry_questionnaire_answers do |t|
      t.references :entry_questionnaire, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :club_question, null: false, foreign_key: { on_delete: :cascade }
      t.string :body, null: false, limit: 200
    end
    add_index :entry_questionnaire_answers, [:entry_questionnaire_id, :club_question_id],
              unique: true, name: "idx_questionnaire_answers_on_questionnaire_and_question"

    create_table :entry_questionnaire_dismissals do |t|
      t.references :tournament_entry, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :created_at, null: false
    end
    add_index :entry_questionnaire_dismissals, [:tournament_entry_id, :user_id],
              unique: true, name: "idx_questionnaire_dismissals_on_entry_and_user"

    seed_existing_clubs
  end

  def down
    drop_table :entry_questionnaire_dismissals
    drop_table :entry_questionnaire_answers
    drop_table :entry_questionnaires
    drop_table :club_questions
    remove_column :clubs, :questionnaires_start_at
  end

  private

  # Raw SQL, not the models: a migration must keep working after the models
  # change.
  def seed_existing_clubs
    now = connection.quote(Time.current.utc.to_fs(:db))
    execute("UPDATE clubs SET questionnaires_start_at = #{now}")
    DEFAULT_PROMPTS.each_with_index do |prompt, index|
      execute(<<~SQL.squish)
        INSERT INTO club_questions (club_id, prompt, position, created_at, updated_at)
        SELECT id, #{connection.quote(prompt)}, #{index + 1}, #{now}, #{now} FROM clubs
      SQL
    end
  end
end
