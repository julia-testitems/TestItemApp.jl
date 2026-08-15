@testitem "run_tests on fixture package" begin
    using TestItemControllers.Results

    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    result = TestItemApp.run_tests(
        fixture;
        progress_ui = :none,
        julia_cmd = joinpath(Sys.BINDIR, "julia"),
        timeout = 300,
    )

    @test result isa TestrunResult
    @test isempty(result.definition_errors)
    @test length(result.testitems) == 2

    by_name = Dict(ti.name => ti for ti in result.testitems)
    @test haskey(by_name, "passing item")
    @test haskey(by_name, "failing item")

    passing = by_name["passing item"]
    @test length(passing.profiles) == 1
    @test passing.profiles[1].profile_name == "Default"
    @test passing.profiles[1].status == :passed
    @test passing.profiles[1].duration !== nothing

    failing = by_name["failing item"]
    @test failing.profiles[1].status == :failed
    @test failing.profiles[1].messages !== nothing
    @test !isempty(failing.profiles[1].messages)
    @test occursin("Test Failed", failing.profiles[1].messages[1].message)

    # Round-trip through the shared JSON serialization
    io = IOBuffer()
    Results.write_json(io, result)
    roundtripped = Results.read_json(IOBuffer(String(take!(io))))
    @test length(roundtripped.testitems) == 2
    @test Dict(ti.name => ti.profiles[1].status for ti in roundtripped.testitems) ==
          Dict("passing item" => :passed, "failing item" => :failed)
end

@testitem "run_tests collects coverage" begin
    using TestItemControllers
    using TestItemControllers.Results

    # `--coverage` used to fail every single test item: `execute_testrun` was called
    # without `coverage_root_uris`, and the test process then iterated `nothing`.
    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    result = TestItemApp.run_tests(
        fixture;
        filter = i -> i.name == "passing item",
        progress_ui = :none,
        julia_cmd = joinpath(Sys.BINDIR, "julia"),
        timeout = 300,
        environments = [TestItemApp.RunProfile("Default", true, Dict{String,Any}())],
    )

    @test result.testitems[1].profiles[1].status == :passed
    @test result.coverage !== nothing
    @test !isempty(result.coverage)
    covered = only(fc for fc in result.coverage if endswith(fc.uri, "AppTestPkg.jl"))
    @test any(c -> c isa Int && c > 0, covered.coverage)

    # ...and the LCOV wrapper turns it into a file a coverage service can read.
    mktempdir() do dir
        path = joinpath(dir, "lcov.info")
        @test TestItemControllers.write_lcov(path, result) == true
        text = read(path, String)
        @test occursin("SF:", text)
        @test occursin("end_of_record", text)
    end
end

@testitem "run_tests without coverage carries none" begin
    using TestItemControllers
    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    result = TestItemApp.run_tests(
        fixture;
        filter = i -> i.name == "passing item",
        progress_ui = :none,
        julia_cmd = joinpath(Sys.BINDIR, "julia"),
        timeout = 300,
    )
    @test result.coverage === nothing
    mktempdir() do dir
        @test TestItemControllers.write_lcov(joinpath(dir, "lcov.info"), result) == false
    end
end

@testitem "run_tests records perf stats" begin
    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    result = TestItemApp.run_tests(
        fixture;
        filter = i -> i.name == "passing item",
        progress_ui = :none,
        julia_cmd = joinpath(Sys.BINDIR, "julia"),
        timeout = 300,
    )
    perf = result.testitems[1].profiles[1].perf
    @test perf !== nothing
    @test perf.bytes !== nothing && perf.bytes > 0
    @test perf.allocs !== nothing && perf.allocs > 0
end

@testitem "--junit-xml writes a parseable report" begin
    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    mktempdir() do dir
        path = joinpath(dir, "junit.xml")
        exit_code = TestItemApp.real_main([
            fixture,
            "--junit-xml", path,
            "--progress", "none",
            "--output", "none",
            "--julia-cmd", joinpath(Sys.BINDIR, "julia"),
            "--max-workers", "1",
        ])
        @test exit_code == 1  # the fixture has one deliberately failing item

        @test isfile(path)
        text = read(path, String)
        @test startswith(text, "<?xml version=\"1.0\"")
        @test occursin("<testsuites ", text)
        @test occursin("name=\"passing item\"", text)
        @test occursin("name=\"failing item\"", text)
        @test occursin("<failure ", text)
        # Classnames are relative to the run root, not absolute machine paths.
        @test occursin("classname=\"test/app_tests.jl\"", text)

        # Well-formed enough to survive a real parse: tags balance and nothing is stray.
        opened = [m[1] for m in eachmatch(r"<([a-z-]+)[ >]", text)]
        closed = [m[1] for m in eachmatch(r"</([a-z-]+)>", text)]
        @test sort(unique(closed)) ⊆ sort(unique(opened))
        @test count("<testcase", text) == 2
    end
