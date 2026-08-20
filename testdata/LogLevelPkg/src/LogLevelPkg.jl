module LogLevelPkg

# Stands in for a package that logs at debug level: the point of `--log-level debug` is to
# make this message visible without the caller having to name the module in JULIA_DEBUG.
function add(a, b)
    @debug "LogLevelPkg computing a sum" a b
    return a + b
end

end
