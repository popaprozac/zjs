## nim-lex: dump the token stream in the exact format of `zjs lex`, for
## byte-diffing against the Zen-c reference (the differential oracle).
import std/[os, strformat]
import ../src/zjs/lexer
import ../src/zjs/token

proc main() =
  let src = if paramCount() >= 1: paramStr(1) else: ""
  var lx = initLexer(src)
  for t in lx.tokens():
    let text = src[t.start.int ..< (t.start + t.length).int]
    stdout.write(&"{($t.kind):<12}  start={($t.start):<4}  length={($t.length):<4}  text=\"{text}\"\n")

main()
