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
end
