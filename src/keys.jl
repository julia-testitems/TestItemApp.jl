# keys.jl — cancel a foreground run with Esc (or q) and Ctrl-C

# Exit code of a run the user cancelled; distinct from 1 (failures) and 2 (usage error),
# and what a shell reports for a SIGINT-terminated process.
const CANCEL_EXIT_CODE = 130

# Put the terminal into raw mode so single key presses can be read without Enter. Returns
# `true` when it worked; only attempted when stdin is a real terminal (never in CI or when
# input is piped).
function _enable_raw_stdin()
    stdin isa Base.TTY || return false
    try
        ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, Int32(1)) == 0 || return false
        Base.start_reading(stdin)
        return true
    catch
        return false
    end
end

function _disable_raw_stdin(enabled::Bool)
    enabled || return
    try
        Base.stop_reading(stdin)
        ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, Int32(0))
    catch
    end
    return nothing
end

_is_cancel_key(b::UInt8) = b == 0x1b || b == UInt8('q') || b == UInt8('Q')   # Esc / q

"""
    run_cancellable(f) -> (value, cancelled_by_user)

Run `f(token)` on its own task while the calling task watches for a cancel request:
Esc (or `q`) when stdin is a terminal, or Ctrl-C. Either cancels the token — the run then
winds down its test processes and returns normally — and the call reports
`cancelled_by_user = true`. A second Ctrl-C after that is not intercepted.
"""
function run_cancellable(f)
    cts = CancellationTokenSource()
    task = Threads.@spawn f(get_token(cts))
    cancelled_by_user = false
    raw = _enable_raw_stdin()
    Base.exit_on_sigint(false)
    try
        while !istaskdone(task)
            try
                if raw && !cancelled_by_user && bytesavailable(stdin) > 0
                    if _is_cancel_key(read(stdin, UInt8))
                        cancelled_by_user = true
                        cancel(cts)
                        printstyled("\nCancelling test run (Esc)...\n"; color=:yellow)
                    end
                end
                sleep(0.05)
            catch err
                err isa InterruptException || rethrow()
                cancelled_by_user && rethrow()   # second Ctrl-C: give up waiting
                cancelled_by_user = true
                cancel(cts)
                printstyled("\nCancelling test run (Ctrl-C)...\n"; color=:yellow)
            end
        end
    finally
        _disable_raw_stdin(raw)
        Base.exit_on_sigint(!isinteractive())
    end
    value = try
        fetch(task)
    catch err
        # Surface the run's own exception rather than the task wrapper.
        err isa TaskFailedException ? throw(err.task.exception) : rethrow()
    end
    return value, cancelled_by_user
end
