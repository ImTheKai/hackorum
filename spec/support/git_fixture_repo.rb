require "open3"
require "fileutils"

# Builds a throwaway git repository for CommitImport specs. Real git, fixed
# dates, so output is deterministic.
class GitFixtureRepo
  attr_reader :path

  def initialize(path)
    @path = path.to_s
    FileUtils.mkdir_p(@path)
    git("init", "--quiet", "--initial-branch=master")
    git("config", "user.name", "Fixture Committer")
    git("config", "user.email", "fixture@example.com")
  end

  def commit(subject:, body: "", files: nil, date: "2026-01-01T00:00:00+00:00",
             author_name: "Fixture Author", author_email: "author@example.com")
    files ||= { "src/backend/executor/execMain.c" => SecureRandom.hex(4) }
    files.each do |rel, content|
      full = File.join(@path, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      git("add", "--", rel)
    end

    message = body.to_s.empty? ? subject : "#{subject}\n\n#{body}"
    env = {
      "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date,
      "GIT_AUTHOR_NAME" => author_name, "GIT_AUTHOR_EMAIL" => author_email
    }
    git_with_env(env, "commit", "--quiet", "--allow-empty", "-m", message)
    head
  end

  def create_branch(name)
    git("branch", name)
  end

  def checkout(name)
    git("checkout", "--quiet", name)
  end

  def tag(name)
    git("tag", name)
  end

  def head
    git("rev-parse", "HEAD").strip
  end

  def mirror_to(target)
    out, err, status = Open3.capture3("git", "clone", "--quiet", "--mirror", @path, target.to_s)
    raise "git clone failed: #{err}#{out}" unless status.success?
    target.to_s
  end

  def clone_to(target)
    out, err, status = Open3.capture3("git", "clone", "--quiet", @path, target.to_s)
    raise "git clone failed: #{err}#{out}" unless status.success?
    target.to_s
  end

  private

  def git(*args)
    git_with_env({}, *args)
  end

  def git_with_env(env, *args)
    out, err, status = Open3.capture3(env, "git", "-C", @path, *args)
    raise "git #{args.join(' ')} failed: #{err}#{out}" unless status.success?
    out
  end
end
