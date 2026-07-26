module PatchCi
  # result.json is written by a job that ran patch code, so everything here
  # treats it as hostile input: size cap first, then schema, then coercion.
  class ResultPayload
    MAX_BYTES = 64 * 1024
    MAX_FAILED = 200
    MAX_NAME = 200
    SCHEMA = 1
    INT4_MAX = 2_147_483_647
    INT8_MAX = 9_223_372_036_854_775_807

    attr_reader :error, :raw

    def self.parse(text)
      new(text)
    end

    def initialize(text)
      @error = nil
      @data = {}
      @raw = nil
      validate(text)
    end

    def valid?
      @error.nil?
    end

    def status = @data["status"]
    def run_id = int(@data["run_id"], max: INT8_MAX)
    def run_attempt = int(@data["run_attempt"], default: 1)
    def head_sha = string(@data["head_sha"])
    def pg_major = int(@data["pg_major"])
    def build_seconds = int(section("build")["seconds"])
    def test_seconds = int(section("tests")["seconds"])
    def image_ref = string(section("image")["ref"])
    def image_digest = string(section("image")["digest"])
    def ccache_hit = int(section("ccache")["hit"])
    def ccache_miss = int(section("ccache")["miss"])

    def failed_tests
      list = section("tests")["failed"]
      return [] unless list.is_a?(Array)
      list.first(MAX_FAILED).map { |name| string(name).slice(0, MAX_NAME) }.reject(&:empty?)
    end

    private

    def validate(text)
      return fail!("payload too large") if text.to_s.bytesize > MAX_BYTES

      begin
        parsed = JSON.parse(text.to_s)
      rescue JSON::ParserError => e
        return fail!("malformed json: #{e.message.slice(0, 200)}")
      end
      return fail!("payload is not an object") unless parsed.is_a?(Hash)

      @data = parsed
      return fail!("unsupported schema: #{parsed['schema'].inspect}") unless parsed["schema"] == SCHEMA
      return fail!("unknown status: #{parsed['status'].inspect}") unless PatchCiRun::STATUSES.include?(parsed["status"])

      @raw = parsed
      nil
    end

    def fail!(message)
      @error = message
      nil
    end

    def section(key)
      value = @data[key]
      value.is_a?(Hash) ? value : {}
    end

    def int(value, default: 0, max: INT4_MAX)
      # FloatDomainError covers Infinity/NaN, which JSON reaches via 1e400
      number = Integer(value)
      number.abs > max ? default : number
    rescue TypeError, ArgumentError, FloatDomainError
      default
    end

    def string(value)
      value.is_a?(String) ? value.scrub : ""
    end
  end
end
