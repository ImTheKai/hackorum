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
require "stringio"

begin
  require "sqlite3"
rescue LoadError
  warn "hackorum-commits requires the 'sqlite3' gem. Install it with: gem install sqlite3"
  exit 1
end

module HackorumCommits
  VERSION = "0.1.0"

  Config = Struct.new(
    :server, :repo, :llm_url, :llm_model, :state_dir,
    :candidate_limit, :branches, :since, :limit, :command,
    keyword_init: true
  ) do
    def self.parse(argv)
      opts = {
        server: "https://hackorum.dev",
        repo: "postgres",
        llm_url: "http://localhost:8080/v1",
        llm_model: "qwen3-coder-30b",
        state_dir: ".hackorum-commits",
        candidate_limit: 8,
        branches: nil,
        since: nil,
        limit: nil
      }
      parser = OptionParser.new do |o|
        o.banner = "Usage: bundle exec ruby script/hackorum_commits.rb [command] [options]\n" \
                   "Commands: walk parse discover confirm export run version"
        o.on("--server URL") { |v| opts[:server] = v }
        o.on("--repo PATH") { |v| opts[:repo] = v }
        o.on("--llm-url URL") { |v| opts[:llm_url] = v }
        o.on("--llm-model NAME") { |v| opts[:llm_model] = v }
        o.on("--state-dir PATH") { |v| opts[:state_dir] = v }
        o.on("--candidate-limit N", Integer) { |v| opts[:candidate_limit] = v }
        o.on("--branches LIST", "Comma-separated refs (default: master + REL_*)") { |v| opts[:branches] = v.split(",") }
        o.on("--since DATE", "Only commits on/after this ISO date") { |v| opts[:since] = v }
        o.on("--limit N", Integer, "Max commits to process") { |v| opts[:limit] = v }
      end
      remaining = parser.parse(argv)
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
      CREATE TABLE IF NOT EXISTS thread_candidates (
        sha TEXT, topic_id INTEGER, source TEXT, prefilter_score REAL, metadata TEXT,
        UNIQUE(sha, topic_id)
      );
      CREATE TABLE IF NOT EXISTS thread_links (
        sha TEXT, topic_id INTEGER, mailing_list TEXT, method TEXT,
        confidence REAL, evidence TEXT, verdict TEXT, external_message_id TEXT,
        UNIQUE(sha, topic_id)
      );
      CREATE TABLE IF NOT EXISTS api_cache (
        request_key TEXT PRIMARY KEY, response TEXT, fetched_at TEXT
      );
      CREATE TABLE IF NOT EXISTS llm_cache (
        prompt_hash TEXT PRIMARY KEY, response TEXT, model TEXT, created_at TEXT
      );
    SQL

    def initialize(path)
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @db.execute_batch(SCHEMA)
    end

    def upsert_commit(sha:, subject:, body:, authored_at:, committed_at:,
                      author_name:, author_email:, committer_name:, committer_email:,
                      branches:, versions:, stage: "walked")
      params = [sha, subject, body, authored_at, committed_at,
                author_name, author_email, committer_name, committer_email,
                JSON.generate(branches), JSON.generate(versions), stage, Time.now.utc.iso8601]
      @db.execute(<<~SQL, params)
        INSERT INTO commits (sha, subject, body, authored_at, committed_at,
          author_name, author_email, committer_name, committer_email,
          branches, versions, stage, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(sha) DO UPDATE SET subject=excluded.subject, body=excluded.body,
          branches=excluded.branches, versions=excluded.versions, updated_at=excluded.updated_at
      SQL
    end

    def commit(sha)
      @db.execute("SELECT * FROM commits WHERE sha = ?", [sha]).first
    end

    def set_stage(sha, stage)
      @db.execute("UPDATE commits SET stage = ?, updated_at = ? WHERE sha = ?",
                  [stage, Time.now.utc.iso8601, sha])
    end

    def add_relation(from_sha:, to_sha:, kind:, confidence:, method:)
      @db.execute(<<~SQL, [from_sha, to_sha, kind, confidence, method])
        INSERT OR IGNORE INTO commit_relations (from_sha, to_sha, kind, confidence, method)
        VALUES (?,?,?,?,?)
      SQL
    end

    def relations_for(sha)
      @db.execute("SELECT * FROM commit_relations WHERE from_sha = ?", [sha])
    end

    def api_cache_get(key)
      row = @db.execute("SELECT response FROM api_cache WHERE request_key = ?", [key]).first
      row && row["response"]
    end

    def api_cache_put(key, response)
      @db.execute("INSERT OR REPLACE INTO api_cache (request_key, response, fetched_at) VALUES (?,?,?)",
                  [key, response, Time.now.utc.iso8601])
    end

    def add_candidate(sha:, topic_id:, source:, prefilter_score:, metadata:)
      @db.execute(<<~SQL, [sha, topic_id, source, prefilter_score, JSON.generate(metadata)])
        INSERT OR REPLACE INTO thread_candidates (sha, topic_id, source, prefilter_score, metadata)
        VALUES (?,?,?,?,?)
      SQL
    end

    def candidates_for(sha)
      @db.execute("SELECT * FROM thread_candidates WHERE sha = ?", [sha])
    end

    def llm_cache_get(key)
      row = @db.execute("SELECT response FROM llm_cache WHERE prompt_hash = ?", [key]).first
      row && row["response"]
    end

    def llm_cache_put(key, response, model)
      @db.execute("INSERT OR REPLACE INTO llm_cache (prompt_hash, response, model, created_at) VALUES (?,?,?,?)",
                  [key, response, model, Time.now.utc.iso8601])
    end

    def add_link(sha:, topic_id:, mailing_list:, method:, confidence:, verdict:, evidence:, external_message_id:)
      @db.execute(<<~SQL, [sha, topic_id, mailing_list, method, confidence, verdict, evidence, external_message_id])
        INSERT OR REPLACE INTO thread_links
          (sha, topic_id, mailing_list, method, confidence, verdict, evidence, external_message_id)
        VALUES (?,?,?,?,?,?,?,?)
      SQL
    end

    def links_for(sha)
      @db.execute("SELECT * FROM thread_links WHERE sha = ?", [sha])
    end

    def add_fact(sha:, kind:, value:, method:, confidence:, evidence:)
      @db.execute(<<~SQL, [sha, kind, value, method, confidence, evidence])
        INSERT OR IGNORE INTO commit_facts (sha, kind, value, method, confidence, evidence)
        VALUES (?,?,?,?,?,?)
      SQL
    end

    def facts_for(sha)
      @db.execute("SELECT * FROM commit_facts WHERE sha = ?", [sha])
    end

    def each_commit
      @db.execute("SELECT * FROM commits ORDER BY committed_at").each { |row| yield row }
    end

    def each_commit_at_stage(stage)
      @db.execute("SELECT * FROM commits WHERE stage = ? ORDER BY committed_at", [stage]).each { |r| yield r }
    end

    def set_message_ids(sha, ids)
      ids.each do |id|
        @db.execute("INSERT OR IGNORE INTO commit_facts (sha, kind, value, method, confidence, evidence) VALUES (?,?,?,?,?,?)",
                    [sha, "discussion_message_id", id, "trailer", 1.0, "Discussion: #{id}"])
      end
    end

    def message_ids_for(sha)
      @db.execute("SELECT value FROM commit_facts WHERE sha = ? AND kind = 'discussion_message_id'", [sha])
         .map { |r| r["value"] }
    end
  end

  class ApiClient
    def initialize(config:, store:)
      @config = config
      @store = store
      @base = URI.parse(config.server)
    end

    def search_candidates(q:, from:, to:, mailing_lists:, patches_only:, limit:)
      params = { q: q, from: from, to: to, patches_only: patches_only, limit: limit }
      Array(mailing_lists).each_with_index { |ml, i| params[:"mailing_list[#{i}]"] = ml }
      body = get_json("/topics/search_candidates.json", params)
      body ? body["candidates"] : []
    end

    def resolve_message_id(message_id)
      escaped = URI.encode_www_form_component(message_id)
      get_json("/messages/by-id/#{escaped}.json", {})
    end

    def topic_summary(topic_id)
      get_json("/topics/#{topic_id}/summary.json", {})
    end

    private

    def get_json(path, params)
      key = Digest::SHA256.hexdigest("#{path}?#{params.sort_by { |k, _| k.to_s }.to_json}")
      cached = @store.api_cache_get(key)
      return JSON.parse(cached) if cached

      uri = @base.dup
      uri.path = path
      uri.query = URI.encode_www_form(params) unless params.empty?
      req = Net::HTTP::Get.new(uri)
      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(req) }

      return nil if res.code.to_i == 404
      raise "GET #{path} failed: #{res.code}" unless res.code.to_i.between?(200, 299)

      @store.api_cache_put(key, res.body)
      JSON.parse(res.body)
    end
  end

  class LlmClient
    def initialize(config:, store:)
      @config = config
      @store = store
      @endpoint = URI.parse("#{config.llm_url.chomp('/')}/chat/completions")
    end

    def complete(system:, user:, schema:)
      body = {
        model: @config.llm_model,
        messages: [
          { role: "system", content: system },
          { role: "user", content: user }
        ],
        temperature: 0,
        response_format: { type: "json_schema", json_schema: schema }
      }
      key = Digest::SHA256.hexdigest(body.to_json)
      cached = @store.llm_cache_get(key)
      return JSON.parse(cached) if cached

      req = Net::HTTP::Post.new(@endpoint)
      req["Content-Type"] = "application/json"
      req.body = body.to_json
      res = Net::HTTP.start(@endpoint.hostname, @endpoint.port,
                            use_ssl: @endpoint.scheme == "https") { |h| h.request(req) }
      raise "LLM call failed: #{res.code} #{res.body}" unless res.code.to_i.between?(200, 299)

      content = JSON.parse(res.body).dig("choices", 0, "message", "content")
      raise "LLM response missing choices[0].message.content: #{res.body}" if content.nil?
      parsed = JSON.parse(content)
      @store.llm_cache_put(key, content, @config.llm_model)
      parsed
    end
  end

  class GitWalker
    RECORD_SEP = "\x1e"
    FIELD_SEP  = "\x1f"
    FORMAT = %w[%H %an %ae %cn %ce %aI %cI %s %b].join(FIELD_SEP) + RECORD_SEP

    def initialize(repo:, store:, branches: nil, limit: nil, since: nil)
      @repo = repo
      @store = store
      @branches = branches
      @limit = limit
      @since = since
    end

    def refs
      @refs ||= (@branches || default_refs)
    end

    def default_refs
      out = git("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin")
      rel = out.lines.map(&:strip).map { |r| r.sub(%r{\Aorigin/}, "") }
               .select { |r| r == "master" || r.start_with?("REL") }
      (["master"] + rel).uniq
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
      branches_by_sha = Hash.new { |h, k| h[k] = [] }
      refs.each do |ref|
        shas = list_shas(ref)
        shas.each { |sha| branches_by_sha[sha] << ref }
      end

      branches_by_sha.each do |sha, refs_for_sha|
        data = commit_data(sha)
        next unless data
        versions = refs_for_sha.map { |r| version_for_ref(r) }.uniq
        @store.upsert_commit(
          sha: sha, subject: data[:subject], body: data[:body],
          authored_at: data[:authored_at], committed_at: data[:committed_at],
          author_name: data[:author_name], author_email: data[:author_email],
          committer_name: data[:committer_name], committer_email: data[:committer_email],
          branches: refs_for_sha, versions: versions
        )
      end

      detect_backport_twins(branches_by_sha.keys)
    end

    def detect_backport_twins(shas)
      by_key = Hash.new { |h, k| h[k] = [] }
      shas.each do |sha|
        row = @store.commit(sha)
        next unless row
        next if row["subject"].to_s.strip.length < 10 # too generic to match safely
        key = [row["subject"], row["author_email"]]
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
               ["rev-list", "origin/#{ref}"]
             else
               ["rev-list", ref]
             end
      args << "--max-count=#{@limit}" if @limit
      args << "--since=#{@since}" if @since
      git(*args).lines.map(&:strip).reject(&:empty?)
    end

    def ref_exists?(ref)
      git("rev-parse", "--verify", "--quiet", ref)
      true
    rescue StandardError
      false
    end

    def commit_data(sha)
      raw = git("show", "-s", "--format=#{FORMAT}", sha)
      record = raw.split(RECORD_SEP).first
      return nil unless record
      f = record.split(FIELD_SEP, 9)
      {
        author_name: f[1], author_email: f[2], committer_name: f[3], committer_email: f[4],
        authored_at: f[5], committed_at: f[6], subject: f[7], body: f[8].to_s.strip
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

    MSGID_RE = %r{postgr\.es/(?:m|message-id)/([^\s>"\]]+)}i
    CVE_RE = /\bCVE-\d{4}-\d{4,7}\b/i
    FIXES_RE = /(?:fix(?:es)?[ \t]+(?:for[ \t]+)?commit|cherry picked from commit)[ \t]+([0-9a-f]{8,40})\b/i

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
      full.scan(MSGID_RE).flatten.map { |id| id.sub(/[).,;]+\z/, "") }.uniq
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
      "#{@subject}\n#{@body}".scan(FIXES_RE).flatten.uniq.map do |sha|
        fact("fixes_commit", sha, "commit_ref", 0.95, sha)
      end
    end

    def fact(kind, value, method, confidence, evidence)
      { kind: kind, value: value.to_s.strip, method: method, confidence: confidence, evidence: evidence.to_s.strip }
    end
  end

  class Discovery
    STOPWORDS = %w[fix fixes back-patch back patch revert reverts add remove update the a an
                   for to of in on and or commit support improve avoid prevent make use].freeze
    BEFORE_DAYS = 365
    AFTER_DAYS = 30

    def initialize(config:, store:, api:)
      @config = config
      @store = store
      @api = api
    end

    def discover(commit, facts:, message_ids:)
      sha = commit["sha"]
      seen = Set.new
      message_ids.each do |mid|
        resolved = @api.resolve_message_id(mid)
        next unless resolved
        @store.add_candidate(sha: sha, topic_id: resolved["topic_id"], source: "trailer",
                             prefilter_score: 1.0, metadata: resolved)
        seen << resolved["topic_id"]
      end

      terms = search_terms(subject: commit["subject"], facts: facts)
      return if terms.empty?
      return if commit["committed_at"].nil? || commit["committed_at"].to_s.strip.empty?
      from, to = date_window(commit["committed_at"])

      search_added = 0
      [true, false].each do |patches_only|
        hits = @api.search_candidates(q: terms.join(" "), from: from, to: to,
                                      mailing_lists: [], patches_only: patches_only,
                                      limit: @config.candidate_limit)
        hits.each do |hit|
          tid = hit["topic_id"]
          next if seen.include?(tid)
          break if search_added >= @config.candidate_limit
          seen << tid
          search_added += 1
          @store.add_candidate(sha: sha, topic_id: tid, source: "search",
                               prefilter_score: hit["score"] || 0.0, metadata: hit)
        end
      end
    end

    def search_terms(subject:, facts:)
      tokens = subject.to_s.downcase.scan(/[a-z0-9_]+/)
                      .reject { |t| STOPWORDS.include?(t) || t.length < 3 }
      keyword_tokens = subject.to_s.scan(/[A-Za-z0-9_]+/).select { |t| tokens.include?(t.downcase) }
      names = facts.select { |f| %w[author reported_by co_author reviewer].include?(f[:kind] || f["kind"]) }
                   .map { |f| (f[:value] || f["value"]).to_s.sub(/\s*<[^>]+>\s*/, "").strip }
                   .reject(&:empty?)
      (keyword_tokens + names).uniq
    end

    def date_window(committed_at)
      t = Time.parse(committed_at)
      [ (t - BEFORE_DAYS * 86_400).utc.iso8601, (t + AFTER_DAYS * 86_400).utc.iso8601 ]
    end
  end

  class Confirmer
    SCHEMA = {
      name: "commit_thread_links",
      schema: {
        type: "object",
        properties: {
          links: {
            type: "array",
            items: {
              type: "object",
              properties: {
                topic_id: { type: "integer" },
                verdict: { type: "string", enum: %w[related uncertain unrelated] },
                confidence: { type: "number" },
                evidence: { type: "string" }
              },
              required: %w[topic_id verdict confidence]
            }
          },
          facts: {
            type: "array",
            items: {
              type: "object",
              properties: { kind: { type: "string" }, value: { type: "string" } },
              required: %w[kind value]
            }
          }
        },
        required: %w[links]
      }
    }.freeze

    SYSTEM = <<~TXT
      You link a PostgreSQL git commit to the mailing-list discussion thread(s) it
      came from or that motivated it. For each candidate thread, decide whether it is
      related to the commit. Return strict JSON matching the schema. Be conservative:
      only "related" when the thread clearly discusses the same change, bug, or feature.
    TXT

    def initialize(store:, llm:)
      @store = store
      @llm = llm
    end

    def confirm(commit, candidates:)
      trailer, search = candidates.partition { |c| c["source"] == "trailer" }

      trailer.each do |c|
        meta = parse_meta(c)
        @store.add_link(sha: commit["sha"], topic_id: c["topic_id"],
                        mailing_list: Array(meta["mailing_lists"]).first,
                        method: "trailer", confidence: 1.0, verdict: "related",
                        evidence: "Discussion trailer", external_message_id: meta["message_id"])
      end

      return if search.empty?

      result = @llm.complete(system: SYSTEM, user: build_user_prompt(commit, search), schema: SCHEMA)
      verdicts = Array(result["links"]).each_with_object({}) { |l, h| h[l["topic_id"]] = l }

      search.each do |c|
        v = verdicts[c["topic_id"]]
        next unless v
        meta = parse_meta(c)
        @store.add_link(sha: commit["sha"], topic_id: c["topic_id"],
                        mailing_list: Array(meta["mailing_lists"]).first,
                        method: "llm", confidence: v["confidence"], verdict: v["verdict"],
                        evidence: v["evidence"].to_s, external_message_id: nil)
      end

      Array(result["facts"]).each do |f|
        @store.add_fact(sha: commit["sha"], kind: f["kind"], value: f["value"],
                        method: "llm", confidence: 0.7, evidence: "LLM-extracted")
      end
    end

    private

    def parse_meta(candidate)
      JSON.parse(candidate["metadata"].to_s)
    rescue JSON::ParserError
      {}
    end

    def build_user_prompt(commit, candidates)
      lines = ["COMMIT subject: #{commit['subject']}", "COMMIT body:", commit["body"].to_s, "", "CANDIDATE THREADS:"]
      candidates.each do |c|
        meta = parse_meta(c)
        lines << "- topic_id=#{c['topic_id']} lists=#{Array(meta['mailing_lists']).join(',')} " \
                 "title=#{meta['title']} snippet=#{meta['first_message_snippet'].to_s[0, 300]}"
      end
      lines.join("\n")
    end
  end

  class Exporter
    def initialize(store:, config:)
      @store = store
      @config = config
    end

    def export(io)
      generated = { tool_version: VERSION, model: @config.llm_model, run_at: Time.now.utc.iso8601 }
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
    def initialize(config:, store:, api:, llm:, walker: nil)
      @config = config
      @store = store
      @api = api
      @llm = llm
      @walker = walker
      @discovery = Discovery.new(config: config, store: store, api: api)
      @confirmer = Confirmer.new(store: store, llm: llm)
    end

    def walk
      (@walker || GitWalker.new(repo: @config.repo, store: @store,
                                branches: @config.branches, limit: @config.limit,
                                since: @config.since)).walk!
    end

    def parse
      @store.each_commit_at_stage("walked") do |c|
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

    def discover
      @store.each_commit_at_stage("parsed") do |c|
        facts = @store.facts_for(c["sha"])
        message_ids = @store.message_ids_for(c["sha"])
        @discovery.discover(c, facts: facts, message_ids: message_ids)
        @store.set_stage(c["sha"], "discovered")
      end
    end

    def confirm
      @store.each_commit_at_stage("discovered") do |c|
        @confirmer.confirm(c, candidates: @store.candidates_for(c["sha"]))
        @store.set_stage(c["sha"], "confirmed")
      end
    end

    def export(io)
      Exporter.new(store: @store, config: @config).export(io)
    end

    def run(io)
      walk
      parse
      discover
      confirm
      export(io)
    end
  end

  class CLI
    def self.run(argv)
      config = Config.parse(argv)
      return print_usage if config.command.nil?
      return print_version if config.command == "version"

      FileUtils.mkdir_p(config.state_dir)
      store = Store.new(File.join(config.state_dir, "state.db"))
      api = ApiClient.new(config: config, store: store)
      llm = LlmClient.new(config: config, store: store)
      pipeline = Pipeline.new(config: config, store: store, api: api, llm: llm)

      case config.command
      when "walk" then pipeline.walk
      when "parse" then pipeline.parse
      when "discover" then pipeline.discover
      when "confirm" then pipeline.confirm
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
      warn "Usage: bundle exec ruby script/hackorum_commits.rb {walk|parse|discover|confirm|export|run|version} [options]"
      warn "  --server URL  --repo PATH  --llm-url URL  --llm-model NAME  --state-dir PATH"
      warn "  --candidate-limit N  --branches a,b  --since DATE  --limit N"
    end

    def self.print_version
      puts VERSION
    end
  end
end

HackorumCommits::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
