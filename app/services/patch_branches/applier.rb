require "fileutils"

module PatchBranches
  class Applier
    IDENTITY = [ "-c", "user.name=hackorum", "-c", "user.email=git@hackorum.dev",
                 "-c", "maintenance.auto=false", "-c", "gc.auto=0" ].freeze

    CANDIDATE_PREFIXES = %w[src doc contrib].freeze

    # git refusing to run at all, as opposed to a patch that does not apply.
    # Deliberately one narrow signature rather than a taxonomy: this is the one
    # that cost us 38 hours of false conflicts, and a pattern loose enough to
    # catch an unknown infra error would eventually swallow a real one.
    INFRA_PATTERNS = [ /previous rebase directory .* still exists/ ].freeze

    Result = Struct.new(:success, :output, :conflict_files, :failed_patch, :infra, :empty,
                        keyword_init: true) do
      def success?
        success
      end

      # true when the failure says nothing about the patch, so no caller may
      # store it as a verdict on one
      def infra?
        !!infra
      end

      # applied without changing anything - terminal, unlike a conflict: no
      # later master makes an unreadable patch readable or an upstreamed one new
      def empty_result?
        !!empty
      end
    end

    # what an empty result means, told apart by what git made of the hunks
    NO_DIFF_CONTENT = "series produced no commits (nothing git could read as a diff)".freeze
    UNSUPPORTED_FORMAT = "unsupported patch format (git read no hunks, e.g. a context diff)".freeze
    ALREADY_IN_BASE = "patch applies but changes nothing - already in the base".freeze

    def initialize(worktree)
      @wt = worktree
    end

    # Applies patch_files (sorted) on top of base_sha. On success points
    # branch_name at the result. The worktree is always left clean.
    # committed_at backdates the commits (submission time instead of run
    # time), which also makes re-applied commits reproduce the same sha.
    def apply(base_sha, patch_files, branch_name, committed_at: nil)
      @stamp_env = commit_date_env(committed_at)
      result = apply_series(base_sha, patch_files)

      if !result.success? && missing_path_failure?(result.output)
        prefix = detect_prefix(patch_files, base_sha)
        result = apply_series(base_sha, patch_files, directory: "#{prefix}/") if prefix
      end

      unless result.success?
        @wt.run("branch", "-D", branch_name)
        return result
      end

      # Content, not commit shas. git reports "Applied patch cleanly" both for a
      # format it cannot read and for a patch already present in the base, and
      # the bare-diff path commits that nothing with --allow-empty. The commit
      # sha differs from the base either way, so a sha comparison called it
      # applied and the branch went out carrying an empty commit - which CI then
      # reports as a pass for a patchset it never tested.
      if @wt.run("diff", "--quiet", base_sha, "HEAD").success?
        @wt.run("branch", "-D", branch_name)
        return Result.new(success: false, empty: true, conflict_files: [],
                          output: empty_reason(patch_files))
      end

      @wt.run!("branch", "-f", branch_name, "HEAD")
      result
    end

    private

    # numstat is git's own reading of the patch, so the three ways to change
    # nothing tell themselves apart: nothing parsed at all (a cover letter or
    # junk attachment), a header with no hunks git understands (a context diff -
    # that gap is ours), or real hunks whose result is already in the base (what
    # an old patchset looks like once it has been committed upstream).
    def empty_reason(patch_files)
      stats = patch_files.map { |file| @wt.run("apply", "--numstat", file) }.select(&:success?)
      return NO_DIFF_CONTENT if stats.empty?
      return UNSUPPORTED_FORMAT if stats.all? { |result| zero_lines?(result) }
      ALREADY_IN_BASE
    end

    def zero_lines?(result)
      lines = result.stdout.lines
      lines.any? && lines.all? { |line| line.start_with?("0\t0\t") }
    end

    def apply_series(base_sha, patch_files, directory: nil)
      reset_to(base_sha)

      patch_files.each do |file|
        result = apply_one(file, directory: directory)
        next if result.success?

        output = result.output
        cleanup
        return Result.new(
          success: false,
          output: output,
          conflict_files: parse_conflict_files(output),
          failed_patch: File.basename(file),
          infra: INFRA_PATTERNS.any? { |pattern| pattern.match?(output) },
          # terminal like an empty result, and for the same reason: no later
          # master makes a format we cannot read readable
          empty: output.include?(UNSUPPORTED_FORMAT)
        )
      end

      note = directory ? "applied with --directory=#{directory}" : ""
      Result.new(success: true, output: note, conflict_files: [])
    end

    # "sha1 information is lacking" is git am's wording for the same problem:
    # the path is unknown, so the 3-way fallback cannot build a base tree.
    def missing_path_failure?(output)
      output.to_s.match?(/does not exist in index|No such file or directory|sha1 information is lacking/)
    end

    # Patches generated from a subtree (e.g. paths like backend/foo.c instead
    # of src/backend/foo.c) can be fixed by git's --directory option. A prefix
    # qualifies when every path from the patchset is missing at base_sha as-is
    # but present under the prefix; only an unambiguous single match counts.
    def detect_prefix(patch_files, base_sha)
      paths = patchset_paths(patch_files)
      return nil if paths.empty?
      return nil unless @wt.blob_shas(base_sha, paths).empty?

      qualifying = CANDIDATE_PREFIXES.select do |prefix|
        prefixed = paths.map { |p| "#{prefix}/#{p}" }
        @wt.blob_shas(base_sha, prefixed).size == paths.size
      end
      qualifying.size == 1 ? qualifying.first : nil
    end

    # Paths as git apply sees them with the default -p1: the b/ side of
    # diff --git lines, or +++ lines with their first component stripped
    # (covers plain diffs whose paths carry no a/ b/ markers).
    def patchset_paths(patch_files)
      paths = []
      patch_files.each do |file|
        content = File.read(file, encoding: "BINARY").scrub
        from_diff_git = content.scan(%r{^diff --git a/.+ b/(.+)$}).flatten
        if from_diff_git.any?
          paths.concat(from_diff_git)
        else
          paths.concat(content.scan(/^\+\+\+ ([^\t\n]+)/).flatten.filter_map do |raw|
            stripped = raw.sub(%r{\A[^/]+/}, "")
            stripped unless stripped == raw || stripped.empty?
          end)
        end
      end
      paths.map { |p| p.delete_suffix("\r") }.uniq
    end

    def reset_to(sha)
      cleanup
      @wt.run!("checkout", "--quiet", "--force", "--detach", sha)
      @wt.run!("clean", "-fdxq")
    end

    def cleanup
      @wt.run("am", "--abort")
      # the abort is not enough on its own: an unparseable abort-safety kills it
      # outright, and older git gives up once HEAD has moved. Either way the
      # state directory survives, and git then refuses every later mbox apply
      # with "previous rebase directory ... still exists" - one killed apply
      # wedges the shared worktree for good. Nothing in there is worth keeping.
      dir = am_state_dir
      FileUtils.rm_rf(dir) if dir
      @wt.run("reset", "--hard", "--quiet")
      @wt.run("clean", "-fdxq")
    end

    # asked of git rather than built by hand: in a linked worktree the state
    # lives under the main repo's .git/worktrees/<name>, not in the worktree
    def am_state_dir
      result = @wt.run("rev-parse", "--git-path", "rebase-apply")
      return nil unless result.success?
      File.expand_path(result.stdout.strip, @wt.dir)
    end

    def commit_date_env(committed_at)
      return {} unless committed_at

      date = committed_at.iso8601
      # author dates in mbox patches come from the email and win over the
      # env var; bare-diff synthetic commits get both
      { "GIT_COMMITTER_DATE" => date, "GIT_AUTHOR_DATE" => date }
    end

    def apply_one(file, directory: nil)
      # Rejected before git sees it, because git does not reject it. It cannot
      # apply a context diff at all, but it does read the git-style headers a
      # patch like this carries, so it "applies cleanly" and materialises the
      # files they declare: unchanged where the base has them, empty where it
      # does not. The second shape changes the tree, so no after-the-fact check
      # on the result catches it - the format is the thing to refuse.
      return unsupported_format_result(file) if context_diff?(file)

      dir_args = directory ? [ "--directory=#{directory}" ] : []
      if mbox?(file)
        @wt.run(*IDENTITY, "am", "--3way", "--empty=drop", *dir_args, file, env: @stamp_env)
      else
        result = @wt.run("apply", "--3way", *dir_args, file)
        if !result.success?
          return result unless no_valid_patches?(result)
          return GitRepo::Result.new("", "", 0) if hunkless?(file)

          # real content git apply cannot parse (context diffs etc) raises the
          # same error an empty file does; that is a failure, not a skip
          return GitRepo::Result.new(result.stdout,
                                     "#{result.stderr}\nunsupported patch format (not a unified diff): #{File.basename(file)}",
                                     result.exitstatus)
        end

        @wt.run!("add", "-A")
        @wt.run(*IDENTITY, "commit", "-q", "--allow-empty",
                "-m", "Apply #{File.basename(file)}", env: @stamp_env)
      end
    end

    # context hunks and no unified ones. Both markers present means a unified
    # diff quoting something that looks like a context header, and git reads
    # those hunks fine.
    def context_diff?(file)
      content = File.read(file, encoding: "BINARY").scrub
      content.match?(/^\*{15}/) && !content.match?(/^@@ -/)
    end

    def unsupported_format_result(file)
      GitRepo::Result.new("", "#{UNSUPPORTED_FORMAT}: #{File.basename(file)}", 1)
    end

    def no_valid_patches?(result)
      result.output.match?(/No valid patches in input/)
    end

    def hunkless?(file)
      content = File.read(file, encoding: "BINARY").scrub
      !content.match?(/^@@ -|^\*{15}/)
    end

    # Email-formatted patch vs bare diff: look for mail headers before the
    # first diff hunk.
    def mbox?(file)
      head = File.read(file, 8192, encoding: "BINARY").to_s
      preamble = head.split(/^diff --git /, 2).first.to_s
      preamble.start_with?("From ") || preamble.match?(/^From: /)
    end

    def parse_conflict_files(output)
      files = []
      output.to_s.each_line do |line|
        case line
        when /^Applied patch to '(.+)' with conflicts\.$/
          files << $1
        when /^CONFLICT \([^)]+\): Merge conflict in (.+)$/
          files << $1.strip
        when %r{^CONFLICT \(modify/delete\): (.+?) deleted in }
          files << $1
        when /^error: patch failed: (.+?):\d+/
          files << $1
        when /^error: (.+?): (?:patch does not apply|does not exist in index|already exists in index|already exists in working directory)/
          files << $1
        end
      end
      files.uniq
    end
  end
end
