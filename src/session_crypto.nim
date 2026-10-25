# src/session_crypto.nim
## Ephemeral In-Memory Ed25519 Session Keypairs and Attestation for Rhizo
## Provides dynamic OpenSSL libcrypto loading, keypair generation, raw key serialization,
## signing, and verification.

import std/[dynlib, strutils, os]

type
  t_RAND_bytes = proc(buf: pointer, num: cint): cint {.cdecl.}
  t_EVP_PKEY_new_raw_private_key = proc(typeId: cint, e: pointer, key: pointer, keylen: csize_t): pointer {.cdecl.}
  t_EVP_PKEY_new_raw_public_key = proc(typeId: cint, e: pointer, key: pointer, keylen: csize_t): pointer {.cdecl.}
  t_EVP_PKEY_get_raw_public_key = proc(pkey: pointer, pub: pointer, len: ptr csize_t): cint {.cdecl.}
  t_EVP_PKEY_free = proc(pkey: pointer) {.cdecl.}
  t_EVP_MD_CTX_new = proc(): pointer {.cdecl.}
  t_EVP_MD_CTX_free = proc(ctx: pointer) {.cdecl.}
  t_EVP_DigestSignInit = proc(ctx: pointer, pctx: ptr pointer, typeMd: pointer, e: pointer, pkey: pointer): cint {.cdecl.}
  t_EVP_DigestSign = proc(ctx: pointer, sigret: pointer, siglen: ptr csize_t, tbs: pointer, tbslen: csize_t): cint {.cdecl.}
  t_EVP_DigestVerifyInit = proc(ctx: pointer, pctx: ptr pointer, typeMd: pointer, e: pointer, pkey: pointer): cint {.cdecl.}
  t_EVP_DigestVerify = proc(ctx: pointer, sigret: pointer, siglen: csize_t, tbs: pointer, tbslen: csize_t): cint {.cdecl.}

var
  libCryptoHandle: LibHandle = nil
  cryptoLoaded = false
  cryptoLoadAttempted = false

  fn_RAND_bytes: t_RAND_bytes
  fn_EVP_PKEY_new_raw_private_key: t_EVP_PKEY_new_raw_private_key
  fn_EVP_PKEY_new_raw_public_key: t_EVP_PKEY_new_raw_public_key
  fn_EVP_PKEY_get_raw_public_key: t_EVP_PKEY_get_raw_public_key
  fn_EVP_PKEY_free: t_EVP_PKEY_free
  fn_EVP_MD_CTX_new: t_EVP_MD_CTX_new
  fn_EVP_MD_CTX_free: t_EVP_MD_CTX_free
  fn_EVP_DigestSignInit: t_EVP_DigestSignInit
  fn_EVP_DigestSign: t_EVP_DigestSign
  fn_EVP_DigestVerifyInit: t_EVP_DigestVerifyInit
  fn_EVP_DigestVerify: t_EVP_DigestVerify

const
  EVP_PKEY_ED25519* = 1087.cint

proc getCryptoLib(): LibHandle =
  if libCryptoHandle != nil: return libCryptoHandle
  when defined(macosx):
    let candidates = [
      "/opt/homebrew/lib/libcrypto.dylib",
      "/opt/homebrew/lib/libcrypto.4.dylib",
      "/opt/homebrew/lib/libcrypto.3.dylib",
      "/usr/local/lib/libcrypto.dylib",
      "libcrypto.dylib"
    ]
  elif defined(windows):
    let candidates = ["libcrypto-3-x64.dll", "libcrypto-1_1-x64.dll", "libcrypto.dll"]
  else:
    let candidates = ["libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so"]

  for c in candidates:
    let h = loadLib(c)
    if h != nil:
      libCryptoHandle = h
      return h
  return nil

proc initSessionCrypto*(): bool =
  if cryptoLoadAttempted: return cryptoLoaded
  cryptoLoadAttempted = true
  let lib = getCryptoLib()
  if lib == nil:
    return false

  fn_RAND_bytes = cast[t_RAND_bytes](symAddr(lib, "RAND_bytes"))
  fn_EVP_PKEY_new_raw_private_key = cast[t_EVP_PKEY_new_raw_private_key](symAddr(lib, "EVP_PKEY_new_raw_private_key"))
  fn_EVP_PKEY_new_raw_public_key = cast[t_EVP_PKEY_new_raw_public_key](symAddr(lib, "EVP_PKEY_new_raw_public_key"))
  fn_EVP_PKEY_get_raw_public_key = cast[t_EVP_PKEY_get_raw_public_key](symAddr(lib, "EVP_PKEY_get_raw_public_key"))
  fn_EVP_PKEY_free = cast[t_EVP_PKEY_free](symAddr(lib, "EVP_PKEY_free"))
  fn_EVP_MD_CTX_new = cast[t_EVP_MD_CTX_new](symAddr(lib, "EVP_MD_CTX_new"))
  fn_EVP_MD_CTX_free = cast[t_EVP_MD_CTX_free](symAddr(lib, "EVP_MD_CTX_free"))
  fn_EVP_DigestSignInit = cast[t_EVP_DigestSignInit](symAddr(lib, "EVP_DigestSignInit"))
  fn_EVP_DigestSign = cast[t_EVP_DigestSign](symAddr(lib, "EVP_DigestSign"))
  fn_EVP_DigestVerifyInit = cast[t_EVP_DigestVerifyInit](symAddr(lib, "EVP_DigestVerifyInit"))
  fn_EVP_DigestVerify = cast[t_EVP_DigestVerify](symAddr(lib, "EVP_DigestVerify"))

  if fn_RAND_bytes == nil or fn_EVP_PKEY_new_raw_private_key == nil or
     fn_EVP_PKEY_new_raw_public_key == nil or fn_EVP_PKEY_get_raw_public_key == nil or
     fn_EVP_PKEY_free == nil or fn_EVP_MD_CTX_new == nil or fn_EVP_MD_CTX_free == nil or
     fn_EVP_DigestSignInit == nil or fn_EVP_DigestSign == nil or
     fn_EVP_DigestVerifyInit == nil or fn_EVP_DigestVerify == nil:
    return false

  cryptoLoaded = true
  return true

