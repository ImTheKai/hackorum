#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "json"
require "digest"
require "net/http"
require "uri"
require "fileutils"
require "open3"
require "time"
require "set"

begin
  require "sqlite3"
rescue LoadError
  warn "hackorum-commits requires the 'sqlite3' gem. Install it with: gem install sqlite3"
  exit 1
end

module HackorumCommits
  VERSION = "0.1.0"

  # Lightweight progress reporter. Writes timestamped lines to stderr so that
  # long-running phases (git walk, per-commit API calls) are observable.
  # `Progress.silent` is a no-op instance used as the default in tests.
  class Progress
    def self.silent
      @silent ||= new(enabled: false)
    end

    def initialize(enabled: true, io: $stderr)
      @enabled = enabled
      @io = io
      @start = Time.now
    end

    def say(msg)
      return unless @enabled
      @io.puts(format("[%7.1fs] %s", Time.now - @start, msg))
      @io.flush
    end

    def phase(name)
      say("=== #{name} ===")
    end

    # Logs "done" once `total` is known to be small, otherwise emits a line
    # every `every` items so the user sees steady movement.
    def progress(index, total, label, every: 50)
      return unless @enabled
      return unless index == total || (index % every).zero?
      say("#{label}: #{index}/#{total}")
    end
  end

  Config = Struct.new(
    :server, :repo, :state_dir,
    :branches, :since, :until_date, :limit, :quiet, :command,
    :match_window, :dominance, :judge_floor,
    :llm_url, :llm_model,
    :corpus_since, :corpus_until,
    :judge_confidence, :skip_judge, :only_shas,
    keyword_init: true
  ) do
    def self.parse(argv)
      opts = {
        server: "https://hackorum.dev",
        repo: "postgres",
        state_dir: ".hackorum-commits",
        branches: nil,
        since: nil,
        until_date: nil,
        limit: nil,
        quiet: false,
        match_window: 60,
        dominance: 1.5,
        judge_floor: 3.0,
        llm_url: ENV.fetch("HACKORUM_LLM_URL", "http://localhost:8080/v1"),
        llm_model: ENV.fetch("HACKORUM_LLM_MODEL", "local"),
        corpus_since: nil,
        corpus_until: nil,
        judge_confidence: 0.8,
        skip_judge: false,
        only_shas: nil
      }
      parser = OptionParser.new do |o|
        o.banner = "Usage: bundle exec ruby script/hackorum_commits.rb [command] [options]\n" \
                   "Commands: walk parse link quickfix corpus-sync match judge export run version"
        o.on("--server URL") { |v| opts[:server] = v }
        o.on("--repo PATH") { |v| opts[:repo] = v }
        o.on("--state-dir PATH") { |v| opts[:state_dir] = v }
        o.on("--branches LIST", "Comma-separated refs (default: master + REL_*)") { |v| opts[:branches] = v.split(",") }
        o.on("--since DATE", "Only commits on/after this ISO date") { |v| opts[:since] = v }
        o.on("--until DATE", "Only commits on/before this ISO date") { |v| opts[:until_date] = v }
        o.on("--limit N", Integer, "Max commits to process") { |v| opts[:limit] = v }
        o.on("--quiet", "Suppress progress output on stderr") { opts[:quiet] = true }
        o.on("--match-window DAYS", Integer) { |v| opts[:match_window] = v }
        o.on("--dominance RATIO", Float) { |v| opts[:dominance] = v }
        o.on("--judge-floor SCORE", Float) { |v| opts[:judge_floor] = v }
        o.on("--llm-url URL") { |v| opts[:llm_url] = v }
        o.on("--llm-model NAME") { |v| opts[:llm_model] = v }
        o.on("--corpus-since DATE") { |v| opts[:corpus_since] = v }
        o.on("--corpus-until DATE") { |v| opts[:corpus_until] = v }
        o.on("--judge-confidence C", Float) { |v| opts[:judge_confidence] = v }
        o.on("--skip-judge") { opts[:skip_judge] = true }
        o.on("--only-shas LIST", "Judge only these comma-separated sha prefixes") { |v| opts[:only_shas] = v.split(",").map(&:strip).reject(&:empty?) }
      end
      remaining = parser.parse(argv)
      unless (0.0..1.0).cover?(opts[:judge_confidence])
        raise ArgumentError, "--judge-confidence must be within 0.0..1.0 (got #{opts[:judge_confidence]})"
      end
      opts[:command] = remaining.shift
      new(**opts)
    end
  end

  class Store
    attr_reader :db

    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS commits (
        sha TEXT PRIMARY KEY, subject TEXT, body TEXT,
        authored_at TEXT, committed_at TEXT,
        author_name TEXT, author_email TEXT,
        committer_name TEXT, committer_email TEXT,
        branches TEXT, versions TEXT,
        files TEXT,
        stage TEXT DEFAULT 'walked', updated_at TEXT
      );
      CREATE TABLE IF NOT EXISTS commit_relations (
        from_sha TEXT, to_sha TEXT, kind TEXT,
        confidence REAL, method TEXT,
        UNIQUE(from_sha, to_sha, kind)
      );
      CREATE TABLE IF NOT EXISTS commit_facts (
        sha TEXT, kind TEXT, value TEXT, method TEXT, confidence REAL, evidence TEXT,
        UNIQUE(sha, kind, value)
      );
      CREATE TABLE IF NOT EXISTS thread_links (
        sha TEXT, topic_id INTEGER, mailing_list TEXT, method TEXT,
        confidence REAL, evidence TEXT, verdict TEXT, external_message_id TEXT,
        UNIQUE(sha, topic_id)
      );
      CREATE TABLE IF NOT EXISTS api_cache (
        request_key TEXT PRIMARY KEY, response TEXT, fetched_at TEXT
      );
      CREATE TABLE IF NOT EXISTS patchsets (
        message_id INTEGER PRIMARY KEY, external_message_id TEXT,
        topic_id INTEGER, submitted_at TEXT, title TEXT, sender TEXT, paths TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_patchsets_submitted ON patchsets(submitted_at);
      CREATE TABLE IF NOT EXISTS corpus_sync_state (
        id INTEGER PRIMARY KEY CHECK (id = 1), cursor TEXT, synced_at TEXT
      );
      CREATE TABLE IF NOT EXISTS match_candidates (
        sha TEXT, topic_id INTEGER, score REAL, jaccard REAL,
        n_overlap INTEGER, n_nonnoise INTEGER, date_gap_days INTEGER,
        title TEXT, sender TEXT, matched_paths TEXT, patch_path_count INTEGER,
        submitted_at TEXT, UNIQUE(sha, topic_id)
      );
      CREATE TABLE IF NOT EXISTS judgments (
        sha TEXT, topic_id INTEGER, prompt_hash TEXT, verdict TEXT,
        confidence REAL, evidence TEXT, model TEXT, created_at TEXT,
        UNIQUE(sha, topic_id, prompt_hash)
      );
    SQL

    def initialize(path)
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @db.execute_batch(SCHEMA)
      ensure_column("commits", "files", "TEXT")
    end

    def upsert_commit(sha:, subject:, body:, authored_at:, committed_at:,
                      author_name:, author_email:, committer_name:, committer_email:,
                      branches:, versions:, files: [], stage: "walked")
      params = [ sha, subject, body, authored_at, committed_at,
                author_name, author_email, committer_name, committer_email,
                JSON.generate(branches), JSON.generate(versions), JSON.generate(files),
                stage, Time.now.utc.iso8601 ]
      @db.execute(<<~SQL, params)
        INSERT INTO commits (sha, subject, body, authored_at, committed_at,
          author_name, author_email, committer_name, committer_email,
          branches, versions, files, stage, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(sha) DO UPDATE SET subject=excluded.subject, body=excluded.body,
          branches=excluded.branches, versions=excluded.versions, files=excluded.files, updated_at=excluded.updated_at
      SQL
    end

    def commit(sha)
      @db.execute("SELECT * FROM commits WHERE sha = ?", [ sha ]).first
    end

    def commit_by_prefix(prefix)
      rows = @db.execute("SELECT sha FROM commits WHERE sha LIKE ? LIMIT 2", [ "#{prefix}%" ])
      rows.size == 1 ? rows.first["sha"] : nil
    end

    def set_stage(sha, stage)
      @db.execute("UPDATE commits SET stage = ?, updated_at = ? WHERE sha = ?",
                  [ stage, Time.now.utc.iso8601, sha ])
    end

    def add_relation(from_sha:, to_sha:, kind:, confidence:, method:)
      @db.execute(<<~SQL, [ from_sha, to_sha, kind, confidence, method ])
        INSERT OR IGNORE INTO commit_relations (from_sha, to_sha, kind, confidence, method)
        VALUES (?,?,?,?,?)
      SQL
    end

    def relations_for(sha)
      @db.execute("SELECT * FROM commit_relations WHERE from_sha = ?", [ sha ])
    end

    def api_cache_get(key)
      row = @db.execute("SELECT response FROM api_cache WHERE request_key = ?", [ key ]).first
      row && row["response"]
    end

    def api_cache_put(key, response)
      @db.execute("INSERT OR REPLACE INTO api_cache (request_key, response, fetched_at) VALUES (?,?,?)",
                  [ key, response, Time.now.utc.iso8601 ])
    end

    def add_link(sha:, topic_id:, mailing_list:, method:, confidence:, verdict:, evidence:, external_message_id:)
      @db.execute(<<~SQL, [ sha, topic_id, mailing_list, method, confidence, verdict, evidence, external_message_id ])
        INSERT OR REPLACE INTO thread_links
          (sha, topic_id, mailing_list, method, confidence, verdict, evidence, external_message_id)
        VALUES (?,?,?,?,?,?,?,?)
      SQL
    end

    def links_for(sha)
      @db.execute("SELECT * FROM thread_links WHERE sha = ?", [ sha ])
    end

    def add_fact(sha:, kind:, value:, method:, confidence:, evidence:)
      @db.execute(<<~SQL, [ sha, kind, value, method, confidence, evidence ])
        INSERT OR IGNORE INTO commit_facts (sha, kind, value, method, confidence, evidence)
        VALUES (?,?,?,?,?,?)
      SQL
    end

    def facts_for(sha)
      @db.execute("SELECT * FROM commit_facts WHERE sha = ?", [ sha ])
    end

    def each_commit
      @db.execute("SELECT * FROM commits ORDER BY committed_at").each { |row| yield row }
    end

    def each_commit_at_stage(stage)
      @db.execute("SELECT * FROM commits WHERE stage = ? ORDER BY committed_at", [ stage ]).each { |r| yield r }
    end

    def count_commits
      @db.execute("SELECT COUNT(*) AS n FROM commits").first["n"]
    end

    def count_at_stage(stage)
      @db.execute("SELECT COUNT(*) AS n FROM commits WHERE stage = ?", [ stage ]).first["n"]
    end

    def set_message_ids(sha, ids)
      ids.each do |id|
        @db.execute("INSERT OR IGNORE INTO commit_facts (sha, kind, value, method, confidence, evidence) VALUES (?,?,?,?,?,?)",
                    [ sha, "discussion_message_id", id, "trailer", 1.0, "Discussion: #{id}" ])
      end
    end

    def message_ids_for(sha)
      @db.execute("SELECT value FROM commit_facts WHERE sha = ? AND kind = 'discussion_message_id'", [ sha ])
         .map { |r| r["value"] }
    end

    def upsert_patchset(message_id:, external_message_id:, topic_id:, submitted_at:, title:, sender:, paths:)
      @db.execute(<<~SQL, [ message_id, external_message_id, topic_id, submitted_at, title, sender, JSON.generate(paths) ])
        INSERT OR REPLACE INTO patchsets
          (message_id, external_message_id, topic_id, submitted_at, title, sender, paths)
        VALUES (?,?,?,?,?,?,?)
      SQL
    end

    def each_patchset
      @db.execute("SELECT * FROM patchsets ORDER BY submitted_at").each { |r| yield r }
    end

    def count_patchsets
      @db.execute("SELECT COUNT(*) AS n FROM patchsets").first["n"]
    end

    def transaction(&block)
      @db.transaction(&block)
    end

    def corpus_cursor
      row = @db.execute("SELECT cursor FROM corpus_sync_state WHERE id = 1").first
      row && row["cursor"]
    end

    def set_corpus_cursor(cursor)
      @db.execute("INSERT OR REPLACE INTO corpus_sync_state (id, cursor, synced_at) VALUES (1,?,?)",
                  [ cursor, Time.now.utc.iso8601 ])
    end

    def replace_candidates(sha, cands)
      @db.transaction do
        @db.execute("DELETE FROM match_candidates WHERE sha = ?", [ sha ])
        cands.each do |c|
          params = [ sha, c[:topic_id], c[:score], c[:jaccard], c[:n_overlap],
                    c[:n_nonnoise], c[:date_gap_days], c[:title], c[:sender],
                    JSON.generate(c[:matched_paths]), c[:patch_path_count], c[:submitted_at] ]
          @db.execute(<<~SQL, params)
            INSERT OR REPLACE INTO match_candidates
              (sha, topic_id, score, jaccard, n_overlap, n_nonnoise, date_gap_days,
               title, sender, matched_paths, patch_path_count, submitted_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
          SQL
        end
      end
    end

    def candidates_for(sha)
      @db.execute("SELECT * FROM match_candidates WHERE sha = ? ORDER BY score DESC", [ sha ])
    end

    def judgment_for(sha, topic_id, prompt_hash)
      @db.execute("SELECT * FROM judgments WHERE sha = ? AND topic_id = ? AND prompt_hash = ?",
                  [ sha, topic_id, prompt_hash ]).first
    end

    def save_judgment(sha:, topic_id:, prompt_hash:, verdict:, confidence:, evidence:, model:)
      @db.execute(<<~SQL, [ sha, topic_id, prompt_hash, verdict, confidence, evidence, model, Time.now.utc.iso8601 ])
        INSERT OR REPLACE INTO judgments
          (sha, topic_id, prompt_hash, verdict, confidence, evidence, model, created_at)
        VALUES (?,?,?,?,?,?,?,?)
      SQL
    end

    def delete_links_by_method(sha, method)
      @db.execute("DELETE FROM thread_links WHERE sha = ? AND method = ?", [ sha, method ])
    end

    def each_commit_at_stages(stages)
      marks = stages.map { "?" }.join(",")
      @db.execute("SELECT * FROM commits WHERE stage IN (#{marks}) ORDER BY committed_at", stages)
         .each { |r| yield r }
    end

    def count_at_stages(stages)
      marks = stages.map { "?" }.join(",")
      @db.execute("SELECT COUNT(*) AS n FROM commits WHERE stage IN (#{marks})", stages).first["n"]
    end

    def each_commit_with_prefixes(prefixes)
      return if prefixes.nil? || prefixes.empty?
      clause = prefixes.map { "sha LIKE ?" }.join(" OR ")
      args = prefixes.map { |p| "#{p}%" }
      @db.execute("SELECT * FROM commits WHERE #{clause} ORDER BY committed_at", args).each { |r| yield r }
    end

    def oldest_unlinked_committed_at
      row = @db.execute(<<~SQL).first
        SELECT MIN(committed_at) AS m FROM commits c
        WHERE NOT EXISTS (
          SELECT 1 FROM thread_links l WHERE l.sha = c.sha AND l.verdict != 'unrelated'
        )
      SQL
      row && row["m"]
    end

    private

    def ensure_column(table, column, type)
      cols = @db.execute("PRAGMA table_info(#{table})").map { |r| r["name"] }
      @db.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{type}") unless cols.include?(column)
    end
  end

  class ApiClient
    def initialize(config:, store:)
      @config = config
      @store = store
      @base = URI.parse(config.server)
    end

    def resolve_message_id(message_id)
      escaped = URI.encode_www_form_component(message_id)
      get_json("/messages/by-id/#{escaped}.json", {})
    end

    def patch_submissions(since:, until_date: nil, per: 500)
      params = { per: per, since: since }
      params[:until] = until_date if until_date
      get_json("/patch_submissions.json", params, cache: false)
    end

    private

    def get_json(path, params, cache: true)
      key = Digest::SHA256.hexdigest("#{path}?#{params.sort_by { |k, _| k.to_s }.to_json}")
      if cache
        cached = @store.api_cache_get(key)
        return JSON.parse(cached) if cached
      end

      uri = @base.dup
      uri.path = path
      uri.query = URI.encode_www_form(params) unless params.empty?
      req = Net::HTTP::Get.new(uri)
      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: 15, read_timeout: 120) { |h| h.request(req) }

      return nil if res.code.to_i == 404
      raise "GET #{path} failed: #{res.code}" unless res.code.to_i.between?(200, 299)

      @store.api_cache_put(key, res.body) if cache
      JSON.parse(res.body)
    end
  end

  class LlmClient
    class Error < StandardError; end

    def initialize(config:)
      @endpoint = URI.parse("#{config.llm_url.to_s.chomp('/')}/chat/completions")
      @model = config.llm_model
    end

    attr_reader :model

    def complete(system:, user:, schema:)
      req = Net::HTTP::Post.new(@endpoint)
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(
        model: @model,
        messages: [ { role: "system", content: system }, { role: "user", content: user } ],
        temperature: 0,
        response_format: { type: "json_schema", json_schema: schema }
      )
      res = Net::HTTP.start(@endpoint.hostname, @endpoint.port,
                            use_ssl: @endpoint.scheme == "https",
                            open_timeout: 15, read_timeout: 600) { |h| h.request(req) }
      raise Error, "LLM #{res.code}: #{res.body.to_s[0, 200]}" unless res.code.to_i.between?(200, 299)
      content = JSON.parse(res.body).dig("choices", 0, "message", "content")
      raise Error, "LLM response missing content: #{res.body.to_s[0, 200]}" if content.nil?
      JSON.parse(content)
    rescue JSON::ParserError, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
           Net::OpenTimeout, Net::ReadTimeout, IOError => e
      raise Error, "#{e.class}: #{e.message}"
    end
  end

  class Judge
    PROMPT_VERSION = "v2"
    SYSTEM_PROMPT = <<~PROMPT
      You judge whether a PostgreSQL mailing-list thread is the submission/discussion
      thread for a given git commit. You get the commit message and evidence about one
      candidate thread (file overlap between the commit and patches posted in the thread).
      Answer "related" only when the evidence is specific: the thread clearly discusses
      the same change, the file overlap is meaningful, and title/sender/timing agree.
      A same-area thread about a different change is "unrelated".
      When uncertain, answer "unrelated" with low confidence.
      A commit that credits a report or complaint ("per report from", "per complaint from",
      "reported by") rather than a patch was typically fixed by the committer directly; the
      matching thread is likely the bug report, not the patch source, so answer "unrelated"
      unless the thread clearly contains the actual applied patch. Mechanical or janitorial
      commits (pure cleanup, removing dead code/NULL checks, whitespace, comment fixes,
      "clean up", "remove useless") usually do not originate from a discussion thread -
      default to "unrelated" for these. Sharing only a few files out of a large patch, or a
      merely same-area/same-topic thread, is weak evidence; require that the thread discusses
      the same specific change.
    PROMPT
    SCHEMA = {
      name: "judgment",
      schema: {
        type: "object",
        properties: {
          evidence: { type: "string" },
          verdict: { type: "string", enum: [ "related", "unrelated" ] },
          confidence: { type: "number" }
        },
        required: [ "verdict", "confidence", "evidence" ],
        additionalProperties: false
      }
    }.freeze
    MAX_INVALID_STREAK = 3
    INVALID_RESULT = {
      "verdict" => "unrelated", "confidence" => 0.0, "evidence" => "invalid response shape"
    }.freeze

    def initialize(store:, config:, llm: nil, progress: Progress.silent)
      @store = store
      @config = config
      @llm = llm || LlmClient.new(config: config)
      @progress = progress
    end

    def judge!
      @stats = Hash.new(0)
      @invalid_streak = 0
      subset = @config.only_shas && !@config.only_shas.empty?
      if subset
        @progress.phase("judge: arbitrating candidates for sha subset (#{@config.only_shas.join(', ')})")
        @store.each_commit_with_prefixes(@config.only_shas) do |c|
          judge_commit(c) unless linked?(c["sha"])
        end
      else
        total = @store.count_at_stages([ "matched" ])
        @progress.phase("judge: arbitrating candidates for #{total} commits")
        index = 0
        @store.each_commit_at_stages([ "matched" ]) do |c|
          index += 1
          @progress.progress(index, total, "judge", every: 10)
          judge_commit(c) unless linked?(c["sha"])
          @store.set_stage(c["sha"], "judged")
        end
      end
      @progress.say("judge: #{@stats[:linked]} linked, #{@stats[:rejected]} rejected, " \
                    "#{@stats[:invalid]} invalid, #{@stats[:cache_hits]} cache hits, " \
                    "#{@stats[:fresh]} fresh calls")
    end

    private

    def linked?(sha)
      @store.links_for(sha).any? { |l| l["verdict"] != "unrelated" }
    end

    def judge_commit(commit)
      @store.candidates_for(commit["sha"]).each do |cand|
        user = user_prompt(commit, cand)
        phash = Digest::SHA256.hexdigest("#{PROMPT_VERSION}\n#{SYSTEM_PROMPT}\n#{@llm.model}\n#{user}")
        j = cached_judgment(commit, cand, phash) || fresh(commit, cand, user, phash)
        if j["verdict"] == "related" && j["confidence"].to_f >= @config.judge_confidence
          @store.add_link(
            sha: commit["sha"], topic_id: cand["topic_id"], mailing_list: nil,
            method: "file_overlap_judge", confidence: j["confidence"].to_f,
            verdict: "related", evidence: j["evidence"].to_s[0, 500], external_message_id: nil
          )
          @stats[:linked] += 1
          break
        end
        @stats[:rejected] += 1 unless j.equal?(INVALID_RESULT)
      end
    end

    def cached_judgment(commit, cand, phash)
      j = @store.judgment_for(commit["sha"], cand["topic_id"], phash)
      @stats[:cache_hits] += 1 if j
      j
    end

    def fresh(commit, cand, user, phash)
      result = @llm.complete(system: SYSTEM_PROMPT, user: user, schema: SCHEMA)
      @stats[:fresh] += 1
      return invalid!(cand) unless valid?(result)
      @invalid_streak = 0
      @store.save_judgment(
        sha: commit["sha"], topic_id: cand["topic_id"], prompt_hash: phash,
        verdict: result["verdict"], confidence: result["confidence"].to_f,
        evidence: result["evidence"].to_s[0, 500], model: @llm.model
      )
      result
    end

    def valid?(r)
      r.is_a?(Hash) && %w[related unrelated].include?(r["verdict"]) && r["confidence"].is_a?(Numeric)
    end

    def invalid!(cand)
      @stats[:invalid] += 1
      @invalid_streak += 1
      if @invalid_streak >= MAX_INVALID_STREAK
        raise LlmClient::Error,
              "#{@invalid_streak} consecutive schema-invalid responses; check llama-server json_schema support"
      end
      @progress.say("judge: schema-invalid response for topic #{cand['topic_id']}, treating as unrelated")
      INVALID_RESULT
    end

    def user_prompt(commit, cand)
      text = "#{commit['subject']}\n\n#{commit['body']}"
      sender = cand["sender"].to_s
      sender_credited = sender.length > 4 && text.downcase.include?(sender.downcase)
      matched = JSON.parse(cand["matched_paths"] || "[]")
      <<~PROMPT
        COMMIT (#{commit['committed_at']}):
        #{text[0, 4000]}

        CANDIDATE THREAD:
        title: #{cand['title']}
        patch sender: #{sender}
        sender name appears in commit message: #{sender_credited}
        patch posted: #{cand['submitted_at']} (#{cand['date_gap_days']} days before commit)
        overlap score: #{cand['score'].round(2)}, jaccard: #{cand['jaccard'].round(3)}
        overlapping files (#{cand['n_overlap']} of #{cand['patch_path_count']} patch files): #{matched.join(', ')}

        Is this thread the submission/discussion thread for this commit?
      PROMPT
    end
  end

  class GitWalker
    RECORD_SEP = "\x1e"
    FIELD_SEP  = "\x1f"
    FORMAT = %w[%H %an %ae %cn %ce %aI %cI %s %b].join(FIELD_SEP) + RECORD_SEP

    def initialize(repo:, store:, branches: nil, limit: nil, since: nil, until_date: nil, progress: Progress.silent)
      @repo = repo
      @store = store
      @branches = branches
      @limit = limit
      @since = since
      @until_date = until_date
      @progress = progress
    end

    def refs
      @refs ||= (@branches || default_refs)
    end

    def default_refs
      out = git("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin")
      rel = out.lines.map(&:strip).map { |r| r.sub(%r{\Aorigin/}, "") }
               .select { |r| r == "master" || r.start_with?("REL") }
      ([ "master" ] + rel).uniq
    end

    def version_for_ref(ref)
      return "devel" if ref == "master"
      if (m = ref.match(/\AREL_(\d+)_/))
        m[1]
      elsif (m = ref.match(/\AREL(\d+)_(\d+)_/))
        "#{m[1]}.#{m[2]}"
      else
        ref
      end
    end

    def walk!
      @progress.say("Resolving refs to walk")
      @progress.say("Refs (#{refs.size}): #{refs.join(', ')}")

      branches_by_sha = Hash.new { |h, k| h[k] = [] }
      refs.each do |ref|
        shas = list_shas(ref)
        window = [ ("since #{@since}" if @since), ("until #{@until_date}" if @until_date) ].compact.join(", ")
        @progress.say("rev-list #{ref}: #{shas.size} commits#{window.empty? ? '' : " (#{window})"}")
        shas.each { |sha| branches_by_sha[sha] << ref }
      end

      total = branches_by_sha.size
      @progress.say("Loading metadata for #{total} unique commits (one `git show` each)")
      index = 0
      branches_by_sha.each do |sha, refs_for_sha|
        index += 1
        @progress.progress(index, total, "metadata", every: 200)
        data = commit_data(sha)
        next unless data
        versions = refs_for_sha.map { |r| version_for_ref(r) }.uniq
        @store.upsert_commit(
          sha: sha, subject: data[:subject], body: data[:body],
          authored_at: data[:authored_at], committed_at: data[:committed_at],
          author_name: data[:author_name], author_email: data[:author_email],
          committer_name: data[:committer_name], committer_email: data[:committer_email],
          branches: refs_for_sha, versions: versions, files: data[:files]
        )
      end

      @progress.say("Detecting backport twins across #{total} commits")
      detect_backport_twins(branches_by_sha.keys)
      @progress.say("Walk complete: #{total} commits stored")
    end

    def detect_backport_twins(shas)
      by_key = Hash.new { |h, k| h[k] = [] }
      shas.each do |sha|
        row = @store.commit(sha)
        next unless row
        next if row["subject"].to_s.strip.length < 10 # too generic to match safely
        key = [ row["subject"], row["author_email"] ]
        by_key[key] << row
      end

      by_key.each_value do |rows|
        next if rows.size < 2
        sorted = rows.sort_by { |r| r["committed_at"].to_s }
        canonical = sorted.first
        sorted.drop(1).each do |r|
          @store.add_relation(from_sha: r["sha"], to_sha: canonical["sha"],
                              kind: "cherry_picked_from", confidence: 0.9, method: "heuristic")
        end
      end
    end

    private

    def list_shas(ref)
      args = if ref_exists?("origin/#{ref}")
               [ "rev-list", "origin/#{ref}" ]
      else
               [ "rev-list", ref ]
      end
      args << "--max-count=#{@limit}" if @limit
      args << "--since=#{@since}" if @since
      args << "--until=#{@until_date}" if @until_date
      git(*args).lines.map(&:strip).reject(&:empty?)
    end

    def ref_exists?(ref)
      git("rev-parse", "--verify", "--quiet", ref)
      true
    rescue StandardError
      false
    end

    def commit_data(sha)
      raw = git("-c", "core.quotepath=false", "show", "--format=#{FORMAT}", "--name-only", sha)
      record, files_blob = raw.split(RECORD_SEP, 2)
      return nil unless record
      f = record.split(FIELD_SEP, 9)
      files = files_blob.to_s.lines.map(&:strip).reject(&:empty?)
      {
        author_name: f[1], author_email: f[2], committer_name: f[3], committer_email: f[4],
        authored_at: f[5], committed_at: f[6], subject: f[7], body: f[8].to_s.strip,
        files: files
      }
    end

    def git(*args)
      out, err, status = Open3.capture3("git", "-C", @repo, *args)
      raise "git #{args.join(' ')} failed: #{err}" unless status.success?
      out
    end
  end

  class CommitParser
    Result = Struct.new(:facts, :message_ids, keyword_init: true)

    TRAILER_KINDS = {
      "reviewed-by"     => "reviewer",
      "author"          => "author",
      "reported-by"     => "reported_by",
      "co-authored-by"  => "co_author",
      "tested-by"       => "tested_by"
    }.freeze

    MSGID_RE = %r{
      (?:postgr\.es|postgre\.es|(?:www\.)?postgresql\.org)
      /(?:m|message-id)/
      ([^\s>"\]]+)
    }ix
    CVE_RE = /\bCVE-\d{4}-\d{4,7}\b/i
    FIX_FOR_RE     = /fix(?:es)?[ \t]+(?:for[ \t]+)?commit[ \t]+([0-9a-f]{8,40})\b/i
    CHERRY_PICK_RE = /cherry picked from commit[ \t]+([0-9a-f]{8,40})\b/i

    def initialize(subject:, body:, committer_name:, committer_email:)
      @subject = subject.to_s
      @body = body.to_s
      @committer_name = committer_name
      @committer_email = committer_email
    end

    def parse
      facts = []
      facts.concat(trailer_facts)
      facts << committer_fact
      facts.concat(cve_facts)
      facts.concat(fixes_facts)
      Result.new(facts: facts.compact, message_ids: message_ids)
    end

    def message_ids
      full = "#{@subject}\n#{@body}"
      full.scan(MSGID_RE).flatten
          .map { |id| id.sub(%r{\A(?:flat|raw)/}i, "").sub(/[).,;]+\z/, "") }
          .uniq
    end

    private

    def trailer_facts
      @body.each_line.flat_map do |line|
        m = line.match(/\A([A-Za-z-]+):\s*(.+?)\s*\z/)
        next [] unless m
        kind = TRAILER_KINDS[m[1].downcase]
        next [] unless kind
        [ fact(kind, m[2], "trailer", 1.0, line.strip) ]
      end
    end

    def committer_fact
      value = "#{@committer_name} <#{@committer_email}>"
      fact("committer", value, "git_metadata", 1.0, value)
    end

    def cve_facts
      "#{@subject}\n#{@body}".scan(CVE_RE).uniq.map do |cve|
        fact("cve", cve.upcase, "commit_ref", 1.0, cve)
      end
    end

    def fixes_facts
      text = "#{@subject}\n#{@body}"
      fixes = text.scan(FIX_FOR_RE).flatten.uniq.map do |sha|
        fact("fixes_commit", sha, "commit_ref", 0.95, sha)
      end
      cherries = text.scan(CHERRY_PICK_RE).flatten.uniq.map do |sha|
        fact("cherry_picked_from", sha, "commit_ref", 0.9, sha)
      end
      fixes + cherries
    end

    def fact(kind, value, method, confidence, evidence)
      { kind: kind, value: value.to_s.strip, method: method, confidence: confidence, evidence: evidence.to_s.strip }
    end
  end

  class TrailerLinker
    def initialize(store:, api:, progress: Progress.silent)
      @store = store
      @api = api
      @progress = progress
    end

    def link(sha:, message_ids:)
      linked = false
      message_ids.each do |mid|
        resolved = @api.resolve_message_id(mid)
        next unless resolved && resolved["topic_id"]
        @store.add_link(
          sha: sha, topic_id: resolved["topic_id"],
          mailing_list: Array(resolved["mailing_lists"]).first,
          method: "trailer", confidence: 1.0, verdict: "related",
          evidence: "Discussion trailer", external_message_id: mid
        )
        linked = true
      end
      linked
    end
  end

  class CorpusSync
    DAY = 86_400

    def initialize(store:, api:, config:, progress: Progress.silent)
      @store = store
      @api = api
      @config = config
      @progress = progress
    end

    def sync!
      cursor = @config.corpus_since || @store.corpus_cursor || derived_since
      return @progress.say("corpus-sync: no commits and no --corpus-since; skipping") unless cursor
      pages = 0
      loop do
        page = @api.patch_submissions(since: cursor, until_date: @config.corpus_until)
        subs = page.fetch("patch_submissions", [])
        break if subs.empty?
        next_cursor = page["next_cursor"]
        advance = !next_cursor.nil? && next_cursor != cursor
        @store.transaction do
          subs.each do |s|
            @store.upsert_patchset(
              message_id: s["id"], external_message_id: s["message_id"],
              topic_id: s["topic_id"], submitted_at: s["date"],
              title: s["topic_title"], sender: s["sender"], paths: s["paths"] || []
            )
          end
          @store.set_corpus_cursor(next_cursor) if advance
        end
        break unless advance
        cursor = next_cursor
        pages += 1
        @progress.say("corpus-sync: page #{pages} (+#{subs.size}, total #{@store.count_patchsets})")
      end
    end

    private

    def derived_since
      oldest = @store.oldest_unlinked_committed_at
      return nil unless oldest
      (Time.parse(oldest) - @config.match_window * DAY).utc.iso8601
    end
  end

  class OverlapMatcher
    NOISE_PATH_RE = %r{
      \Aconfigure(\.in|\.ac)?\z |
      \Adoc/src/sgml/release.*\.sgml\z |
      \.po\z |
      \Asrc/tools/pgindent/typedefs\.list\z
    }x
    NOISE_WEIGHT = 0.25
    MAX_POSTING = 2000
    DAY = 86_400

    def initialize(store:, config:, progress: Progress.silent)
      @store = store
      @config = config
      @progress = progress
      @window = config.match_window * DAY
      @noise = {}
    end

    def match!
      load_corpus
      stages = %w[quickfixed matched judged]
      total = @store.count_at_stages(stages)
      @progress.phase("match: scoring #{total} commits against #{@patchsets.size} patchsets")
      index = 0
      @store.each_commit_at_stages(stages) do |c|
        index += 1
        @progress.progress(index, total, "match", every: 500)
        @store.delete_links_by_method(c["sha"], "file_overlap")
        @store.replace_candidates(c["sha"], [])
        process(c) unless linked?(c["sha"])
        @store.set_stage(c["sha"], "matched")
      end
    end

    private

    def load_corpus
      @patchsets = []
      @df = Hash.new(0)
      @by_path = {}
      @store.each_patchset do |row|
        paths = JSON.parse(row["paths"])
        next if paths.empty?
        ps = { message_id: row["message_id"], topic_id: row["topic_id"],
               t: Time.parse(row["submitted_at"]),
               title: row["title"], sender: row["sender"],
               submitted_at: row["submitted_at"], paths: Set.new(paths) }
        @patchsets << ps
        paths.each do |p|
          @df[p] += 1
          (@by_path[p] ||= []) << ps
        end
      end
      @n = @patchsets.size
      @idf = Hash.new { |h, p| h[p] = Math.log(@n / (1.0 + @df[p])) }
    end

    def linked?(sha)
      @store.links_for(sha).any? { |l| l["verdict"] != "unrelated" }
    end

    def noise?(p) = @noise.fetch(p) { @noise[p] = p.match?(NOISE_PATH_RE) }

    def process(commit)
      files = JSON.parse(commit["files"] || "[]")
      return if files.empty?
      cfiles = Set.new(files)
      ct = Time.parse(commit["committed_at"])

      best = {}
      candidate_patchsets(files).each do |ps|
        gap = ct - ps[:t]
        next unless gap >= 0 && gap <= @window
        inter = cfiles & ps[:paths]
        next if inter.empty?
        cand = score(cfiles, ps, inter, gap)
        cur = best[ps[:topic_id]]
        best[ps[:topic_id]] = cand if cur.nil? || cand[:score] > cur[:score]
      end
      decide(commit["sha"], best.values.sort_by { |c| -c[:score] })
    end

    def candidate_patchsets(files)
      files.flat_map { |f| (l = @by_path.fetch(f) { [] }).size > MAX_POSTING ? [] : l }
           .uniq { |ps| ps[:message_id] }
    end

    def score(cfiles, ps, inter, gap)
      nonnoise = inter.reject { |p| noise?(p) }
      idf_sum = inter.sum { |p| noise?(p) ? @idf[p] * NOISE_WEIGHT : @idf[p] }
      union = cfiles | ps[:paths]
      jac = inter.size.fdiv(union.size)
      nn_union = union.reject { |p| noise?(p) }
      jac_nn = nn_union.empty? ? 0.0 : nonnoise.size.fdiv(nn_union.size)
      {
        topic_id: ps[:topic_id], score: idf_sum * (0.5 + 0.5 * jac),
        jaccard: jac, jac_nonnoise: jac_nn,
        n_overlap: inter.size, n_nonnoise: nonnoise.size,
        date_gap_days: (gap / DAY).floor, title: ps[:title], sender: ps[:sender],
        matched_paths: inter.sort, patch_path_count: ps[:paths].size,
        submitted_at: ps[:submitted_at]
      }
    end

    def decide(sha, ranked)
      return if ranked.empty?
      top = ranked.first
      runner = ranked[1]
      exact = ranked.select { |c| c[:jac_nonnoise] >= 1.0 && c[:n_nonnoise] >= 2 }
      dominant = runner.nil? || top[:score] >= @config.dominance * runner[:score]
      if exact.size == 1 && exact.first[:topic_id] == top[:topic_id] && dominant
        @store.add_link(
          sha: sha, topic_id: top[:topic_id], mailing_list: nil,
          method: "file_overlap", confidence: 0.95, verdict: "related",
          evidence: "exact file-set match: #{top[:matched_paths].join(', ')}"[0, 500],
          external_message_id: nil
        )
      else
        queue = ranked.take(3).select { |c| c[:score] >= @config.judge_floor }
        @store.replace_candidates(sha, queue)
      end
    end
  end

  class Exporter
    def initialize(store:, config:)
      @store = store
      @config = config
    end

    def export(io)
      generated = { tool_version: VERSION, run_at: Time.now.utc.iso8601 }
      @store.each_commit do |c|
        io.puts JSON.generate(record_for(c, generated))
      end
    end

    private

    def record_for(c, generated)
      {
        sha: c["sha"],
        subject: c["subject"],
        authored_at: c["authored_at"],
        committed_at: c["committed_at"],
        committer: { name: c["committer_name"], email: c["committer_email"] },
        author: { name: c["author_name"], email: c["author_email"] },
        versions: JSON.parse(c["versions"] || "[]"),
        branches: JSON.parse(c["branches"] || "[]"),
        facts: @store.facts_for(c["sha"]).reject { |f| f["kind"] == "discussion_message_id" }
                     .map { |f| slice(f, %w[kind value method confidence evidence]) },
        commit_relations: @store.relations_for(c["sha"]).map { |r| { kind: r["kind"], sha: r["to_sha"], confidence: r["confidence"], method: r["method"] } },
        thread_links: @store.links_for(c["sha"])
                            .reject { |l| l["verdict"] == "unrelated" }
                            .map { |l| slice(l, %w[topic_id mailing_list external_message_id method confidence verdict evidence]) },
        generator: generated
      }
    end

    def slice(row, keys)
      keys.each_with_object({}) { |k, h| h[k] = row[k] }
    end
  end

  class Pipeline
    def initialize(config:, store:, api:, walker: nil, progress: Progress.silent)
      @config = config
      @store = store
      @api = api
      @walker = walker
      @progress = progress
      @trailer_linker = TrailerLinker.new(store: store, api: api, progress: progress)
    end

    def walk
      @progress.phase("walk: reading git history (#{@config.repo})")
      (@walker || GitWalker.new(repo: @config.repo, store: @store,
                                branches: @config.branches, limit: @config.limit,
                                since: @config.since, until_date: @config.until_date,
                                progress: @progress)).walk!
    end

    def parse
      total = @store.count_at_stage("walked")
      @progress.phase("parse: extracting facts/message-ids from #{total} commits")
      index = 0
      @store.each_commit_at_stage("walked") do |c|
        index += 1
        @progress.progress(index, total, "parse", every: 200)
        result = CommitParser.new(subject: c["subject"], body: c["body"],
                                  committer_name: c["committer_name"],
                                  committer_email: c["committer_email"]).parse
        result.facts.each do |f|
          @store.add_fact(sha: c["sha"], kind: f[:kind], value: f[:value],
                          method: f[:method], confidence: f[:confidence], evidence: f[:evidence])
        end
        @store.set_message_ids(c["sha"], result.message_ids)
        @store.set_stage(c["sha"], "parsed")
      end
    end

    def link_trailers
      total = @store.count_at_stage("parsed")
      @progress.phase("link: resolving discussion trailers for #{total} commits")
      index = 0
      @store.each_commit_at_stage("parsed") do |c|
        index += 1
        @progress.progress(index, total, "link", every: 200)
        @trailer_linker.link(sha: c["sha"], message_ids: @store.message_ids_for(c["sha"]))
        @store.set_stage(c["sha"], "linked")
      end
    end

    def quickfix
      total = @store.count_at_stage("linked")
      @progress.phase("quickfix: resolving explicit fix references for #{total} commits")
      index = 0
      @store.each_commit_at_stage("linked") do |c|
        index += 1
        @progress.progress(index, total, "quickfix", every: 200)
        attribute_explicit(c) unless patch_linked?(c["sha"])
        @store.set_stage(c["sha"], "quickfixed")
      end
    end

    def corpus_sync
      @progress.phase("corpus-sync: pulling patch submissions")
      CorpusSync.new(store: @store, api: @api, config: @config, progress: @progress).sync!
    end

    def match
      OverlapMatcher.new(store: @store, config: @config, progress: @progress).match!
    end

    def judge
      if @config.skip_judge
        @progress.phase("judge: skipped (--skip-judge)")
        return
      end
      Judge.new(store: @store, config: @config, progress: @progress).judge!
    end

    def export(io)
      @progress.phase("export: writing #{@store.count_commits} records")
      Exporter.new(store: @store, config: @config).export(io)
    end

    def run(io)
      walk
      parse
      link_trailers
      quickfix
      corpus_sync
      match
      judge
      export(io)
    end

    private

    def patch_link?(link)
      link["method"] == "trailer" && link["verdict"] != "unrelated"
    end

    def patch_linked?(sha)
      @store.links_for(sha).any? { |l| patch_link?(l) }
    end

    def attribute_explicit(commit)
      targets = @store.facts_for(commit["sha"])
                      .select { |f| f["kind"] == "fixes_commit" }
                      .map { |f| f["value"] }
      attributed = false
      targets.each do |ref|
        full = @store.commit(ref) ? ref : @store.commit_by_prefix(ref)
        next unless full
        if inherit_links(from: commit["sha"], target_sha: full, method: "quickfix_ref",
                         confidence: 0.95, evidence_prefix: "fixes commit #{ref[0, 12]}")
          attributed = true
        end
      end
      attributed
    end

    def inherit_links(from:, target_sha:, method:, confidence:, evidence_prefix:)
      target_links = @store.links_for(target_sha).select { |l| patch_link?(l) }
      return false if target_links.empty?
      @store.add_relation(from_sha: from, to_sha: target_sha, kind: "quickfix_of",
                          confidence: confidence, method: method)
      target_links.each do |l|
        @store.add_link(
          sha: from, topic_id: l["topic_id"], mailing_list: l["mailing_list"],
          method: method, confidence: confidence, verdict: "quickfix",
          evidence: "#{evidence_prefix} -> topic #{l['topic_id']}",
          external_message_id: l["external_message_id"]
        )
      end
      true
    end
  end

  class CLI
    def self.run(argv)
      config = Config.parse(argv)
      return print_usage if config.command.nil?
      return print_version if config.command == "version"

      FileUtils.mkdir_p(config.state_dir)
      progress = Progress.new(enabled: !config.quiet)
      store = Store.new(File.join(config.state_dir, "state.db"))
      api = ApiClient.new(config: config, store: store)
      pipeline = Pipeline.new(config: config, store: store, api: api, progress: progress)

      case config.command
      when "walk" then pipeline.walk
      when "parse" then pipeline.parse
      when "link" then pipeline.link_trailers
      when "quickfix" then pipeline.quickfix
      when "corpus-sync" then pipeline.corpus_sync
      when "match" then pipeline.match
      when "judge" then pipeline.judge
      when "export" then export_to_file(pipeline, config)
      when "run"
        path = File.join(config.state_dir, "commits.jsonl")
        File.open(path, "w") { |io| pipeline.run(io) }
        warn "Wrote #{path}"
      else
        warn "Unknown command: #{config.command}"
        print_usage
      end
    end

    def self.export_to_file(pipeline, config)
      path = File.join(config.state_dir, "commits.jsonl")
      File.open(path, "w") { |io| pipeline.export(io) }
      warn "Wrote #{path}"
    end

    def self.print_usage
      warn "Usage: bundle exec ruby script/hackorum_commits.rb {walk|parse|link|quickfix|corpus-sync|match|judge|export|run|version} [options]"
      warn "  --server URL  --repo PATH  --state-dir PATH"
      warn "  --branches a,b  --since DATE  --until DATE  --limit N"
      warn "  --match-window DAYS  --dominance RATIO  --judge-floor SCORE"
      warn "  --llm-url URL  --llm-model NAME"
      warn "  --corpus-since DATE  --corpus-until DATE"
      warn "  --judge-confidence C  --skip-judge  --only-shas LIST"
    end

    def self.print_version
      puts VERSION
    end
  end
end

HackorumCommits::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
