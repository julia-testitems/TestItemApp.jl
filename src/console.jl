# console.jl — terminal rendering of a TestItemRuns event stream

# Perf stats are only interesting when they carry something, and the compile timings are
# absent on Julia versions that do not expose them.
function _format_perf(perf)
    perf === nothing && return ""
    parts = String[]
    perf.bytes !== nothing && push!(parts, "$(Base.format_bytes(perf.bytes)) alloc")
    perf.allocs !== nothing && push!(parts, "$(perf.allocs) allocs")
    perf.gctime !== nothing && perf.gctime > 0 && push!(parts, "gc $(round(perf.gctime; digits=1))ms")
    perf.compile_time !== nothing && perf.compile_time > 0 && push!(parts, "compile $(round(perf.compile_time; digits=1))ms")
    perf.recompile_time !== nothing && perf.recompile_time > 0 && push!(parts, "recompile $(round(perf.recompile_time; digits=1))ms")
    return isempty(parts) ? "" : " [" * join(parts, ", ") * "]"
end

# The captured output of one test item, echoed under a header so it cannot be confused with
# the runner's own reporting.
function _echo_output(text, label)
    (text === nothing || isempty(strip(text))) && return
    printstyled("    ── output of $label ──\n"; color=:light_black)
    for line in split(rstrip(text, ['\n']), '\n')
        println("    ", line)
    end
end

"""
    ConsoleReporter(progress_ui, output_mode, stream)

An event sink for `TestItemRuns` that renders a run on the terminal: a ProgressMeter bar
(`:bar`), one line per finished item (`:log`) or nothing (`:none`); echoes captured output
per `output_mode` (`:issues`, `:all`, `:none`); streams output live when `stream`. After
the run, [`print_summary!`](@ref) and [`print_failures!`](@ref) print the wrap-up.
"""
mutable struct ConsoleReporter
    progress_ui::Symbol
    output_mode::Symbol
    stream::Bool
    progress::Union{Nothing,ProgressMeter.Progress}
    n_total::Int
    count_success::Int
    count_fail::Int
    count_error::Int
    count_skipped::Int
    outputs::Dict{Tuple{String,String,String},Vector{String}}   # (id, package_uri, profile) → chunks
    launch_header_printed::Bool
    launch_count::Int
    n_definition_errors::Int
    run_status::Union{Nothing,Symbol}
end

ConsoleReporter(progress_ui::Symbol=:bar, output_mode::Symbol=:issues, stream::Bool=false) =
    ConsoleReporter(progress_ui, output_mode, stream, nothing, 0, 0, 0, 0, 0,
        Dict{Tuple{String,String,String},Vector{String}}(), false, 0, 0, nothing)

_output_key(item, profile) = (item.id, item.package_uri, profile)

# Events are delivered one at a time from a single task, so no locking is needed here.
(r::ConsoleReporter)(::RunEvent) = nothing

function (r::ConsoleReporter)(ev::DiscoveryFinished)
    r.n_definition_errors = length(ev.discovery.definition_errors)
    return nothing
end

function (r::ConsoleReporter)(ev::RunStarted)
    r.n_total = ev.n_units
    if r.progress_ui != :none
        n_items = ev.n_items
        n_files = length(unique(i.uri for i in ev.run.items))
        msg = "  Discovered $n_items test item$(n_items == 1 ? "" : "s") in $n_files file$(n_files == 1 ? "" : "s")"
        if ev.n_units != n_items
            msg *= " ($(ev.n_units) run$(ev.n_units == 1 ? "" : "s") across $(ev.n_profiles) profile$(ev.n_profiles == 1 ? "" : "s"))"
        end
        printstyled(msg, "\n"; color=:cyan)
        if ev.n_units == 0 && r.n_definition_errors == 0
            @warn "No test items to run"
        end
    end
    r.progress = ProgressMeter.Progress(ev.n_units;
        barglyphs = ProgressMeter.BarGlyphs('┣', '━', '╸', ' ', '┫'),
        barlen = 40, color = :green, enabled = r.progress_ui == :bar)
    return nothing
end

function (r::ConsoleReporter)(ev::ProcessStatusChanged)
    ev.status == "Launching" || return nothing
    r.launch_count += 1
    if r.progress_ui == :bar
        n = r.launch_count
        # Rewrite the line in place so the count ticks up as processes launch.
        r.launch_header_printed && print("\r\e[2K")
        r.launch_header_printed = true
        printstyled("  Launching $n test process$(n == 1 ? "" : "es")..."; color=:cyan)
    end
    return nothing
end

function (r::ConsoleReporter)(ev::OutputAppended)
    push!(get!(Vector{String}, r.outputs, _output_key(ev.item, ev.profile)), ev.output)
    if r.stream
        print(ev.output)
        flush(stdout)
    end
    return nothing
