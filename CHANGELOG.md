# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Pure Redis Strand State Management & Three-Key Ratification Gate (`scripts/strand.lua`, `src/rhizo.nim`, `tests/test_strand_lua.py`)**:
  - Implemented pure Redis strand state management in `scripts/strand.lua`, completely eliminating on-disk `.vine.json` dependency.
  - Supported actions: `create`, `submit`, `ratify`, `reject`, `weave`, `get`, and `list` across lifecycle states (`PROVISIONED`, `SUBMITTED`, `RATIFIED`, `REJECTED`, `WOVEN`).
  - Enforced atomic ratification invariants in Lua: verifies independent auditor (`auditor_pubkey != author_pubkey`), checks active auditor heartbeat lease, checks anti-blink temporal floor, and updates state and index sets atomically.
  - Added comprehensive automated test suite `tests/test_strand_lua.py`.
- **Ephemeral In-Memory Ed25519 Session Keypairs & Signed Envelope Attestation (`src/session_crypto.nim`, `src/rhizo.nim`, `tests/test_session_crypto.py`, `tests/test_crypto_primitives.nim`)**:
  - Implemented ephemeral Ed25519 session keypairs generated on `rhizo open <name>` via dynamic cross-platform OpenSSL `libcrypto` symbol resolution.
  - Stored public key in Redis under `agent:<name>` (field: `session_pubkey`) and private key in session memory / secure POSIX `0600` file (`~/.config/rhizo/sessions/<name>.key`) and `RHIZO_SESSION_PRIVKEY` env var.
  - Added signed envelope attestation across `send`, `reply`, `claim`, `lock`, `scatter`, and `enqueue` using the session's private key (`session_sig`).
  - Implemented cryptographic recipient and coordinator verification against the sender's authoritative public key registered in `agent:<sender>`.
  - Added verification subcommands: `rhizo lock verify <lock_name>`, `rhizo task verify <task_id>`, and `rhizo verify <msg_json_or_file>`.
  - Displayed session public key in `rhizo open` registration summary and `rhizo probe` health report.
  - Added hermetic unit tests (`tests/test_crypto_primitives.nim`) and comprehensive integration test suite (`tests/test_session_crypto.py`) asserting signature generation, payload verification, and rejection of tampered, forged, and cross-session spoofed payloads.
- **Dedicated CLI Subcommand Help Handling (`src/rhizo.nim`, `tests/test_cli_help.py`)**:
  - Implemented early intercept for `--help` and `-h` across all subcommands (`listen`, `send`, `reply`, `broadcast`, `open`, `claim`, `work`, `lock`, `unlock`, `probe`, `who`, `watchdog`, `leader`, `route`, `config`, etc.).
  - Fixed issue where `rhizo listen --help` and `rhizo listen <name> --help` would fail on missing agent name or start blocking/hanging indefinitely on Redis.
  - Added standalone unit test suite in `tests/test_cli_help.py` asserting non-blocking behavior, exit code 0, and usage banner presence across 20+ subcommands.
