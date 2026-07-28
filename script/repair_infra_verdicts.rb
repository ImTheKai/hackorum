#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off: undo the verdicts a wedged apply worktree wrote. A leftover git am
# state directory made every mbox apply refuse, and until PatchBranches::Applier
# started clearing it that refusal was stored as if the patchset had been tried:
# probes recorded a conflict and bumped their own throttle, and first applies
# went to "failed at apply". Neither says anything about the patchset.
#
# Two repairs, matching the two shapes:
#   probed rows  -> clear the error and the probe stamp, so they read as never
#                   probed and the rebase tier picks them up on the next cycle
#   failed rows  -> delete, so the row is gone and the new_version tier applies
#                   the topic's newest patchset from scratch. Only ever rows
#                   that never reached github: a pushed row has a branch and a
#                   verdict hanging off it, and deleting that loses real state.
#
# Prints what it would do and writes nothing unless --commit is given.
require_relative "../config/environment"

SIGNATURE = "%previous rebase directory%"

commit = ARGV.include?("--commit")

probed = PatchBranch.where("master_apply_error LIKE ?", SIGNATURE)
failed = PatchBranch.where("failure_reason LIKE ?", SIGNATURE).where(status: "failed")

# a pushed row, or one carrying runs, is not ours to delete - report and keep it
deletable = failed.where(pushed_at: nil)
                  .where("NOT EXISTS (SELECT 1 FROM patch_ci_runs r WHERE r.patch_branch_id = patch_branches.id)")
kept = failed.where.not(id: deletable.select(:id))

puts "probed rows to unstick:   #{probed.count}"
puts "failed rows to delete:    #{deletable.count}"
puts "failed rows left alone:   #{kept.count}#{' (pushed or with runs - check these by hand)' if kept.any?}"
kept.limit(10).each { |row| puts "  kept #{row.branch_name} pushed_at=#{row.pushed_at} ci=#{row.ci_status}" }

unless commit
  puts "dry run, nothing written - pass --commit to apply"
  exit
end

# update_all, not each: this is a column reset with no callbacks to run, and
# nothing here depends on the rest of the row
unstuck = probed.update_all(master_apply_error: nil, last_master_apply_at: nil)
deleted = deletable.delete_all
puts "unstuck #{unstuck}, deleted #{deleted}"
puts "rebase tier now due: #{PatchCi::Planner.new.counts[:rebase]}"
