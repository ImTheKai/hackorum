#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off: fill base_committed_at/base_commit_height for existing rows.
require_relative "../config/environment"

repo = PatchBranches::GitRepo.new(File.expand_path("../postgres", __dir__))
scope = PatchBranch.where.not(base_sha: nil).where(base_committed_at: nil)
total = scope.count
done = 0
scope.find_each do |row|
  row.update_columns(base_committed_at: repo.commit_time(row.base_sha),
                     base_commit_height: repo.commit_height(row.base_sha))
  done += 1
  puts "[#{done}/#{total}]" if (done % 500).zero?
end
puts "remaining without meta: #{PatchBranch.where.not(base_sha: nil).where(base_committed_at: nil).count}"
