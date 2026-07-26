module PatchCi
  # One batched fetch gets every result payload; a request per ref would not
  # scale as the ref namespace grows.
  class ResultRefs
    REFSPEC = "+refs/hackorum-ci/*:refs/hackorum-ci/*".freeze

    def initialize(repo, remote: "origin")
      @repo = repo
      @remote = remote
    end

    def fetch!
      @repo.run("fetch", "--quiet", "--prune", @remote, REFSPEC)
    end

    # { run_id => raw result.json }
    def payloads
      result = @repo.run("for-each-ref", "--format=%(refname)", "refs/hackorum-ci")
      return {} unless result.success?

      result.stdout.split("\n").each_with_object({}) do |ref, acc|
        run_id = ref.split("/").last.to_i
        next if run_id.zero?
        blob = @repo.run("show", "#{ref}:result.json")
        acc[run_id] = blob.stdout if blob.success?
      end
    end
  end
end
