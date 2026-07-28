#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off: remove the branches we pushed that carry an empty patch commit.
#
# Until PatchBranches::Applier compared content instead of commit shas, a patch
# git "applied cleanly" without changing anything still produced a branch: the
# patch commit was empty, only the CI commit on top had content, and CI reported
# a pass for a patchset it never tested. Those branches are on github and this
# deletes them.
#
# Content is the test, not the row's state: it is what the Applier now checks,
# and it holds however the row got labelled. The CI commit only ever touches
# .github, so anything else in the diff is the patchset's own.
#
# "Empty" is per line count, not per file: a context diff whose paths are gone
# from master (pg_xlogdump, say) makes git create them empty, so the branch does
# carry files - with nothing in them. --no-renames keeps a pure rename, which is
# a real change reported as 0/0, from reading as empty.
#
# In-flight rows go too. Their build is testing an empty tree, so cancelling it
# by deleting the branch loses nothing; the run may land as cancelled or, after
# 48h of silence, infra_error, and the row retires either way.
#
# The rows are left to the code: the next master move re-probes each one, the
# apply comes back empty and the row retires as failed/empty with the reason
# spelled out. Nothing re-pushes them in the meantime (backfill wants an unpushed
# row, rebase re-probes before it pushes), so the branches stay gone.
#
# Needs push access, the same way bin/orchestrator gets it:
#   GIT_SSH_COMMAND="ssh -i <deploy key> -o IdentitiesOnly=yes" ruby script/delete_empty_branches.rb
require_relative "../config/environment"

REMOTE = "origin"
CHUNK = 20

commit = ARGV.include?("--commit")
repo = PatchBranches::GitRepo.new(File.expand_path("../postgres", __dir__))

def empty_branch?(repo, row)
  return false unless row.base_sha && repo.rev_parse(row.branch_name)
  changed = repo.run("diff", "--numstat", "--no-renames", row.base_sha, row.branch_name)
                .stdout.lines.map(&:strip)
                .reject { |line| line.split("\t", 3).last.to_s.start_with?(".github/") }
  changed.all? { |line| line.start_with?("0\t0\t") }
end

empty = PatchBranch.current.applied.where.not(pushed_at: nil).order(:id)
                   .select { |row| empty_branch?(repo, row) }

puts "empty branches to delete: #{empty.size}"
puts "  in flight, going anyway: #{empty.count { |r| PatchCiRun::IN_FLIGHT_BRANCH_STATUSES.include?(r.ci_status) }}"
empty.first(10).each { |row| puts "  #{row.branch_name} ci=#{row.ci_status} base=#{row.base_sha[0, 9]}" }
puts "  ... and #{empty.size - 10} more" if empty.size > 10

unless commit
  puts "dry run, nothing deleted - pass --commit to delete"
  exit
end

deleted = 0
empty.each_slice(CHUNK) do |slice|
  names = slice.map(&:branch_name)
  result = repo.run("push", REMOTE, "--delete", *names)
  if result.success?
    deleted += names.size
    # local too, so a re-run does not have to ask github about them again
    names.each { |name| repo.run("branch", "-D", name) }
    puts "deleted #{deleted}/#{empty.size}"
  else
    warn "chunk failed, left alone: #{names.join(' ')}"
    warn result.output.lines.first(3).join
  end
end
puts "deleted #{deleted} of #{empty.size}"
