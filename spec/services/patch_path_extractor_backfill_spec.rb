require "rails_helper"

RSpec.describe "PatchPathExtractor.backfill" do
  it "populates paths for patch-ish messages in range and skips others" do
    old = 3.years.ago
    with_att = create(:message, created_at: old)
    create(:attachment, message: with_att, file_name: "a.patch",
           body: Base64.encode64("--- a/src/one.c\n+++ b/src/one.c\n@@ -1 +1 @@\n"))
    with_att.patch_submission_files.delete_all

    inline = create(:message, created_at: old,
      body: "patch:\n--- a/src/two.c\n+++ b/src/two.c\n@@ -1 +1 @@\n")
    plain = create(:message, created_at: old, body: "just words")

    outside = create(:message, created_at: old - 1.month,
      body: "patch:\n--- a/src/three.c\n+++ b/src/three.c\n@@ -1 +1 @@\n")

    PatchPathExtractor.backfill(from: old - 1.day, to: old + 1.day, io: StringIO.new)

    expect(with_att.reload.patch_submission_files.pluck(:path)).to eq([ "src/one.c" ])
    expect(inline.reload.patch_submission_files.pluck(:path)).to eq([ "src/two.c" ])
    expect(plain.reload.patch_submission_files).to be_empty
    expect(outside.reload.patch_submission_files).to be_empty
  end
end
