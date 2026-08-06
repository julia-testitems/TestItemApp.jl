@testitem "passing item" begin
    @test AppTestPkg.add(1, 2) == 3
end

@testitem "failing item" tags=[:failing] begin
    @test AppTestPkg.add(1, 2) == 4
end
