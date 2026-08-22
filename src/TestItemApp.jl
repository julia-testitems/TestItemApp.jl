module TestItemApp

import JSON, Logging, ProgressMeter
import TestItemRuns
using TestItemRuns: TestrunResult, TestrunResultTestitem, TestrunResultTestitemProfile,
    TestrunResultMessage, TestrunResultStackFrame, TestrunResultDefinitionError,
    TestrunResultPerfStats, TestrunResultFileCoverage,
    write_json, write_junit_xml, write_lcov
using TestItemRuns: RunEvent, DiscoveryFinished, RunStarted, TestItemStarted, TestItemFinished,
    OutputAppended, ProcessStatusChanged, RunFinished
using TestItemRuns.CancellationTokens: CancellationTokenSource, get_token, cancel

export run_tests, RunProfile

include("console.jl")
include("run.jl")
include("keys.jl")
include("cli.jl")

function (@main)(args)
    return real_main(collect(String, args))
end

include("precompile.jl")

end
