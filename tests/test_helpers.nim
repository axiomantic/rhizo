# tests/test_helpers.nim
# Shared in-process execution & split stdout/stderr capture utilities for Rhizo Nim tests.

import std/[os, strutils, json]
when defined(posix):
  import std/posix
elif defined(windows):
  proc c_dup(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
  proc c_dup2(fd1, fd2: cint): cint {.importc: "_dup2", header: "<io.h>".}
  proc c_close(fd: cint): cint {.importc: "_close", header: "<io.h>".}
import config, redis, rhizo

putEnv("RHIZO_EAR_DISABLED", "1")
putEnv("RHIZO_TEST", "1")

var ioCaptureSeq = 0

type
  InProcessResult* = tuple[outStr: string, errStr: string, combined: string, code: int]

when defined(posix):
  proc readAllPipe(fd: cint): string =
    let fl = fcntl(fd, F_GETFL, 0)
    discard fcntl(fd, F_SETFL, fl or O_NONBLOCK)
    var buf: array[4096, char]
    while true:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n <= 0:
        break
      let oldLen = result.len
      result.setLen(oldLen + n)
      copyMem(addr result[oldLen], addr buf[0], n)

  proc captureIoSplit*(fn: proc()): tuple[outStr: string, errStr: string] =
    var pipeOut, pipeErr: array[2, cint]
    discard pipe(pipeOut)
    discard pipe(pipeErr)
    discard fcntl(pipeOut[0], F_SETFD, FD_CLOEXEC)
    discard fcntl(pipeOut[1], F_SETFD, FD_CLOEXEC)
    discard fcntl(pipeErr[0], F_SETFD, FD_CLOEXEC)
    discard fcntl(pipeErr[1], F_SETFD, FD_CLOEXEC)
    flushFile(stdout)
    flushFile(stderr)
    let savedOut = dup(STDOUT_FILENO)
    let savedErr = dup(STDERR_FILENO)
    discard fcntl(savedOut, F_SETFD, FD_CLOEXEC)
    discard fcntl(savedErr, F_SETFD, FD_CLOEXEC)
    discard dup2(pipeOut[1], STDOUT_FILENO)
    discard dup2(pipeErr[1], STDERR_FILENO)
    discard close(pipeOut[1])
    discard close(pipeErr[1])
    try:
      fn()
    finally:
      flushFile(stdout)
      flushFile(stderr)
      discard dup2(savedOut, STDOUT_FILENO)
      discard dup2(savedErr, STDERR_FILENO)
      discard close(savedOut)
      discard close(savedErr)
    let outStr = readAllPipe(pipeOut[0])
    let errStr = readAllPipe(pipeErr[0])
    discard close(pipeOut[0])
    discard close(pipeErr[0])
    result = (outStr, errStr)

  proc captureIoSplitFileStdout*(fn: proc()): tuple[outStr: string, errStr: string] =
    inc ioCaptureSeq
    let outPath = getTempDir() / ("rhizo_fcap_" & $getCurrentProcessId() & "_" & $ioCaptureSeq & ".out")
    let fOut = open(outPath, fmReadWrite)
    let fdOut = getFileHandle(fOut)
    discard fcntl(fdOut, F_SETFD, FD_CLOEXEC)
    var pipeErr: array[2, cint]
    discard pipe(pipeErr)
    discard fcntl(pipeErr[0], F_SETFD, FD_CLOEXEC)
    discard fcntl(pipeErr[1], F_SETFD, FD_CLOEXEC)
    flushFile(stdout)
    flushFile(stderr)
    let savedOut = dup(STDOUT_FILENO)
    let savedErr = dup(STDERR_FILENO)
    discard fcntl(savedOut, F_SETFD, FD_CLOEXEC)
    discard fcntl(savedErr, F_SETFD, FD_CLOEXEC)
    discard dup2(fdOut, STDOUT_FILENO)
    discard dup2(pipeErr[1], STDERR_FILENO)
    discard close(pipeErr[1])
    try:
      fn()
    finally:
      flushFile(stdout)
      flushFile(stderr)
      discard dup2(savedOut, STDOUT_FILENO)
      discard dup2(savedErr, STDERR_FILENO)
      discard close(savedOut)
      discard close(savedErr)
      close(fOut)
    let outStr = if fileExists(outPath): readFile(outPath) else: ""
    let errStr = readAllPipe(pipeErr[0])
    discard close(pipeErr[0])
    try: removeFile(outPath) except CatchableError: discard
    result = (outStr, errStr)

  proc captureIoSplitStdin*(stdinText: string, fn: proc()): tuple[outStr: string, errStr: string] =
    inc ioCaptureSeq
    let inPath = getTempDir() / ("rhizo_in_" & $getCurrentProcessId() & "_" & $ioCaptureSeq & ".txt")
    writeFile(inPath, stdinText)
    let fIn = open(inPath, fmRead)
    let fdIn = getFileHandle(fIn)
    discard fcntl(fdIn, F_SETFD, FD_CLOEXEC)
    let savedIn = dup(STDIN_FILENO)
    discard fcntl(savedIn, F_SETFD, FD_CLOEXEC)
    discard dup2(fdIn, STDIN_FILENO)
    try:
      result = captureIoSplit(fn)
    finally:
      discard dup2(savedIn, STDIN_FILENO)
      discard close(savedIn)
      close(fIn)
      try: removeFile(inPath) except CatchableError: discard
elif defined(windows):
  proc captureIoSplit*(fn: proc()): tuple[outStr: string, errStr: string] =
    inc ioCaptureSeq
    let base = getTempDir() / ("rhizo_cap_" & $getCurrentProcessId() & "_" & $ioCaptureSeq)
    let outPath = base & ".out"
    let errPath = base & ".err"
    let fOut = open(outPath, fmReadWrite)
    let fErr = open(errPath, fmReadWrite)
    let fdOut = cint(getFileHandle(fOut))
    let fdErr = cint(getFileHandle(fErr))
    flushFile(stdout)
    flushFile(stderr)
    let savedOut = c_dup(1)
    let savedErr = c_dup(2)
    discard c_dup2(fdOut, 1)
    discard c_dup2(fdErr, 2)
    try:
      fn()
    finally:
      flushFile(stdout)
      flushFile(stderr)
      discard c_dup2(savedOut, 1)
      discard c_dup2(savedErr, 2)
      discard c_close(savedOut)
      discard c_close(savedErr)
      close(fOut)
      close(fErr)
    let outStr = if fileExists(outPath): readFile(outPath) else: ""
    let errStr = if fileExists(errPath): readFile(errPath) else: ""
    try: removeFile(outPath) except CatchableError: discard
    try: removeFile(errPath) except CatchableError: discard
    result = (outStr, errStr)

  proc captureIoSplitFileStdout*(fn: proc()): tuple[outStr: string, errStr: string] =
    captureIoSplit(fn)

  proc captureIoSplitStdin*(stdinText: string, fn: proc()): tuple[outStr: string, errStr: string] =
    inc ioCaptureSeq
    let inPath = getTempDir() / ("rhizo_in_" & $getCurrentProcessId() & "_" & $ioCaptureSeq & ".txt")
    writeFile(inPath, stdinText)
    let fIn = open(inPath, fmRead)
    let fdIn = cint(getFileHandle(fIn))
    let savedIn = c_dup(0)
    discard c_dup2(fdIn, 0)
    try:
      result = captureIoSplit(fn)
    finally:
      discard c_dup2(savedIn, 0)
      discard c_close(savedIn)
      close(fIn)
      try: removeFile(inPath) except CatchableError: discard

proc captureRet*(fn: proc(): int): InProcessResult =
  var rc = 0
  let (o, e) = captureIoSplit(proc() =
    rc = fn()
  )
  result = (o, e, o & e, rc)

const RhizoTransientEnvKeys = [
  "RHIZO_AGENT_NAME", "RHIZO_AGENT_ID", "RHIZO_SECRET",
  "RHIZO_PROJECT", "RHIZO_REDIS_URL", "RHIZO_PREFIX", "RHIZO_REDIS_PREFIX",
  "RHIZO_ENCRYPT", "RHIZO_CLUSTER",
  "ANTIGRAVITY_CONVERSATION_ID", "ANTIGRAVITY_LS_ADDRESS",
  "ANTIGRAVITY_CSRF_TOKEN", "ANTIGRAVITY_PROJECT_ID"
]

proc runRhizoWithCapture(args: openArray[string], useFileStdout: bool, stdinText: string = "", hasStdin: bool = false): InProcessResult =
  var saved: seq[tuple[k, v: string, present: bool]] = @[]
  for k in RhizoTransientEnvKeys:
    saved.add((k, getEnv(k, ""), existsEnv(k)))
  defer:
    for item in saved:
      if item.present: putEnv(item.k, item.v)
      else: delEnv(item.k)

  let argSeq = @args
  var rc = 0
  let execFn = proc() =
    try:
      main(argSeq, true)
    except CliExitError as err:
      rc = err.exitCode
  let (o, e) = if useFileStdout:
                 captureIoSplitFileStdout(execFn)
               elif hasStdin:
                 captureIoSplitStdin(stdinText, execFn)
               else:
                 captureIoSplit(execFn)
  result = (o, e, o & e, rc)

proc runRhizoInProcess*(args: openArray[string], stdinText: string = "", hasStdin: bool = false): InProcessResult =
  runRhizoWithCapture(args, false, stdinText, hasStdin)

proc runRhizoInProcessFileStdout*(args: openArray[string]): InProcessResult =
  runRhizoWithCapture(args, true)

proc cleanupRedisPrefix*(redisUrl, prefix: string) =
  try:
    var client = openRedisClient(redisUrl)
    defer: (try: client.close() except CatchableError: discard)
    discard client.eval(
      "local ks = redis.call('KEYS', ARGV[1]); for i=1,#ks do redis.call('DEL', ks[i]) end; return #ks",
      @[],
      @[prefix & "*"]
    )
  except CatchableError:
    discard
