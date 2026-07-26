module PatchCi
  class LoopRunner
    DEFAULT_BUDGET = 18

    def initialize(client:, pusher:, selector:, result_refs:, budget: DEFAULT_BUDGET)
      @client = client
      @pusher = pusher
      @selector = selector
      @result_refs = result_refs
      @budget = budget
    end

    def cycle
      runs = @client.runs
      refs_ok = @result_refs.fetch!.success?
      # a failed fetch means missing payloads, and ingesting then would record
      # infra_error for runs that actually reported fine
      ingested = refs_ok ? Ingestor.new(payloads: @result_refs.payloads).ingest(runs) : {}

      # from status-filtered queries, not from the bounded ingestion window
      in_flight = @client.in_flight_count
      free = [ @budget - in_flight, 0 ].max

      candidates = @selector.eligible
      skipped = record_rejections

      pushed = candidates.first(free).count { |row| @pusher.push(row) }

      { in_flight: in_flight, free_slots: free, pushed: pushed,
        skipped: skipped, ingested: ingested, refs_stale: !refs_ok, error: nil }
    rescue GithubClient::Error => e
      # not knowing what is in flight must never be read as "nothing is"
      { in_flight: nil, free_slots: 0, pushed: 0, skipped: 0,
        ingested: {}, refs_stale: true, error: e.message }
    end

    private

    def record_rejections
      rejections = @selector.rejections
      return 0 if rejections.empty?

      PatchBranch.where(id: rejections.keys).find_each do |row|
        @pusher.skip(row, rejections[row.id])
      end
      rejections.size
    end
  end
end
