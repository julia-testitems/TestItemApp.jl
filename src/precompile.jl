# Precompile workload: run the CLI paths juliati hits on every invocation —
# arg parsing, test item discovery, terminal reporting, the controller reactor
# and result serialization — without ever spawning child Julia processes.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    function _write_workload_project(dir, testfile_content)
        mkpath(joinpath(dir, "src"))
        mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "Project.toml"), """
        name = "TestItemAppWorkload"
        uuid = "5c2f1e6a-8f0d-4bfb-9d2e-4d3a1c6b7e21"
        version = "0.1.0"
        """)
        # A manifest routes environment resolution through the same code path
        # that real-world projects hit.
        write(joinpath(dir, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"
        project_hash = "0000000000000000000000000000000000000000"
        """)
        write(joinpath(dir, "src", "TestItemAppWorkload.jl"), """
        module TestItemAppWorkload
        double(x) = 2x
        end
        """)
        write(joinpath(dir, "test", "runtests.jl"), testfile_content)
        return joinpath(dir, "test", "runtests.jl")
    end

    good_dir = mktempdir()
    good_runtests = _write_workload_project(good_dir, """
    @testsetup module Helpers
    shared = 42
    end

    @testitem "double" tags=[:fast] setup=[Helpers] begin
        @test TestItemAppWorkload.double(2) == 4
    end

    @testitem "second" begin
        @test 1 == 1
    end
    """)

    # A non-literal test item name is a detection error: with the default
    # fail_on_detection_error the work list is emptied before any test process
    # would be launched, so the whole discovery/reporting pipeline runs during
    # precompilation without spawning children.
    broken_dir = mktempdir()
    _write_workload_project(broken_dir, """
    @testitem some_variable begin
        @test true
    end
    """)

    @compile_workload begin
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                real_main(["--help"])
                real_main(["--version"])
                real_main(["--definitely-not-an-option"])

                parse_run_args([
                    good_dir,
                    "--filter", "name == \"double\"",
                    "--timeout=5",
                    "--profile-name", "Precompile",
                    "--env", "A=1",
                    "--env-json", "{\"B\": \"2\", \"C\": null}",
                    "--juliaup-channel", "release",
                    "--results-json", joinpath(good_dir, "results.json"),
                    "--progress", "log",
                    "--output=all",
                    "--max-workers", "2",
                    "--threads", "2",
                    "--coverage",
                    "--coverage-lcov", joinpath(good_dir, "lcov.info"),
                    "--junit-xml", joinpath(good_dir, "junit.xml"),
                    "--gc-between-testitems",
                    "--memory-threshold=0.9",
                    "--schedule", "contiguous",
                    "--no-fail-on-detection-error",
                    "--julia-cmd", "julia",
                ])

                let f = make_filter("startswith(name, \"dou\") || :fast in tags")
                    f((name = "double", tags = [:fast], filename = good_runtests, package_name = "TestItemAppWorkload"))
                end

                # Discovery, reporting and result assembly; the detection error
                # empties the work list, so no controller processes launch.
                run_tests(broken_dir; progress_ui = :log, store_path = mktempdir())
                run_tests(good_dir; progress_ui = :none, filter = i -> false, store_path = mktempdir())

                # Controller reactor start/stop and the execute_testrun entry
                # path (empty run: returns before any process is spawned).
                Logging.with_logger(Logging.NullLogger()) do
                    ctx = RunContext(
                        Dict{String,TestItemControllers.TestItemDetail}(),
                        Dict{String,String}(),
                        :bar,
                        :issues,
                        false,
                        () -> nothing,
                        0, 0, 0, 0,
                        [],
                        Dict{Tuple{String,String},Vector{String}}(),
                        Dict{String,Vector{String}}(),
                        false,
                        0,
                        ReentrantLock(),
                    )
                    controller = TestItemControllers.TestItemController(_make_callbacks(ctx))
                    reactor_task = @async run(controller)
                    try
                        TestItemControllers.execute_testrun(
                            controller,
                            "precompile-workload",
                            TestItemControllers.TestEnvironment[],
                            TestItemControllers.TestItemDetail[],
                            TestItemControllers.TestRunItem[],
                            TestItemControllers.TestSetupDetail[],
                            1,
                            nothing,
                        )
                    finally
                        TestItemControllers.shutdown(controller)
                        wait_for_shutdown(controller, reactor_task)
                    end
                end

                # Result JSON output with all record types populated.
                sample = TestrunResult(
                    [TestrunResultDefinitionError("msg", "file:///t.jl", 1, 1)],
                    [TestrunResultTestitem("double", "file:///t.jl", [
                        TestrunResultTestitemProfile("Default", :passed, 1.5, nothing, nothing,
                            TestrunResultPerfStats(1.5, 1024, 8, 0.1, 0.2, 0.0)),
                        TestrunResultTestitemProfile("Other", :failed, 2.5,
                            [TestrunResultMessage("failed", "1", "2", "file:///t.jl", 1, 1,
                                [TestrunResultStackFrame("f", "file:///t.jl", 1, 1)])],
                            "captured output"),
                    ])],
                    Dict{String,String}("process-1" => "output"),
                    [TestrunResultFileCoverage("file:///t.jl", Union{Nothing,Int}[nothing, 1, 0])],
                )
                Results.write_json(joinpath(good_dir, "sample.json"), sample)
                TestItemControllers.write_junit_xml(joinpath(good_dir, "sample.xml"), sample; root=good_dir)
                TestItemControllers.write_lcov(joinpath(good_dir, "sample.info"), sample)

                # Progress bar rendering with the showvalues shapes engine.jl uses.
                p = ProgressMeter.Progress(2;
                    barglyphs = ProgressMeter.BarGlyphs('┣', '━', '╸', ' ', '┫'), barlen = 40,
                    color = :green, enabled = true, output = devnull)
                ProgressMeter.next!(p, showvalues = [(Symbol("Progress"), "1/2 (1 passed)")])
                ProgressMeter.next!(p, showvalues = [(Symbol("Progress"), "2/2 (1 passed, 1 failed)")])
            end
        end
    end
end
