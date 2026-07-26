module PatchBranches
  class Runner
    def initialize(repo_path:, worktrees_dir:, concurrency: 8, force: false)
      @repo = GitRepo.new(repo_path)
      @worktrees_dir = worktrees_dir
      @concurrency = concurrency
      @force = force
      @counts = Hash.new(0)
      @mutex = Mutex.new
    end

    def run(message_ids)
      master_sha = @repo.rev_parse("master")
      raise "no master ref in #{@repo.dir}" unless master_sha

      queue = Queue.new
      message_ids.each { |id| queue << id }
      total = message_ids.size
      done = 0

      threads = @concurrency.times.map do |i|
        Thread.new do
          worktree = prepare_worktree(i)
          loop do
            message_id = begin
              queue.pop(true)
            rescue ThreadError
              break
            end

            ActiveRecord::Base.connection_pool.with_connection do
              process(message_id, worktree, master_sha)
            end

            @mutex.synchronize do
              done += 1
              if (done % 25).zero? || done == total
                puts "[#{done}/#{total}] #{@counts.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
              end
            end
          end
        rescue => e
          @mutex.synchronize { puts "worker #{i} died: #{e.class}: #{e.message}" }
          bump(:dead_worker)
        end
      end
      threads.each(&:join)
      @counts
    end

    private

    # Serialized: concurrent "git worktree add" calls race on .git internals.
    def prepare_worktree(i)
      path = File.join(@worktrees_dir, "wt#{i}")
      @mutex.synchronize { @repo.ensure_worktree!(path) }
      GitRepo.new(path)
    end

    def process(message_id, worktree, master_sha)
      apply_one = ApplyOne.new(repo: @repo, worktree: worktree, force: @force)
      outcome, = apply_one.call(message_id, master_sha: master_sha)
      bump(outcome)
      report_save_error(apply_one)
    rescue => e
      if apply_one
        apply_one.persist_error(e)
        report_save_error(apply_one)
      end
      bump(:error)
      @mutex.synchronize { puts "ERROR message #{message_id}: #{e.class}: #{e.message}" }
    end

    # a save ApplyOne could not do (e.g. branch_name unique collision) is a
    # counted outcome, not a dead worker thread
    def report_save_error(apply_one)
      error = apply_one.save_error
      return unless error

      bump(:save_failed)
      @mutex.synchronize { puts "save failed for message #{apply_one.message&.id}: #{error.class}: #{error.message}" }
    end

    def bump(key)
      @mutex.synchronize { @counts[key] += 1 }
    end
  end
end
