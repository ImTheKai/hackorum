require "rails_helper"
require_relative "../../script/commit_import"

RSpec.describe CommitImportJob do
  it "runs the importer under the advisory lock" do
    importer = instance_double(CommitImport::Importer, run!: true)
    allow(CommitImport::Importer).to receive(:new).and_return(importer)

    described_class.perform_now

    expect(importer).to have_received(:run!)
  end

  it "skips the run when the lock is held" do
    importer = instance_double(CommitImport::Importer, run!: true)
    allow(CommitImport::Importer).to receive(:new).and_return(importer)
    allow(AdvisoryLock).to receive(:with_lock).and_return(nil)

    described_class.perform_now

    expect(importer).not_to have_received(:run!)
  end

  it "logs when it skips because the lock is held" do
    allow(AdvisoryLock).to receive(:with_lock).and_return(nil)
    allow(Rails.logger).to receive(:info).and_call_original

    described_class.perform_now

    expect(Rails.logger).to have_received(:info).with(/lock.*held/i)
  end

  it "does not log a skip when the lock is acquired and the importer legitimately returns nil" do
    importer = instance_double(CommitImport::Importer, run!: nil)
    allow(CommitImport::Importer).to receive(:new).and_return(importer)
    allow(Rails.logger).to receive(:info).and_call_original

    described_class.perform_now

    expect(Rails.logger).not_to have_received(:info).with(/lock.*held/i)
  end
end

RSpec.describe CommitImportScript do
  let(:options) { { repo: "/nonexistent", fetch: false, limit: nil, reparse: false, relink: false } }

  it "runs the importer under the same lock the job uses" do
    importer = instance_double(CommitImport::Importer, run!: true)
    allow(CommitImport::Importer).to receive(:new).and_return(importer)

    ran = described_class.run(options)

    expect(ran).to be(true)
    expect(importer).to have_received(:run!)
  end

  it "does not run the importer when the lock is held (e.g. by the hourly job)" do
    importer = instance_double(CommitImport::Importer, run!: true)
    allow(CommitImport::Importer).to receive(:new).and_return(importer)
    allow(AdvisoryLock).to receive(:with_lock).and_return(nil)

    ran = described_class.run(options)

    expect(ran).to be(false)
    expect(importer).not_to have_received(:run!)
  end
end
