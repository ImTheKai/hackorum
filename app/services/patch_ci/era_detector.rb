module PatchCi
  class EraDetector
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

    # eras.yml's enabled flag is the only switch: a family is enabled once its
    # image is built and pushed. A hand-kept list here was a second copy of the
    # same fact, free to drift from it - which is how pg12/13/16/17 stayed in
    # ci_none. Majors no family serves (pre-9.6 trees, a new major before its
    # image exists) are unsupported too.
    def supported?(major)
      Eras.enabled?(major)
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
