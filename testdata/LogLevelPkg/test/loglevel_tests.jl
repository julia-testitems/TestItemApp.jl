@testitem "logs at debug level" begin
    @debug "message from the test item body"
    @test LogLevelPkg.add(1, 2) == 3
end
