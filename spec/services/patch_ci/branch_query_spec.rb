require "rails_helper"

RSpec.describe PatchCi::BranchQuery do
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }

  def query(params = {})
    described_class.new(params: ActionController::Parameters.new(params),
                        repo_state: repo_state)
  end

  def branch(title: "some patch", days_behind: 1, **attrs)
    topic = create(:topic, title: title, last_message_at: Time.current)
    create(:patch_branch, topic: topic,
           base_committed_at: days_behind && repo_state.master_committed_at - days_behind.days,
           base_commit_height: 10, **attrs)
  end

  def names(q)
    q.rows.map(&:branch_name)
  end

  describe "facets" do
    it "filters by base tier" do
      recent = branch(days_behind: 1)
      branch(days_behind: 400)

      expect(names(query(base: "recent"))).to eq([ recent.branch_name ])
    end

    it "accepts several base tiers" do
      recent = branch(days_behind: 1)
      stale = branch(days_behind: 100)
      ancient = branch(days_behind: 400)

      got = names(query(base: "recent,stale"))

      expect(got).to match_array([ recent.branch_name, stale.branch_name ])
      expect(got).not_to include(ancient.branch_name)
    end

    it "filters by health bucket" do
      fresh = branch(pushed_at: 1.day.ago, ci_status: "success")
      branch(status: "failed", failure_stage: "apply")

      expect(names(query(state: "fresh"))).to eq([ fresh.branch_name ])
    end

    it "filters by pg major" do
      pg20 = branch(pg_major: 20)
      branch(pg_major: 15)

      expect(names(query(pg: "20"))).to eq([ pg20.branch_name ])
    end

    it "normalizes a zero-padded pg major so the chip matches the filter" do
      pg20 = branch(pg_major: 20)
      branch(pg_major: 15)

      q = query(pg: "020")

      expect(names(q)).to eq([ pg20.branch_name ])
      expect(q.selected(:pg)).to eq([ "20" ])
      expect(q.active_params[:pg]).to eq("20")
    end

    # a data-derived whitelist would drop this filter and show everything
    it "filters to nothing for a major that is absent from the table" do
      branch(pg_major: 20)

      q = query(pg: "14")

      expect(q.rows).to be_empty
      expect(q.selected(:pg)).to eq([ "14" ])
    end

    it "ignores an out-of-range pg major" do
      row = branch(pg_major: 20)

      q = query(pg: "9" * 25)

      expect { q.rows }.not_to raise_error
      expect(names(q)).to eq([ row.branch_name ])
    end

    it "filters by result status" do
      branch(ci_status: "success", pushed_at: 1.day.ago)
      bad = branch(ci_status: "build_failed", pushed_at: 1.day.ago)

      expect(names(query(result: "build_failed"))).to eq([ bad.branch_name ])
    end

    it "matches rows with no result under result=none" do
      never = branch(ci_status: nil)
      branch(ci_status: "success", pushed_at: 1.day.ago)

      expect(names(query(result: "none"))).to eq([ never.branch_name ])
    end

    it "combines facets" do
      wanted = branch(days_behind: 1, pg_major: 20)
      branch(days_behind: 400, pg_major: 20)
      branch(days_behind: 1, pg_major: 15)

      expect(names(query(base: "recent", pg: "20"))).to eq([ wanted.branch_name ])
    end

    it "ignores unknown facet values" do
      row = branch

      expect(names(query(base: "bogus", state: "bogus", result: "bogus", pg: "abc")))
        .to eq([ row.branch_name ])
    end

    it "survives an array param" do
      row = branch(pg_major: 20)

      q = query(pg: [ "20" ])

      expect(names(q)).to eq([ row.branch_name ])
      expect(q.selected(:pg)).to eq([])
      expect(q.active_params).to eq({})
    end

    it "survives a hash param" do
      row = branch

      q = query(base: { a: "1" })

      expect(names(q)).to eq([ row.branch_name ])
      expect(q.selected(:base)).to eq([])
      expect(q.active_params).to eq({})
    end

    it "raises on a facet it does not know" do
      expect { query.facet_values(:nope) }.to raise_error(ArgumentError, /unknown facet/)
    end
  end

  describe "search" do
    it "matches a branch name substring" do
      row = branch(branch_name: "t4481_v2")
      branch(branch_name: "t9902_v1", title: "unrelated")

      expect(names(query(q: "481_v"))).to eq([ row.branch_name ])
    end

    it "matches a topic title substring, case-insensitively" do
      row = branch(title: "Fix comment in pg_upgrade")
      other = branch(title: "Unicode update")

      got = names(query(q: "PG_UPGRA"))

      expect(got).to eq([ row.branch_name ])
      expect(got).not_to include(other.branch_name)
    end

    # the other branch name is digit-free on purpose: search also does
    # branch_name ILIKE, and the factory's t<n>_1 names could otherwise
    # contain the topic id by coincidence
    it "matches a bare topic id" do
      row = branch
      branch(branch_name: "no-digits-here")

      expect(names(query(q: row.topic_id.to_s))).to eq([ row.branch_name ])
    end

    it "clamps an absurdly long query" do
      branch

      q = query(q: "x" * 5_000)

      expect(q.search.length).to eq(100)
      expect(q.rows).to be_empty
    end

    # NUL is valid UTF-8, so Rails' param encoding check passes it through and
    # quote_string raises on it. An embedded one survives strip, a leading one
    # does not - so the interesting case is in the middle.
    it "strips NUL bytes out of the query" do
      row = branch(branch_name: "t4481_v2")

      nul = "\0"
      q = query(q: "4481#{nul}_v2")

      expect(q.search).to eq("4481_v2")
      expect(names(q)).to eq([ row.branch_name ])
    end

    it "combines a search with a facet" do
      wanted = branch(title: "pg_upgrade fix", ci_status: nil)
      branch(title: "pg_upgrade fix", ci_status: "success", pushed_at: 1.day.ago)
      branch(title: "unrelated", ci_status: nil)

      expect(names(query(result: "none", q: "pg_upgrade"))).to eq([ wanted.branch_name ])
    end

    # an unbounded digit string bound as a topic id is an out-of-range bigint
    it "treats an over-long number as a substring instead of a topic id" do
      branch

      q = query(q: "9" * 19)

      expect { q.rows }.not_to raise_error
      expect(q.rows).to be_empty
    end
  end

  describe "sorting" do
    it "defaults to most recently updated first" do
      old = branch
      new = branch
      old.update_columns(updated_at: 3.days.ago)
      new.update_columns(updated_at: 1.hour.ago)

      expect(names(query).first).to eq(new.branch_name)
    end

    # NULLS LAST on a NOT NULL column costs the updated_at+id index a seq scan
    # + sort, and only EXPLAIN would show it - so pin the SQL instead
    it "does not ask for NULLS LAST on the not-null default sort" do
      sql = query.rows.to_sql

      expect(sql).to include(%(ORDER BY patch_branches.updated_at DESC, "patch_branches"."id" DESC))
      expect(sql).not_to include("NULLS LAST")
    end

    it "sorts by base with the most behind first" do
      near = branch(days_behind: 1)
      far = branch(days_behind: 400)
      near.update_columns(base_commit_height: 900)
      far.update_columns(base_commit_height: 10)

      expect(names(query(sort: "base")).first).to eq(far.branch_name)
    end

    # the inversion must follow dir, not hardcode desc
    it "sorts by base the other way round under dir=asc" do
      near = branch(days_behind: 1)
      far = branch(days_behind: 400)
      near.update_columns(base_commit_height: 900)
      far.update_columns(base_commit_height: 10)

      expect(names(query(sort: "base", dir: "asc")).first).to eq(near.branch_name)
    end

    it "puts rows without a sort value last" do
      with = branch(pg_major: 20)
      without = branch(pg_major: nil)

      expect(names(query(sort: "pg", dir: "desc")).last).to eq(without.branch_name)
    end

    it "falls back to the default for an unknown sort key" do
      old = branch
      new = branch
      old.update_columns(updated_at: 3.days.ago)
      new.update_columns(updated_at: 1.hour.ago)

      expect(names(query(sort: "haxx; DROP TABLE"))).to eq([ new.branch_name, old.branch_name ])
    end

    it "breaks ties by id descending" do
      first = branch
      second = branch
      stamp = 1.hour.ago
      PatchBranch.where(id: [ first.id, second.id ]).update_all(updated_at: stamp)

      expect(names(query)).to eq([ second.branch_name, first.branch_name ])
    end
  end

  # one object serves both the table and `paginate`, so pin both halves
  describe "rows" do
    it "is decorated and still answers kaminari" do
      branch

      q = query

      expect(q.rows.first.health_bucket).to eq("awaiting_ci")
      expect(q.rows.current_page).to eq(1)
      expect(q.rows.total_pages).to eq(1)
      expect(q.rows.total_count).to eq(1)
    end
  end

  # drives every chip link and the pagination params, and must never carry a
  # page or the links would strand people on a page that no longer exists
  describe "active_params" do
    it "is empty when nothing differs from the defaults" do
      expect(query(dir: "desc", sort: "updated", q: "   ").active_params).to eq({})
    end

    it "keeps a stripped search and a non-default direction" do
      expect(query(q: " hi ", dir: "asc").active_params).to eq({ q: "hi", dir: "asc" })
    end

    it "drops unknown facet values" do
      expect(query(base: "recent,bogus").active_params).to eq({ base: "recent" })
    end

    it "carries a non-default sort" do
      expect(query(sort: "base").active_params).to eq({ sort: "base" })
    end

    it "never carries a page" do
      expect(query(page: "4", base: "recent").active_params).to eq({ base: "recent" })
    end
  end

  describe "#filtered?" do
    it "is false for a bare page" do
      expect(query).not_to be_filtered
    end

    # a sort is in active_params but is not a filter
    it "is false for a sort alone" do
      expect(query(sort: "pg", dir: "asc")).not_to be_filtered
    end

    it "is false once an unknown facet value has been dropped" do
      expect(query(state: "bogus")).not_to be_filtered
    end

    it "is true for a facet" do
      expect(query(state: "fresh")).to be_filtered
    end

    it "is true for a search" do
      expect(query(q: "vacuum")).to be_filtered
    end

    it "is false for a whitespace-only search" do
      expect(query(q: "   ")).not_to be_filtered
    end
  end

  describe "pagination" do
    it "pages" do
      stub_const("PatchCi::Config::BRANCHES_PAGE", 1)
      older = branch
      newer = branch
      older.update_columns(updated_at: 2.hours.ago)
      newer.update_columns(updated_at: 1.hour.ago)

      expect(names(query)).to eq([ newer.branch_name ])
      expect(names(query(page: "2"))).to eq([ older.branch_name ])
    end

    it "ignores a garbage page number" do
      row = branch
      expect(names(query(page: "99999999999999999999"))).to eq([ row.branch_name ])
    end

    # counts the whole table, not the page - they label the facet chips
    it "exposes bucket counts that ignore the filters" do
      branch(pushed_at: 1.day.ago, ci_status: "success")
      branch(status: "failed", failure_stage: "apply")

      counts = query(state: "fresh").bucket_counts

      expect(counts["fresh"]).to eq(1)
      expect(counts["needs_rebase"]).to eq(1)
    end

    it "counts under the filters" do
      branch(days_behind: 1)
      branch(days_behind: 400)

      expect(query(base: "recent").total_count).to eq(1)
      expect(query.total_count).to eq(2)
    end
  end
end
