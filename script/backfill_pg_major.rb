#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off: fill pg_major for rows created before the column existed.
require_relative "../config/environment"

repo = PatchBranches::GitRepo.new(File.expand_path("../postgres", __dir__))
PatchCi::PgMajorBackfill.new(detector: PatchCi::EraDetector.new(repo)).call
puts "remaining without pg_major: #{PatchBranch.where(pg_major: nil).where.not(base_sha: nil).count}"
puts "skipped, no base sha: #{PatchBranch.where(pg_major: nil, base_sha: nil).count}"
