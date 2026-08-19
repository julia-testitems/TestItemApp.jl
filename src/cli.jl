# cli.jl — the `juliati` command line interface

# Filter expressions from `--filter` are evaluated in this module.
module FilterEval end

struct CliError <: Exception
    msg::String
end

const USAGE = """
juliati — run Julia @testitem tests from the command line

Usage:
  juliati [path] [options]         Run all test items found under path (default: current directory)
  juliati --help                   Show this help
  juliati --version                Show version

Options:
  --filter <expr>                Julia expression over `name`, `tags`, `filename`,
                                 `package_name`; only items for which it is true run.
  --timeout <seconds|none>       Per-test-item timeout in seconds (default: 1200).
                                 "none" disables the timeout entirely.
  --profile-name <name>          Profile name recorded in the results (default: "Default").
  --env <KEY=VALUE>              Environment variable for test processes (repeatable).
  --env-json <json>              JSON object of environment variables for test processes;
                                 a null value removes the variable.
  --juliaup-channel <channel>    Set JULIAUP_CHANNEL for test processes.
  --results-json <path>          Write the test run results as JSON to this file.
  --junit-xml <path>             Write the test run results as JUnit XML to this file.
  --progress <bar|log|none>      Progress output style (default: bar).
  --output <issues|all|none>     Which captured test item output to echo to the console:
                                 only failing items (default), every item, or nothing.
  --stream                       Stream test item output live as it is produced. Requires
                                 --max-workers 1.
  --max-workers <n>              Maximum number of parallel test processes.
  --threads <n|auto|n,m>         Value for the test processes' --threads (default: Julia's).
  --coverage                     Run in coverage mode.
  --coverage-lcov <path>         Write the merged coverage of the run to this file in LCOV
                                 format. Implies --coverage.
  --gc-between-testitems         Run a full GC between test items (default when more than
                                 one test process is used).
  --no-gc-between-testitems      Never GC between test items.
  --memory-threshold <frac>      Recycle a test process once system memory use exceeds this
                                 fraction, between 0 and 1 (default: off).
  --schedule <duration|contiguous>
                                 How test items are distributed over test processes:
                                 "duration" (default) orders by measured duration, past
                                 failures and warm setups; "contiguous" is the old
                                 chunk-by-position behavior.
  --failfast                     Stop the run as soon as a test item fails or errors. Test
                                 items that had not started are reported as skipped; ones
                                 already running in another test process are cut short and
                                 do not appear in the results at all.
  --fail-on-detection-error      Do not run any tests if a test item fails to parse (default).
  --no-fail-on-detection-error   Run tests even if some test items fail to parse.
  --julia-cmd <path>             Julia executable used for test processes (default: "julia").
  --check-bounds <auto|yes>      --check-bounds mode for test processes. "auto" (default)
                                 respects @inbounds and reuses existing precompile caches;
                                 "yes" forces bounds checks everywhere (Pkg.test behavior)
                                 but precompiles into a separate cache slot on first run.
  --debug                        Enable debug logging.

Exit codes: 0 all tests passed; 1 test failures or definition errors; 2 usage error.
"""

_cli_error(msg) = throw(CliError(msg))

# Every option that consumes a following value must be listed here, or `--opt=value`
# silently degrades into an unknown option. Options whose value can itself contain '='
# (`--env KEY=VAL`) are the reason the split is whitelist-driven rather than unconditional.
const VALUE_TAKING_OPTIONS = (
    "--filter", "--timeout", "--profile-name", "--env", "--env-json",
    "--juliaup-channel", "--results-json", "--junit-xml", "--progress", "--output",
    "--max-workers", "--threads", "--coverage-lcov", "--memory-threshold", "--schedule",
    "--julia-cmd", "--check-bounds",
)

# There is no timeout at all unless one is asked for, which turns a hung test item into a
# hung CI job. 1200s matches the default of the `julia-run-testitems` action.
const DEFAULT_TIMEOUT = 1200.0

