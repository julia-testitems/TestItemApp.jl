# Capture everything written to `stdout` while `f` runs, and return it as a String.
#
# `redirect_stdout` needs a real OS-level stream, not an `IOBuffer` — the runner prints
# from the reactor task as well as from the calling task, so a pipe is what actually
# collects all of it.
function capture_stdout(f)
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
    reader = @async read(pipe, String)
    try
        redirect_stdout(pipe) do
            f()
        end
    finally
        close(pipe.in)
    end
    return fetch(reader)
end
