module PatchCi
  class EraDetector
    # bumped as era images land; majors outside this get ci_status ci_none
    SUPPORTED_MAJORS = [ 9, 10, 11, 14, 15, 18, 19, 20 ].freeze

    CONFIGURE_FILES = %w[configure.ac configure.in].freeze
    AC_INIT = /AC_INIT\(\[PostgreSQL\],\s*\[([^\]]+)\]/

    def initialize(repo)
      @repo = repo
      @majors = {}
    end

    # 9.6beta1 -> 9, 10beta1 -> 10, 19devel -> 19. Only master is ever read,
    # so the 9.x collapse is safe: no 9.6.24 ever appears here.
    #
    # cache keys must be commit shas, never refs: a long-lived detector handed
    # "master" would keep answering with the pre-fetch tree. Only hits are
    # cached, so a git show that failed on a busy repo is retried, not pinned.
    def major_for(sha)
      return nil if sha.blank?
      @majors[sha] ||= compute_major(sha)
    end

    def supported?(major)
      SUPPORTED_MAJORS.include?(major)
    end

    private

    def compute_major(sha)
      source = configure_source(sha)
      return nil unless source

      version = source[AC_INIT, 1]
      return nil unless version

      version[/\A(\d+)/, 1]&.to_i
    end

    def configure_source(sha)
      CONFIGURE_FILES.each do |path|
        result = @repo.run("show", "#{sha}:#{path}")
        return result.stdout if result.success?
      end
      nil
    end
  end
end
