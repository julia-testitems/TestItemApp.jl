@testitem "parse_run_args defaults" begin
    opts = TestItemApp.parse_run_args(String[])
    @test opts.path == pwd()
    @test opts.filter_str === nothing
    @test opts.timeout === nothing
    @test opts.profile_name == "Default"
    @test isempty(opts.env)
    @test opts.results_json === nothing
    @test opts.progress == :bar
    @test opts.coverage == false
    @test opts.fail_on_detection_error == true
    @test opts.julia_cmd == "julia"
    @test opts.check_bounds === nothing
    @test opts.debug == false
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
