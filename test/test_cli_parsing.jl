@testitem "parse_run_args defaults" begin
    opts = TestItemApp.parse_run_args(String[])
    @test opts.path == pwd()
    @test opts.filter_str === nothing
    @test opts.timeout == TestItemApp.DEFAULT_TIMEOUT
    @test opts.profile_name == "Default"
    @test isempty(opts.env)
    @test opts.results_json === nothing
    @test opts.junit_xml === nothing
    @test opts.progress == :bar
    @test opts.output == :issues
    @test opts.stream == false
    @test opts.threads === nothing
    @test opts.coverage == false
    @test opts.coverage_lcov === nothing
    @test opts.gc_between_testitems === nothing
    @test opts.memory_threshold === nothing
    @test opts.schedule == :duration
    @test opts.fail_on_detection_error == true
    @test opts.failfast == false
    @test opts.julia_cmd == "julia"
    @test opts.check_bounds === nothing
    @test opts.log_level == :Info
    @test opts.debug == false
end

@testitem "parse_run_args timeout defaults and opt-out" begin
    # A missing timeout used to mean "no timeout", which turns a hung item into a hung job.
    @test TestItemApp.parse_run_args(String[]).timeout == 1200.0
    @test TestItemApp.parse_run_args(String["--timeout", "30"]).timeout == 30.0
    @test TestItemApp.parse_run_args(String["--timeout=none"]).timeout === nothing
    @test TestItemApp.parse_run_args(String["--timeout", "off"]).timeout === nothing
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--timeout", "0"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--timeout", "-5"])
end

@testitem "parse_run_args new options in both syntaxes" begin
    space = TestItemApp.parse_run_args(String[
        "--junit-xml", "j.xml",
        "--output", "all",
        "--coverage-lcov", "lcov.info",
        "--threads", "4",
        "--memory-threshold", "0.75",
        "--schedule", "contiguous",
    ])
    equals = TestItemApp.parse_run_args(String[
        "--junit-xml=j.xml",
        "--output=all",
        "--coverage-lcov=lcov.info",
        "--threads=4",
        "--memory-threshold=0.75",
        "--schedule=contiguous",
    ])
    for opts in (space, equals)
        @test opts.junit_xml == "j.xml"
        @test opts.output == :all
        @test opts.coverage_lcov == "lcov.info"
        @test opts.coverage == true   # --coverage-lcov implies --coverage
        @test opts.threads == "4"
        @test opts.memory_threshold == 0.75
        @test opts.schedule == :contiguous
    end
    @test space == equals
end

@testitem "every value-taking option is in the --opt=value whitelist" begin
    # `--opt=value` is split only for options on this whitelist, so a value-taking option
    # that is missing from it silently degrades to "unknown option".
    # Which options take a value is probed at runtime rather than read off the source: an
    # option that consumes one reports "missing value for" when given nothing to consume.
    src = read(joinpath(pkgdir(TestItemApp), "src", "cli.jl"), String)
    all_options = Set(m[1] for m in eachmatch(r"a == \"(--[a-z0-9-]+)\"", src))
    @test "--filter" in all_options && "--coverage" in all_options

    takes_value(opt) = try
        TestItemApp.parse_run_args(String[opt])
        false
    catch e
        e isa TestItemApp.CliError && occursin("missing value for", e.msg)
    end

    value_taking = Set(opt for opt in all_options if takes_value(opt))
    @test issetequal(value_taking, TestItemApp.VALUE_TAKING_OPTIONS)

    # And every whitelisted option really does get split on '='. An unsplit `--opt=value`
    # falls through to "unknown option", so any other error still proves the split happened.
    for opt in TestItemApp.VALUE_TAKING_OPTIONS
        try
            TestItemApp.parse_run_args(String["$opt=zzz"])
        catch e
            @test !occursin("unknown option", e.msg)
        end
    end
end

@testitem "parse_run_args gc and stream flags" begin
    @test TestItemApp.parse_run_args(String["--gc-between-testitems"]).gc_between_testitems == true
    @test TestItemApp.parse_run_args(String["--no-gc-between-testitems"]).gc_between_testitems == false

    @test TestItemApp.parse_run_args(String["--stream", "--max-workers", "1"]).stream == true
    # Live output from several processes would interleave arbitrarily.
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--stream"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--stream", "--max-workers", "4"])
    @test TestItemApp.real_main(["--stream", "--max-workers", "2"]) == 2
end

@testitem "parse_run_args new option errors" begin
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--output", "verbose"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--schedule", "random"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--memory-threshold", "1.5"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--memory-threshold", "lots"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--threads", "0"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--threads", "many"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--threads", "1,2,3"])
end

