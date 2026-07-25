#!/usr/bin/env ruby
# frozen_string_literal: true

# Import PostgreSQL commit history from a local git checkout.
#
#   ruby script/commit_import.rb                          # clone/fetch, import
#   ruby script/commit_import.rb --repo ~/src/postgres --no-fetch
#   ruby script/commit_import.rb --limit 100
#   ruby script/commit_import.rb --reparse
#   ruby script/commit_import.rb --relink
#
# Takes the same advisory lock as CommitImportJob, so a manual run and the
# hourly job never run at the same time. If the lock is held, this prints a
# message and exits non-zero rather than silently doing nothing.

require_relative "../config/environment"
require "optparse"

module CommitImportScript
  def self.parse_options(argv)
    options = { repo: CommitImport.repo_path, fetch: true, limit: nil, reparse: false, relink: false }

    parser = OptionParser.new do |o|
      o.banner = "Usage: ruby script/commit_import.rb [options]"
      o.on("--repo PATH", "Git checkout or mirror (default: #{CommitImport.repo_path})") { |v| options[:repo] = v }
      o.on("--no-fetch", "Skip git fetch (leaves your remotes alone)") { options[:fetch] = false }
      o.on("--limit N", Integer, "Import at most N new commits") { |v| options[:limit] = v }
      o.on("--reparse", "Re-parse trailers of stored commits, no git access") { options[:reparse] = true }
      o.on("--relink", "Re-resolve people for all commits, not just recent ones") { options[:relink] = true }
      o.on("-h", "--help", "Print this help") do
        puts o
        exit 0
      end
    end
    parser.parse!(argv)

    if options[:reparse] && options[:relink]
      warn "error: --reparse and --relink are mutually exclusive, run them one at a time"
      exit 1
    end

    options
  end

  # Runs the importer under the shared advisory lock. Returns true if it ran,
  # false if another commit import (the hourly job or a separate manual run)
  # already held the lock. Mirrors the ran-flag trick in CommitImportJob: the
  # lock's own return value can't tell "skipped" apart from "ran and returned
  # nil", so a flag set unconditionally inside the block is used instead.
  def self.run(options)
    importer = CommitImport::Importer.new(
      repository: CommitImport::Repository.new(path: options[:repo]),
      fetch: options[:fetch],
      limit: options[:limit],
      logger: Logger.new($stdout)
    )

    ran = false
    AdvisoryLock.with_lock(CommitImportJob::LOCK_KEY) do
      ran = true
      if options[:reparse]
        importer.reparse!
      elsif options[:relink]
        importer.relink_people!
      else
        importer.run!
      end
    end
    ran
  end
end

if $PROGRAM_NAME == __FILE__
  options = CommitImportScript.parse_options(ARGV)
  ran = CommitImportScript.run(options)
  unless ran
    warn "commit import already in progress (the hourly job or another manual run) - " \
         "wait for it to finish, or stop the web container if you need to force it now"
    exit 1
  end
end
