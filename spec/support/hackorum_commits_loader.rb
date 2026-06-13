# Loads the internal script once so its classes are available to specs.
# The script guards its CLI entry with `if $PROGRAM_NAME == __FILE__`, so
# `load` defines classes without running the CLI.
SCRIPT_PATH = File.expand_path("../../script/hackorum_commits.rb", __dir__)
load SCRIPT_PATH unless defined?(HackorumCommits::VERSION)
