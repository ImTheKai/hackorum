#!/usr/bin/env ruby
# frozen_string_literal: true

# Recompute Message#is_patch_submission for every message.
#
# A message is a patch submission if it has at least one attachment whose
# filename ends with .patch/.diff/.diffs (optionally followed by .gz/.bz2/.txt)
# AND whose name does not contain nocfbot/no_cfbot.
# See Attachment::PATCH_SUBMISSION_EXTENSIONS for the authoritative list.
#
# Usage:
#   ruby script/backfill_patch_submissions.rb           # dry run, report only
#   ruby script/backfill_patch_submissions.rb --fix     # apply changes

require_relative '../config/environment'

dry_run = !ARGV.include?('--fix')

puts "Backfilling Message#is_patch_submission for all messages..."
puts "(dry run - use --fix to apply changes)" if dry_run
puts

total = Message.count
changed = 0
batch_size = 1000
processed = 0

Message.includes(:attachments).find_each(batch_size: batch_size) do |msg|
  processed += 1
  new_value = msg.attachments.any?(&:patch_submission_candidate?)
  next if msg.is_patch_submission == new_value

  changed += 1
  unless dry_run
    msg.update_column(:is_patch_submission, new_value)
  end

  if (processed % 10_000).zero?
    puts "  processed #{processed}/#{total}, changed so far: #{changed}"
  end
end

puts
puts "Done. Processed #{processed} messages; #{changed} need updating."
if dry_run && changed.positive?
  puts "Re-run with --fix to apply."
end
