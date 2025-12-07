#!/usr/bin/env ruby
# frozen_string_literal: true

# Link PostgreSQL Contributors to Aliases
#
# This script creates Contributor records from the official PostgreSQL contributor lists
# and links them to existing Alias records in the database based on matching emails/names.
#
# PREREQUISITE: The database must already be populated with message data from mbox imports.
#
# Source: https://www.postgresql.org/developer/committers/
#         https://www.postgresql.org/community/contributors/
#
# Usage:
#   ruby script/link_contributors.rb

require_relative '../config/environment'

puts "Linking PostgreSQL contributors to aliases..."

# Clear existing contributors
Contributor.destroy_all

# Helper to find email addresses for contributors from our existing alias database
def find_contributor_emails(name)
  # Look for aliases with this exact name
  aliases = Alias.where(name: name).pluck(:email).uniq

  # If no exact match, try case-insensitive
  if aliases.empty?
    aliases = Alias.where("LOWER(name) = ?", name.downcase).pluck(:email).uniq
  end

  # If still nothing, try partial match (e.g., "Tom Lane" might be "Tom Lane <tom@lane.com>")
  if aliases.empty?
    aliases = Alias.where("name ILIKE ?", "%#{name}%").pluck(:email).uniq
  end

  aliases
end

# Core Team
core_team = [
  "Peter Eisentraut",
  "Andres Freund",
  "Magnus Hagander",
  "Jonathan Katz",
  "Tom Lane",
  "Bruce Momjian",
  "Dave Page"
]

created_count = 0
core_team.each do |name|
  # Create a single Contributor record for this person
  contributor = Contributor.create!(
    name: name,
    contributor_type: 'core_team',
    profile_url: "https://www.postgresql.org/community/contributors/"
  )
  created_count += 1

  # Link all their email aliases
  emails = find_contributor_emails(name)
  if emails.any?
    aliases = Alias.where(email: emails)
    contributor.aliases << aliases
    puts "  ✓ #{name}: #{emails.join(', ')} (#{aliases.count} aliases)"
  else
    puts "  ⚠ #{name}: no aliases found"
  end
end

puts "✓ Created #{created_count} core team entries"

# Committers (from https://www.postgresql.org/developer/committers/)
committers = [
  "Bruce Momjian", "Tom Lane", "Tatsuo Ishii", "Peter Eisentraut",
  "Joe Conway", "Álvaro Herrera", "Andrew Dunstan", "Magnus Hagander",
  "Heikki Linnakangas", "Robert Haas", "Jeff Davis", "Fujii Masao",
  "Noah Misch", "Andres Freund", "Dean Rasheed", "Alexander Korotkov",
  "Amit Kapila", "Tomas Vondra", "Michael Paquier", "Thomas Munro",
  "Peter Geoghegan", "Etsuro Fujita", "David Rowley", "Daniel Gustafsson",
  "John Naylor", "Nathan Bossart", "Amit Langote", "Masahiko Sawada",
  "Melanie Plageman", "Richard Guo", "Jacob Champion"
]

# Add committers (skip if already exists by name)
committer_count = 0
committers.each do |name|
  # Skip if already exists (probably in core team)
  next if Contributor.exists?(name: name)

  contributor = Contributor.create!(
    name: name,
    contributor_type: 'committer',
    profile_url: "https://www.postgresql.org/developer/committers/"
  )
  committer_count += 1

  # Link all their email aliases
  emails = find_contributor_emails(name)
  if emails.any?
    aliases = Alias.where(email: emails)
    contributor.aliases << aliases
    puts "  ✓ #{name}: #{emails.join(', ')} (#{aliases.count} aliases)"
  else
    puts "  ⚠ #{name}: no aliases found"
  end
end

puts "✓ Created #{committer_count} committer entries"

