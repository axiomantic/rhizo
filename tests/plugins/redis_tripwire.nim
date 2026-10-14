# rhizo/tests/plugins/redis_tripwire.nim
# Project-level Tripwire plugin for Rhizo Redis & Lua script execution.

import tripwire
import tripwire/[types, registry, timeline, sandbox, intercept, errors]
import tripwire/plugins/plugin_intercept
import std/[tables, macros]

export plugin_intercept.tripwirePluginIntercept

type
  RedisPlugin* = ref object of Plugin
  RedisScriptResponse* = ref object of MockResponse
    result*: string

method realize*(r: RedisScriptResponse): string {.base, raises: [Defect].} =
  r.result

method supportsPassthrough*(p: RedisPlugin): bool {.raises: [].} = true
method passthroughFor*(p: RedisPlugin, procName: string): bool {.raises: [].} = true

let redisPluginInstance* = RedisPlugin(name: "redis", enabled: true)
registerPlugin(redisPluginInstance)

proc fingerprintRunLua*(scriptSha: string, evalArgs: seq[string]): string =
  var parts: seq[string] = @[scriptSha]
  for a in evalArgs: parts.add(a)
  fingerprintOf("runLuaScript", parts)

# Generate TRM templates for arrays of size 2 through 8
macro emitRunLuaScriptArrayVariants(minN: static[int], maxN: static[int]): untyped =
  result = newStmtList()
  let urlI = ident"redisUrl"
  let txtI = ident"scriptText"
  let shaI = ident"scriptSha"
  let argsI = ident"evalArgs"
  for n in minN .. maxN:
    let tmplName = ident("runLuaScriptArrayTRM" & $n)
    let arrayTy = nnkBracketExpr.newTree(ident"array", newLit(n), ident"string")
    let tdef = quote do:
      template `tmplName`*{runLuaScript(`urlI`, `txtI`, `shaI`, `argsI`)}(
          `urlI`: string, `txtI`: string, `shaI`: string,
          `argsI`: `arrayTy`): string =
        tripwirePluginIntercept(
          redisPluginInstance,
          "runLuaScript",
          fingerprintRunLua(`shaI`, @(`argsI`)),
          RedisScriptResponse):
          {.noRewrite.}:
            runLuaScript(`urlI`, `txtI`, `shaI`, `argsI`)
    result.add(tdef)

emitRunLuaScriptArrayVariants(2, 8)
