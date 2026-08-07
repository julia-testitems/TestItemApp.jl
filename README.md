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

`juliati` walks the given folder, finds every `@testitem` (and `@testsetup`), groups them by package, launches parallel test processes and reports the results:

```
  Discovered 24 test item run(s) in 3 file(s)
  Launching test processes....
  Progress: 24/24 (23 passed, 1 failed)

24 tests ran, 23 passed, 1 failed.
```

The exit code is `0` when everything passed, `1` on test failures or definition errors, and `2` on usage errors — so it works directly in CI pipelines.

## Options

| Option | Description |
| --- | --- |
| `--filter <expr>` | Julia expression over `name`, `tags`, `filename`, `package_name`; only items for which it evaluates to `true` are run. |
| `--timeout <seconds>` | Per-test-item timeout (default: no timeout). |
| `--max-workers <n>` | Maximum number of parallel test processes (default: number of CPU threads, capped at 8). |
| `--progress <bar\|log\|none>` | Progress output style (default: `bar`). |
| `--coverage` | Run test processes in coverage mode. |
| `--results-json <path>` | Write the full test run results as JSON to this file. |
| `--profile-name <name>` | Profile name recorded in the results (default: `"Default"`). |
| `--env <KEY=VALUE>` | Environment variable for test processes (repeatable). |
| `--env-json <json>` | JSON object of environment variables for test processes; a `null` value removes the variable. |
| `--juliaup-channel <channel>` | Set `JULIAUP_CHANNEL` for test processes. |
| `--julia-cmd <path>` | Julia executable used for test processes (default: `julia`). |
| `--fail-on-detection-error` / `--no-fail-on-detection-error` | Whether to refuse to run any tests when a test item fails to parse (default: fail). |
| `--debug` | Enable debug logging. |
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

### JSON results

With `--results-json results.json` the complete run — every test item, its status, duration, failure messages with stack traces, and captured output — is written as JSON, suitable for further processing in CI.

## Julia API

The functionality behind the CLI is also available programmatically:

```julia
using TestItemApp

result = run_tests(
    "path/to/MyPackage";
    filter = i -> :fast in i.tags,
    max_workers = 4,
    timeout = 300,
    environments = [RunProfile("Julia 1.12", false, Dict{String,Any}())],
)
```

`run_tests` returns a `TestrunResult` with per-item, per-profile statuses; `RunProfile` describes one named configuration (name, coverage mode, environment variables) under which every test item is run — pass several profiles to run the whole suite once per configuration. See the docstrings of `run_tests` and `RunProfile` for all keyword arguments.

## License

MIT — see [LICENSE](LICENSE).
