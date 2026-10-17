%% Test-only RSA key generation and RS256 signing for identity tests. No
%% Gleam package generates RSA keys or signs with them; OTP's crypto does.
-module(libarrie_identity_test_ffi).
-export([rsa_keypair/0, rsa_sign/2]).

%% {Modulus, Exponent, PrivateKey} with the public parts as big-endian binaries.
rsa_keypair() ->
    {[E, N], Private} = crypto:generate_key(rsa, {2048, 65537}),
    {N, E, Private}.

rsa_sign(Message, Private) ->
    crypto:sign(rsa, sha256, Message, Private).
