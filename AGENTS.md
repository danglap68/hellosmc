# Running tests

- Always run RSpec through `bin/parallel_rspec` (the `parallel_tests` runner), including focused files, regression checks and individual examples. Do not run ordinary `bundle exec rspec` or invoke `RSpec::Core::Runner` directly unless the user explicitly requests sequential debugging.
- With this machine's rbenv setup, use `rbenv exec ruby bin/parallel_rspec`. Full suite: `rbenv exec ruby bin/parallel_rspec`. Focused scope: append spec paths. Individual example: append `spec/path/example_spec.rb:LINE`. RSpec options: use `-o '--example description'`.
- On first use, after schema changes, or when adding workers, pass `--prepare`. This creates/reloads numbered test databases from `db/schema.rb`; subsequent runs omit it to avoid unnecessary setup. Migrate the development database separately only when the task requires it.
- Default: up to 4 workers. Override with `PARALLEL_TEST_PROCESSORS=2` (or another positive integer), and pass `--prepare` when the added worker databases do not exist. Use this environment variable rather than `-n` so preparation and execution use the same count.
- Workers use separate `hellosmc_test1`, `hellosmc_test2`, etc., `tmp/storage1`, `tmp/storage2`, etc., and `log/test1.log`, `log/test2.log`, etc. Keep new test fixtures and temporary outputs isolated per worker. Do not set `DATABASE_URL` for tests; use `DB_*` connection variables.
- If parallel tests fail, fix isolation/setup or report the blocker; do not silently fall back to sequential RSpec. A single file/example still uses the parallel runner, although file-level parallelism cannot speed up one file.
- Run the affected specs first. Run the full suite when the change warrants it. CI must also use `bin/parallel_rspec`.
