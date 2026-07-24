# frozen_string_literal: true

# Whole-business-day delta between two times. No holiday calendar; a v1
# simplification that will read as slightly generous around public holidays.
module BusinessDays
  WEEKEND_WDAYS = [ 0, 6 ].freeze

  def self.between(start_time, end_time)
    return 0 if end_time <= start_time

    full_days = (end_time.to_date - start_time.to_date).to_i
    (1..full_days).count { |offset| !WEEKEND_WDAYS.include?((start_time.to_date + offset).wday) }
  end
end
