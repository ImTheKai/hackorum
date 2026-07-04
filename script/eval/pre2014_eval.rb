#!/usr/bin/env ruby
# frozen_string_literal: true

require "sqlite3"
require "json"

GT = {
  "280744d461" => [ 22969, 23073 ],
  "c44327afa4" => [ 23467 ],
  "923413ac6d" => [ 23011, 23004 ],
  "013ed0bd81" => [ 23743 ],
  "74a1d4fe7c" => [ 27242 ],
  "6d09b2105f" => [ 27233, 27232 ],
  "a99c42f291" => [ 28541 ],
  "c172b7b02e" => [ 27353 ],
  "45f64f1bbf" => [ 30290 ],
  "6f5b8beb64" => [ 27267 ],
  "dc3eb56383" => [ 29637, 29554 ],
  "a7e587863c" => [ 22672 ],
  "d0cfc01823" => [ 23533, 23298 ],
  "b7fcf68e86" => [ 25118 ],
  "ccd69b8886" => [ 26160 ],
  "a9dad56441" => [ 28514 ],
  "efc7952c89" => [ 29559 ],
  "f897c4744f" => [ 28345 ],
  # verified 2026-07-04: Tom Lane's inline fix was posted on thread 64159
  # (was mislabeled as abstain in the original sample)
  "ed962fd712" => [ 64159 ]
}.freeze

ABSTAIN = %w[
  636edd553d f9e9da6664 c8c03d72e1 61cf7bcdf7 d06e2d2005
  6960277270 8c843fff2d 8e617e29aa 74242c23c1
  e5efda442c dacaeff5ae 1abd146ddd 2c30f96103 a52aa6c6db e8969c4733
].freeze
KNOWN_FALSE = %w[dacaeff5ae].freeze

db = SQLite3::Database.new(ARGV.fetch(0))
db.results_as_hash = true

def links_for_prefix(db, prefix)
  db.execute(<<~SQL, [ "#{prefix}%" ])
    SELECT l.topic_id, l.method, l.confidence FROM thread_links l
    JOIN commits c ON c.sha = l.sha
    WHERE c.sha LIKE ? AND l.verdict != 'unrelated'
    ORDER BY l.confidence DESC
  SQL
end

hits = 0
GT.each do |prefix, topics|
  links = links_for_prefix(db, prefix)
  top = links.first
  ok = top && topics.include?(top["topic_id"])
  hits += 1 if ok
  puts format("%-12s %-4s got=%-8s want=%s via=%s", prefix, ok ? "HIT" : "MISS",
              top ? top["topic_id"] : "-", topics.join("/"), top ? top["method"] : "-")
end

false_links = []
ABSTAIN.each do |prefix|
  links = links_for_prefix(db, prefix)
  next if links.empty?
  false_links << prefix
  puts format("%-12s FALSE-LINK topic=%s via=%s", prefix, links.first["topic_id"], links.first["method"])
end

unexpected = false_links - KNOWN_FALSE
puts "hit@1 #{hits}/#{GT.size}, abstain false links #{false_links.size}/#{ABSTAIN.size} (unexpected: #{unexpected.size})"
if hits == GT.size && unexpected.empty?
  puts "PASS: hit@1 #{hits}/#{GT.size}"
  exit 0
else
  puts "FAIL"
  exit 1
end
