import std/[unittest, strutils, os]
import ../src/session_crypto

suite "Session Crypto Unit Tests":
  test "Generate keypair, sign and verify":
    check isCryptoAvailable()
    let (pubHex, privHex) = generateSessionKeypair()
    check pubHex.len == 64
    check privHex.len == 64

    let payload = "id_123|sender|recipient|task|do work|body data|2026-10-25T12:00:00Z"
    let sigHex = signPayload(privHex, payload)
    check sigHex.len == 128

    # Positive verification
    check verifyPayload(pubHex, payload, sigHex)

    # Tampered payload fails verification
    let tamperedPayload = "id_123|sender|recipient|task|TAMPERED work|body data|2026-10-25T12:00:00Z"
    check not verifyPayload(pubHex, tamperedPayload, sigHex)

    # Tampered signature fails verification
    var tamperedSig = sigHex
    tamperedSig[0] = if sigHex[0] == 'a': 'b' else: 'a'
    check not verifyPayload(pubHex, payload, tamperedSig)

    # Cross-session verification fails
    let (otherPub, otherPriv) = generateSessionKeypair()
    check not verifyPayload(otherPub, payload, sigHex)

  test "Derive public key from private key":
    let (pubHex, privHex) = generateSessionKeypair()
    let derivedPub = getSessionPubkeyFromPrivKey(privHex)
    check derivedPub == pubHex
    check derivedPub.len == 64

  test "Save and load session private key":
    let agent = "test-agent-crypto"
    let (pubHex, privHex) = generateSessionKeypair()
    saveSessionPrivKey(agent, privHex)
    let loaded = loadSessionPrivKey(agent)
    check loaded == privHex
    let path = sessionKeyPath(agent)
    check fileExists(path)
    # Cleanup
    try: removeFile(path) except CatchableError: discard

echo "Running tests..."
