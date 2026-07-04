require "rails_helper"

RSpec.describe HackorumCommits::CommitParser do
  def parse(fixture)
    text = File.read(Rails.root.join("spec/fixtures/hackorum_commits/#{fixture}"))
    subject, body = text.split("\n", 2)
    described_class.new(
      subject: subject, body: body,
      committer_name: "Andrew Dunstan", committer_email: "andrew@example.com"
    ).parse
  end

  it "extracts people trailers as facts" do
    result = parse("modern_commit.txt")
    kinds = result.facts.group_by { |f| f[:kind] }
    expect(kinds["reviewer"].map { |f| f[:value] }).to include(a_string_including("Jane Reviewer"))
    expect(kinds["reported_by"].first[:value]).to include("Bob Reporter")
    expect(kinds["co_author"].first[:value]).to include("Carol Coder")
    expect(kinds["author"].first[:value]).to include("Dan Dev")
    expect(kinds["reviewer"].first[:method]).to eq("trailer")
    expect(kinds["reviewer"].first[:confidence]).to eq(1.0)
  end

  it "extracts a committer fact" do
    result = parse("modern_commit.txt")
    committer = result.facts.find { |f| f[:kind] == "committer" }
    expect(committer[:value]).to include("Andrew Dunstan")
  end

  it "labels committer fact with method git_metadata" do
    result = parse("modern_commit.txt")
    committer = result.facts.find { |f| f[:kind] == "committer" }
    expect(committer[:method]).to eq("git_metadata")
  end

  it "does not produce fixes_commit facts for modern_commit.txt (no cross-line match)" do
    result = parse("modern_commit.txt")
    fixes = result.facts.select { |f| f[:kind] == "fixes_commit" }
    expect(fixes).to be_empty
  end

  it "extracts a tested_by fact from Tested-by trailer" do
    result = parse("modern_commit.txt")
    tested = result.facts.find { |f| f[:kind] == "tested_by" }
    expect(tested).not_to be_nil
    expect(tested[:value]).to include("Tina Tester")
  end

  it "extracts discussion message-ids (bare ids, multiple forms)" do
    result = parse("cve_commit.txt")
    expect(result.message_ids).to contain_exactly("abc-123@example.com", "def-456@example.com")
  end

  it "detects CVE and fixes-commit references" do
    result = parse("cve_commit.txt")
    cve = result.facts.find { |f| f[:kind] == "cve" }
    fixes = result.facts.find { |f| f[:kind] == "fixes_commit" }
    expect(cve[:value]).to eq("CVE-2025-1234")
    expect(fixes[:value]).to eq("deadbeefcafe1234")
  end

  it "classifies 'cherry picked from commit' as cherry_picked_from, not fixes_commit" do
    result = HackorumCommits::CommitParser.new(
      subject: "Some backport",
      body: "(cherry picked from commit abcdef1234567890)",
      committer_name: "C", committer_email: "c@x"
    ).parse
    expect(result.facts.select { |f| f[:kind] == "fixes_commit" }).to be_empty
    cherry = result.facts.find { |f| f[:kind] == "cherry_picked_from" }
    expect(cherry[:value]).to eq("abcdef1234567890")
  end

  it "still classifies 'fix for commit' as fixes_commit" do
    result = HackorumCommits::CommitParser.new(
      subject: "Repair oversight",
      body: "This is the fix for commit deadbeefcafe1234.",
      committer_name: "C", committer_email: "c@x"
    ).parse
    fixes = result.facts.find { |f| f[:kind] == "fixes_commit" }
    expect(fixes[:value]).to eq("deadbeefcafe1234")
    expect(result.facts.select { |f| f[:kind] == "cherry_picked_from" }).to be_empty
  end

  describe "discussion message-id extraction" do
    {
      "https://postgr.es/m/abc@x"                              => "abc@x",
      "https://postgr.es/message-id/abc@x"                     => "abc@x",
      "https://www.postgresql.org/message-id/abc@x"            => "abc@x",
      "https://www.postgresql.org/message-id/flat/abc@x"       => "abc@x",
      "https://postgr.es/message-id/flat/abc@x"                => "abc@x",
      "http://postgre.es/m/abc@x"                              => "abc@x",
      "see https://postgr.es/m/abc@x."                         => "abc@x"
    }.each do |url, expected|
      it "extracts #{expected} from #{url}" do
        parser = HackorumCommits::CommitParser.new(
          subject: "Fix things", body: "Discussion: #{url}\n",
          committer_name: "C", committer_email: "c@x"
        )
        expect(parser.message_ids).to eq([ expected ])
      end
    end
  end
end
