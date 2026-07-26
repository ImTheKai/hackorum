module PatchCi
  # One refresh per orchestrator cycle, never per row - N finishing runs must
  # not mean N re-fetches per client.
  class DashboardBroadcast
    STREAM = "ci_dashboard".freeze

    def self.refresh!
      Turbo::StreamsChannel.broadcast_refresh_to(STREAM)
    end
  end
end
