# Fixture for the `failfast` tests.
#
# Every item fails, because which of them runs first is not fixed: the
# controller keys its remaining work on `(testitem_id, test_env_id)` in a
# `Dict`, and the environment id is a fresh UUID per run. With every item
# failing, "the first one to run fails and the rest are skipped" holds whichever
# order the run happens to pick.

@testitem "failfast a" begin
    @test FailfastPkg.add(1, 2) == 4
end

@testitem "failfast b" begin
    @test FailfastPkg.add(1, 2) == 5
end

@testitem "failfast c" begin
    @test FailfastPkg.add(1, 2) == 6
end
