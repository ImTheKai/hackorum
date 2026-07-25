class ReleaseTag < ApplicationRecord
  # REL_18_5 -> 18.5, REL_19_BETA1 -> 19beta1, REL9_5_2 -> 9.5.2.
  # Anything else (branch tags, ancient oddities) normalizes to nil: the tag is
  # still recorded as seen, but never assigned to a commit.
  PATTERNS = [
    [ /\AREL_(\d+)_(\d+)\z/, ->(m) { "#{m[1]}.#{m[2]}" } ],
    [ /\AREL_(\d+)_(BETA|RC|ALPHA)(\d+)\z/i, ->(m) { "#{m[1]}#{m[2].downcase}#{m[3]}" } ],
    [ /\AREL(\d+)_(\d+)_(\d+)\z/, ->(m) { "#{m[1]}.#{m[2]}.#{m[3]}" } ],
    [ /\AREL(\d+)_(\d+)_(BETA|RC|ALPHA)(\d+)\z/i, ->(m) { "#{m[1]}.#{m[2]}#{m[3].downcase}#{m[4]}" } ]
  ].freeze

  validates :name, presence: true, uniqueness: true

  def self.normalize(name)
    PATTERNS.each do |regex, formatter|
      m = name.to_s.match(regex)
      return formatter.call(m) if m
    end
    nil
  end
end
