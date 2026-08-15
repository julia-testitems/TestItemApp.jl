@testitem "skipped by literal" skip=true begin
    error("this must never run")
end

@testitem "skipped by expression" skip=(1 + 1 == 2) begin
    error("this must never run either")
end

@testitem "not skipped" skip=false begin
    @test SkipPkg.add(1, 2) == 3
end
