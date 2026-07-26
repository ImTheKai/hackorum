module PatchCi
  class EraDetector
    # bumped as era images land; majors outside this get ci_status ci_none
    SUPPORTED_MAJORS = [ 9, 10, 11, 14, 15, 18, 19, 20 ].freeze

    CONFIGURE_FILES = %w[configure.ac configure.in].freeze
    AC_INIT = /AC_INIT\(\[PostgreSQL\],\s*\[([^\]]+)\]/

    def initialize(repo)
      @repo = repo
    end

    # 9.6beta1 -> 9, 10beta1 -> 10, 19devel -> 19. Only master is ever read,
    # so the 9.x collapse is safe: no 9.6.24 ever appears here.
    def major_for(sha)
      source = configure_source(sha)
      return nil unless source

      version = source[AC_INIT, 1]
      return nil unless version

      major = version[/\A(\d+)/, 1]
      major&.to_i
    end

    def supported?(major)
      SUPPORTED_MAJORS.include?(major)
    end

    private

    def configure_source(sha)
      CONFIGURE_FILES.each do |path|
        result = @repo.run("show", "#{sha}:#{path}")
        return result.stdout if result.success?
      end
      nil
    end
  end
end
