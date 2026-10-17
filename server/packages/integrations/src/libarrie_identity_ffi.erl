%% RSA signature verification for OIDC ID/access tokens.
%%
%% Interop justification (DESIGN.md section 3): no maintained Gleam package
%% verifies RS256 JWT signatures (gwt supports only HMAC algorithms and
%% gleam_crypto exposes hashes/HMAC but no public-key verification). OTP's
%% `crypto:verify/5` is the narrowest correct primitive. This module is the
%% only Erlang boundary in identity handling and is wrapped by
%% `libarrie/integrations/identity`.
-module(libarrie_identity_ffi).
-export([rsa_sha256_verify/4]).

rsa_sha256_verify(Message, Signature, Modulus, Exponent) ->
    try
        crypto:verify(rsa, sha256, Message, Signature, [Exponent, Modulus])
    catch
        _:_ -> false
    end.
