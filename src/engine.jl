# engine.jl — discover test items with JuliaWorkspaces and run them with TestItemControllers

const DEFAULT_MAX_WORKERS = min(Sys.CPU_THREADS, 8)

"""
    RunProfile

One named configuration under which every test item is run.

# Fields
- `name::String` — profile name, recorded in the results (e.g. `"Julia 1.12.0~x64:ubuntu-latest"`).
- `coverage::Bool` — run in coverage mode.
- `env::Dict{String,Any}` — environment variables for the test processes. A `nothing`
  value removes the variable from the child environment.
"""
struct RunProfile
    name::String
    coverage::Bool
    env::Dict{String,Any}
end

# `position_at` returned a `(line, column)` tuple in older JuliaWorkspaces versions
# and now returns a `Position`. Accept either.
_line(pos) = hasproperty(pos, :line) ? pos.line : pos[1]
_column(pos) = hasproperty(pos, :column) ? pos.column : pos[2]

function _display_path(uri::AbstractString)
    path = try
        TestItemControllers.uri2filepath(uri)
    catch
        nothing
    end
    return path === nothing ? uri : path
end

mutable struct RunContext
    testitems_by_id::Dict{String,TestItemControllers.TestItemDetail}
    profile_name_by_env_id::Dict{String,String}
    progress_ui::Symbol
    progressbar_next::Function
    count_success::Int
    count_fail::Int
    count_error::Int
    count_skipped::Int
    responses::Vector{Any}
    outputs::Dict{Tuple{String,String},Vector{String}}   # (testitem_id, test_env_id) → output chunks
    process_outputs::Dict{String,Vector{String}}
    launch_header_printed::Bool
    lock::ReentrantLock
end

function _make_callbacks(ctx::RunContext)
    function record_result(testitem_id, test_env_id, status, messages, duration)
        lock(ctx.lock) do
            testitem = ctx.testitems_by_id[testitem_id]
            profile_name = get(ctx.profile_name_by_env_id, test_env_id, "Default")
            status == :passed && (ctx.count_success += 1)
            status == :failed && (ctx.count_fail += 1)
            status == :errored && (ctx.count_error += 1)
            status == :skipped && (ctx.count_skipped += 1)
            if ctx.progress_ui == :log
                symbol = status == :passed ? "✓" : status == :skipped ? "⊘" : "✗"
                duration_string = duration !== nothing ? " ($(duration)ms)" : ""
                println("$symbol $profile_name $(_display_path(testitem.uri)):$(testitem.label) → $status$duration_string")
            end
            ctx.progress_ui == :bar && ctx.progressbar_next()
            push!(ctx.responses, (
                testitem = testitem,
                test_env_id = test_env_id,
                profile_name = profile_name,
                result = (status = status, messages = messages, duration = duration),
            ))
        end
    end

    TestItemControllers.ControllerCallbacks(
        on_testitem_started = (testrun_id, testitem_id, test_env_id) -> nothing,
        on_testitem_passed = (testrun_id, testitem_id, test_env_id, duration) ->
            record_result(testitem_id, test_env_id, :passed, nothing, duration),
        on_testitem_failed = (testrun_id, testitem_id, test_env_id, messages, duration) ->
            record_result(testitem_id, test_env_id, :failed, messages, duration),
        on_testitem_errored = (testrun_id, testitem_id, test_env_id, messages, duration) ->
            record_result(testitem_id, test_env_id, :errored, messages, duration),
        on_testitem_skipped = (testrun_id, testitem_id, test_env_id) ->
            record_result(testitem_id, test_env_id, :skipped, nothing, nothing),
        on_append_output = (testrun_id, testitem_id, test_env_id, output) -> begin
            testitem_id === nothing && return  # process-level output; captured by on_process_output
            lock(ctx.lock) do
                push!(get!(Vector{String}, ctx.outputs, (testitem_id, test_env_id)), output)
            end
        end,
        on_attach_debugger = (testrun_id, debug_pipename) -> nothing,
        on_process_created = (id, test_env_id) -> nothing,
        on_process_terminated = id -> nothing,
        on_process_status_changed = (id, status) -> begin
            status == "Launching" || return
            lock(ctx.lock) do
                if ctx.progress_ui == :bar
                    if !ctx.launch_header_printed
                        ctx.launch_header_printed = true
                        printstyled("  Launching test processes"; color=:cyan)
                    end
                    printstyled("."; color=:cyan)
                end
            end
        end,
        on_process_output = (id, output) -> begin
            lock(ctx.lock) do
                push!(get!(Vector{String}, ctx.process_outputs, id), output)
            end
        end,
    )
