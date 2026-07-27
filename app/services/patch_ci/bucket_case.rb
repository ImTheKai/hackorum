module PatchCi
  # Shared bucket-CASE builder for a [[label, bound], ...] constant: one WHEN
  # per bucket with a bound, quoted label, ELSE catches the last (nil-bound)
  # entry. Comparison direction is the caller's to pick - push lag needs "<"
  # against an ascending interval, base age needs ">" against a descending
  # timestamp - that difference is exactly how a hand-copied third CASE would
  # silently get its boundary inverted.
  class BucketCase
    # buckets: [[label, bound], ...], only the last entry's bound may be nil
    # expr: sql for the left side of the comparison
    # operator: comparison operator, eg "<" or ">"
    # bound_sql: proc(bound) -> sanitized sql for the right side
    # null_check: raw sql condition; true means the row is 'unknown'
    def self.sql(buckets, expr:, operator:, bound_sql:, null_check:)
      whens = buckets.filter_map do |label, bound|
        next if bound.nil?
        ActiveRecord::Base.sanitize_sql_array(
          [ "WHEN #{expr} #{operator} #{bound_sql.call(bound)} THEN ?", label ]
        )
      end
      Arel.sql(<<~SQL)
        CASE
          WHEN #{null_check} THEN 'unknown'
          #{whens.join("\n")}
          ELSE #{ActiveRecord::Base.connection.quote(buckets.last.first)}
        END
      SQL
    end
  end
end
