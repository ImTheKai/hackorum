require "digest"
require "tmpdir"

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
      @mutex.synchronize do
        unless worktree_healthy?(path)
          FileUtils.mkdir_p(@worktrees_dir)
          @repo.run("worktree", "remove", "--force", path)
          FileUtils.rm_rf(path)
          @repo.run("worktree", "prune")
          @repo.run!("worktree", "add", "--quiet", "--detach", path, "master")
        end
      end
      GitRepo.new(path)
    end

    # File.exist? alone is not enough: a missing .git makes git walk up to
    # the parent repo, so rev_parse alone is not enough either (it would
    # resolve HEAD there instead of failing). Need both.
    def worktree_healthy?(path)
      File.exist?(File.join(path, ".git")) && !!GitRepo.new(path).rev_parse("HEAD")
    end

    def process(message_id, worktree, master_sha)
      message = Message.includes(:attachments, :topic).find(message_id)
      branch_name = "t#{message.topic_id}_#{message.topic.chronological_index_of(message)}"
      record = PatchBranch.find_or_initialize_by(message_id: message.id)

      Dir.mktmpdir("patchset") do |dir|
        files = PatchsetExtractor.new(message).extract(dir)
        content_hash = Digest::SHA256.hexdigest(files.map { |f| File.binread(f) }.join)

        if skippable?(record, content_hash)
          bump(:skipped)
          return
        end

        applier = Applier.new(worktree)

        master_result = applier.apply(master_sha, files, branch_name,
                                      committed_at: message.created_at)
        if master_result.success?
          save(record, message, branch_name, status: "applied",
               base_sha: master_sha, on_master: true, base_source: "master",
               content_hash: content_hash)
          bump(:applied_on_master)
          return
        end

        detection = BaseCommitDetector
          .new(@repo, files, submission_date: message.created_at)
          .detect

        if detection.nil?
          save(record, message, branch_name, status: "failed",
               failure_stage: "base_detection",
               failure_reason: clip(master_result.output),
               conflict_files: master_result.conflict_files,
               content_hash: content_hash)
          bump(:no_base)
          return
        end

        result = detection.sha == master_sha ? master_result
                                             : applier.apply(detection.sha, files, branch_name,
                                                             committed_at: message.created_at)

        if result.success?
          save(record, message, branch_name, status: "applied",
               base_sha: detection.sha, on_master: false,
               base_source: detection.source, content_hash: content_hash)
          bump(:applied_on_base)
        else
          save(record, message, branch_name, status: "failed",
               failure_stage: "apply", base_sha: detection.sha,
               base_source: detection.source,
               failure_reason: clip(result.output),
               conflict_files: result.conflict_files,
               content_hash: content_hash)
          bump(:apply_failed)
        end
      end
    rescue PatchsetExtractor::Error => e
      rescue_save(record, message, branch_name, status: "failed",
                  failure_stage: "extract", failure_reason: e.message)
      bump(:extract_failed)
    rescue => e
      if record && message && branch_name
        rescue_save(record, message, branch_name, status: "failed", failure_stage: "error",
                    failure_reason: clip("#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"))
      end
      bump(:error)
      @mutex.synchronize { puts "ERROR message #{message_id}: #{e.class}: #{e.message}" }
    end

    # a save on the rescue path (e.g. branch_name unique collision) must not
    # kill the worker thread
    def rescue_save(record, message, branch_name, **kwargs)
      save(record, message, branch_name, **kwargs)
    rescue => e
      bump(:save_failed)
      @mutex.synchronize { puts "save failed for message #{message&.id}: #{e.class}: #{e.message}" }
    end

    def skippable?(record, content_hash)
      !@force && record.persisted? &&
        record.status == "applied" && record.patch_content_hash == content_hash
    end

    def save(record, message, branch_name, status:, base_sha: nil, on_master: false,
             base_source: nil, failure_stage: nil, failure_reason: nil,
             conflict_files: [], content_hash: nil)
      record.assign_attributes(
        topic_id: message.topic_id,
        branch_name: branch_name,
        status: status,
        base_sha: base_sha,
        on_master: on_master,
        base_source: base_source,
        failure_stage: failure_stage,
        failure_reason: failure_reason,
        conflict_files: conflict_files || [],
        patch_content_hash: content_hash,
        attempted_at: Time.current
      )
      record.save!
    end

    def clip(text)
      text.to_s.scrub("?").slice(0, 20_000)
    end

    def bump(key)
      @mutex.synchronize { @counts[key] += 1 }
    end
  end
end