"""
    parse_run_args(args::Vector{String})

Parse the command line arguments into a NamedTuple of run options.
Throws [`CliError`](@ref) on invalid input.
"""
function parse_run_args(args::Vector{String})
    # Accept both `--opt value` and `--opt=value`
    expanded = String[]
    for a in args
        if startswith(a, "--") && occursin('=', a)
            opt, value = split(a, '='; limit=2)
            if opt in VALUE_TAKING_OPTIONS
                push!(expanded, String(opt), String(value))
                continue
            end
        end
        push!(expanded, a)
    end

    path = nothing
    filter_str = nothing
    timeout = DEFAULT_TIMEOUT
    profile_name = "Default"
    env = Dict{String,Any}()
    results_json = nothing
    junit_xml = nothing
    progress = :bar
    output = :issues
    stream = false
    max_workers = DEFAULT_MAX_WORKERS
    threads = nothing
    coverage = false
    coverage_lcov = nothing
    gc_between_testitems = nothing
    memory_threshold = nothing
    schedule = :duration
    fail_on_detection_error = true
    failfast = false
    julia_cmd = "julia"
    check_bounds = nothing
    debug = false

    i = 0
    n = length(expanded)
    function next_value(name)
        i += 1
        i > n && _cli_error("missing value for $name")
        return expanded[i]
    end

    while i < n
        i += 1
        a = expanded[i]
        if a == "--filter"
            filter_str = next_value(a)
        elseif a == "--timeout"
            value = next_value(a)
            if value in ("none", "off")
                timeout = nothing
            else
                timeout = tryparse(Float64, value)
                (timeout === nothing || timeout <= 0) && _cli_error("invalid value for --timeout: $value")
            end
        elseif a == "--profile-name"
            profile_name = next_value(a)
        elseif a == "--env"
            value = next_value(a)
            occursin('=', value) || _cli_error("--env expects KEY=VALUE, got: $value")
            k, v = split(value, '='; limit=2)
            env[String(k)] = String(v)
        elseif a == "--env-json"
            value = next_value(a)
            parsed = try
                JSON.parse(value)
            catch
                _cli_error("invalid JSON for --env-json: $value")
            end
            parsed isa AbstractDict || _cli_error("--env-json expects a JSON object")
            for (k, v) in parsed
                env[String(k)] = v
            end
        elseif a == "--juliaup-channel"
            value = next_value(a)
            isempty(value) || (env["JULIAUP_CHANNEL"] = value)
        elseif a == "--results-json"
            results_json = next_value(a)
        elseif a == "--junit-xml"
            junit_xml = next_value(a)
        elseif a == "--progress"
            value = next_value(a)
            value in ("bar", "log", "none") || _cli_error("invalid value for --progress: $value")
            progress = Symbol(value)
        elseif a == "--output"
            value = next_value(a)
            value in ("issues", "all", "none") || _cli_error("invalid value for --output: $value (expected issues, all or none)")
            output = Symbol(value)
        elseif a == "--stream"
            stream = true
        elseif a == "--max-workers"
            value = next_value(a)
            max_workers = tryparse(Int, value)
            (max_workers === nothing || max_workers < 1) && _cli_error("invalid value for --max-workers: $value")
        elseif a == "--threads"
            value = next_value(a)
            _valid_threads(value) || _cli_error("invalid value for --threads: $value (expected a positive integer, \"auto\", or \"N,M\")")
            threads = value
        elseif a == "--coverage"
            coverage = true
        elseif a == "--coverage-lcov"
            coverage_lcov = next_value(a)
            coverage = true
        elseif a == "--gc-between-testitems"
            gc_between_testitems = true
        elseif a == "--no-gc-between-testitems"
            gc_between_testitems = false
        elseif a == "--memory-threshold"
            value = next_value(a)
            memory_threshold = tryparse(Float64, value)
            (memory_threshold === nothing || !(0 <= memory_threshold <= 1)) &&
                _cli_error("invalid value for --memory-threshold: $value (expected a fraction between 0 and 1)")
        elseif a == "--schedule"
            value = next_value(a)
            value in ("duration", "contiguous") || _cli_error("invalid value for --schedule: $value (expected duration or contiguous)")
            schedule = Symbol(value)
        elseif a == "--failfast"
            failfast = true
        elseif a == "--fail-on-detection-error"
            fail_on_detection_error = true
        elseif a == "--no-fail-on-detection-error"
            fail_on_detection_error = false
        elseif a == "--julia-cmd"
            julia_cmd = next_value(a)
        elseif a == "--check-bounds"
            value = next_value(a)
            value in ("auto", "yes") || _cli_error("invalid value for --check-bounds: $value (expected auto or yes)")
            check_bounds = value
        elseif a == "--debug"
            debug = true
        elseif startswith(a, "-")
            _cli_error("unknown option: $a")
        elseif path === nothing
            path = a
        else
            _cli_error("unexpected argument: $a")
        end
    end

    # Live streaming interleaves output from whichever process happens to write next, so it
    # is only meaningful when there is exactly one of them.
    stream && max_workers != 1 &&
        _cli_error("--stream requires --max-workers 1 (got $max_workers)")

    return (
        path = something(path, pwd()),
        filter_str = filter_str,
        timeout = timeout,
        profile_name = isempty(profile_name) ? "Default" : profile_name,
        env = env,
        results_json = results_json,
        junit_xml = junit_xml,
        progress = progress,
        output = output,
        stream = stream,
        max_workers = max_workers,
        threads = threads,
        coverage = coverage,
        coverage_lcov = coverage_lcov,
        gc_between_testitems = gc_between_testitems,
        memory_threshold = memory_threshold,
        schedule = schedule,
        fail_on_detection_error = fail_on_detection_error,
        failfast = failfast,
        julia_cmd = julia_cmd,
        check_bounds = check_bounds,
        debug = debug,
    )
