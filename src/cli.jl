# cli.jl — the `juliati` command line interface

# Filter expressions from `--filter` are evaluated in this module.
module FilterEval end

struct CliError <: Exception
    msg::String
end

const USAGE = """
juliati — run Julia @testitem tests from the command line

Usage:
  juliati run [path] [options]     Run all test items found under path (default: current directory)
  juliati --help                   Show this help
  juliati --version                Show version

Options for `run`:
  --filter <expr>                Julia expression over `name`, `tags`, `filename`,
                                 `package_name`; only items for which it is true run.
  --timeout <seconds>            Per-test-item timeout (default: no timeout).
  --profile-name <name>          Profile name recorded in the results (default: "Default").
  --env <KEY=VALUE>              Environment variable for test processes (repeatable).
  --env-json <json>              JSON object of environment variables for test processes;
                                 a null value removes the variable.
  --juliaup-channel <channel>    Set JULIAUP_CHANNEL for test processes.
  --results-json <path>          Write the test run results as JSON to this file.
  --progress <bar|log|none>      Progress output style (default: bar).
  --max-workers <n>              Maximum number of parallel test processes.
  --coverage                     Run in coverage mode.
  --fail-on-detection-error      Do not run any tests if a test item fails to parse (default).
  --no-fail-on-detection-error   Run tests even if some test items fail to parse.
  --julia-cmd <path>             Julia executable used for test processes (default: "julia").
  --debug                        Enable debug logging.

Exit codes: 0 all tests passed; 1 test failures or definition errors; 2 usage error.
"""

_cli_error(msg) = throw(CliError(msg))

"""
    parse_run_args(args::Vector{String})

Parse the arguments of the `run` subcommand into a NamedTuple of options.
Throws [`CliError`](@ref) on invalid input.
"""
function parse_run_args(args::Vector{String})
    # Accept both `--opt value` and `--opt=value`
    expanded = String[]
    for a in args
        if startswith(a, "--") && occursin('=', a)
            opt, value = split(a, '='; limit=2)
            # Options whose value itself contains '=' (--env KEY=VAL) must not be split twice,
            # so only split when the part before '=' is a known value-taking option.
            if opt in ("--filter", "--timeout", "--profile-name", "--env", "--env-json",
                "--juliaup-channel", "--results-json", "--progress", "--max-workers", "--julia-cmd")
                push!(expanded, String(opt), String(value))
                continue
            end
        end
        push!(expanded, a)
    end

    path = nothing
    filter_str = nothing
    timeout = nothing
    profile_name = "Default"
    env = Dict{String,Any}()
    results_json = nothing
    progress = :bar
    max_workers = DEFAULT_MAX_WORKERS
    coverage = false
    fail_on_detection_error = true
    julia_cmd = "julia"
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
            timeout = tryparse(Float64, value)
            timeout === nothing && _cli_error("invalid value for --timeout: $value")
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
        elseif a == "--progress"
            value = next_value(a)
            value in ("bar", "log", "none") || _cli_error("invalid value for --progress: $value")
            progress = Symbol(value)
        elseif a == "--max-workers"
            value = next_value(a)
            max_workers = tryparse(Int, value)
            (max_workers === nothing || max_workers < 1) && _cli_error("invalid value for --max-workers: $value")
        elseif a == "--coverage"
            coverage = true
        elseif a == "--fail-on-detection-error"
            fail_on_detection_error = true
        elseif a == "--no-fail-on-detection-error"
            fail_on_detection_error = false
        elseif a == "--julia-cmd"
            julia_cmd = next_value(a)
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

    return (
        path = something(path, pwd()),
        filter_str = filter_str,
        timeout = timeout,
        profile_name = isempty(profile_name) ? "Default" : profile_name,
        env = env,
        results_json = results_json,
        progress = progress,
        max_workers = max_workers,
        coverage = coverage,
        fail_on_detection_error = fail_on_detection_error,
        julia_cmd = julia_cmd,
        debug = debug,
    )
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
        progress_ui = opts.progress,
        environments = [RunProfile(opts.profile_name, opts.coverage, opts.env)],
        julia_cmd = opts.julia_cmd,
    )

    if opts.results_json !== nothing
        Results.write_json(opts.results_json, result)
    end

    any_failed = any(p.status != :passed for ti in result.testitems for p in ti.profiles)
    return (any_failed || !isempty(result.definition_errors)) ? 1 : 0
end

function real_main(args::Vector{String})::Int
    try
        if isempty(args) || args[1] in ("-h", "--help", "help")
            println(isempty(args) ? stderr : stdout, USAGE)
            return isempty(args) ? 2 : 0
        elseif args[1] in ("--version", "version")
            println("juliati $(pkgversion(TestItemApp))")
            return 0
        elseif args[1] == "run"
            return run_command(args[2:end])
        else
            println(stderr, "Unknown command: $(args[1])\n")
            println(stderr, USAGE)
            return 2
        end
    catch err
        if err isa CliError
            println(stderr, "Error: $(err.msg)")
            return 2
        end
        rethrow()
    end
end
