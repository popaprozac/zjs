#!/usr/bin/env python3
"""The tables of engine/number_text.zs: Ryu's 125-bit powers of five for doubles, kept compactly.
Every 26th entry is kept whole; the rest are made from one by a multiply by 5^d (d < 26) and a
shift, plus a correction kept two bits to an entry. Checks every entry the conversion can ask
for, made that way, against the exact value, and prints the tables as Z constants.
  python3 scripts/ryu-tables.py
  POW5[i]  = 5^i scaled to exactly 125 bits (floor), i = 0..325          (e2 < 0)
  INV[q]   = floor(2^(pow5bits(q) - 1 + 125) / 5^q) + 1, q = 0..290     (e2 >= 0)"""
import sys
B = 125
def pow5bits(e): return ((e * 1217359) >> 19) + 1
def log10pow2(e): return (e * 78913) >> 18
def log10pow5(e): return (e * 732923) >> 20
def pow5(i):
    v = 5 ** i; b = v.bit_length()
    assert b == pow5bits(i), (i, b, pow5bits(i))
    return v >> (b - B) if b >= B else v << (B - b)
def inv(q): return (1 << (pow5bits(q) - 1 + B)) // (5 ** q) + 1

# The indexes the conversion uses, over every biased exponent.
need_pow5, need_inv = set(), set()
for ieee in range(0, 2047):
    e2 = (1 if ieee == 0 else ieee) - 1023 - 52 - 2
    if e2 >= 0:
        q = log10pow2(e2) - (1 if e2 > 3 else 0); need_inv.add(q)
    else:
        q = log10pow5(-e2) - (1 if -e2 > 1 else 0); need_pow5.add(-e2 - q)
NP, NI = max(need_pow5) + 1, max(need_inv) + 1
STEP = 26
def made_pow5(i):
    b, d = divmod(i, STEP)
    base = pow5(b * STEP)
    return (base * 5 ** d) >> (pow5bits(i) - pow5bits(b * STEP))
def made_inv(q):
    b = -(-q // STEP); d = b * STEP - q
    base = inv(b * STEP)
    return (base * 5 ** d) >> (pow5bits(b * STEP) - pow5bits(q))
dp = [pow5(i) - made_pow5(i) for i in range(NP)]
di = [inv(q) - made_inv(q) for q in range(NI)]
print("// pow5 entries", NP, "inv entries", NI, "pow5 corrections", sorted(set(dp)), "inv corrections", sorted(set(di)), file=sys.stderr)
assert set(dp) <= {0, 1, 2, 3} and set(di) <= {-1, 0, 1, 2}
# The inverse corrections are kept plus one.
for i in range(NP): assert pow5(i) < (1 << B) and made_pow5(i) + dp[i] == pow5(i)
for q in range(NI): assert inv(q) < (1 << 126) and made_inv(q) + di[q] == inv(q)
# Shifts stay under 64, and the 192-bit products' top limb shifted out fits.
for i in range(NP): assert 0 <= pow5bits(i) - pow5bits((i // STEP) * STEP) < 64
for q in range(NI): b = -(-q // STEP); assert 0 <= pow5bits(b * STEP) - pow5bits(q) < 64
def packed(ds):
    words = []
    for w in range(0, len(ds), 32):
        v = 0
        for k, d in enumerate(ds[w:w + 32]): v |= d << (2 * k)
        words.append(v)
    return words
bases_p = [pow5(b * STEP) for b in range((NP - 1) // STEP + 1)]
bases_i = [inv(b * STEP) for b in range((NI - 1 + STEP - 1) // STEP + 1)]
def limbs(v): return (v & (2**64 - 1), v >> 64)
def z(name, vals):
    return "  const %s: u64[%d] = [%s];" % (name, len(vals), ", ".join("0x%016X" % v for v in vals))
print(z("pow5Low", [limbs(v)[0] for v in bases_p]))
print(z("pow5High", [limbs(v)[1] for v in bases_p]))
print(z("invLow", [limbs(v)[0] for v in bases_i]))
print(z("invHigh", [limbs(v)[1] for v in bases_i]))
print(z("pow5Fix", packed(dp)))
print(z("invFix", packed([d + 1 for d in di])))
print(z("small", [5 ** d for d in range(STEP)]))