end

# `--threads` mirrors Julia's own: a positive integer, "auto", or an `N,M` pair naming the
# default and interactive thread pools (either half may be "auto").
function _valid_threads(value::AbstractString)
    isempty(value) && return false
    parts = split(value, ',')
    length(parts) <= 2 || return false
    return all(parts) do p
        p == "auto" && return true
        n = tryparse(Int, p)
        return n !== nothing && n > 0
    end
end

function make_filter(filter_str::AbstractString)
    filter_expr = Meta.parse(filter_str)
    f = Base.eval(FilterEval, :(
        i -> let name = i.name, tags = i.tags, filename = realpath(i.filename), package_name = i.package_name
            $filter_expr
        end
    ))
    return i -> Base.invokelatest(f, i)
end

function run_command(args::Vector{String})::Int
    opts = parse_run_args(args)

    if opts.debug
        ENV["JULIA_DEBUG"] = "TestItemApp,TestItemControllers"
    end

    isdir(opts.path) || _cli_error("no such directory: $(opts.path)")

    result = run_tests(
        opts.path;
        filter = opts.filter_str === nothing ? nothing : make_filter(opts.filter_str),
        max_workers = opts.max_workers,
        timeout = opts.timeout,
        fail_on_detection_error = opts.fail_on_detection_error,
        failfast = opts.failfast,
        progress_ui = opts.progress,
        output_mode = opts.output,
        stream = opts.stream,
        environments = [RunProfile(opts.profile_name, opts.coverage, opts.env)],
        julia_cmd = opts.julia_cmd,
        julia_num_threads = opts.threads,
        check_bounds = opts.check_bounds,
        gc_between_testitems = opts.gc_between_testitems,
        memory_threshold = opts.memory_threshold,
        schedule = opts.schedule,
    )

    if opts.results_json !== nothing
        Results.write_json(opts.results_json, result)
    end

    if opts.junit_xml !== nothing
        # `root` must be absolute: JUnit classnames are relativized against it with
        # `relpath`, which does not resolve a relative root against the working directory.
        TestItemControllers.write_junit_xml(opts.junit_xml, result; root=abspath(opts.path))
    end

    if opts.coverage_lcov !== nothing
        if !TestItemControllers.write_lcov(opts.coverage_lcov, result)
            @warn "No coverage data was collected, $(opts.coverage_lcov) not written"
        end
    end

    any_failed = any(p.status != :passed for ti in result.testitems for p in ti.profiles)
    return (any_failed || !isempty(result.definition_errors)) ? 1 : 0
end

# Running tests is the default action (pytest-style): `juliati [path] [options]`.
# `-i`/`--interactive` is reserved for a future TUI mode.
function real_main(args::Vector{String})::Int
    try
        if !isempty(args) && args[1] in ("-h", "--help", "help")
            println(USAGE)
            return 0
        elseif !isempty(args) && args[1] in ("--version", "version")
            println("juliati $(pkgversion(TestItemApp))")
            return 0
        else
            return run_command(args)
        end
    catch err
        if err isa CliError
            println(stderr, "Error: $(err.msg)")
            return 2
        end
        rethrow()
    end
end
