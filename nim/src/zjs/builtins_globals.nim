## Built-in global slot map — the Zen-c realm registration order.
##
## Zen-c registers every standard built-in global (Object, Array, Math,
## isNaN, …) into the realm's slot table at FIXED slots, assigned in the
## order they are installed at realm init (`ctx_init_builtins` +
## `ctx_init_temporal` + `zjs_install_stdlib_extensions` in
## `src/context.zc`). User globals only begin at slot 108
## (`USER_GLOBAL_BASE`); slots 0..107 belong to these built-ins.
##
## This table is RUNTIME-COUPLED, exactly like `USER_GLOBAL_BASE=108`:
## it mirrors how many / which built-ins the Zen-c runtime constructs and
## in what order. If the reference engine's registration order changes,
## this map (and USER_GLOBAL_BASE) must change in lockstep. Every entry
## below was extracted by probing `build/zjs disasm` for the slot each
## name resolves to (`var __probe = <name>;` → `LoadGlobal g<slot>`), then
## cross-checked against the ordered registration calls in context.zc.
##
## Notes on the map:
##   * g4 = `undefined` is a realm slot in Zen-c, but the compiler emits
##     the `undefined` identifier as a `LoadUndefined` LITERAL and never
##     interns it. It is therefore intentionally ABSENT from this table
##     (adding it would risk a `LoadGlobal g4` vs `LoadUndefined`
##     divergence). g4 is reserved/internal from the compiler's view.
##   * Slots 44/55/63/72/80/81/82/88/90-93/96 hold internal or web-API
##     bindings (`WebSocket`, `$262`, `DOMException`, `reportError`,
##     `__zjs_zlib`, `process`, `__DOM_CODES`, stream helpers, …). They
##     are real slot-table globals in the reference realm, so user code
##     referencing them must resolve to the same fixed slot — they are
##     included here.
##   * `Blob` / `File` / `FormData` / `Buffer` / `CompressionStream` /
##     `DecompressionStream` are installed as `globalThis.X = …` OBJECT
##     PROPERTIES (not interned slot globals) in this build, so the
##     reference disasm assigns them USER slots (>=108). They are
##     correctly EXCLUDED — a reference to them falls through to the
##     user-slot path here too.

import std/tables

const builtinGlobalSlot: Table[string, uint32] = {
  "globalThis":                     0'u32,
  "Error":                          1'u32,
  "NaN":                            2'u32,
  "Infinity":                       3'u32,
  # g4 = undefined — reserved (emitted as LoadUndefined literal; see header)
  "isNaN":                          5'u32,
  "isFinite":                       6'u32,
  "parseFloat":                     7'u32,
  "parseInt":                       8'u32,
  "Array":                          9'u32,
  "Boolean":                       10'u32,
  "Number":                        11'u32,
  "String":                        12'u32,
  "ReferenceError":                13'u32,
  "TypeError":                     14'u32,
  "RangeError":                    15'u32,
  "eval":                          16'u32,
  "Function":                      17'u32,
  "Date":                          18'u32,
  "RegExp":                        19'u32,
  "Symbol":                        20'u32,
  "URL":                           21'u32,
  "URLSearchParams":               22'u32,
  "Map":                           23'u32,
  "Set":                           24'u32,
  "WeakMap":                       25'u32,
  "WeakSet":                       26'u32,
  "Proxy":                         27'u32,
  "Reflect":                       28'u32,
  "Promise":                       29'u32,
  "ArrayBuffer":                   30'u32,
  "Uint8Array":                    31'u32,
  "Int8Array":                     32'u32,
  "Uint8ClampedArray":             33'u32,
  "Int16Array":                    34'u32,
  "Uint16Array":                   35'u32,
  "Int32Array":                    36'u32,
  "Uint32Array":                   37'u32,
  "Float32Array":                  38'u32,
  "Float64Array":                  39'u32,
  "DataView":                      40'u32,
  "BigInt":                        41'u32,
  "BigInt64Array":                 42'u32,
  "BigUint64Array":                43'u32,
  "WebSocket":                     44'u32,
  "Headers":                       45'u32,
  "Response":                      46'u32,
  "Request":                       47'u32,
  "fetch":                         48'u32,
  "WeakRef":                       49'u32,
  "FinalizationRegistry":          50'u32,
  "EvalError":                     51'u32,
  "URIError":                      52'u32,
  "SyntaxError":                   53'u32,
  "AggregateError":                54'u32,
  "$262":                          55'u32,
  "Math":                          56'u32,
  "Object":                        57'u32,
  "JSON":                          58'u32,
  "Temporal":                      59'u32,
  "console":                       60'u32,
  "queueMicrotask":                61'u32,
  "performance":                   62'u32,
  "DOMException":                  63'u32,
  "btoa":                          64'u32,
  "atob":                          65'u32,
  "escape":                        66'u32,
  "unescape":                      67'u32,
  "encodeURI":                     68'u32,
  "encodeURIComponent":            69'u32,
  "decodeURI":                     70'u32,
  "decodeURIComponent":            71'u32,
  "reportError":                   72'u32,
  "setTimeout":                    73'u32,
  "setInterval":                   74'u32,
  "clearTimeout":                  75'u32,
  "clearInterval":                 76'u32,
  "TextEncoder":                   77'u32,
  "TextDecoder":                   78'u32,
  "crypto":                        79'u32,
  "__zjs_zlib":                    80'u32,
  "process":                       81'u32,
  "__DOM_CODES":                   82'u32,
  "Event":                         83'u32,
  "CustomEvent":                   84'u32,
  "EventTarget":                   85'u32,
  "AbortSignal":                   86'u32,
  "AbortController":               87'u32,
  "__structuredCloneImpl":         88'u32,
  "structuredClone":               89'u32,
  "deferred":                      90'u32,
  "isCallable":                    91'u32,
  "defaultSize":                   92'u32,
  "callOrUndefined":               93'u32,
  "ReadableStreamDefaultController":94'u32,
  "ReadableStreamDefaultReader":   95'u32,
  "bytesFrom":                     96'u32,
  "ReadableStreamBYOBReader":      97'u32,
  "ReadableStream":                98'u32,
  "WritableStreamDefaultController":99'u32,
  "WritableStreamDefaultWriter":  100'u32,
  "WritableStream":               101'u32,
  "TransformStreamDefaultController":102'u32,
  "TransformStream":              103'u32,
  "CountQueuingStrategy":         104'u32,
  "ByteLengthQueuingStrategy":    105'u32,
  "TextEncoderStream":            106'u32,
  "TextDecoderStream":            107'u32,
}.toTable

proc builtinSlot*(name: string): int =
  ## Return the FIXED built-in slot for `name` (0..107), or -1 if `name`
  ## is not a Zen-c realm built-in. On a miss the caller allocates a user
  ## slot (USER_GLOBAL_BASE + …); on a hit it must return this slot
  ## WITHOUT touching the user table (built-ins never consume a user slot).
  if builtinGlobalSlot.hasKey(name): int(builtinGlobalSlot[name])
  else: -1

proc builtinName*(slot: uint32): string =
  ## Reverse lookup: the built-in name occupying `slot`, or "" if the slot
  ## holds no named built-in. Used by the disassembler to print the
  ## `; <name>` annotation for built-in global ops — which bypass the
  ## compiler's per-function user global-name table, so their name isn't
  ## recorded there. Linear over the const table; disasm is not hot.
  for k, v in builtinGlobalSlot:
    if v == slot: return k
  return ""
