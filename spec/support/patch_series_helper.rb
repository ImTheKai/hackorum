# Generates real patches with git itself, so index hashes are correct.
module PatchSeriesHelper
  IDENT = [ "-c", "user.name=t", "-c", "user.email=t@example.com" ].freeze

  # Commits new_content for path on top of from_sha (detached HEAD), writes
  # the format-patch mbox into out_dir, returns the patch path. Leaves the
  # repo back on master.
  def generate_patch(repo_path, from_sha, path, new_content, out_dir, subject: "change")
    git = PatchBranches::GitRepo.new(repo_path)
    git.run!("checkout", "--quiet", "--detach", from_sha)
    File.write(File.join(repo_path, path), new_content)
    git.run!(*IDENT, "commit", "-aqm", subject)
    patch = git.run!("format-patch", "-1", "-o", out_dir, "HEAD").stdout.strip
    git.run!("checkout", "--quiet", "--force", "master")
    patch
  end

  # Commits new_content_1 then new_content_2 for path on top of from_sha
  # (detached HEAD), writes a 2-patch format-patch series into out_dir.
  # Returns both patch paths, sorted (0001 before 0002).
  def generate_patch_series(repo_path, from_sha, path, new_content_1, new_content_2, out_dir, subject: "change")
    git = PatchBranches::GitRepo.new(repo_path)
    git.run!("checkout", "--quiet", "--detach", from_sha)
    full = File.join(repo_path, path)
    File.write(full, new_content_1)
    git.run!(*IDENT, "commit", "-aqm", "#{subject} 1")
    File.write(full, new_content_2)
    git.run!(*IDENT, "commit", "-aqm", "#{subject} 2")
    patches = git.run!("format-patch", "-2", "-o", out_dir, "HEAD").stdout.split("\n").map(&:strip).sort
    git.run!("checkout", "--quiet", "--force", "master")
    patches
  end

  # Bare diff (no mbox headers) between two shas.
  def generate_diff(repo_path, from_sha, to_sha, out_dir)
    git = PatchBranches::GitRepo.new(repo_path)
    diff = git.run!("diff", from_sha, to_sha).stdout
    path = File.join(out_dir, "change.diff")
    File.write(path, diff)
    path
  end
end