# Major Contributors
major_contributors = [
  "Laurenz Albe", "Ashutosh Bapat", "Oleg Bartunov", "Christoph Berg",
  "Andrey Borodin", "Nathan Bossart", "Jacob Champion", "Joe Conway",
  "Dave Cramer", "Jeff Davis", "Bertrand Drouvot", "Andrew Dunstan",
  "Vik Fearing", "Jelte Fennema-Nio", "Etsuro Fujita", "Peter Geoghegan",
  "Devrim Gündüz", "Richard Guo", "Daniel Gustafsson", "Robert Haas",
  "Stacey Haysler", "Álvaro Herrera", "Kyotaro Horiguchi", "Tatsuo Ishii",
  "Petr Jelinek", "Stefan Kaltenbrunner", "Amit Kapila", "Alexander Korotkov",
  "Alexander Lakhin", "Amit Langote", "Guillaume Lelarge", "Heikki Linnakangas",
  "Anastasia Lubennikova", "Fujii Masao", "Noah Misch", "Thomas Munro",
  "John Naylor", "Michael Paquier", "Melanie Plageman", "Paul Ramsey",
  "Dean Rasheed", "Julien Rouhaud", "David Rowley", "Greg Sabino Mullane",
  "Masahiko Sawada", "Andreas Scherbaum", "Teodor Sigaev", "Steve Singer",
  "Pavel Stehule", "Robert Treat", "Tomas Vondra", "Mark Wong"
]

major_count = 0
major_contributors.each do |name|
  next if Contributor.exists?(name: name)

  contributor = Contributor.create!(
    name: name,
    contributor_type: 'major_contributor',
    profile_url: "https://www.postgresql.org/community/contributors/"
  )
  major_count += 1

  emails = find_contributor_emails(name)
  if emails.any?
    aliases = Alias.where(email: emails)
    contributor.aliases << aliases
    puts "  ✓ #{name}: #{emails.join(', ')} (#{aliases.count} aliases)"
  else
    puts "  ⚠ #{name}: no aliases found"
  end
end

puts "✓ Created #{major_count} major contributor entries"

# Significant Contributors (abbreviated list - you can expand this)
significant_contributors = [
  "Ants Aasma", "Ian Barwick", "Konstantin Knizhnik", "Matthias van de Meent",
  "Erik Rijkers", "Dilip Kumar", "Nikita Glukhov", "Jian He",
  "Andrey Lepikhov", "Shveta Malik", "Zhijie Hou"
  # Note: The full list contains 100+ names - add more as needed
]

sig_count = 0
significant_contributors.each do |name|
  next if Contributor.exists?(name: name)

  contributor = Contributor.create!(
    name: name,
    contributor_type: 'significant_contributor',
    profile_url: "https://www.postgresql.org/community/contributors/"
  )
  sig_count += 1

  emails = find_contributor_emails(name)
  if emails.any?
    aliases = Alias.where(email: emails)
    contributor.aliases << aliases
    puts "  ✓ #{name}: #{emails.join(', ')} (#{aliases.count} aliases)"
  else
    puts "  ⚠ #{name}: no aliases found"
  end
end

puts "✓ Created #{sig_count} significant contributor entries"

# Past Major Contributors
past_major = [
  "Josh Berkus", "David Fetter", "Marc G. Fournier", "Stephen Frost",
  "Andrew Gierth", "Thomas G. Lockhart", "Michael Meskes",
  "Vadim B. Mikheev", "Simon Riggs", "Jan Wieck"
]

past_count = 0
past_major.each do |name|
  next if Contributor.exists?(name: name)

  contributor = Contributor.create!(
    name: name,
    contributor_type: 'past_major_contributor',
    profile_url: "https://www.postgresql.org/community/contributors/"
  )
  past_count += 1

  emails = find_contributor_emails(name)
  if emails.any?
    aliases = Alias.where(email: emails)
    contributor.aliases << aliases
    puts "  ✓ #{name}: #{emails.join(', ')} (#{aliases.count} aliases)"
  else
    puts "  ⚠ #{name}: no aliases found"
  end
end

puts "✓ Created #{past_count} past major contributor entries"

puts "\nTotal contributors: #{Contributor.count}"
puts "  Core team: #{Contributor.core_team.count}"
puts "  Committers: #{Contributor.committers.count}"
puts "  Major contributors: #{Contributor.major_contributors.count}"
puts "  Significant contributors: #{Contributor.significant_contributors.count}"
puts "  Past major contributors: #{Contributor.past_major_contributors.count}"
