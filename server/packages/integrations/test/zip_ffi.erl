-module(zip_ffi).
-export([unzip/1]).

%% Reads an archive with OTP's own zip implementation (an independent reader),
%% returning {Name, Contents} pairs.
unzip(Bin) ->
    case zip:unzip(Bin, [memory]) of
        {ok, Files} -> {ok, [{unicode:characters_to_binary(Name), Data} || {Name, Data} <- Files]};
        {error, Reason} -> {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.
