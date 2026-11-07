# Testing

Run from any directory with `sh /path/to/checkout/tests/run.sh`. Python 3.9+
and Neovim are required; `NVIM_BIN` selects the executable (`NVIM` is an RPC
address inside Neovim jobs and is not an executable override).

```sh
sh tests/run.sh                     # Default offline suites
sh tests/run.sh --list              # List selected registered commands
sh tests/run.sh --check             # Reject missing or unregistered test files
sh tests/run.sh unit --filter setup # Focus on a named case
sh tests/run.sh --keep              # Keep successful runs as well as failures
sh tests/run.sh --output /tmp/new-test-run # New, retained artifact directory
```

Available suites: `acceptance`, `unit`. Default suites: `unit`.
Select a suite explicitly, or use a comma-separated list. `all` includes offline
and cross-plugin suites, including parser suites; it excludes `acceptance*`,
`compatibility` and benchmarks. Nonselected suites are printed, not silently
counted as passed. Explicitly selected cases fail when their required fixtures
or tools are missing. Install dependencies separately; running tests never
downloads plugins, parsers or language servers.

`tests/cases.json` is the executable source of truth. Every Lua/Python/shell file
under `tests/` must be registered as a case, named support fixture or documented
manual check. Keep benchmark, interactive-terminal, historical-configuration
and network acceptance checks out of the default suites. Configuration-specific
keys, selections and cross-plugin workflows also belong in the configuration
repository's integration suite.

Every registered case gets a fresh process, data/config/cache/state/runtime and
temporary directories. Independent failures do not prevent later cases from
running. Each case has a deadline; timeouts stop its process groups, including
PTY children that create sessions. Failed runs retain `summary.json`, per-case
`output.log`, and the Neovim logs/state written into the case directory. UI
fixtures that manage their own temporary directories still control their own
screenshots/transcripts; include the last relevant frame in failure messages.
`--output` refuses to overwrite an existing directory. CI should always upload
that directory, including when testing fails.

The standard-library-only runner and its regression checks are vendored in each
plugin to keep standalone checkouts independent from personal configuration and
runtime plugin-manager initialization. `cases.json` and behavior assertions
remain owned by this repository. After editing a runner, run its regression
checks and the affected real suites. Avoid bulk changes to behavior assertions
merely to make a runner migration pass.

Cross-plugin revisions are recorded under `fixtures` in `cases.json`. Inspect
those pins before explicitly installing them into absent sibling directories:

```sh
python3 tests/run.py fixtures        # Explicit network operation; never automatic
sh tests/run.sh all --locked         # Exact, clean dependency revisions
```

Installation refuses to replace any existing checkout at a different revision
or with local changes. Local development can omit `--locked`; summaries record
the actual fixture revisions and dirty state. Publish pinned dependency commits
before publishing a consumer CI change that fetches them. Optional third-party
compatibility adapters still require their documented environment paths.

The complete TeX suite requires `TEX_TOOLS_TEST_PARSER=/absolute/path/latex.so`.
CI builds the pinned LaTeX grammar first. Behavior cases clean up their own
buffers after each test so repeated setup/ownership checks do not accumulate
hundreds of unrelated mapped buffers.

The canonical runner copies live in `plugin-tools.nvim/tests/`. Maintainers can
run `python3 scripts/sync-test-runner.py --check` there to detect drift, or use
`--write` to refresh sibling copies without changing their case manifests.

## Documentation checks

`python3 tests/run.py unit --filter docs` checks local Markdown links and fragments,
README Lua syntax, help entry points and isolated native setup. It does not
download dependencies or write generated tags into the checkout. The canonical
checker is maintained with the shared runner in plugin-tools.nvim.
