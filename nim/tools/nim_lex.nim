## nim-lex: dump the token stream in the exact format of `zjs lex`, for
## byte-diffing against the Zen-c reference (the differential oracle).
##
## tkLabel is in labels.nim (shared with nim_parse.nim), which mirrors the
## Zen-c tools/zjs.zc `tk_label` table exactly: kinds absent from that table
## (BigIntLit, RegexLit, TemplateLit, KwWith, KwGet, KwSet, PrivateName)
## produce "?" just as Zen-c does.
import std/[os, strformat]
import ../src/zjs/lexer
import ../src/zjs/token
import labels

proc main() =
  let src = if paramCount() >= 1: paramStr(1) else: ""
  var lx = initLexer(src)
  for t in lx.tokens():
    let text = src[t.start.int ..< (t.start + t.length).int]
    let label = tkLabel(t.kind)
    stdout.write(&"{label:<12}  start={($t.start):<4}  length={($t.length):<4}  text=\"{text}\"\n")

main()