end

@testitem "--gc-between-testitems and --memory-threshold reach the controller" begin
    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    # `memory_threshold = 1.0` can never trip, so this exercises the plumbing without
    # paying for a worker recycle after every item.
    result = TestItemApp.run_tests(
        fixture;
        filter = i -> i.name == "passing item",
        progress_ui = :none,
        julia_cmd = joinpath(Sys.BINDIR, "julia"),
        timeout = 300,
        max_workers = 1,
        gc_between_testitems = true,
        memory_threshold = 1.0,
        schedule = :contiguous,
    )
    @test result.testitems[1].profiles[1].status == :passed
end

@testitem "output_mode controls the console echo" begin
    include(joinpath(@__DIR__, "capture_stdout.jl"))

    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    run_with(mode) = capture_stdout() do
        TestItemApp.run_tests(
            fixture;
            filter = i -> i.name == "passing item",
            progress_ui = :log,
            output_mode = mode,
            julia_cmd = joinpath(Sys.BINDIR, "julia"),
            timeout = 300,
            max_workers = 1,
        )
    end

    # A passing item's captured output is only echoed under `:all`.
    @test occursin("── output of passing item ──", run_with(:all))
    @test !occursin("── output of", run_with(:issues))
    @test !occursin("── output of", run_with(:none))
end

@testitem "stream prints output without the per-item header" begin
    include(joinpath(@__DIR__, "capture_stdout.jl"))

    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    text = capture_stdout() do
        TestItemApp.run_tests(
            fixture;
            filter = i -> i.name == "passing item",
            progress_ui = :none,
            stream = true,
            output_mode = :all,
            julia_cmd = joinpath(Sys.BINDIR, "julia"),
            timeout = 300,
            max_workers = 1,
        )
    end
    @test occursin("Test Summary", text)
    # Streaming replaces the after-the-fact echo rather than doubling it.
    @test !occursin("── output of", text)
end

@testitem "run_tests rejects bad option values" begin
    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    @test_throws ErrorException TestItemApp.run_tests(fixture; output_mode = :verbose, progress_ui = :none)
    @test_throws ErrorException TestItemApp.run_tests(fixture; schedule = :random, progress_ui = :none)
end

@testitem "run_tests filter selects items" begin
    using TestItemControllers.Results

    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    result = TestItemApp.run_tests(
        fixture;
        filter = i -> i.name == "passing item",
        progress_ui = :none,
        julia_cmd = joinpath(Sys.BINDIR, "julia"),
        timeout = 300,
    )

    @test length(result.testitems) == 1
    @test result.testitems[1].name == "passing item"
    @test result.testitems[1].profiles[1].status == :passed
end

@testitem "skip reaches the test process" begin
    using TestItemControllers.Results

    # `skip` used to be dropped between discovery and the test process, so it worked in the
    # editor and silently did nothing on the command line — the item ran anyway. Both bodies
    # here call `error`, so if the skip is not honoured the test fails loudly rather than
    # quietly passing.
    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "SkipPkg"))
    result = TestItemApp.run_tests(
        fixture;
        progress_ui = :none,
        julia_cmd = joinpath(Sys.BINDIR, "julia"),
        timeout = 300,
    )

    @test isempty(result.definition_errors)
    by_name = Dict(ti.name => ti for ti in result.testitems)

    @test only(by_name["skipped by literal"].profiles).status == :skipped
    # The expression is evaluated in the test process, not here.
    @test only(by_name["skipped by expression"].profiles).status == :skipped
    @test only(by_name["not skipped"].profiles).status == :passed
end

@testitem "results carry the discovery id" begin
    using TestItemControllers.Results

    # The id is recorded rather than derived: it carries a package qualifier that cannot be
    # recovered from a file path, and the JUnit report and anything keyed on test identity
    # depend on it being the real one.
    fixture = normpath(joinpath(@__DIR__, "..", "testdata", "AppTestPkg"))
    result = TestItemApp.run_tests(
        fixture;
        progress_ui = :none,
        julia_cmd = joinpath(Sys.BINDIR, "julia"),
        timeout = 300,
    )

    by_name = Dict(ti.name => ti for ti in result.testitems)
    id = by_name["passing item"].id

    @test !isempty(id)
    @test startswith(id, "AppTestPkg@")
    @test endswith(id, "/test/app_tests.jl::passing item")
end
