# run.jl — the `run_tests` entry point: TestItemRuns plus console reporting

const DEFAULT_MAX_WORKERS = TestItemRuns.DEFAULT_MAX_WORKERS

"""
    RunProfile

Alias of `TestItemRuns.RunProfile`; `RunProfile(name, coverage, env)` still works.
"""
const RunProfile = TestItemRuns.RunProfile

"""
    run_tests(path; kwargs...)::TestrunResult

Discover all `@testitem`s under `path`, run them with console reporting, and return the
aggregated `TestrunResult`. A thin front end over `TestItemRuns.run_tests`.

# Keyword arguments
- `filter` — predicate over `(filename, name, tags, package_name)`; only matching items run.
- `max_workers::Int` — maximum number of parallel test processes.
- `timeout` — per-test-item timeout in seconds, or `nothing` for no timeout.
- `fail_on_detection_error::Bool` — when `true` (default), skip running if any test item
  fails to parse; the errors are reported in the result either way.
- `print_failed_results::Bool`, `print_summary::Bool` — terminal reporting toggles.
- `progress_ui::Symbol` — `:bar`, `:log`, or `:none` (`:none` also silences the toggles above).
- `output_mode::Symbol` — which captured test item output is echoed to the console:
  `:issues` (default, failing items only), `:all`, or `:none`. Output is always captured
  and always attached to the result; this only controls the console echo.
- `stream::Bool` — print test item output as it is produced instead of when the item
  finishes. Only meaningful with a single test process.
- `environments::Vector{RunProfile}` — run every item once per profile.
- `julia_cmd`, `julia_args`, `julia_num_threads` — how to launch test processes.
  `julia_num_threads` is the test processes' `--threads` value (`"4"`, `"auto"`, `"4,1"`).
- `gc_between_testitems::Union{Nothing,Bool}` — run a full GC between test items;
  `nothing` (default) turns it on when more than one test process is used.
- `memory_threshold::Union{Nothing,Float64}` — recycle a test process once system memory
  use exceeds this fraction; `nothing` (default) never recycles.
- `schedule::Symbol` — `:duration` (default) or `:contiguous`.
- `failfast::Bool` — stop at the first failing or errored item; the rest are reported as
  skipped and the run is still a completed one, so it exits like an ordinary failure.
- `log_level::Symbol` — minimum log level for the code under test (`:Debug`, `:Info`
  (default), `:Warn`, `:Error`).
- `activation_timeout` — seconds a test process may spend activating and precompiling its
  environment before its items are errored, or `nothing` for no limit.
- `check_bounds` — `--check-bounds` value for test processes: `"auto"` (or `nothing`, the
  default) respects `@inbounds` annotations and lets test processes reuse the precompile
  caches of normal dev sessions; `"yes"` forces bounds checks everywhere (the `Pkg.test`
  behavior) at the cost of re-precompiling the whole environment into a separate cache
  slot on the first run.
- `token` — optional cancellation token; a cancelled run returns its partial result.
- `log_min_level` — minimum level for log records emitted while the run is active
  (default `Logging.Warn`, which hides the controller's info-level lifecycle messages;
  `JULIA_DEBUG` overrides still apply).
"""
run_tests(path; kwargs...) = first(_run_tests_reported(path; kwargs...))

# Returns `(result, reporter)`; the reporter knows whether the run was cancelled.
function _run_tests_reported(
        path;
        filter = nothing,
        max_workers::Int = DEFAULT_MAX_WORKERS,
        timeout = nothing,
        fail_on_detection_error::Bool = true,
        print_failed_results::Bool = true,
        print_summary::Bool = true,
        progress_ui::Symbol = :bar,
        output_mode::Symbol = :issues,
        stream::Bool = false,
        environments::Vector{RunProfile} = [RunProfile("Default", false, Dict{String,Any}())],
        julia_cmd::String = "julia",
        julia_args::Vector{String} = String[],
        julia_num_threads::Union{Nothing,String} = nothing,
        check_bounds::Union{Nothing,String} = nothing,
        gc_between_testitems::Union{Nothing,Bool} = nothing,
        memory_threshold::Union{Nothing,Float64} = nothing,
        schedule::Symbol = :duration,
        failfast::Bool = false,
        log_level::Symbol = :Info,
        activation_timeout = nothing,
        token = nothing,
        store_path::Union{Nothing,String} = nothing,
        log_min_level = Logging.Warn,
    )
    path = abspath(path)
    progress_ui in (:bar, :log, :none) || error("progress_ui must be :bar, :log or :none")
    output_mode in (:issues, :all, :none) || error("output_mode must be :issues, :all or :none")
    schedule in (:duration, :contiguous) || error("schedule must be :duration or :contiguous")
    log_level in (:Debug, :Info, :Warn, :Error) || error("log_level must be :Debug, :Info, :Warn or :Error")
    if progress_ui == :none
        print_summary = false
        print_failed_results = false
    end

    # The legacy filter contract: a NamedTuple, evaluated with the run path as working
    # directory (filter expressions may use relative paths).
    item_filter = filter === nothing ? nothing :
        item -> cd(path) do
            filter((filename = item.filename, name = item.name, tags = item.tags, package_name = item.package_name))
        end

    reporter = ConsoleReporter(progress_ui, output_mode, stream)

    # juliati runs once and exits, so it owns its session and shuts the test processes down
    # before returning rather than sharing the process-wide default session.
    session = TestItemRuns.TestSession(;
        schedule = schedule,
        activation_timeout_seconds = activation_timeout,
        log_min_level = log_min_level,
    )
    result = try
        TestItemRuns.run_tests(session, path;
            filter = item_filter,
            on_event = reporter,
            profiles = environments,
            max_workers = max_workers,
            timeout = timeout,
            fail_on_definition_error = fail_on_detection_error,
            failfast = failfast,
            log_level = log_level,
            julia_cmd = julia_cmd,
            julia_args = julia_args,
            julia_num_threads = julia_num_threads,
            check_bounds = check_bounds,
            gc_between_testitems = gc_between_testitems,
            memory_threshold = memory_threshold,
            token = token,
            store_path = store_path,
            log_min_level = log_min_level,
        )
    finally
        close(session)
    end

    print_summary && print_summary!(reporter, result)
    print_failed_results && print_failures!(reporter, result)

    return result, reporter
end