end

function _progress_next!(r::ConsoleReporter)
    if r.launch_header_printed
        r.launch_header_printed = false
        println()
    end
    done = r.count_success + r.count_fail + r.count_error + r.count_skipped
    parts = String[]
    r.count_success > 0 && push!(parts, "$(r.count_success) passed")
    r.count_fail > 0 && push!(parts, "$(r.count_fail) failed")
    r.count_error > 0 && push!(parts, "$(r.count_error) errored")
    r.count_skipped > 0 && push!(parts, "$(r.count_skipped) skipped")
    detail = isempty(parts) ? "" : " ($(join(parts, ", ")))"
    ProgressMeter.next!(r.progress, showvalues = [(Symbol("Progress"), "$done/$(r.n_total)$detail")])
end

function (r::ConsoleReporter)(ev::TestItemFinished)
    status = ev.status
    status == :passed && (r.count_success += 1)
    status == :failed && (r.count_fail += 1)
    status == :errored && (r.count_error += 1)
    status == :skipped && (r.count_skipped += 1)
    if r.progress_ui == :log
        symbol = status == :passed ? "✓" : status == :skipped ? "⊘" : "✗"
        duration_string = ev.duration !== nothing ? " ($(ev.duration)ms)" : ""
        println("$symbol $(ev.profile) $(ev.item.filename):$(ev.item.name) → $status$duration_string$(_format_perf(ev.perf))")
    end
    r.progress_ui == :bar && r.progress !== nothing && _progress_next!(r)
    # `:issues` echoes at the end, next to the failure detail; `:all` echoes here so
    # a passing item's output appears while the run is still going.
    if r.output_mode == :all && !r.stream
        chunks = get(r.outputs, _output_key(ev.item, ev.profile), nothing)
        chunks === nothing || _echo_output(join(chunks), ev.item.name)
    end
    return nothing
end

function (r::ConsoleReporter)(ev::RunFinished)
    r.run_status = ev.status
    if r.launch_header_printed
        r.launch_header_printed = false
        println()
    end
    return nothing
end

"""
    print_summary!(r::ConsoleReporter, result::TestrunResult)
"""
function print_summary!(r::ConsoleReporter, result::TestrunResult)
    println()
    n_errors = length(result.definition_errors)
    n_ran = sum(length(t.profiles) for t in result.testitems; init=0)
    parts = String[]
    if r.run_status == :cancelled
        push!(parts, "\e[33mrun cancelled\e[0m")
    end
    n_errors > 0 && push!(parts, "$n_errors definition error$(ifelse(n_errors == 1, "", "s"))")
    push!(parts, "$n_ran tests ran")
    r.count_success > 0 && push!(parts, "\e[32m$(r.count_success) passed\e[0m")
    r.count_fail > 0 && push!(parts, "\e[31m$(r.count_fail) failed\e[0m")
    r.count_error > 0 && push!(parts, "\e[31m$(r.count_error) errored\e[0m")
    r.count_skipped > 0 && push!(parts, "$(r.count_skipped) skipped")
    println(join(parts, ", "), ".")
end

"""
    print_failures!(r::ConsoleReporter, result::TestrunResult)

Definition errors and the detail of every failed/errored (item, profile).
"""
function print_failures!(r::ConsoleReporter, result::TestrunResult)
    for te in result.definition_errors
        println()
        println("Definition error at $(TestItemRuns._display_path(te.uri)):$(te.line)")
        println("  $(te.message)")
    end

    for t in result.testitems, p in t.profiles
        p.status in (:failed, :errored) || continue
        println()
        label = p.status == :failed ? "FAIL" : "ERROR"
        printstyled("  [$label] $(t.name)"; color=:red, bold=true)
        if length(t.profiles) > 1
            print(" ($(p.profile_name))")
        end
        if p.duration !== nothing
            print(" ($(p.duration)ms)")
        end
        println()
        if r.output_mode == :issues && !r.stream
            _echo_output(p.output, t.name)
        end
        if p.messages !== nothing
            for m in p.messages
                println("    ", replace(m.message, "\n" => "\n    "))
                m.expected_output !== nothing && println("    Expected: ", replace(m.expected_output, "\n" => "\n             "))
                m.actual_output !== nothing && println("    Actual:   ", replace(m.actual_output, "\n" => "\n             "))
                if m.stack_frames !== nothing
                    for frame in m.stack_frames
                        frame_uri = isempty(frame.uri) ? "?" : frame.uri
                        println("      at $(frame.label) ($(frame_uri):$(frame.line):$(frame.column))")
                    end
                end
            end
        end
    end
end
