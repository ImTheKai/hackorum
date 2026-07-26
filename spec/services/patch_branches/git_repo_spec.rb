require "rails_helper"

RSpec.describe PatchBranches::GitRepo do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  let(:fixture) { GitFixtureRepo.new(@dir) }
  let(:repo) { described_class.new(fixture.path) }

  it "runs git commands and captures output" do
    fixture.commit(subject: "first")
    result = repo.run("log", "--oneline")
    expect(result).to be_success
    expect(result.stdout).to include("first")
  end

  it "pipes stdin to git" do
    result = repo.run("hash-object", "-w", "--stdin", stdin: "hello\n")
    expect(result).to be_success
    sha = result.stdout.strip
    expect(repo.run("cat-file", "blob", sha).stdout).to eq("hello\n")
  end

  it "leaves invalid UTF-8 alone with raw" do
    invalid = (+"a\xC3(b").force_encoding(Encoding::BINARY)
    File.binwrite(File.join(@dir, "bin.dat"), invalid)
    sha = repo.run!("hash-object", "-w", "--", "bin.dat").stdout.strip

    raw = repo.run("cat-file", "blob", sha, raw: true)
    expect(raw.stdout.encoding).to eq(Encoding::BINARY)
    expect(raw.stdout).to eq(invalid)
    expect(repo.run("cat-file", "blob", sha).stdout.bytes).not_to eq(invalid.bytes)
  end

  it "reports failures without raising" do
    result = repo.run("rev-parse", "--verify", "nope")
    expect(result).not_to be_success
    expect(result.output).not_to be_empty
  end

  it "run! raises with the output" do
    expect { repo.run!("rev-parse", "--verify", "nope") }
      .to raise_error(PatchBranches::GitRepo::Error, /nope/)
  end

  it "rev_parse resolves refs to shas" do
    sha = fixture.commit(subject: "first")
    expect(repo.rev_parse("master")).to eq(sha)
    expect(repo.rev_parse("garbage")).to be_nil
  end

  it "blob_sha resolves commit:path" do
    fixture.commit(subject: "first", files: { "a.c" => "hello\n" })
    sha = repo.rev_parse("master")
    expect(repo.blob_sha(sha, "a.c")).to match(/\A[0-9a-f]{40}\z/)
    expect(repo.blob_sha(sha, "missing.c")).to be_nil
  end

  it "blob_shas resolves many paths in one call" do
    fixture.commit(subject: "first", files: { "a.c" => "hello\n", "sub dir/b file.c" => "world\n" })
    sha = repo.rev_parse("master")
    blobs = repo.blob_shas(sha, [ "a.c", "sub dir/b file.c", "missing.c" ])
    expect(blobs.keys).to contain_exactly("a.c", "sub dir/b file.c")
    expect(blobs["a.c"]).to eq(repo.blob_sha(sha, "a.c"))
    expect(blobs["sub dir/b file.c"]).to eq(repo.blob_sha(sha, "sub dir/b file.c"))
    expect(repo.blob_shas("0" * 40, [ "a.c" ])).to eq({})
  end

  describe "commit metadata" do
    it "commit_time and commit_height for a valid sha, nil otherwise" do
      date = "2026-03-04T05:06:07+00:00"
      first = fixture.commit(subject: "first", date: date)
      fixture.commit(subject: "second")
      sha = repo.rev_parse("HEAD")
      expect(repo.commit_time(first)).to eq(Time.zone.parse(date))
      expect(repo.commit_height(first)).to eq(1)
      expect(repo.commit_height(sha)).to eq(2)
      expect(repo.commit_time("0" * 40)).to be_nil
      expect(repo.commit_height("0" * 40)).to be_nil
    end
  end
end