end

_convert_stack_frames(frames) = frames === nothing ? nothing :
    TestrunResultStackFrame[
        TestrunResultStackFrame(
            f.label,
            something(f.uri, ""),
            something(f.line, 0),
            something(f.column, 0),
        ) for f in frames
    ]

_convert_messages(messages) = messages === nothing ? nothing :
    TestrunResultMessage[
        TestrunResultMessage(
            m.message,
            m.expected_output,
            m.actual_output,
            something(m.uri, ""),
            something(m.line, 0),
            something(m.column, 0),
            _convert_stack_frames(m.stack_trace),
        ) for m in messages
    ]

# Test processes must not inherit the environment the host was launched with: a Pkg
# app shim (and the GitHub Action runner) pins JULIA_LOAD_PATH/JULIA_PROJECT/
# JULIA_DEPOT_PATH to the host's own environment, which would prevent the test
# process from resolving its own. Profile-provided values override these defaults.
function _child_env(profile::RunProfile)
    env_vars = Dict{String,Union{String,Nothing}}(
        "JULIA_LOAD_PATH" => nothing,
        "JULIA_PROJECT" => nothing,
        "JULIA_DEPOT_PATH" => nothing,
    )
    for (k, v) in profile.env
        env_vars[k] = v === nothing ? nothing : string(v)
    end
    return env_vars
end

"""
    run_tests(path; kwargs...)::TestrunResult

Discover all `@testitem`s under `path` and run them, returning the aggregated
[`TestrunResult`](@ref TestItemControllers.Results.TestrunResult).

# Keyword arguments
- `filter` — predicate over `(filename, name, tags, package_name)`; only matching items run.
- `max_workers::Int` — maximum number of parallel test processes.
- `timeout` — per-test-item timeout in seconds, or `nothing` for no timeout.
- `fail_on_detection_error::Bool` — when `true` (default), skip running if any test item
  fails to parse; the errors are reported in the result either way.
- `print_failed_results::Bool`, `print_summary::Bool` — terminal reporting toggles.
- `progress_ui::Symbol` — `:bar`, `:log`, or `:none` (`:none` also silences the toggles above).
- `environments::Vector{RunProfile}` — run every item once per profile.
- `julia_cmd`, `julia_args`, `julia_num_threads` — how to launch test processes.
- `check_bounds` — `--check-bounds` value for test processes: `"auto"` (or `nothing`, the
  default) respects `@inbounds` annotations and lets test processes reuse the precompile
  caches of normal dev sessions; `"yes"` forces bounds checks everywhere (the `Pkg.test`
  behavior) at the cost of re-precompiling the whole environment into a separate cache
  slot on the first run.
- `token` — optional cancellation token.
- `log_min_level` — minimum level for log records emitted while the run is active
  (default `Logging.Warn`, which hides the controller's info-level lifecycle messages;
  `JULIA_DEBUG` overrides still apply).
"""
function run_tests(path; log_min_level = Logging.Warn, kwargs...)
    # The controller logs its lifecycle with @info from the reactor task and the tasks
    # it spawns; tasks inherit the logger at spawn time, so the logger must be in place
    # before the controller is created, i.e. around the whole run.
    Logging.with_logger(Logging.ConsoleLogger(stderr, log_min_level)) do
        _run_tests(path; kwargs...)
    end
end

