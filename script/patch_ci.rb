#!/usr/bin/env ruby
# frozen_string_literal: true

# Push patch branches to GitHub and ingest their CI results.
# See GITINTEGRATION and --help.

require "optparse"

options = {
  repo: File.expand_path("../postgres", __dir__),
  worktree: File.expand_path("../tmp/patch_ci_worktree", __dir__),
  remote: "origin",
  github_repo: "hackorum-dev/postgres",
  # literal, not PatchCi::LoopRunner::DEFAULT_BUDGET: rails is not loaded yet
  budget: 18,
  interval: 60
}

OptionParser.new do |o|
  o.banner = "Usage: ruby script/patch_ci.rb [options]"
  o.on("--once", "run a single cycle and exit") { options[:once] = true }
  o.on("--stats", "summarise patch_ci_runs, no network") { options[:stats] = true }
  o.on("--limit N", Integer, "cap branches pushed per cycle; 0 = poll only") { |v| options[:limit] = v }
  o.on("--budget N", Integer, "max concurrent runs (default 18)") { |v| options[:budget] = v }
  o.on("--interval N", Integer, "seconds between cycles (default 60)") { |v| options[:interval] = v }
  o.on("--force", "re-push already pushed branches") { options[:force] = true }
  o.on("--repo PATH", "postgres checkout (default ./postgres)") { |v| options[:repo] = v }
end.parse!

require_relative "../config/environment"

if options[:stats]
  puts "branches pushed: #{PatchBranch.pushed.count}"
  puts "by ci_status:"
  PatchBranch.group(:ci_status).count.sort_by { |k, _| k.to_s }.each { |s, c| puts "  #{s || '(none)'}: #{c}" }
  puts "runs: #{PatchCiRun.count}"
  PatchCiRun.group(:status).count.sort_by { |_, c| -c }.each { |s, c| puts "  #{s}: #{c}" }
  puts "top failed tests:"
  PatchCiRun.pluck(:failed_tests).flatten.tally.sort_by { |_, c| -c }.first(20)
            .each { |t, c| puts "  #{c}x #{t}" }
  exit 0
end

repo = PatchBranches::GitRepo.new(options[:repo])

# a worktree left half-created by a killed process must not read as healthy
# for the rest of this process's life; see GitRepo#ensure_worktree!
repo.ensure_worktree!(options[:worktree])
worktree = PatchBranches::GitRepo.new(options[:worktree])

runner = PatchCi::LoopRunner.new(
  client: PatchCi::GithubClient.new(repo: options[:github_repo]),
  pusher: PatchCi::Pusher.new(repo: repo, worktree: worktree, remote: options[:remote]),
  selector: PatchCi::PushCandidateSelector.new(repo, force: options[:force], limit: options[:limit]),
  result_refs: PatchCi::ResultRefs.new(repo, remote: options[:remote]),
  budget: options[:budget]
)

loop do
  result = runner.cycle
  puts "[#{Time.current.iso8601}] #{result.except(:ingested).map { |k, v| "#{k}=#{v}" }.join(' ')}"
  warn "poll failed, pushed nothing: #{result[:error]}" if result[:error]
  break if options[:once]
  sleep options[:interval]
end
