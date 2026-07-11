## dtoa.nim — ECMAScript `Number::toString(x, 10)` (§6.1.6.1.20), the
## shortest-round-tripping decimal formatter. Direct port of Zen-c's
## `js_double_to_chars` (src/context.zc:25867).
##
## `doubleToChars` returns the JS-canonical decimal for ANY FINITE double.
## The caller (vmToString) strips NaN / ±Infinity and the integer fast-path
## before delegating here; this routine handles the remaining cases:
## non-integer doubles (0.5, 1/3, 0.1+0.2) and integral doubles outside the
## %lld window. It also reproduces the integer path (`doubleToChars(100.0)`
## → "100", `doubleToChars(0.0)` → "0") so behavior is consistent.
##
## Unlike C printf %g (which goes exponential at decimal exponent < -4 and
## zero-pads the exponent to "e-06"), this applies the spec's fixed-vs-
## exponential rule (exponential only when the decimal position n > 21 or
## n <= -6) and a JS-shaped exponent ("e-7", sign + minimal digits).
##
## CRITICAL: the shortest-round-trip loop binds libc snprintf("%.*e") and
## strtod directly via importc — Nim's formatFloat/parseFloat may round or
## format differently and would break byte-identity with `build/zjs`.

# `%.*e` takes the precision as a variadic `int` (the `*`) then the value as
# a `double`. Mirror vm.nim's c_snprintf_ll importc pattern.
proc c_snprintf_e(buf: cstring, n: csize_t, fmt: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", varargs.}
proc c_strtod(s: cstring, endp: ptr cstring): cdouble
  {.importc: "strtod", header: "<stdlib.h>".}

proc doubleToChars*(d: float64): string =
  ## Shortest round-tripping decimal of a FINITE double `d`
  ## (ECMA-262 §6.1.6.1.20 / Zen-c js_double_to_chars). Caller strips
  ## NaN / ±Inf; ±0 and small integers are handled correctly here too.
  var res = newStringOfCap(32)
  var x = d
  if x < 0:
    res.add('-')
    x = -x

  # Shortest round-tripping significant-digit count via %.*e: the smallest
  # precision whose output strtod-recovers x exactly. The %e form gives a
  # normalized "D.DDDe±XX" with one leading digit, so the sig digits and the
  # decimal exponent are trivially extracted below.
  var prec: cint = 16
  var tmp: array[48, char]
  for t in 0 .. 16:
    discard c_snprintf_e(cast[cstring](addr tmp[0]), csize_t(sizeof(tmp)),
                         cstring("%.*e"), cint(t), cdouble(x))
    if c_strtod(cast[cstring](addr tmp[0]), nil) == cdouble(x):
      prec = cint(t)
      break

  var emt: array[48, char]
  discard c_snprintf_e(cast[cstring](addr emt[0]), csize_t(sizeof(emt)),
                       cstring("%.*e"), prec, cdouble(x))

  # Extract the significant digits and the decimal exponent E from "D.DDDe±XX".
  var digits: array[24, char]
  var k = 0
  var q = 0
  digits[k] = emt[q]; inc k; inc q          # leading digit (1-9), or '0' for zero
  if emt[q] == '.':
    inc q
    while emt[q] != 'e' and emt[q] != 'E':
      digits[k] = emt[q]; inc k; inc q
  inc q                                       # skip 'e'
  var es = 1
  if emt[q] == '+': inc q
  elif emt[q] == '-': (es = -1; inc q)
  var e = 0
  while emt[q] >= '0' and emt[q] <= '9':
    e = e * 10 + (ord(emt[q]) - ord('0'))
    inc q
  e *= es
  let nn = e + 1                              # §6.1.6.1.20: 10^(nn-1) <= x < 10^nn

  if k <= nn and nn <= 21:
    # Integer with trailing zeros: digits then (nn-k) zeros.
    for i in 0 ..< k: res.add(digits[i])
    for z in 0 ..< (nn - k): res.add('0')
  elif 0 < nn and nn <= 21:
    # Decimal point inside the digits.
    for i in 0 ..< nn: res.add(digits[i])
    res.add('.')
    for i in nn ..< k: res.add(digits[i])
  elif -6 < nn and nn <= 0:
    # 0.00…digits — leading-zero fraction.
    res.add('0'); res.add('.')
    for z in 0 ..< (-nn): res.add('0')
    for i in 0 ..< k: res.add(digits[i])
  else:
    # Exponential: d.ddd e±(nn-1), minimal exponent digits.
    res.add(digits[0])
    if k > 1:
      res.add('.')
      for i in 1 ..< k: res.add(digits[i])
    res.add('e')
    var ev = nn - 1
    if ev >= 0: res.add('+')
    else: (res.add('-'); ev = -ev)
    var eb: array[8, char]
    var el = 0
    if ev == 0:
      eb[el] = '0'; inc el
    while ev > 0:
      eb[el] = char(ord('0') + (ev mod 10)); inc el
      ev = ev div 10
    for i in countdown(el - 1, 0): res.add(eb[i])

  return res