proc isCryptoAvailable*(): bool =
  return initSessionCrypto()

proc hexToBytes*(hexStr: string): seq[uint8] =
  let clean = hexStr.strip()
  if clean.len mod 2 != 0: return @[]
  result = newSeq[uint8](clean.len div 2)
  for i in 0 ..< result.len:
    let byteStr = clean[i*2 .. i*2+1]
    try:
      result[i] = parseHexInt(byteStr).uint8
    except ValueError:
      return @[]

proc bytesToHex*(bytes: openArray[uint8]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(toHex(b.int, 2).toLowerAscii)

proc generateSessionKeypair*(): tuple[pubHex, privHex: string] =
  if not initSessionCrypto():
    raise newException(IOError, "Session crypto dynamic library is not available")
  var seed: array[32, uint8]
  if fn_RAND_bytes(seed[0].addr, 32) != 1:
    raise newException(IOError, "Failed to generate random seed for Ed25519 keypair")

  let pkey = fn_EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, nil, seed[0].addr, 32)
  if pkey == nil:
    raise newException(IOError, "Failed to create EVP_PKEY from raw Ed25519 private key")
  defer: fn_EVP_PKEY_free(pkey)

  var pubBytes: array[32, uint8]
  var pubLen: csize_t = 32
  if fn_EVP_PKEY_get_raw_public_key(pkey, pubBytes[0].addr, pubLen.addr) != 1:
    raise newException(IOError, "Failed to get raw Ed25519 public key")

  return (bytesToHex(pubBytes), bytesToHex(seed))

proc signPayload*(privHex: string, payload: string): string =
  if not initSessionCrypto():
    return ""
  let privBytes = hexToBytes(privHex)
  if privBytes.len != 32:
    return ""

  let pkey = fn_EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, nil, privBytes[0].unsafeAddr, 32)
  if pkey == nil:
    return ""
  defer: fn_EVP_PKEY_free(pkey)

  let sctx = fn_EVP_MD_CTX_new()
  if sctx == nil:
    return ""
  defer: fn_EVP_MD_CTX_free(sctx)

  if fn_EVP_DigestSignInit(sctx, nil, nil, nil, pkey) != 1:
    return ""

  var sigBytes: array[64, uint8]
  var sigLen: csize_t = 64
  let cPayload = if payload.len > 0: payload.cstring else: "".cstring
  if fn_EVP_DigestSign(sctx, sigBytes[0].addr, sigLen.addr, cPayload, payload.len.csize_t) != 1:
    return ""

  return bytesToHex(sigBytes)

proc verifyPayload*(pubHex: string, payload: string, sigHex: string): bool =
  if not initSessionCrypto():
    return false
  let pubBytes = hexToBytes(pubHex)
  if pubBytes.len != 32:
    return false
  let sigBytes = hexToBytes(sigHex)
  if sigBytes.len != 64:
    return false

  let pkey = fn_EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, nil, pubBytes[0].unsafeAddr, 32)
  if pkey == nil:
    return false
  defer: fn_EVP_PKEY_free(pkey)

  let vctx = fn_EVP_MD_CTX_new()
  if vctx == nil:
    return false
  defer: fn_EVP_MD_CTX_free(vctx)

  if fn_EVP_DigestVerifyInit(vctx, nil, nil, nil, pkey) != 1:
    return false

  let cPayload = if payload.len > 0: payload.cstring else: "".cstring
  let res = fn_EVP_DigestVerify(vctx, sigBytes[0].unsafeAddr, 64.csize_t, cPayload, payload.len.csize_t)
  return res == 1

proc sessionKeyDir*(): string =
  let home = getHomeDir()
  if home.len > 0:
    return home / ".config" / "rhizo" / "sessions"
  return getTempDir() / "rhizo-sessions"

proc sessionKeyPath*(agentName: string): string =
  let cleanName = agentName.toLowerAscii.strip()
  return sessionKeyDir() / (cleanName & ".key")

proc saveSessionPrivKey*(agentName: string, privHex: string) =
  let dir = sessionKeyDir()
  try:
    createDir(dir)
    when defined(posix):
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  except CatchableError:
    discard

  let keyFile = sessionKeyPath(agentName)
  try:
    writeFile(keyFile, privHex.strip())
    when defined(posix):
      setFilePermissions(keyFile, {fpUserRead, fpUserWrite})
  except CatchableError as e:
    stderr.writeLine("[WARNING] Failed to save session private key to " & keyFile & ": " & e.msg)

  putEnv("RHIZO_SESSION_PRIVKEY", privHex.strip())

proc loadSessionPrivKey*(agentName: string): string =
  let envKey = getEnv("RHIZO_SESSION_PRIVKEY", "").strip()
  if envKey.len == 64:
    return envKey

  let keyFile = sessionKeyPath(agentName)
  if fileExists(keyFile):
    try:
      let content = readFile(keyFile).strip()
      if content.len == 64:
        return content
    except CatchableError:
      discard

  # Fallback to temp path if different
  let tempKeyFile = getTempDir() / ("rhizo-" & agentName.toLowerAscii.strip() & ".key")
  if fileExists(tempKeyFile):
    try:
      let content = readFile(tempKeyFile).strip()
      if content.len == 64:
        return content
    except CatchableError:
      discard

  return ""
