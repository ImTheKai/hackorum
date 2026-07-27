module CiHelper
  CI_BADGES = {
    "success" => [ "b-success", "success" ],
    "tests_failed" => [ "b-testsfail", "tests failed" ],
    "tests_timeout" => [ "b-testsfail", "tests timeout" ],
    "build_failed" => [ "b-buildfail", "build failed" ],
    "build_timeout" => [ "b-buildfail", "build timeout" ],
    "running" => [ "b-running", "running" ],
    "queued" => [ "b-queued", "queued" ],
    "pushed_awaiting_ci" => [ "b-queued", "waiting for runner" ],
    "push_failed" => [ "b-infra", "push failed" ],
    "infra_error" => [ "b-infra", "infra error" ],
    "cancelled" => [ "b-queued", "cancelled" ],
    "ci_none" => [ "b-queued", "no CI" ]
  }.freeze

  CI_TIER_BADGES = {
    new_version: [ "b-newver", "new version" ],
    rebase: [ "b-rebase", "rebase" ],
    backfill: [ "b-backfill", "backfill" ]
  }.freeze

  CI_TIER_WORK = {
    new_version: "apply + push",
    rebase: "re-apply on master + push",
    backfill: "push"
  }.freeze

  # css + label. The health panel, the State badge and the state facet chip all
  # read their words off here, so the same bucket cannot be called two things.
  CI_BUCKET_BADGES = {
    "fresh" => [ "b-success", "fresh" ],
    "needs_rebase" => [ "b-rebase", "needs rebase" ],
    "awaiting_ci" => [ "b-queued", "awaiting CI" ],
    "wont_retry" => [ "b-infra", "won't retry" ],
    "never_applied" => [ "b-buildfail", "never applied" ]
  }.freeze

  CI_BASE_TIER_BADGES = {
    "recent" => "b-success",
    "stale" => "b-rebase",
    "ancient" => "b-buildfail",
    "unknown" => "b-queued"
  }.freeze

  # what lands in a bucket, in one line. Only the buckets whose panel has no
  # live breakdown of its own - awaiting_ci and wont_retry build theirs from
  # counts, so they are absent here on purpose.
  CI_BUCKET_BLURBS = {
    "fresh" => "applies on recent master",
    "needs_rebase" => "base stale or apply failing",
    "never_applied" => "apply or extract failed"
  }.freeze

  # what each /ci/branches facet row is called; facet names are prose, but every
  # facet *value* renders lowercase in this feature, chip and badge alike
  FACET_LABELS = {
    base: "base age",
    state: "state",
    pg: "pg major",
    result: "result"
  }.freeze

  # codepoints so grepping this file for the arrows finds the one definition
  # rather than two glyphs. U+25BE/U+25B4 are the small down/up triangles.
  SORT_ARROWS = { "desc" => 0x25BE.chr("UTF-8"), "asc" => 0x25B4.chr("UTF-8") }.freeze
  ARIA_SORT = { "desc" => "descending", "asc" => "ascending" }.freeze

  GITHUB_URL = "https://github.com".freeze
  SHORT_SHA_CHARS = 9
  DIGEST_LABEL_CHARS = 14

  def ci_status_label(status)
    ci_badge_for(status).last
  end

  # title carries the branch's ci_skip_reason for infra/push failures
  def ci_status_badge(status, title: nil)
    css, label = ci_badge_for(status)
    css = "#{css} ci-hover" if title.present?
    tag.span(label, class: "badge #{css}", title: title.presence)
  end

  def ci_tier_badge(kind)
    css, label = CI_TIER_BADGES.fetch(kind)
    tag.span(label, class: "badge #{css}")
  end

  def ci_tier_work(kind)
    CI_TIER_WORK[kind]
  end

  # /ci/branches health bucket label - same badge look as ci_tier_badge
  def ci_bucket_badge(bucket)
    css, label = ci_bucket_pair(bucket)
    tag.span(label, class: "badge #{css}")
  end

  # the badge's own words, for callers that want them without the badge
  def ci_bucket_label(bucket)
    ci_bucket_pair(bucket).last
  end

  def ci_bucket_blurb(bucket)
    CI_BUCKET_BLURBS[bucket.to_s]
  end

  # tier badge plus a compact behind figure; the exact numbers stay in the
  # title so a narrow column does not cost precision
  def ci_base_tier_badge(row, repo_state)
    tier = row.base_tier.to_s
    css = CI_BASE_TIER_BADGES.fetch(tier, "b-queued")
    label = [ tier, ci_behind_label(row.behind_days(repo_state)) ].compact.join(" ")
    tag.span(label, class: "badge #{css} ci-hover", title: ci_behind_title(row, repo_state))
  end

  def ci_behind_label(days)
    return nil unless days
    days = [ days, 0 ].max
    return "#{days}d" if days < 60
    return "#{(days / 30.0).round}mo" if days < 365
    "#{(days / 365.0).round}y"
  end

  def ci_behind_title(row, repo_state)
    parts = ci_behind_parts(row, repo_state)
    parts ? "#{parts} behind master" : "no base metadata"
  end

  def ci_work_reason(item, repo_state)
    case item.kind
    when :new_version then "patch posted #{time_ago_in_words(item.message.created_at)} ago"
    when :backfill then "applied, never pushed"
    when :rebase
      row = item.patch_branch
      if row.master_apply_error.present?
        "master apply failing, retrying"
      else
        parts = ci_behind_parts(row, repo_state)
        parts ? "#{parts} behind" : "base metadata missing"
      end
    end
  end

  # the "why" of an infra/push failure lives on the branch, not the run
  SKIP_REASON_STATUSES = %w[infra_error push_failed].freeze

  def ci_skip_reason_for(row)
    return nil unless SKIP_REASON_STATUSES.include?(row.ci_status)
    row.ci_skip_reason.presence
  end

  def ci_duration(seconds)
    return "-" if seconds.blank?
    "#{seconds / 60}m #{format('%02d', seconds % 60)}s"
  end

  def ci_percent(value, precision: 1)
    return ci_muted_dash if value.nil?
    number_to_percentage(value * 100, precision: precision)
  end

  def ci_stat_count(value)
    number_with_delimiter(value.to_i)
  end

  def ci_short_sha(sha)
    sha.to_s.first(SHORT_SHA_CHARS).presence
  end

  # t<topic>_<index>: the index is the patchset number the site already shows,
  # so read it back rather than recomputing it - same as Pusher#message_index.
  # nil rather than garbage if a branch name ever stops matching the format.
  def ci_patchset_index(row)
    row.branch_name.to_s[/_(\d+)\z/, 1]
  end

  # the four stages ApplyOne can fail at, in words. "error" is its catch-all
  # for an exception, which "failed at error" would not convey.
  FAILURE_STAGE_PHRASES = {
    "extract" => "patch extract failed",
    "base_detection" => "no usable base commit",
    "apply" => "apply failed",
    "error" => "apply crashed"
  }.freeze

  # the one-phrase "what became of this patchset", for a row with nothing to
  # expand. A row that reached CI says it in badges instead.
  def ci_patchset_outcome(row)
    return FAILURE_STAGE_PHRASES.fetch(row.failure_stage, "apply failed") if row.status == "failed"
    return "applied, never pushed" if row.pushed_at.nil?
    nil
  end

  def ci_github_branch_url(branch_name)
    "#{GITHUB_URL}/#{PatchCi::Config::GITHUB_REPO}/tree/#{branch_name}"
  end

  def ci_github_commit_url(sha)
    "#{GITHUB_URL}/#{PatchCi::Config::GITHUB_REPO}/commit/#{sha}"
  end

  def ci_github_compare_url(base_sha, head_sha)
    "#{GITHUB_URL}/#{PatchCi::Config::GITHUB_REPO}/compare/#{base_sha}...#{head_sha}"
  end

  # attempt 1 has no /attempts page worth linking - the run URL already lands
  # on it, and the suffix would just be noise on every first-try run
  def ci_github_run_url(run)
    url = "#{GITHUB_URL}/#{PatchCi::Config::GITHUB_REPO}/actions/runs/#{run.github_run_id}"
    run.run_attempt > 1 ? "#{url}/attempts/#{run.run_attempt}" : url
  end

  # the one "nothing to show here" mark, so a table cannot grow a second one
  def ci_muted_dash
    tag.span("-", class: "muted")
  end

  def ci_result_cell(row)
    return ci_muted_dash if row.ci_status.blank?
    ci_status_badge(row.ci_status, title: ci_skip_reason_for(row))
  end

  # an in-flight row has no durations yet, so the same cell carries how long
  # it has been out there. Nothing to count from without a push time, and a
  # finished run's durations would be a lie about the one in flight.
  def ci_timing_cell(row)
    if PatchCiRun::IN_FLIGHT_BRANCH_STATUSES.include?(row.ci_status)
      return ci_muted_dash if row.pushed_at.nil?
      tag.span("#{ci_elapsed_minutes(row.pushed_at)} elapsed", class: "muted")
    elsif (run = row.latest_run_summary)
      ci_duration_pair(run)
    else
      ci_muted_dash
    end
  end

  # a run still out there has no durations yet, so the same cell carries how
  # long it has been going - same trade as ci_timing_cell makes for a branch
  def ci_run_timing_cell(run)
    unless run.terminal?
      since = run.started_at || run.queued_at
      return since ? tag.span("#{ci_elapsed_minutes(since)} elapsed", class: "muted") : ci_muted_dash
    end
    ci_duration_pair(run)
  end

  def ci_image_cell(row)
    ci_image_command_cell(row.latest_run_summary, live: true)
  end

  # ghcr tag is :t<topic_id> - one tag for the whole topic, overwritten by
  # every run in it. Only the newest run that built one can still offer the
  # tag; the rest offer the digest they recorded, which nothing overwrites.
  def ci_image_command_cell(run, live:)
    ref = live ? (run&.image_ref).presence : ci_digest_ref(run)
    return ci_muted_dash if ref.blank?
    cmd = ci_docker_command(ref)
    tag.code(ci_docker_label(ref), class: "ci-copy", title: cmd,
             data: { controller: "clipboard", action: "click->clipboard#copy",
                     "clipboard-url-value": cmd })
  end

  def ci_tests_cell(row)
    ci_tests_figure(row.latest_run_summary)
  end

  # hover: false where the failure list is already on the page - the run table
  # folds it out, and the same 200 names twice in one row is not a hint
  def ci_tests_figure(run, hover: true)
    return ci_muted_dash if run.nil? || run.tests_total.blank?
    # a partial payload can report more failures than it reports tests
    passed = [ run.tests_total - run.failed_tests.size, 0 ].max
    text = "#{passed} / #{run.tests_total}"
    return tag.span(text) if !hover || run.failed_tests.empty?
    tag.span(text, class: "ci-hover", title: "Failed: #{run.failed_tests.join(', ')}")
  end

  def ci_docker_command(image_ref)
    "docker run --rm -p 5432:5432 #{image_ref}"
  end

  # rpartition, not split: a registry host may carry a port, and only the
  # trailing :tag is the tag
  def ci_digest_ref(run)
    return nil if run.nil? || run.image_ref.blank? || run.image_digest.blank?
    repo = run.image_ref.rpartition(":").first.presence || run.image_ref
    "#{repo}@#{run.image_digest}"
  end

  def ci_docker_label(image_ref)
    return "docker run ... :#{image_ref.split(':').last}" unless image_ref.include?("@")
    "docker run ... @#{image_ref.split('@').last.slice(0, DIGEST_LABEL_CHARS)}..."
  end

  def ci_elapsed_minutes(since)
    return "-" unless since
    "#{((Time.current - since) / 60).floor}m"
  end

  # a run is dated by the last thing that happened to it; an unclaimed push
  # has none of the three
  def ci_run_when(run)
    stamp = run.completed_at || run.started_at || run.queued_at
    return "-" unless stamp
    smart_time_display(stamp)
  end

  # the aliases are raw json text out of a hostile payload, so a nested object
  # would otherwise render as json on the page
  def ci_ccache_line(run)
    return nil unless run.ccache_hit.to_s.match?(/\A\d+\z/) && run.ccache_miss.to_s.match?(/\A\d+\z/)
    "ccache #{run.ccache_hit} hit / #{run.ccache_miss} miss"
  end

  def ci_facet_label(facet)
    FACET_LABELS.fetch(facet)
  end

  # one chip per facet value, toggling only its own value: the other facets and
  # the sort ride along in active_params, which never carries page.
  # Links inside the frame need no turbo data of their own - they target the
  # enclosing frame, and it carries the visit action.
  def ci_facet_chip(query, facet, value, count: nil)
    selected = query.selected(facet)
    active = selected.include?(value)
    values = active ? selected - [ value ] : selected + [ value ]
    text = ci_facet_value_label(facet, value)
    text = "#{text} (#{number_with_delimiter(count)})" if count
    link_to text,
            ci_branches_path(query.active_params.merge(facet => values.join(",")).compact_blank),
            class: ("is-active" if active), aria: { current: ("true" if active) }
  end

  def ci_facet_all_chip(query, facet)
    active = query.selected(facet).empty?
    link_to "all", ci_branches_path(query.active_params.except(facet)),
            class: ("is-active" if active), aria: { current: ("true" if active) }
  end

  # clicking the active column flips direction, any other column starts desc.
  # No query means the dashboard sections, which share the partial but have
  # nothing to sort - plain header there.
  def ci_sort_header(query, key, label, numeric: false)
    return tag.th(label, class: ("num" if numeric)) if query.nil?

    active = query.sort_key == key
    dir = active && query.sort_dir == "desc" ? "asc" : "desc"
    arrow = active ? " #{SORT_ARROWS.fetch(query.sort_dir)}" : ""
    classes = [ ("num" if numeric), "sortable", ("is-active" if active) ].compact.join(" ")
    tag.th(class: classes, aria: { sort: (ARIA_SORT.fetch(query.sort_dir) if active) }) do
      link_to "#{label}#{arrow}", ci_branches_path(query.active_params.merge(sort: key, dir: dir))
    end
  end

  private

  # the one "build / test" pair, so a table cannot grow a second one with a
  # different blank case
  def ci_duration_pair(run)
    return ci_muted_dash if run.build_seconds.blank? && run.test_seconds.blank?
    tag.span("#{ci_duration(run.build_seconds)} / #{ci_duration(run.test_seconds)}")
  end

  # a chip reading "ci none" over a badge reading "no CI" is the same row
  # disagreeing with itself, so both facets whose values the table also renders
  # as badges take the label off the badge map. NO_RESULT is a sentinel with no
  # badge of its own.
  def ci_facet_value_label(facet, value)
    case facet
    when :result
      value == PatchCi::BranchQuery::NO_RESULT ? "no result" : ci_status_label(value)
    when :state then ci_bucket_label(value)
    else value.to_s.tr("_", " ")
    end
  end

  # the fallback keeps an unmapped bucket readable rather than blank
  def ci_bucket_pair(bucket)
    CI_BUCKET_BADGES.fetch(bucket.to_s, [ "b-queued", bucket.to_s.tr("_", " ") ])
  end

  # css + label pair; views take one or the other through the two wrappers
  def ci_badge_for(status)
    CI_BADGES.fetch(status.to_s, [ "b-queued", status.to_s.humanize.downcase ])
  end

  # nil when we know neither figure. clamped: a repo state fetched while a
  # push was in flight can trail the base, and "-2 days behind" is noise
  def ci_behind_parts(row, repo_state)
    days = row.behind_days(repo_state)
    commits = row.behind_commits(repo_state)
    [ days && "#{[ days, 0 ].max} days", commits && "#{[ commits, 0 ].max} commits" ]
      .compact.join(" / ").presence
  end
end
