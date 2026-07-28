module PatchCi
  # Request params -> one page of table-ready branch rows. Everything the
  # /ci/branches chrome can ask for lives here so the controller stays a
  # dispatcher: five facets, a search box, a whitelisted sort, pagination.
  class BranchQuery
    FACETS = %i[base state check pg result].freeze
    NO_RESULT = "none".freeze
    RESULT_VALUES = (PatchCiRun::STATUSES + [ NO_RESULT ]).freeze
    MAX_QUERY = 100
    # bounded so an over-long number cannot reach postgres as an out-of-range
    # bigint bind; a longer query is just a substring search
    TOPIC_ID = /\A\d{1,9}\z/
    # pg_major is int4, so keep the bind well inside it
    PG_MAJOR = /\A\d{1,3}\z/
    # an unbounded value reaches postgres as a bigint OFFSET and 500s
    PAGE = /\A\d{1,6}\z/

    # every sort is (expression, id DESC) so a page boundary cannot duplicate
    # or drop a row.
    #
    # nulls_last only where the column is actually nullable: postgres does not
    # fold NULLS LAST away on a NOT NULL column, it treats it as a pathkey no
    # index satisfies, which costs the updated_at+id index a seq scan + sort.
    #
    # invert because desc means most-interesting-first on every column, so the
    # header arrow reads the same everywhere. base is stored as height but read
    # as "how far behind", and those run opposite ways - lowest height is most
    # behind.
    #
    # branch sorts by id, not by name: t<n>_<v> names sort wrong as text, where
    # t1000 lands before t999. Do not "fix" this to branch_name.
    SORTS = {
      "updated" => { sql: "patch_branches.updated_at" },
      "base" => { sql: "patch_branches.base_commit_height", invert: true, nulls_last: true },
      "pg" => { sql: "patch_branches.pg_major", nulls_last: true },
      "branch" => { sql: "patch_branches.id" }
    }.freeze
    DEFAULT_SORT = "updated".freeze
    DEFAULT_DIR = "desc".freeze

    def initialize(params:, repo_state:, rows: BranchRows.new(repo_state: repo_state))
      @params = params
      @repo_state = repo_state
      @row_builder = rows
    end

    # one page, as a loaded relation: render it and paginate it
    def rows
      @loaded ||= @row_builder.load(paginated)
    end

    # off the same relation the page renders: kaminari skips the COUNT entirely
    # on a short last page, and counting a second object would only duplicate
    # it. The inner join to topics cannot change the number - topic_id is NOT
    # NULL and belongs_to :topic is required.
    def total_count
      rows.total_count
    end

    def health
      @row_builder.health
    end

    def bucket_counts
      health.cached_counts
    end

    def sort_key
      @sort_key ||= SORTS.key?(param(:sort)) ? param(:sort) : DEFAULT_SORT
    end

    def sort_dir
      @sort_dir ||= param(:dir) == "asc" ? "asc" : DEFAULT_DIR
    end

    # NUL is valid UTF-8, so check_param_encoding lets it through, and
    # quote_string raises on it - same strip as ResultPayload, same reason
    def search
      @search ||= param(:q).to_s.delete("\0").strip.slice(0, MAX_QUERY)
    end

    def selected(facet)
      @selected ||= {}
      @selected[facet] ||= validate(facet, list(facet))
    end

    # for the "clear filters" affordance: the sort is not a filter, and a page
    # that is only sorted has nothing to clear
    def filtered?
      search.present? || FACETS.any? { |facet| selected(facet).any? }
    end

    # for the sort/facet links and for pagination
    def active_params
      out = { q: search.presence, sort: (sort_key unless sort_key == DEFAULT_SORT),
              dir: (sort_dir unless sort_dir == DEFAULT_DIR) }
      FACETS.each { |facet| out[facet] = selected(facet).join(",").presence }
      out.compact
    end

    # the chips to render for all five facets, but the filter whitelist for
    # only four - pg validates by shape instead, see validate
    def facet_values(facet)
      case facet
      when :base then BaseFreshness::TIERS
      when :state then BranchHealth::BUCKETS
      when :check then MasterCheck::TIERS
      when :pg then present_majors
      when :result then RESULT_VALUES
      else raise ArgumentError, "unknown facet: #{facet.inspect}"
      end
    end

    private

    # chips to render, not the filter whitelist. Keyed on the repo state and not
    # because pg_major has anything to do with fetched_at - it just turns over
    # with the other per-cycle caches, so the whole page ages as one thing.
    def present_majors
      @present_majors ||= Rails.cache.fetch([ "ci-present-majors", @repo_state&.fetched_at ],
                                            expires_in: Config::AGGREGATE_TTL) do
        PatchBranch.current.distinct.where.not(pg_major: nil)
                   .order(pg_major: :desc).pluck(:pg_major).map(&:to_s)
      end
    end

    # pg validates by shape, not against present_majors: that list is cached
    # and data-derived, so intersecting with it would silently drop a filter
    # the user can still see in the URL - showing every row instead of none.
    # Normalized through to_i so 020 and 20 produce the same chip state.
    def validate(facet, values)
      return values.grep(PG_MAJOR).map(&:to_i).uniq.map(&:to_s) if facet == :pg
      values & facet_values(facet)
    end

    def paginated
      @paginated ||= ordered.page(page).per(Config::BRANCHES_PAGE)
    end

    def ordered
      spec = SORTS.fetch(sort_key)
      filtered.order(Arel.sql("#{spec.fetch(:sql)} #{column_dir(spec)}#{" NULLS LAST" if spec[:nulls_last]}"),
                     id: :desc)
    end

    def column_dir(spec)
      dir = sort_dir
      dir = (dir == "asc" ? "desc" : "asc") if spec[:invert]
      dir.upcase
    end

    def freshness
      @row_builder.freshness
    end

    def check
      @row_builder.check
    end

    # each facet owns its own SQL; this only decides the order they compose in
    def filtered
      scope = PatchBranch.current
      scope = freshness.filter(scope, selected(:base))
      scope = health.filter(scope, selected(:state))
      scope = check.filter(scope, selected(:check))
      scope = filter_pg(scope)
      scope = filter_result(scope)
      apply_search(scope)
    end

    def filter_pg(scope)
      majors = selected(:pg)
      return scope if majors.empty?
      scope.where(pg_major: majors.map(&:to_i))
    end

    def filter_result(scope)
      results = selected(:result)
      return scope if results.empty?
      statuses = results - [ NO_RESULT ]
      if results.include?(NO_RESULT)
        scope.where(ci_status: statuses).or(scope.where(ci_status: nil))
      else
        scope.where(ci_status: statuses)
      end
    end

    # substring, not the title tsvector: people type "t448" and "pg_upgra",
    # which word search does not match. topics.title has a trigram index;
    # branch_name is a short column on a small table.
    def apply_search(scope)
      return scope if search.blank?
      like = "%#{sanitize_like(search)}%"
      scope = scope.joins(:topic)
      clause = "patch_branches.branch_name ILIKE :like OR topics.title ILIKE :like"
      binds = { like: like }
      if search.match?(TOPIC_ID)
        clause += " OR patch_branches.topic_id = :topic_id"
        binds[:topic_id] = search.to_i
      end
      scope.where(clause, binds)
    end

    def sanitize_like(text)
      ActiveRecord::Base.sanitize_sql_like(text)
    end

    def page
      param(:page).to_s[PAGE] || 1
    end

    def param(key)
      value = @params[key]
      value.is_a?(String) ? value : nil
    end

    def list(key)
      param(key).to_s.split(",").map(&:strip).reject(&:empty?)
    end
  end
end
