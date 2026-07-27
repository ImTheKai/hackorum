module PatchCi
  # Every /ci/stats query param, sanitized once. RunStats and CorpusStats take
  # resolved values (a window, a date_trunc unit, a boolean) and never see
  # params - that is what keeps them testable with plain arguments.
  class StatsParams
    RANGES = { "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days,
               "90d" => 90.days, "all" => nil }.freeze
    # granularity is interpolated into date_trunc, so it is a whitelist, not a cast
    GRANS = %w[hour day week].freeze
    DEFAULT_GRAN = { "24h" => "hour", "7d" => "day", "30d" => "day",
                     "90d" => "week", "all" => "week" }.freeze
    ACTIVE = %w[all active].freeze
    DEFAULT_RANGE = "7d"

    attr_reader :range, :gran, :active

    def initialize(params:)
      @range = params[:range].to_s.presence_in(RANGES.keys) || DEFAULT_RANGE
      @gran = params[:gran].to_s.presence_in(GRANS) || DEFAULT_GRAN.fetch(@range)
      @active = params[:active].to_s.presence_in(ACTIVE) || ACTIVE.first
    end

    # nil for "all": an unbounded window is the absence of a floor, not a very
    # old one, and a floor of 1970 would put an empty first bucket in every chart
    def since
      RANGES.fetch(range)&.ago
    end

    def active_only?
      active == "active"
    end

    def active_params
      { range: range, gran: gran, active: active }
    end

    # keyed, not positional: a plain "-" join would let a future range value
    # with a hyphen collide two different triples into one cache key
    def signature
      [ "r=#{range}", "g=#{gran}", "a=#{active}" ].join(",")
    end
  end
end
