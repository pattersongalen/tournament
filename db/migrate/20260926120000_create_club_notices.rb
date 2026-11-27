class CreateClubNotices < ActiveRecord::Migration[8.0]
  # Notices a site admin posts to chosen members of a club. A recipient must
  # acknowledge a notice once per local day, from starts_on through ends_on
  # (both inclusive). Acknowledgments are an append-only record of who
  # confirmed, and when.
  def change
    create_table :club_notices do |t|
      t.references :club, null: false, foreign_key: true, index: false
      t.string :title, null: false, limit: 120
      t.text :message, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.references :created_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :club_notices, [:club_id, :starts_on, :ends_on]

    create_table :club_notice_recipients do |t|
      t.references :club_notice, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :club_notice_recipients, [:club_notice_id, :user_id], unique: true

    create_table :club_notice_acknowledgments do |t|
      t.references :club_notice, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.date :acknowledged_on, null: false
      t.datetime :created_at, null: false
    end
    add_index :club_notice_acknowledgments, [:club_notice_id, :user_id, :acknowledged_on],
              unique: true, name: "idx_club_notice_acks_on_notice_user_day"
  end
end