@testitem "_valid_threads accepts Julia's own --threads grammar" begin
    @test TestItemApp._valid_threads("1")
    @test TestItemApp._valid_threads("16")
    @test TestItemApp._valid_threads("auto")
    @test TestItemApp._valid_threads("4,1")
    @test TestItemApp._valid_threads("auto,auto")
    @test !TestItemApp._valid_threads("")
    @test !TestItemApp._valid_threads("-1")
    @test !TestItemApp._valid_threads("1,")
end

@testitem "parse_run_args check-bounds" begin
    @test TestItemApp.parse_run_args(String["--check-bounds", "yes"]).check_bounds == "yes"
    @test TestItemApp.parse_run_args(String["--check-bounds=auto"]).check_bounds == "auto"
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--check-bounds", "no"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--check-bounds", "maybe"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--check-bounds"])
end

@testitem "parse_run_args full options" begin
    opts = TestItemApp.parse_run_args(String[
        "/some/path",
        "--filter", ":smoke in tags",
        "--timeout", "1200",
        "--profile-name", "Julia release:ubuntu-latest",
        "--env", "FOO=bar",
        "--env", "EMPTY=",
        "--env-json", """{"BAZ": "1", "REMOVED": null}""",
        "--juliaup-channel", "release",
        "--results-json", "out.json",
        "--progress", "log",
        "--max-workers", "4",
        "--no-fail-on-detection-error",
        "--log-level", "debug",
        "--debug",
    ])
    @test opts.path == "/some/path"
    @test opts.filter_str == ":smoke in tags"
    @test opts.timeout == 1200.0
    @test opts.profile_name == "Julia release:ubuntu-latest"
    @test opts.env["FOO"] == "bar"
    @test opts.env["EMPTY"] == ""
    @test opts.env["BAZ"] == "1"
    @test opts.env["REMOVED"] === nothing
    @test opts.env["JULIAUP_CHANNEL"] == "release"
    @test opts.results_json == "out.json"
    @test opts.progress == :log
    @test opts.max_workers == 4
    @test opts.fail_on_detection_error == false
    @test opts.log_level == :Debug
    @test opts.debug == true
end

@testitem "parse_run_args equals syntax" begin
    opts = TestItemApp.parse_run_args(String["--progress=none", "--env=KEY=a=b", "--timeout=60"])
    @test opts.progress == :none
    @test opts.env["KEY"] == "a=b"
    @test opts.timeout == 60.0
end

@testitem "parse_run_args errors" begin
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--progress", "fancy"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--timeout", "soon"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--env", "NOEQUALS"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--unknown-option"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--filter"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["a", "b"])
    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--max-workers", "0"])
end

@testitem "make_filter evaluates the filter contract" begin
    f = TestItemApp.make_filter("name == \"foo\" || :smoke in tags")
    mktempdir() do dir
        file = joinpath(dir, "a.jl")
        write(file, "")
        @test f((name = "foo", tags = Symbol[], filename = file, package_name = "Pkg"))
        @test f((name = "bar", tags = [:smoke], filename = file, package_name = "Pkg"))
        @test !f((name = "bar", tags = [:other], filename = file, package_name = "Pkg"))
    end
end

@testitem "real_main help, version and usage errors" begin
    @test TestItemApp.real_main(["--help"]) == 0
    @test TestItemApp.real_main(["--version"]) == 0
    # Running is the default action, so bad options and nonexistent paths go
    # through the run path and exit 2. (real_main(String[]) is not tested here —
    # it would actually run tests in the current directory.)
    @test TestItemApp.real_main(["--progress", "fancy"]) == 2
    @test TestItemApp.real_main(["frobnicate"]) == 2  # no such directory
end

@testitem "parse_run_args failfast" begin
    @test TestItemApp.parse_run_args(String[]).failfast == false
    @test TestItemApp.parse_run_args(String["--failfast"]).failfast == true

    # `--failfast` takes no value, so it must not swallow the path that follows it
    opts = TestItemApp.parse_run_args(String["--failfast", "some/path"])
    @test opts.failfast == true
    @test opts.path == "some/path"
end

@testitem "parse_run_args --log-level" begin
    for (value, expected) in ("debug" => :Debug, "info" => :Info, "warn" => :Warn, "error" => :Error)
        @test TestItemApp.parse_run_args(String["--log-level", value]).log_level == expected
        @test TestItemApp.parse_run_args(String["--log-level=$value"]).log_level == expected
    end

    # The level of the code under test is a separate axis from the infrastructure's own
    # debug logging; neither flag implies the other.
    @test TestItemApp.parse_run_args(String["--debug"]).log_level == :Info
    @test TestItemApp.parse_run_args(String["--log-level", "debug"]).debug == false

    err = try
        TestItemApp.parse_run_args(String["--log-level", "verbose"])
        nothing
    catch e
        e
    end
    @test err isa TestItemApp.CliError
    @test occursin("invalid value for --log-level", err.msg)

    @test_throws TestItemApp.CliError TestItemApp.parse_run_args(String["--log-level"])
end
