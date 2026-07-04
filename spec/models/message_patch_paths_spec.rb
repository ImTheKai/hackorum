require "rails_helper"

RSpec.describe "Message patch path recompute" do
  it "replaces patch_submission_files from the extractor" do
    msg = create(:message)
    create(:attachment, message: msg, file_name: "a.patch",
           body: Base64.encode64("--- a/src/one.c\n+++ b/src/one.c\n@@ -1 +1 @@\n"))
    msg.reload.recompute_patch_paths!
    expect(msg.patch_submission_files.pluck(:path)).to eq([ "src/one.c" ])

    msg.recompute_patch_paths!
    expect(msg.patch_submission_files.count).to eq(1)
  end

  it "refreshes on attachment destroy" do
    msg = create(:message)
    att = create(:attachment, message: msg, file_name: "a.patch",
                 body: Base64.encode64("--- a/src/one.c\n+++ b/src/one.c\n@@ -1 +1 @@\n"))
    expect(msg.reload.patch_submission_files.pluck(:path)).to eq([ "src/one.c" ])
    att.destroy
    expect(msg.reload.patch_submission_files).to be_empty
  end
end
