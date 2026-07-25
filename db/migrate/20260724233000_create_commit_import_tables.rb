class CreateCommitImportTables < ActiveRecord::Migration[8.0]
  def change
    create_table :commits do |t|
      t.string :sha, null: false
      t.string :subject, null: false
      t.text :body
      t.datetime :authored_at, null: false
      t.datetime :committed_at, null: false
      t.string :author_name
      t.string :author_email
      t.string :committer_name
      t.string :committer_email
      t.string :branches, array: true, null: false, default: []
      t.string :released_in
      t.datetime :released_at
      t.string :cherry_picked_from_sha
      t.string :unresolved_message_ids, array: true, null: false, default: []
      t.timestamps

      t.index :sha, unique: true
      t.index :committed_at
      t.index :released_in
      t.index :cherry_picked_from_sha
      t.index :committed_at, name: "index_commits_pending_message_ids",
               where: "cardinality(unresolved_message_ids) > 0"
      t.index [ :subject, :author_email ], name: "index_commits_on_subject_and_author_email"
    end

    create_table :commit_files do |t|
      t.references :commit, null: false, foreign_key: true, index: false
      t.string :path, null: false

      t.index [ :commit_id, :path ], unique: true
      t.index :path
    end

    create_table :commit_people do |t|
      t.references :commit, null: false, foreign_key: true, index: false
      t.string :role, null: false
      t.string :raw_name
      t.string :raw_email
      t.references :person, foreign_key: true

      t.index [ :commit_id, :role ]
    end

    create_table :commit_topics do |t|
      t.references :commit, null: false, foreign_key: true, index: false
      t.references :topic, null: false, foreign_key: true
      t.string :external_message_id

      t.index [ :commit_id, :topic_id ], unique: true
    end

    create_table :release_tags do |t|
      t.string :name, null: false
      t.string :version
      t.datetime :released_at
      t.string :commit_sha

      t.index :name, unique: true
    end

    add_column :topics, :commit_count, :integer, null: false, default: 0
  end
end
