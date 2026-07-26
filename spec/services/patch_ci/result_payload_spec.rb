require "rails_helper"

RSpec.describe PatchCi::ResultPayload do
  def valid_json(**overrides)
    {
      schema: 1, branch: "t1_1", run_id: 5, run_attempt: 1,
      head_sha: "a" * 40, base_sha: "b" * 40, pg_major: 20,
      status: "tests_failed",
      build: { ok: true, seconds: 240 },
      tests: { ok: false, seconds: 610, timed_out: false, failed: [ "regress/inherit" ] },
      image: { ref: "ghcr.io/x/y:t1", digest: "sha256:abc" },
      ccache: { hit: 812, miss: 143 }
    }.merge(overrides).to_json
  end

  it "parses a well formed payload" do
    result = described_class.parse(valid_json)

    expect(result).to be_valid
    expect(result.status).to eq("tests_failed")
    expect(result.failed_tests).to eq([ "regress/inherit" ])
    expect(result.build_seconds).to eq(240)
    expect(result.test_seconds).to eq(610)
    expect(result.image_ref).to eq("ghcr.io/x/y:t1")
    expect(result.run_id).to eq(5)
  end

  it "rejects an oversized payload without parsing" do
    result = described_class.parse("x" * 70_000)

    expect(result).not_to be_valid
    expect(result.error).to eq("payload too large")
  end

  it "rejects malformed json" do
    result = described_class.parse("{not json")

    expect(result).not_to be_valid
    expect(result.error).to include("malformed")
  end

  it "rejects an unknown schema" do
    result = described_class.parse(valid_json(schema: 99))

    expect(result).not_to be_valid
    expect(result.error).to include("schema")
  end

  it "rejects an unknown status" do
    result = described_class.parse(valid_json(status: "rm -rf"))

    expect(result).not_to be_valid
    expect(result.error).to include("status")
  end

  it "caps the failed test list" do
    many = (1..500).map { |i| "t#{i}" }
    result = described_class.parse(valid_json(tests: { ok: false, failed: many }))

    expect(result.failed_tests.size).to eq(200)
  end

  it "truncates absurd test names" do
    result = described_class.parse(valid_json(tests: { ok: false, failed: [ "x" * 5_000 ] }))

    expect(result.failed_tests.first.length).to eq(200)
  end

  it "coerces junk numerics to integers" do
    result = described_class.parse(valid_json(ccache: { hit: "812", miss: nil }))

    expect(result.ccache_hit).to eq(812)
    expect(result.ccache_miss).to eq(0)
  end

  it "rejects valid json that is not an object" do
    [ "[1,2,3]", '"just a string"', "null" ].each do |body|
      result = described_class.parse(body)
      expect(result).not_to be_valid, "expected #{body} to be rejected"
      expect(result.error).to include("not an object")
    end
  end

  it "drops non-string entries from the failed test list" do
    result = described_class.parse(
      valid_json(tests: { ok: false, failed: [ "regress/inherit", [ "nested" ], { "a" => 1 }, nil, 42 ] })
    )

    expect(result).to be_valid
    expect(result.failed_tests).to eq([ "regress/inherit" ])
  end

  it "does not raise on an out-of-range float in a numeric field" do
    json = valid_json(pg_major: "__PLACEHOLDER__").sub('"__PLACEHOLDER__"', "1e400")
    result = described_class.parse(json)

    expect(result).to be_valid
    expect(result.pg_major).to eq(0)
  end

  it "defaults a numeric field that overflows an int4 column" do
    result = described_class.parse(valid_json(pg_major: ("9" * 40).to_i))

    expect(result).to be_valid
    expect(result.pg_major).to eq(0)
  end

  it "accepts a run_id above int4 max but within int8 range" do
    big = described_class::INT4_MAX + 1000
    result = described_class.parse(valid_json(run_id: big))

    expect(result).to be_valid
    expect(result.run_id).to eq(big)
  end
end
