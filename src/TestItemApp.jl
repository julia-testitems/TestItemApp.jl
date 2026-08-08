module TestItemApp

import JSON, JuliaWorkspaces, Logging, ProgressMeter, UUIDs
import TestItemControllers
using TestItemControllers: wait_for_shutdown
using TestItemControllers: Results
using TestItemControllers.Results: TestrunResult, TestrunResultTestitem, TestrunResultTestitemProfile,
    TestrunResultMessage, TestrunResultStackFrame, TestrunResultDefinitionError

export run_tests, RunProfile

include("engine.jl")
include("cli.jl")

function (@main)(args)
    return real_main(collect(String, args))
end

include("precompile.jl")

end
