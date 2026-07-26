module PatchCi
  # Reads result payloads out of refs/hackorum-ci with two git spawns per call
  # (for-each-ref + cat-file --batch); a spawn per ref would not scale as the
  # namespace grows.
  class ResultRefs
    # abnormal batch output must never look like "no payload": a partial map
    # records infra_error for runs that reported fine
    ReadError = Class.new(StandardError)

    NAMESPACE = "refs/hackorum-ci".freeze
    REFSPEC = "+#{NAMESPACE}/*:#{NAMESPACE}/*".freeze
    CHUNK = 100

    def self.run_id_for(ref)
      ref.split("/").last.to_i
    end

    def initialize(repo, remote: "origin")
      @repo = repo
      @remote = remote
    end

    def fetch!
      @repo.run("fetch", "--quiet", "--prune", @remote, REFSPEC)
    end

    # { run_id => raw result.json }; only: bounds the read to the caller's runs
    # window - payloads are up to 256KB each, so reading every retained ref is
    # a memory problem. only: :all is the explicit escape hatch (backfill
    # reconciliation): chunking bounds the transient cat-file buffer, but the
    # returned hash still accumulates every ref, so callers of :all own that.
    def payloads(only:)
      raise ArgumentError, "only: expects run ids or :all" if only.nil?

      listing = @repo.run("for-each-ref", "--format=%(refname)", NAMESPACE)
      # an empty listing from a failed command is indistinguishable from "no
      # refs", which ingests as infra_error for every run in the window
      raise ReadError, "for-each-ref failed: #{message(listing.stderr)}" unless listing.success?

      wanted = only == :all ? nil : only.to_set
      refs = listing.stdout.split("\n").filter_map do |ref|
        run_id = ResultRefs.run_id_for(ref)
        next if run_id.zero?
        next if wanted && !wanted.include?(run_id)
        [ ref, run_id ]
      end

      refs.each_slice(CHUNK).each_with_object({}) do |slice, acc|
        acc.merge!(read_batch(slice))
      end
    end

    private

    # cat-file --batch answers each request either with
    # "<sha> <type> <size>\n<size bytes>\n" or with a "<request> missing" line
    # and no content; sizes are byte counts, so parse on bytes (raw: keeps the
    # output binary) and only then tag the payload as UTF-8.
    def read_batch(slice)
      requests = slice.map { |ref, _run_id| "#{ref}:result.json" }
      result = @repo.run("cat-file", "--batch", stdin: requests.join("\n") + "\n", raw: true)
      raise ReadError, "cat-file failed: #{message(result.stderr)}" unless result.success?

      bytes = result.stdout
      pos = 0
      slice.each_with_object({}) do |(ref, run_id), acc|
        eol = bytes.index("\n", pos)
        raise ReadError, "truncated cat-file output before #{ref}" unless eol

        header = bytes[pos...eol]
        pos = eol + 1
        # a ref without result.json answers "missing" (or "ambiguous"), with no
        # content following it - a normal skip
        next unless header =~ /\A[0-9a-f]{40,64} [a-z]+ (\d+)\z/

        size = Regexp.last_match(1).to_i
        raise ReadError, "dangling cat-file header for #{ref}" if pos + size > bytes.bytesize

        # never materialize more than the cap, whatever the producer wrote; one
        # byte over is enough for ResultPayload to reject it as too large
        take = [ size, ResultPayload::MAX_BYTES + 1 ].min
        acc[run_id] = bytes[pos, take].dup.force_encoding(Encoding::UTF_8).scrub
        pos += size + 1
      end
    end

    def message(stderr)
      stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip.slice(0, 200)
    end
  end
end
