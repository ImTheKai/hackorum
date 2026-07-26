require "rails_helper"

RSpec.describe PatchCi::ResultRefs do
  around do |example|
    Dir.mktmpdir do |dir|
      @work_dir = File.join(dir, "origin-work")
      @origin_dir = File.join(dir, "origin.git")
      @local_dir = File.join(dir, "local")
      example.run
    end
  end

  let(:fixture) { GitFixtureRepo.new(@work_dir) }
  let(:origin) { PatchBranches::GitRepo.new(@work_dir) }
  let(:repo) { PatchBranches::GitRepo.new(@local_dir) }
  let(:refs) { described_class.new(repo) }

  # what CI produces: a commit whose tree holds result.json, under
  # refs/hackorum-ci/<run_id>
  def result_ref(name, files)
    entries = files.map do |path, content|
      blob = origin.run!("hash-object", "-w", "--stdin", stdin: content).stdout.strip
      "100644 blob #{blob}\t#{path}"
    end
    tree = origin.run!("mktree", stdin: entries.join("\n") + "\n").stdout.strip
    commit = origin.run!("commit-tree", tree, "-m", "result").stdout.strip
    origin.run!("update-ref", "refs/hackorum-ci/#{name}", commit)
  end

  def clone_and_fetch
    fixture.mirror_to(@origin_dir)
    out, err, status = Open3.capture3("git", "clone", "--quiet", @origin_dir, @local_dir)
    raise "clone failed: #{err}#{out}" unless status.success?
    expect(refs.fetch!).to be_success
  end

  before { fixture.commit(subject: "base", files: { "README" => "x\n" }) }

  it "round-trips several payloads in one batch" do
    result_ref(11, "result.json" => %({"run_id":11}))
    result_ref(12, "result.json" => %({"run_id":12}))
    clone_and_fetch

    expect(refs.payloads(only: [ 11, 12 ]))
      .to eq(11 => %({"run_id":11}), 12 => %({"run_id":12}))
  end

  it "returns a multi-KB payload byte-exact" do
    big = %({"tests":"#{'a' * 10_000}"})
    result_ref(13, "result.json" => big)
    clone_and_fetch

    payload = refs.payloads(only: [ 13 ])[13]
    expect(payload.bytesize).to eq(big.bytesize)
    expect(payload).to eq(big)
  end

  it "keeps byte offsets straight around a multibyte payload" do
    multibyte = %({"author":"Zsolt Parragi áő€"})
    result_ref(14, "result.json" => multibyte)
    result_ref(15, "result.json" => %({"run_id":15}))
    clone_and_fetch

    payloads = refs.payloads(only: [ 14, 15 ])
    expect(payloads[14]).to eq(multibyte)
    expect(payloads[14].encoding).to eq(Encoding::UTF_8)
    expect(payloads[15]).to eq(%({"run_id":15}))
  end

  it "skips refs without result.json and keeps the rest of the batch" do
    result_ref(16, "other.txt" => "nothing here\n")
    result_ref(17, "result.json" => %({"run_id":17}))
    clone_and_fetch

    expect(refs.payloads(only: [ 16, 17 ])).to eq(17 => %({"run_id":17}))
  end

  it "skips ref names without a numeric tail" do
    result_ref("garbage", "result.json" => %({"junk":true}))
    result_ref(18, "result.json" => %({"run_id":18}))
    clone_and_fetch

    expect(refs.payloads(only: :all)).to eq(18 => %({"run_id":18}))
  end

  it "reads nothing outside the requested run ids" do
    result_ref(19, "result.json" => %({"run_id":19}))
    result_ref(20, "result.json" => %({"run_id":20}))
    clone_and_fetch

    expect(refs.payloads(only: [ 19 ])).to eq(19 => %({"run_id":19}))
    expect(refs.payloads(only: [])).to eq({})
  end

  it "clamps a payload over the size cap without losing the rest of the batch" do
    stub_const("PatchCi::ResultPayload::MAX_BYTES", 1024)
    result_ref(23, "result.json" => "x" * 4096)
    result_ref(24, "result.json" => %({"run_id":24}))
    clone_and_fetch

    payloads = refs.payloads(only: [ 23, 24 ])
    expect(payloads[23].bytesize).to eq(1025)
    expect(payloads[24]).to eq(%({"run_id":24}))
  end

  it "spawns two subprocesses for the whole read" do
    result_ref(21, "result.json" => %({"run_id":21}))
    result_ref(22, "result.json" => %({"run_id":22}))
    clone_and_fetch
    calls = spy_on_run

    refs.payloads(only: [ 21, 22 ])

    expect(calls.map { |call| call[:cmd] }).to eq([ "for-each-ref", "cat-file" ])
  end

  it "asks cat-file only for the requested refs" do
    result_ref(25, "result.json" => %({"run_id":25}))
    result_ref(26, "result.json" => %({"run_id":26}))
    clone_and_fetch
    calls = spy_on_run

    refs.payloads(only: [ 26 ])

    batch = calls.find { |call| call[:cmd] == "cat-file" }
    expect(batch[:stdin]).to eq("refs/hackorum-ci/26:result.json\n")
  end

  it "chunks the batch so only: :all never reads everything at once" do
    (31..35).each { |id| result_ref(id, "result.json" => %({"run_id":#{id}})) }
    clone_and_fetch
    stub_const("#{described_class}::CHUNK", 2)
    calls = spy_on_run

    payloads = refs.payloads(only: :all)

    expect(payloads.keys).to match_array(31..35)
    expect(calls.count { |call| call[:cmd] == "cat-file" }).to eq(3)
  end

  it "raises when the ref listing fails" do
    clone_and_fetch
    allow(repo).to receive(:run).with("for-each-ref", any_args)
                               .and_return(PatchBranches::GitRepo::Result.new("", "boom", 1))

    expect { refs.payloads(only: :all) }
      .to raise_error(described_class::ReadError, /for-each-ref failed/)
  end

  it "rejects only: nil so a missing window cannot mean everything" do
    expect { refs.payloads(only: nil) }.to raise_error(ArgumentError, /:all/)
  end

  describe "abnormal batch output" do
    before do
      result_ref(51, "result.json" => %({"run_id":51}))
      clone_and_fetch
    end

    def stub_batch(stdout, exitstatus = 0)
      result = PatchBranches::GitRepo::Result.new(stdout.b, "boom".b, exitstatus)
      allow(repo).to receive(:run).and_wrap_original do |original, *args, **opts|
        args.first == "cat-file" ? result : original.call(*args, **opts)
      end
    end

    it "raises when a chunk exits nonzero" do
      stub_batch("", 128)
      expect { refs.payloads(only: :all) }.to raise_error(described_class::ReadError, /cat-file failed/)
    end

    it "raises on a truncated stream" do
      stub_batch("")
      expect { refs.payloads(only: :all) }.to raise_error(described_class::ReadError, /truncated/)
    end

    it "raises on a header whose content is not there" do
      stub_batch("#{'0' * 40} blob 100\nshort\n")
      expect { refs.payloads(only: :all) }.to raise_error(described_class::ReadError, /dangling/)
    end
  end

  def spy_on_run
    calls = []
    allow(repo).to receive(:run).and_wrap_original do |original, *args, **opts|
      calls << { cmd: args.first, stdin: opts[:stdin] }
      original.call(*args, **opts)
    end
    calls
  end
end
