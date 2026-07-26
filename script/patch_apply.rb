#!/usr/bin/env ruby
# frozen_string_literal: true

# Mass-apply latest patchsets of uncommitted threads onto the local postgres
# checkout. See GITINTEGRATION and --help.

require "optparse"

options = {
  from: "2017-01-01",
  to: "2026-06-01",
  concurrency: 8,
  repo: File.expand_path("../postgres", __dir__),
  worktrees: File.expand_path("../tmp/patch_worktrees", __dir__)
}

OptionParser.new do |o|
  o.banner = "Usage: ruby script/patch_apply.rb [options]"
  o.on("--from DATE", "latest-patch range start (default #{options[:from]})") { |v| options[:from] = v }
  o.on("--to DATE", "latest-patch range end, exclusive (default #{options[:to]})") { |v| options[:to] = v }
  o.on("--limit N", Integer, "cap candidate count, newest first") { |v| options[:limit] = v }
  o.on("--sample N", Integer, "random sample of N candidates instead") { |v| options[:sample] = v }
  o.on("--topic ID", Integer, "single topic, ignores all filters") { |v| options[:topic] = v }
  o.on("--concurrency N", Integer, "worker threads (default 8)") { |v| options[:concurrency] = v }
  o.on("--force", "redo successes too") { options[:force] = true }
  o.on("--repo PATH", "postgres checkout (default ./postgres)") { |v| options[:repo] = v }
  o.on("--stats", "no applying, summarize patch_branches") { options[:stats] = true }
end.parse!

abort "concurrency must be positive, got #{options[:concurrency]}" if !options[:stats] && options[:concurrency] <= 0

ENV["RAILS_MAX_THREADS"] = [ ENV["RAILS_MAX_THREADS"].to_i, options[:concurrency] + 3 ].max.to_s
require_relative "../config/environment"

def first_interesting_line(reason)
  lines = reason.to_s.lines.map(&:strip).reject(&:empty?)
  lines.find { |l| l.match?(/\A(error|fatal|CONFLICT|Patch failed|Applied patch)/i) } || lines.first || "(empty)"
end

if options[:stats]
  puts "total: #{PatchBranch.count}"
  PatchBranch.group(:status).count.sort.each { |s, c| puts "  #{s}: #{c}" }
  puts "applied on master vs base:"
  PatchBranch.applied.group(:on_master).count.sort_by { |m, _| m.to_s }.each { |m, c| puts "  on_master=#{m}: #{c}" }
  puts "by base source (applied / apply-failed):"
  applied_src = PatchBranch.applied.group(:base_source).count
  failed_src = PatchBranch.failed.where(failure_stage: "apply").group(:base_source).count
  (applied_src.keys | failed_src.keys).sort_by(&:to_s).each do |src|
    puts "  #{src || '(older run)'}: #{applied_src[src].to_i} / #{failed_src[src].to_i}"
  end
  puts "failures by stage:"
  PatchBranch.failed.group(:failure_stage).count.sort_by { |_, c| -c }.each { |s, c| puts "  #{s}: #{c}" }
  puts "top failure reasons:"
  PatchBranch.failed.pluck(:failure_reason).map { |r| first_interesting_line(r) }
             .tally.sort_by { |_, c| -c }.first(20).each { |l, c| puts "  #{c}x #{l[0, 120]}" }
  puts "top conflict files:"
  PatchBranch.failed.pluck(:conflict_files).flatten.tally
             .sort_by { |_, c| -c }.first(20).each { |f, c| puts "  #{c}x #{f}" }
  exit 0
end

messages =
  if options[:topic]
    PatchBranches::CandidateSelector.for_topic(options[:topic])
  else
    from = begin
      Time.zone.parse(options[:from]) or abort "bad --from: #{options[:from].inspect} did not parse"
    rescue ArgumentError => e
      abort "bad --from: #{e.message}"
    end
    to = begin
      Time.zone.parse(options[:to]) or abort "bad --to: #{options[:to].inspect} did not parse"
    rescue ArgumentError => e
      abort "bad --to: #{e.message}"
    end
    PatchBranches::CandidateSelector
      .new(from: from, to: to)
      .candidates(limit: options[:limit], sample: options[:sample])
  end

ids = messages.pluck(:id)
puts "#{ids.size} candidates"
exit 0 if ids.empty?

runner = PatchBranches::Runner.new(
  repo_path: options[:repo],
  worktrees_dir: options[:worktrees],
  concurrency: options[:concurrency],
  force: options[:force]
)

counts = runner.run(ids)
puts "done: #{counts.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
exit 1 if counts[:error].to_i > 0 || counts[:dead_worker].to_i > 0
