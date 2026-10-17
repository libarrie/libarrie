%% Run the sandboxed image decoder as an OS process.
%%
%% Interop justification (DESIGN.md sections 3 and 7): the evaluated Gleam
%% packages cannot meet the no-shell rule. `child_process` stops and kills
%% processes through `os:cmd("kill ...")` (a /bin/sh shell-out) and cannot
%% half-close stdin; `shellout` offers no binary stdin; `glexec` wraps
%% erlexec's C++ port program (built against libstdc++). This module is the
%% only process-launching boundary: `spawn_executable` with an absolute path
%% and argument list, never a shell. Input and output travel through a
%% per-run scratch directory, and the launcher enforces CPU, memory and
%% wall-clock limits in the kernel, so no signal ever has to be sent from
%% here. On timeout the port is closed and the launcher's alarm terminates
%% the decoder.
-module(libarrie_decoder_ffi).
-export([run/3]).

run(Executable, Args, TimeoutMs) ->
    Port =
        try
            open_port(
                {spawn_executable, unicode:characters_to_list(Executable)},
                [{args, [unicode:characters_to_list(A) || A <- Args]},
                 exit_status, binary, stderr_to_stdout, hide, {env, []}]
            )
        catch
            error:Reason -> {error, Reason}
        end,
    case Port of
        {error, Why} ->
            {launch_failed, iolist_to_binary(io_lib:format("~p", [Why]))};
        _ ->
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            collect(Port, Deadline, <<>>)
    end.

collect(Port, Deadline, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            %% Diagnostics only; bounded so a noisy decoder cannot grow memory.
            Kept = case byte_size(Acc) < 4096 of
                true -> <<Acc/binary, Data/binary>>;
                false -> Acc
            end,
            collect(Port, Deadline, Kept);
        {Port, {exit_status, Status}} ->
            {exited, Status, binary:part(Acc, 0, min(byte_size(Acc), 4096))}
    after Remaining ->
        try port_close(Port) catch _:_ -> ok end,
        {timed_out, Acc}
    end.