function _run_tests(
        path;
        filter = nothing,
        max_workers::Int = DEFAULT_MAX_WORKERS,
        timeout = nothing,
        fail_on_detection_error::Bool = true,
        print_failed_results::Bool = true,
        print_summary::Bool = true,
        progress_ui::Symbol = :bar,
        environments::Vector{RunProfile} = [RunProfile("Default", false, Dict{String,Any}())],
        julia_cmd::String = "julia",
        julia_args::Vector{String} = String[],
        julia_num_threads::Union{Nothing,String} = nothing,
        check_bounds::Union{Nothing,String} = nothing,
        token = nothing,
        store_path::Union{Nothing,String} = nothing,
    )
    path = abspath(path)
    progress_ui in (:bar, :log, :none) || error("progress_ui must be :bar, :log or :none")
    if progress_ui == :none
        print_summary = false
        print_failed_results = false
    end

    jw = JuliaWorkspaces.workspace_from_folders([path]; store_path=store_path)

    # ── Discovery ─────────────────────────────────────────────────────
    testitems = []
    testerrors = []
    test_setups = TestItemControllers.TestSetupDetail[]
    for (uri, file_info) in pairs(JuliaWorkspaces.get_test_items(jw))
        project_details = JuliaWorkspaces.get_test_env(jw, uri)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)

        for item in file_info.testitems
            item_pos = JuliaWorkspaces.position_at(textfile.content, first(item.range))
            code_pos = JuliaWorkspaces.position_at(textfile.content, first(item.code_range))
            detail = TestItemControllers.TestItemDetail(
                item.id,
                string(item.uri),
                item.name,
                something(project_details.package_name, ""),
                project_details.package_uri === nothing ? "" : string(project_details.package_uri),
                item.option_default_imports,
                String[string(s) for s in item.option_setup],
                _line(item_pos),
                _column(item_pos),
                textfile.content.content[item.code_range],
                _line(code_pos),
                _column(code_pos),
            )
            push!(testitems, (
                detail = detail,
                tags = item.option_tags,
                package_info = (
                    package_name = something(project_details.package_name, ""),
                    package_uri = project_details.package_uri === nothing ? "" : string(project_details.package_uri),
                    project_uri = project_details.project_uri === nothing ? nothing : string(project_details.project_uri),
                    env_content_hash = project_details.env_content_hash === nothing ? nothing : string(project_details.env_content_hash),
                ),
            ))
        end

        for item in file_info.testerrors
            pos = JuliaWorkspaces.position_at(textfile.content, first(item.range))
            push!(testerrors, (uri = string(item.uri), line = _line(pos), column = _column(pos), message = item.message))
        end

        for setup in file_info.testsetups
            project_details.package_uri === nothing && continue
            pos = JuliaWorkspaces.position_at(textfile.content, first(setup.code_range))
            push!(test_setups, TestItemControllers.TestSetupDetail(
                string(project_details.package_uri),
                string(setup.name),
                string(setup.kind),
                string(uri),
                _line(pos),
                _column(pos),
                textfile.content.content[setup.code_range],
            ))
        end
    end

    if !isempty(testerrors) && fail_on_detection_error
        empty!(testitems)
    end

    if filter !== nothing
        cd(path) do
            Base.filter!(
                i -> filter((
                    filename = _display_path(i.detail.uri),
                    name = i.detail.label,
                    tags = i.tags,
                    package_name = i.package_info.package_name,
                )),
                testitems,
            )
        end
    end

    # ── Translation to controller types ───────────────────────────────
    unique_packages = Dict{String,NamedTuple}()
    for i in testitems
        get!(unique_packages, i.package_info.package_uri, i.package_info)
    end

    testitems_by_id = Dict{String,TestItemControllers.TestItemDetail}(i.detail.id => i.detail for i in testitems)

    test_envs = TestItemControllers.TestEnvironment[]
    profile_name_by_env_id = Dict{String,String}()
    work_units = TestItemControllers.TestRunItem[]
    item_timeout = timeout === nothing ? nothing : Float64(timeout)
    for profile in environments
        env_vars = _child_env(profile)
        mode = profile.coverage ? "Coverage" : "Normal"
        for (pkg_uri, pkg) in unique_packages
            env = TestItemControllers.TestEnvironment(
                string(UUIDs.uuid4()),
                julia_cmd,
                julia_args,
                julia_num_threads,
                env_vars,
                mode,
                pkg.package_name,
                pkg.package_uri,
                pkg.project_uri,
                pkg.env_content_hash,
                check_bounds,
            )
            push!(test_envs, env)
            profile_name_by_env_id[env.id] = profile.name
            for i in testitems
                if i.package_info.package_uri == pkg_uri
                    push!(work_units, TestItemControllers.TestRunItem(i.detail.id, env.id, item_timeout, :Info))
                end
            end
        end
    end

    n_total = length(work_units)

    if progress_ui != :none
        n_files = length(unique(i.detail.uri for i in testitems))
        printstyled("  Discovered $n_total test item run(s) in $n_files file(s)\n"; color=:cyan)
    end

    # ── Execution ─────────────────────────────────────────────────────
    p = ProgressMeter.Progress(n_total;
        barglyphs = ProgressMeter.BarGlyphs('┣', '━', '╸', ' ', '┫'),
        color = :green, enabled = progress_ui == :bar)

    ctx = RunContext(
        testitems_by_id,
        profile_name_by_env_id,
        progress_ui,
        () -> nothing,  # placeholder, replaced below
        0, 0, 0, 0,
        [],
        Dict{Tuple{String,String},Vector{String}}(),
        Dict{String,Vector{String}}(),
        false,
        ReentrantLock(),
    )
    ctx.progressbar_next = () -> begin
        if ctx.launch_header_printed
            ctx.launch_header_printed = false
            println()
        end
        done = ctx.count_success + ctx.count_fail + ctx.count_error + ctx.count_skipped
        parts = String[]
        ctx.count_success > 0 && push!(parts, "$(ctx.count_success) passed")
        ctx.count_fail > 0 && push!(parts, "$(ctx.count_fail) failed")
        ctx.count_error > 0 && push!(parts, "$(ctx.count_error) errored")
        ctx.count_skipped > 0 && push!(parts, "$(ctx.count_skipped) skipped")
        detail = isempty(parts) ? "" : " ($(join(parts, ", ")))"
        ProgressMeter.next!(p, showvalues = [(Symbol("Progress"), "$done/$n_total$detail")])
    end

    if !isempty(work_units)
        callbacks = _make_callbacks(ctx)
        controller = TestItemControllers.TestItemController(callbacks)
        reactor_task = @async try
            run(controller)
        catch err
            Base.display_error(err, catch_backtrace())
        end

        try
            TestItemControllers.execute_testrun(
                controller,
                string(UUIDs.uuid4()),
                test_envs,
                collect(values(testitems_by_id)),
                work_units,
                test_setups,
                max_workers,
                token,
            )
        finally
            TestItemControllers.shutdown(controller)
            wait_for_shutdown(controller, reactor_task)
        end

        if ctx.launch_header_printed
            println()
        end
    elseif isempty(testerrors) && progress_ui != :none
        @warn "No test items to run" filter_applied = (filter !== nothing)
    end

    # ── Reporting ─────────────────────────────────────────────────────
    if print_summary
        println()
        parts = String[]
        length(testerrors) > 0 && push!(parts, "$(length(testerrors)) definition error$(ifelse(length(testerrors) == 1, "", "s"))")
        push!(parts, "$(length(ctx.responses)) tests ran")
        ctx.count_success > 0 && push!(parts, "\e[32m$(ctx.count_success) passed\e[0m")
        ctx.count_fail > 0 && push!(parts, "\e[31m$(ctx.count_fail) failed\e[0m")
        ctx.count_error > 0 && push!(parts, "\e[31m$(ctx.count_error) errored\e[0m")
        ctx.count_skipped > 0 && push!(parts, "$(ctx.count_skipped) skipped")
        println(join(parts, ", "), ".")
    end

    if print_failed_results
        for te in testerrors
            println()
            println("Definition error at $(_display_path(te.uri)):$(te.line)")
            println("  $(te.message)")
        end

        for r in ctx.responses
            if r.result.status in (:failed, :errored)
                println()
                label = r.result.status == :failed ? "FAIL" : "ERROR"
                printstyled("  [$label] $(r.testitem.label)"; color=:red, bold=true)
                if r.result.duration !== nothing
                    print(" ($(r.result.duration)ms)")
                end
                println()
                if r.result.messages !== nothing
                    for m in r.result.messages
                        println("    ", replace(m.message, "\n" => "\n    "))
                        m.expected_output !== nothing && println("    Expected: ", replace(m.expected_output, "\n" => "\n             "))
                        m.actual_output !== nothing && println("    Actual:   ", replace(m.actual_output, "\n" => "\n             "))
                        if m.stack_trace !== nothing
                            for frame in m.stack_trace
                                frame_uri = frame.uri !== nothing ? frame.uri : "?"
                                println("      at $(frame.label) ($(frame_uri):$(something(frame.line, 0)):$(something(frame.column, 0)))")
                            end
                        end
                    end
                end
            end
        end
    end

    # ── Result assembly ───────────────────────────────────────────────
    order = Tuple{String,String}[]
    profiles_by_item = Dict{Tuple{String,String},Vector{TestrunResultTestitemProfile}}()
    for r in ctx.responses
        key = (r.testitem.label, r.testitem.uri)
        haskey(profiles_by_item, key) || push!(order, key)
        output_key = (r.testitem.id, r.test_env_id)
        push!(get!(Vector{TestrunResultTestitemProfile}, profiles_by_item, key), TestrunResultTestitemProfile(
            r.profile_name,
            r.result.status,
            r.result.duration,
            _convert_messages(r.result.messages),
            haskey(ctx.outputs, output_key) ? join(ctx.outputs[output_key]) : nothing,
        ))
    end

    return TestrunResult(
        TestrunResultDefinitionError[
            TestrunResultDefinitionError(e.message, e.uri, e.line, e.column) for e in testerrors
        ],
        TestrunResultTestitem[
            TestrunResultTestitem(k[1], k[2], profiles_by_item[k]) for k in order
        ],
        Dict{String,String}(id => join(chunks) for (id, chunks) in ctx.process_outputs),
    )
end
