require "rails_helper"

RSpec.describe PatchBranches::Runner do
  include PatchSeriesHelper

  around do |example|
    Dir.mktmpdir do |dir|
      @repo_dir = File.join(dir, "repo")
      @patch_dir = File.join(dir, "patches")
      @worktrees_dir = File.join(dir, "worktrees")
      FileUtils.mkdir_p(@patch_dir)
      example.run
    end
  end

  let(:fixture) { GitFixtureRepo.new(@repo_dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }
  let(:runner) do
    described_class.new(repo_path: fixture.path, worktrees_dir: @worktrees_dir, concurrency: 1)
  end

  def message_with_attachment(file_name, body)
    message = create(:message)
    create(:attachment, message: message, file_name: file_name, body: Base64.encode64(body))
    message.reload
  end

  it "walks the batch and counts one outcome per message" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" }, date: Time.current.iso8601)
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    applied = message_with_attachment(File.basename(patch), File.binread(patch))
    broken = message_with_attachment("screenshot.png", "png")

    counts = runner.run([ applied.id, broken.id ])

    expect(counts).to eq(applied_on_master: 1, extract_failed: 1)
    expect(PatchBranch.find_by(message_id: applied.id))
      .to have_attributes(status: "applied", on_master: true)
    expect(PatchBranch.find_by(message_id: broken.id))
      .to have_attributes(status: "failed", failure_stage: "extract")
  end

  it "counts an unexpected failure and still marks the row" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    patch = generate_patch(fixture.path, base, "a.c", "v2\n", @patch_dir)
    message = message_with_attachment(File.basename(patch), File.binread(patch))
    allow_any_instance_of(PatchBranches::Applier).to receive(:apply).and_raise("boom")

    counts = runner.run([ message.id ])

    expect(counts).to eq(error: 1)
    expect(PatchBranch.find_by(message_id: message.id))
      .to have_attributes(status: "failed", failure_stage: "error",
                          failure_reason: a_string_including("boom"))
  end

  it "raises when the repository has no master" do
    FileUtils.mkdir_p(@repo_dir)
    repo.run!("init", "--quiet", "--initial-branch=master")

    expect { runner.run([]) }.to raise_error(/no master ref/)
  end
end
