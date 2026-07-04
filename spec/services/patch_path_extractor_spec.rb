require "rails_helper"

RSpec.describe PatchPathExtractor do
  describe ".paths_from_text" do
    it "extracts unified diff paths and strips a/ b/ prefixes" do
      text = <<~DIFF
        diff --git a/src/backend/commands/copy.c b/src/backend/commands/copy.c
        --- a/src/backend/commands/copy.c
        +++ b/src/backend/commands/copy.c
        @@ -1,3 +1,4 @@
      DIFF
      expect(described_class.paths_from_text(text)).to eq([ "src/backend/commands/copy.c" ])
    end

    it "extracts context diff paths and drops hunk line ranges" do
      text = <<~DIFF
        *** src/bin/psql/describe.c	2009-01-01 10:00:00
        --- src/bin/psql/describe.c	2009-01-02 10:00:00
        ***************
        *** 120,126 ****
        --- 120,128 ----
      DIFF
      expect(described_class.paths_from_text(text)).to eq([ "src/bin/psql/describe.c" ])
    end

    it "extracts Index: lines and re-anchors absolute-ish prefixes at src/" do
      text = "Index: pgsql/src/interfaces/ecpg/ecpglib/connect.c\n"
      expect(described_class.paths_from_text(text)).to eq([ "src/interfaces/ecpg/ecpglib/connect.c" ])
    end

    it "rejects /dev/null and tokens without slash or dot" do
      text = "--- /dev/null\n+++ b/contrib/new/file.c\n--- somethingweird\n"
      expect(described_class.paths_from_text(text)).to eq([ "contrib/new/file.c" ])
    end
  end

  describe ".call" do
    it "extracts from a plain patch attachment" do
      msg = create(:message)
      create(:attachment, message: msg, file_name: "fix.patch",
             body: Base64.encode64("--- a/src/foo.c\n+++ b/src/foo.c\n@@ -1 +1 @@\n"))
      expect(described_class.call(msg.reload)).to eq([ "src/foo.c" ])
    end

    it "gunzips .gz attachments" do
      gz = StringIO.new
      w = Zlib::GzipWriter.new(gz)
      w.write("--- a/src/bar.c\n+++ b/src/bar.c\n@@ -1 +1 @@\n")
      w.close
      msg = create(:message)
      create(:attachment, message: msg, file_name: "fix.patch.gz",
             body: Base64.encode64(gz.string))
      expect(described_class.call(msg.reload)).to eq([ "src/bar.c" ])
    end

    it "returns no paths for corrupt gzip without raising" do
      msg = create(:message)
      create(:attachment, message: msg, file_name: "fix.patch.gz",
             body: Base64.encode64("not gzip at all"))
      expect(described_class.call(msg.reload)).to eq([])
    end

    it "extracts inline diffs from the body when diff structure is present" do
      msg = create(:message,
        body: "Here is my patch:\n\n--- a/src/inline.c\n+++ b/src/inline.c\n@@ -1 +1 @@\n-x\n+y\n")
      expect(described_class.call(msg)).to eq([ "src/inline.c" ])
    end

    it "ignores bodies that merely contain a --- separator line" do
      msg = create(:message, body: "some text\n--- \nsignature here\n")
      expect(described_class.call(msg)).to eq([])
    end
  end
end
