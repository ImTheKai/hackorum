class WidenCommitsSubjectAuthorIndex < ActiveRecord::Migration[8.0]
  # Backport grouping does DISTINCT ON (subject, author_email) ordered by
  # committed_at, id to pick the earliest commit. The old two-column index
  # cannot serve that tiebreak order, so the query seq-scans and sorts. Widen
  # it to carry the full order so the planner can use it.
  def up
    remove_index :commits, name: "index_commits_on_subject_and_author_email"
    add_index :commits, [ :subject, :author_email, :committed_at, :id ],
              name: "index_commits_on_subject_and_author_email"
  end

  def down
    remove_index :commits, name: "index_commits_on_subject_and_author_email"
    add_index :commits, [ :subject, :author_email ],
              name: "index_commits_on_subject_and_author_email"
  end
end
