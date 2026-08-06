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
