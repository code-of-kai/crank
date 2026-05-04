# CRANK_SETUP_002 — OTP version too old

## What triggers this

`Crank.Application`'s OTP-app `start` callback checked `:erlang.system_info(:otp_release)` at boot and found a release older than 26. Crank refuses to start.

```
** (RuntimeError) error: [CRANK_SETUP_002] Crank purity-enforcement violation
  (location unavailable)

  Why: upgrade Erlang/OTP to 26 or later
  Context: Crank.Application boot
```

The check runs as the very first thing inside `Crank.Application`'s boot path, before any supervisor or worker is started. Failing fast at boot beats failing deep in a property test.

## Why it's wrong

Crank requires the OTP 26 trace-session API (`:trace.session_create/3`, `:trace.session_destroy/1`) for `Crank.PurityTrace` to work. Earlier OTP releases only have the global `:erlang.trace/3` mechanism, which can't be made parallel-test-safe — multiple test processes would race for the single global tracer slot and corrupt each other's results.

The version guard is enforced in three places:

- **`mix.exs`** documents the requirement in package metadata.
- **`Crank.Application`** raises `CRANK_SETUP_002` at boot if OTP < 26.
- **CI matrix** runs only OTP 26+.

Together these prevent a project from accidentally running Crank on an older runtime.

## How to fix

Upgrade Erlang/OTP. On most platforms:

- **asdf:** `asdf install erlang 26.2.5; asdf local erlang 26.2.5`
- **Homebrew:** `brew install erlang@26 && brew unlink erlang && brew link erlang@26`
- **Ubuntu/Debian:** Use the `erlang-solutions` apt repo and pin to OTP 26+.

Verify after upgrade:

```sh
erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'
# 26 (or higher)
```

If you need to keep the project on OTP 25 for unrelated reasons, the only option is to pin Crank to a pre-1.2 version that did not require trace sessions — but that version does not have the runtime-tracing layer. It is not a long-term path.

## How to suppress at this layer

`CRANK_SETUP_002` is not suppressible. Crank cannot operate on OTP < 26.

## See also

- [`CRANK_SETUP_001`](CRANK_SETUP_001.md) — Boundary wiring guard.
- [Property testing](../property-testing.md) — what the trace API enables.
