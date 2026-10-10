# Package
version       = "0.2.15"
author        = "Axiomantic"
description   = "High Performance Inter-Assistant Redis Bus & Multi-Agent Coordination Mesh"
license       = "MIT"
srcDir        = "src"
bin           = @["rhizo"]
binDir        = "bin"

# Dependencies
requires "nim >= 2.0.0"
requires "yaml >= 2.1.0"
requires "https://github.com/elijahr/redis.git#feat/timeouts-and-reconnect"

task test, "Run test suite":
  exec "nim r tests/test_routing_unit.nim"
  exec "nim r tests/test_protocol_tripwire.nim"

after build:
  when defined(macosx) or defined(darwin):
    echo "[BUILD] Ad-hoc codesigning binary on macOS to prevent AMFI SIGKILL..."
    exec "codesign -s - -f bin/rhizo"
