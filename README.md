# TestItemApp.jl

A command line test runner for Julia [`@testitem`](https://github.com/julia-sciml/TestItems.jl) tests. It installs a `juliati` executable that discovers all test items in a folder and runs them in parallel test processes — no editor required.

Test item discovery is powered by [JuliaWorkspaces.jl](https://github.com/julia-vscode/JuliaWorkspaces.jl) and execution by [TestItemControllers.jl](https://github.com/julia-vscode/TestItemControllers.jl), the same infrastructure that runs test items in the [Julia VS Code extension](https://www.julia-vscode.org/).

## Installation

TestItemApp is a [Julia app](https://pkgdocs.julialang.org/dev/apps/) and requires Julia 1.12 or newer:

```julia
using Pkg
Pkg.Apps.add("TestItemApp")
```

This installs the `juliati` executable into `~/.julia/bin`. Make sure that directory is on your `PATH`.

## Usage

Run all test items in the current directory:

```
juliati
```

Or point it at a package folder:

```
juliati path/to/MyPackage
```

`juliati` walks the given folder, finds every `@testitem` (along with the `@testmodule`s and `@testsnippet`s they take a dependency on via `setup`), groups them by package, launches parallel test processes and reports the results:

```
  Discovered 24 test items in 3 files
  Launching 4 test processes...
  Progress: 24/24 (23 passed, 1 failed)

24 tests ran, 23 passed, 1 failed.
```

The exit code is `0` when everything passed, `1` on test failures or definition errors, and `2` on usage errors — so it works directly in CI pipelines.

## Options

| Option | Description |
| --- | --- |
| `--filter <expr>` | Julia expression over `name`, `tags`, `filename`, `package_name`; only items for which it evaluates to `true` are run. |
| `--timeout <seconds\|none>` | Per-test-item timeout in seconds (default: `1200`). `none` disables it. |
| `--max-workers <n>` | Maximum number of parallel test processes (default: number of CPU threads, capped at 8). |
| `--threads <n\|auto\|n,m>` | Value for the test processes' `--threads` (default: Julia's own default). |
| `--progress <bar\|log\|none>` | Progress output style (default: `bar`). |
| `--output <issues\|all\|none>` | Which captured test item output is echoed to the console: only failing items (default), every item, or nothing. Output is always captured into the results regardless. |
| `--stream` | Print test item output live as it is produced instead of when the item finishes. Requires `--max-workers 1`. |
| `--coverage` | Run test processes in coverage mode. |
| `--coverage-lcov <path>` | Write the merged coverage of the run to this file in LCOV format. Implies `--coverage`. |
| `--gc-between-testitems` / `--no-gc-between-testitems` | Run a full GC between test items. On by default when more than one test process is used. |
| `--memory-threshold <frac>` | Recycle a test process once system memory use exceeds this fraction (0–1). Off by default. |
| `--schedule <duration\|contiguous>` | How test items are distributed over test processes. `duration` (default) orders by measured duration, past failures and warm setups; `contiguous` chunks by position. |
| `--results-json <path>` | Write the full test run results as JSON to this file. |
| `--junit-xml <path>` | Write the test run results as JUnit XML to this file. |
| `--profile-name <name>` | Profile name recorded in the results (default: `"Default"`). |
| `--env <KEY=VALUE>` | Environment variable for test processes (repeatable). |
| `--env-json <json>` | JSON object of environment variables for test processes; a `null` value removes the variable. |
| `--juliaup-channel <channel>` | Set `JULIAUP_CHANNEL` for test processes. |
| `--julia-cmd <path>` | Julia executable used for test processes (default: `julia`). |
| `--check-bounds <auto\|yes>` | `--check-bounds` mode for test processes. `auto` (default) respects `@inbounds` and reuses existing precompile caches; `yes` forces bounds checks everywhere (the `Pkg.test` behavior) but precompiles the environment into a separate cache slot on the first run. |
| `--fail-on-detection-error` / `--no-fail-on-detection-error` | Whether to refuse to run any tests when a test item fails to parse (default: fail). |
| `--log-level <debug\|info\|warn\|error>` | Minimum log level for the code under test — the package and the test item bodies (default: `info`). |
| `--debug` | Enable debug logging for the test infrastructure itself (TestItemApp and TestItemControllers). Says nothing about the code under test; use `--log-level` for that. |
| `--help`, `--version` | Show help / version. |

Options can be written as `--opt value` or `--opt=value`.

### Filtering

`--filter` takes an arbitrary Julia expression that is evaluated for each test item with the variables `name`, `tags`, `filename` and `package_name` in scope:

```sh
# Run a single test item by name
juliati --filter 'name == "my testitem"'

# Run everything tagged :fast that is not tagged :windows
juliati --filter ':fast in tags && !(:windows in tags)'

# Run only test items from one file
juliati --filter 'endswith(filename, "test_parsing.jl")'
```

### Test item output

Every test item's captured output always reaches `--results-json` and `--junit-xml`. `--output` only controls what is echoed to the console: `issues` (the default) prints it alongside the failure detail of failing items, `all` prints it for every item as it finishes, and `none` prints none of it.

For debugging a single test item, `--stream` prints its output as it happens rather than after it finishes. Because output from several test processes would interleave arbitrarily, it requires `--max-workers 1`:

```sh
juliati --filter 'name == "the slow one"' --max-workers 1 --stream --progress log
```

### Log levels

Two separate things can be called "debug logging", and `juliati` keeps them on separate flags:

- `--log-level` sets the minimum level for **the code under test** — your package and the test item bodies. `--log-level debug` makes every `@debug` in them visible, without you having to name any module.
- `--debug` turns on debug logging for **the test infrastructure itself** (TestItemApp and TestItemControllers): process launches, scheduling, timeouts. Reach for it when a run hangs or a test process dies, not when you want to see your own package's logging.

```sh
# Show my package's @debug output for one test item
juliati --filter 'name == "the flaky one"' --log-level debug --max-workers 1
```

`--log-level` applies a `ConsoleLogger` around the test item, so it raises the level for everything the item runs. `JULIA_DEBUG` still works if you want to scope debug output to specific modules instead — pass it through to the test processes with `--env JULIA_DEBUG=MyPkg`.

### Reports

With `--results-json results.json` the complete run — every test item, its status, duration, performance statistics, failure messages with stack traces, and captured output — is written as JSON, suitable for further processing in CI.

`--junit-xml junit.xml` writes the same run as JUnit XML, which most CI systems ingest natively: one `<testsuite>` per source file, one `<testcase>` per (test item, profile), with captured output in `<system-out>` and per-item performance statistics as `<properties>`.

### Coverage

`--coverage` runs the test processes with coverage instrumentation, attributed per test item, and `--coverage-lcov lcov.info` writes the merged result in LCOV format for Codecov, Coveralls, `genhtml` and friends:

```sh
juliati --coverage-lcov lcov.info
```

### Memory and scheduling

Test processes are pooled and outlive a single run, so long sessions benefit from `--gc-between-testitems` (on by default with more than one worker) and `--memory-threshold 0.9`, which recycles a test process once system memory use crosses that fraction.

`--schedule duration` (the default) orders test items by their measured duration, past failures and which test process already has their `@testmodule`s warm. `--schedule contiguous` restores the previous chunk-by-position behavior if that ordering ever misbehaves.

## License

MIT — see [LICENSE](LICENSE).
