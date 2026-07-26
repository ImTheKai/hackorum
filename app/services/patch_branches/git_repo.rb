require "open3"
require "fileutils"

module PatchBranches
  class GitRepo
    Error = Class.new(StandardError)

    Result = Struct.new(:stdout, :stderr, :exitstatus) do
      def success?
        exitstatus == 0
      end

      def output
        [ stdout, stderr ].reject { |s| s.to_s.empty? }.join("\n")
      end
    end

    attr_reader :dir

    def initialize(dir)
      @dir = dir.to_s
    end

    # scrub: git output can contain invalid UTF-8 (patch content in errors),
    # callers run regexes over it
    def run(*args, env: {})
      stdout, stderr, status = Open3.capture3(env, "git", *args, chdir: @dir)
      Result.new(stdout.scrub, stderr.scrub, status.exitstatus)
    end

    def run!(*args, env: {})
      result = run(*args, env: env)
      raise Error, "git #{args.join(' ')} failed: #{result.output}" unless result.success?
      result
    end

    def rev_parse(ref)
      result = run("rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      result.success? ? result.stdout.strip : nil
    end

    def blob_sha(commit, path)
      result = run("rev-parse", "--verify", "--quiet", "#{commit}:#{path}")
      result.success? ? result.stdout.strip : nil
    end

    # path => blob sha for all requested paths present at commit, one git
    # spawn total; missing paths are simply absent from the hash
    def blob_shas(commit, paths)
      result = run("ls-tree", "-z", commit, "--", *paths)
      return {} unless result.success?

      result.stdout.split("\0").each_with_object({}) do |entry, blobs|
        meta, path = entry.split("\t", 2)
        next unless meta && path
        _mode, type, sha = meta.split(" ", 3)
        blobs[path] = sha if type == "blob"
      end
    end

    # File.exist? alone is not enough: a missing .git makes git walk up to
    # the parent repo, so rev_parse alone is not enough either (it would
    # resolve HEAD there instead of failing). Need both.
    def healthy_worktree?
      File.exist?(File.join(@dir, ".git")) && !!rev_parse("HEAD")
    end

    # (re)create the worktree at path if it is missing or broken; a
    # worktree killed mid-setup can look present but broken forever otherwise
    def ensure_worktree!(path, branch: "master")
      return if GitRepo.new(path).healthy_worktree?

      FileUtils.mkdir_p(File.dirname(path))
      run("worktree", "remove", "--force", path)
      FileUtils.rm_rf(path)
      run("worktree", "prune")
      run!("worktree", "add", "--quiet", "--detach", path, branch)
    end
  end
end
