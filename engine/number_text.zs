// Number::toString for a double: the shortest decimal digits that read
// back as the double, found in one pass by Ryu's method (Ulf Adams,
// "Ryū: fast float-to-string conversion", PLDI 2018), and laid out as
// ECMA-262 Number::toString lays them out.
//
// Ryu scales the double and the halfway points to its two neighbors by
// a power of ten, with 125-bit powers of five, and drops decimal digits
// while the interval between the halfway points still holds a shorter
// decimal: the result is the shortest decimal that reads back and, of
// those, the closest to the double, ties to even. The halfway points are
// in the interval when the double's significand is even, since reading
// rounds ties to even.
//
// The powers of five are not kept whole (618 of them, about 10 KB): every
// 26th is, and the rest are made from one by a multiply by 5^d, d < 26,
// and a shift, plus a correction of up to two units in the last place,
// kept two bits to an entry. scripts/ryu-tables.py makes the tables and
// checks every entry made this way against the exact power.

import math from "std/math";
import { expect } from "std/test";

struct Wide {
  lo: u64;
  hi: u64;
}

struct Decimal {
  digits: u64;
  exponent: i32;
}

// a * b, from 32-bit halves: no partial sum overflows.
function multiplyWide(a: u64, b: u64): Wide {
  const aLo = a & 0xFFFF_FFFF;
  const aHi = a >> 32;
  const bLo = b & 0xFFFF_FFFF;
  const bHi = b >> 32;
  const b00 = aLo * bLo;
  const b01 = aLo * bHi;
  const b10 = aHi * bLo;
  const b11 = aHi * bHi;
  const mid1 = b10 + (b00 >> 32);
  const mid2 = b01 + (mid1 & 0xFFFF_FFFF);
  const hi = b11 + (mid1 >> 32) + (mid2 >> 32);
  const lo = (mid2 & 0xFFFF_FFFF).wrappingShiftLeft(32) | (b00 & 0xFFFF_FFFF);
  return Wide({ lo: lo, hi: hi });
}

// The 128-bit (hi, lo) shifted right by `distance`, 0 < distance < 64.
function shiftRightWide(lo: u64, hi: u64, distance: u32): u64 {
  return hi.wrappingShiftLeft(usize(64 - distance)) | (lo >> u64(distance));
}

// ceil(log2(5^e)), the bits 5^e takes, for 0 <= e <= 3528.
function pow5Bits(e: i32): i32 {
  return i32(((u64(e) * 1217359) >> 19) + 1);
}

// floor(log10(2^e)), for 0 <= e <= 1650.
function log10Pow2(e: i32): i32 {
  return i32((u64(e) * 78913) >> 18);
}

// floor(log10(5^e)), for 0 <= e <= 2620.
function log10Pow5(e: i32): i32 {
  return i32((u64(e) * 732923) >> 20);
}

// 5^d, d < 26.
function smallPow5(d: u32): u64 {
  const small: u64[26] = [0x0000000000000001, 0x0000000000000005, 0x0000000000000019, 0x000000000000007D, 0x0000000000000271, 0x0000000000000C35, 0x0000000000003D09, 0x000000000001312D, 0x000000000005F5E1, 0x00000000001DCD65, 0x00000000009502F9, 0x0000000002E90EDD, 0x000000000E8D4A51, 0x0000000048C27395, 0x000000016BCC41E9, 0x000000071AFD498D, 0x0000002386F26FC1, 0x000000B1A2BC2EC5, 0x000003782DACE9D9, 0x00001158E460913D, 0x000056BC75E2D631, 0x0001B1AE4D6E2EF5, 0x000878678326EAC9, 0x002A5A058FC295ED, 0x00D3C21BCECCEDA1, 0x0422CA8B0A00A425];
  return unsafe { select small.uncheckedAt(usize(d)); };
}

// (hi, lo) times `multiplier` (at most 59 bits), shifted right by
// `shift` (under 64), plus `fix` less `lessOne`: an entry made from the
// whole power it is near.
function madeEntry(lo: u64, hi: u64, multiplier: u64, shift: u32, fix: u64, lessOne: u64): Wide {
  const low = multiplyWide(lo, multiplier);
  const high = multiplyWide(hi, multiplier);
  const middle = low.hi.wrappingAdd(high.lo);
  let top = high.hi;
  if (middle < low.hi) top = top + 1;
  let outLo = low.lo;
  let outHi = middle;
  if (shift > 0) {
    outLo = (low.lo >> u64(shift)) | middle.wrappingShiftLeft(usize(64 - shift));
    outHi = (middle >> u64(shift)) | top.wrappingShiftLeft(usize(64 - shift));
  }
  const added = outLo.wrappingAdd(fix);
  if (added < outLo) outHi = outHi + 1;
  if (lessOne != 0 && added == 0) outHi = outHi - 1;
  return Wide({ lo: added.wrappingSubtract(lessOne), hi: outHi });
}

// 5^i scaled to exactly 125 bits, rounded down, for i <= 325: the
// multiplier when the double's binary exponent is negative.
function pow5Entry(i: u32): Wide {
  const pow5Low: u64[13] = [0x0000000000000000, 0x0000000000000000, 0x0E549208B31ADB10, 0x6DC6AD264D8F0866, 0xEB1DBD923D8596CA, 0xB4C1B80B22AE923C, 0x5BB28B4E8F7E4C30, 0xF08AED437682D4FB, 0xB4EE134AD99BF150, 0x16499ECB70C25F03, 0x85A56EAD360865B0, 0x093DB1D57999890B, 0xCF38BB735E3F36AC];
  const pow5High: u64[13] = [0x1000000000000000, 0x14ADF4B7320334B9, 0x1ABA4714957D300D, 0x1145B7E285BF98F5, 0x1652EFDC6018A1FC, 0x1CDA62055B2D9D83, 0x12A5568B9F52F416, 0x1819651531F9E78F, 0x1F25C186A6F04C28, 0x1420EB449C8842E6, 0x1A03FDE214CAF085, 0x10CFEB353A97DAD8, 0x15BAAF44FA52673E];
  const pow5Fix: u64[11] = [0x0000000000000000, 0x0000000000000000, 0x5969599540000000, 0x5655551555545555, 0x4055541041150504, 0x4450454044555145, 0x4000400045555550, 0x5556556596440440, 0x4015415154454045, 0x5140555555559155, 0x0000000000000105];
  const base = i / 26;
  const shift = u32(pow5Bits(i32(i)) - pow5Bits(i32(base * 26)));
  const word = unsafe { select pow5Fix.uncheckedAt(usize(i >> 5)); };
  const fix = (word >> u64((i & 31) * 2)) & 3;
  const lo = unsafe { select pow5Low.uncheckedAt(usize(base)); };
  const hi = unsafe { select pow5High.uncheckedAt(usize(base)); };
  return madeEntry(lo, hi, smallPow5(i - base * 26), shift, fix, 0);
}

// floor(2^(pow5Bits(q) - 1 + 125) / 5^q) + 1, for q <= 290: the
// multiplier when the double's binary exponent is not negative. Each is
// made from the next whole one up; its corrections are kept plus one.
function invEntry(q: u32): Wide {
  const invLow: u64[13] = [0x0000000000000001, 0x52A6C95FC0655034, 0x7CA8D50071DFC806, 0x6520247D3556476E, 0x6139CDD76802E6E9, 0xF951A7FF43DE8C79, 0x7BE8BEE8D6E957E8, 0x8BD3F9E999A423EA, 0x0848F973CB3EE3CE, 0x153285EBB9EFBFA2, 0xADEEE7F86C07B696, 0x4D686A4EAF182222, 0x98C0A106E09EBD9F];
  const invHigh: u64[13] = [0x2000000000000000, 0x18C240C4AECB13BB, 0x1327FC58DA0F6FF5, 0x1DA48CE468E7C702, 0x16EF5B40C2FC7779, 0x11BEBDF578B2F391, 0x1B758D848FAC54B0, 0x153EDA614071A3B7, 0x10701BD527B4978C, 0x196FBB9BB44DB44D, 0x13AE3591F5B4D936, 0x1E74404F3DAADA91, 0x17900EA4FDA7C257];
  const invFix: u64[10] = [0x5556AA5AAAAA9AA9, 0x5595595925555555, 0x9A6AAAAA9A666559, 0x515A5554554559A6, 0x69555A9655555554, 0xAA655699555A99A9, 0x96959555A66965A9, 0x55965A5556555566, 0x5AAAAAAAAAA6A955, 0x0000000000000016];
  const base = (q + 25) / 26;
  const shift = u32(pow5Bits(i32(base * 26)) - pow5Bits(i32(q)));
  const word = unsafe { select invFix.uncheckedAt(usize(q >> 5)); };
  const fix = (word >> u64((q & 31) * 2)) & 3;
  const lo = unsafe { select invLow.uncheckedAt(usize(base)); };
  const hi = unsafe { select invHigh.uncheckedAt(usize(base)); };
  return madeEntry(lo, hi, smallPow5(base * 26 - q), shift, fix, 1);
}

// (m * multiplier) >> j, for 64 < j < 128.
function mulShift(m: u64, multiplier: Wide, j: i32): u64 {
  const upper = multiplyWide(m, multiplier.hi);
  const lower = multiplyWide(m, multiplier.lo).hi;
  const sum = lower.wrappingAdd(upper.lo);
  let top = upper.hi;
  if (sum < lower) top = top + 1;
  return shiftRightWide(sum, top, u32(j - 64));
}

// How many times 5 divides `value`, which is not zero.
function pow5Factor(value: u64): i32 {
  let rest = value;
  let count: i32 = 0;
  while (rest % 5 == 0) {
    rest = rest / 5;
    count = count + 1;
  }
  return count;
}

// The shortest decimal reading back as the finite, positive double with
// these bits, with no trailing zeros in its digits.
function shortestDecimal(bits: u64): Decimal {
  const fraction = bits & 0xF_FFFF_FFFF_FFFF;
  const biased = i32(bits >> 52);
  let e2: i32 = 0;
  let m2: u64 = 0;
  if (biased == 0) {
    // Two bits more than the significand has, for the halfway points.
    e2 = 1 - 1023 - 52 - 2;
    m2 = fraction;
  } else {
    e2 = biased - 1023 - 52 - 2;
    m2 = 0x10_0000_0000_0000 | fraction;
  }
  const acceptBounds = (m2 & 1) == 0;
  const mv = 4 * m2;
  // The neighbor below is nearer at a power of two: its halfway point is
  // a quarter step down rather than a half.
  let mmShift: u64 = 0;
  if (fraction != 0 || biased <= 1) mmShift = 1;
  let vr: u64 = 0;
  let vp: u64 = 0;
  let vm: u64 = 0;
  let e10: i32 = 0;
  let vmIsTrailingZeros = false;
  let vrIsTrailingZeros = false;
  if (e2 >= 0) {
    let q = log10Pow2(e2);
    if (e2 > 3) q = q - 1;
    e10 = q;
    const k = 125 + pow5Bits(q) - 1;
    const i = 0 - e2 + q + k;
    const multiplier = invEntry(u32(q));
    vr = mulShift(4 * m2, multiplier, i);
    vp = mulShift(4 * m2 + 2, multiplier, i);
    vm = mulShift(4 * m2 - 1 - mmShift, multiplier, i);
    if (q <= 21) {
      // At most one of mv, mp, and mm is a multiple of 5.
      if (mv % 5 == 0) {
        vrIsTrailingZeros = pow5Factor(mv) >= q;
      } else if (acceptBounds) {
        vmIsTrailingZeros = pow5Factor(mv - 1 - mmShift) >= q;
      } else if (pow5Factor(mv + 2) >= q) {
        vp = vp - 1;
      }
    }
  } else {
    let q = log10Pow5(0 - e2);
    if (0 - e2 > 1) q = q - 1;
    e10 = q + e2;
    const i = 0 - e2 - q;
    const k = pow5Bits(i) - 125;
    const j = q - k;
    const multiplier = pow5Entry(u32(i));
    vr = mulShift(4 * m2, multiplier, j);
    vp = mulShift(4 * m2 + 2, multiplier, j);
    vm = mulShift(4 * m2 - 1 - mmShift, multiplier, j);
    if (q <= 1) {
      // mv = 4 * m2 has two trailing zero bits; mm has one when mmShift
      // is 1; mp = mv + 2 always has one.
      vrIsTrailingZeros = true;
      if (acceptBounds) {
        vmIsTrailingZeros = mmShift == 1;
      } else {
        vp = vp - 1;
      }
    } else if (q < 63) {
      vrIsTrailingZeros = (mv & ((u64(1) << u64(q)) - 1)) == 0;
    }
  }
  // Digits dropped while the interval holds a shorter decimal.
  let removed: i32 = 0;
  let output: u64 = 0;
  if (vmIsTrailingZeros || vrIsTrailingZeros) {
    // The rare case: an end of the interval or the double itself may be
    // exact, and the digits dropped decide the rounding.
    let lastRemoved: u64 = 0;
    while (vp / 10 > vm / 10) {
      vmIsTrailingZeros = vmIsTrailingZeros && vm % 10 == 0;
      vrIsTrailingZeros = vrIsTrailingZeros && lastRemoved == 0;
      lastRemoved = vr % 10;
      vr = vr / 10;
      vp = vp / 10;
      vm = vm / 10;
      removed = removed + 1;
    }
    if (vmIsTrailingZeros) {
      while (vm % 10 == 0) {
        vrIsTrailingZeros = vrIsTrailingZeros && lastRemoved == 0;
        lastRemoved = vr % 10;
        vr = vr / 10;
        vp = vp / 10;
        vm = vm / 10;
        removed = removed + 1;
      }
    }
    // Exactly half way: to even.
    if (vrIsTrailingZeros && lastRemoved == 5 && vr % 2 == 0) lastRemoved = 4;
    output = vr;
    if ((vr == vm && (!acceptBounds || !vmIsTrailingZeros)) || lastRemoved >= 5) output = vr + 1;
  } else {
    let roundUp = false;
    if (vp / 100 > vm / 100) {
      roundUp = vr % 100 >= 50;
      vr = vr / 100;
      vp = vp / 100;
      vm = vm / 100;
      removed = removed + 2;
    }
    while (vp / 10 > vm / 10) {
      roundUp = vr % 10 >= 5;
      vr = vr / 10;
      vp = vp / 10;
      vm = vm / 10;
      removed = removed + 1;
    }
    output = vr;
    if (vr == vm || roundUp) output = vr + 1;
  }
  let exponent = e10 + removed;
  while (output % 10 == 0) {
    output = output / 10;
    exponent = exponent + 1;
  }
  return Decimal({ digits: output, exponent: exponent });
}

// How many decimal digits `value` has, for value < 10^17.
function digitCount(value: u64): usize {
  let count: usize = 1;
  let bound: u64 = 10;
  while (count < 17 && value >= bound) {
    count = count + 1;
    bound = bound * 10;
  }
  return count;
}

function pow10(count: usize): u64 {
  let value: u64 = 1;
  let k: usize = 0;
  while (k < count) {
    value = value * 10;
    k = k + 1;
  }
  return value;
}

// The `count` low decimal digits of `value`, leading zeros kept, at
// `at`; the end.
function writeDigits(inout text: u8[32], at: usize, value: u64, count: usize): usize {
  let rest = value;
  let index = at + count;
  while (index > at) {
    index = index - 1;
    text[index] = u8(48 + rest % 10);
    rest = rest / 10;
  }
  return at + count;
}

function writeZeros(inout text: u8[32], at: usize, count: usize): usize {
  let index = at;
  while (index < at + count) {
    text[index] = 48;
    index = index + 1;
  }
  return index;
}

function writeWord(inout text: u8[32], at: usize, in word: String): usize {
  let index: usize = 0;
  while (index < word.byteLength) {
    text[at + index] = word.byteAt(index);
    index = index + 1;
  }
  return at + word.byteLength;
}

// ToString(Number) of a double into `text`, as Number::toString lays it
// out, or with `exponentForm` always in exponent form, as
// Number.prototype.toExponential() with no fraction digits gives it; the
// length. At most 25 bytes.
export function doubleTextInto(inout text: u8[32], value: f64, exponentForm: boolean): usize {
  if (value != value) {
    const nan: String = "NaN";
    return writeWord(inout text, 0, in nan);
  }
  const bits = value.toBits();
  let at: usize = 0;
  if ((bits >> 63) != 0 && value != 0.0) {
    text[0] = 45;
    at = 1;
  }
  if ((bits & 0x7FF0_0000_0000_0000) == 0x7FF0_0000_0000_0000) {
    const infinity: String = "Infinity";
    return writeWord(inout text, at, in infinity);
  }
  if (value == 0.0) {
    const zero: String = "0";
    const zeroExponent: String = "0e+0";
    if (exponentForm) return writeWord(inout text, 0, in zeroExponent);
    return writeWord(inout text, 0, in zero);
  }
  const magnitude = at == 1 ? 0.0 - value : value;
  if (!exponentForm && magnitude <= 1e15 && math.trunc(magnitude) == magnitude) {
    const whole = u64(magnitude);
    return writeDigits(inout text, at, whole, digitCount(whole));
  }
  const decimal = shortestDecimal(bits & 0x7FFF_FFFF_FFFF_FFFF);
  const count = digitCount(decimal.digits);
  const k = i32(count);
  // The decimal point's place: the value is 0.d1d2...dk times 10^n.
  const n = decimal.exponent + k;
  if (!exponentForm && k <= n && n <= 21) {
    at = writeDigits(inout text, at, decimal.digits, count);
    return writeZeros(inout text, at, usize(n - k));
  }
  if (!exponentForm && 0 < n && n <= 21) {
    const scale = pow10(usize(k - n));
    at = writeDigits(inout text, at, decimal.digits / scale, usize(n));
    text[at] = 46;
    return writeDigits(inout text, at + 1, decimal.digits % scale, usize(k - n));
  }
  if (!exponentForm && -6 < n && n <= 0) {
    text[at] = 48;
    text[at + 1] = 46;
    at = writeZeros(inout text, at + 2, usize(0 - n));
    return writeDigits(inout text, at, decimal.digits, count);
  }
  const scale = pow10(count - 1);
  at = writeDigits(inout text, at, decimal.digits / scale, 1);
  if (count > 1) {
    text[at] = 46;
    at = writeDigits(inout text, at + 1, decimal.digits % scale, count - 1);
  }
  text[at] = 101;
  const power = n - 1;
  text[at + 1] = power < 0 ? 45 : 43;
  const size = u64(power < 0 ? 0 - power : power);
  return writeDigits(inout text, at + 2, size, digitCount(size));
}

// Entries whose corrections are 1 and 2 (powers) and -1 and +1
// (inverses), and the last of each, against the exact values
// scripts/ryu-tables.py computes. Most digit strings never show an entry
// a unit off in its 125th bit, so the entries are checked themselves.
test "the powers of five made from the kept ones are exact" {
  const madePow579 = pow5Entry(79);
  expect(madePow579.lo).toEqual(0xC938586FE0F2CA80);
  expect(madePow579.hi).toEqual(0x159725DB272F7F32);
  const madePow580 = pow5Entry(80);
  expect(madePow580.lo).toEqual(0x7B866E8BD92F7D20);
  expect(madePow580.hi).toEqual(0x1AFCEF51F0FB5EFF);
  const madePow583 = pow5Entry(83);
  expect(madePow583.lo).toEqual(0x7EA147F492186032);
  expect(madePow583.hi).toEqual(0x1A5B01B605557AC5);
  const madePow585 = pow5Entry(85);
  expect(madePow585.lo).toEqual(0x4AEE003712230B27);
  expect(madePow585.hi).toEqual(0x14971956342AC7EA);
  const madePow5325 = pow5Entry(325);
  expect(madePow5325.lo).toEqual(0x78E1316E60A48310);
  expect(madePow5325.hi).toEqual(0x18B40A4EEC437C52);
  const madeInv47 = invEntry(47);
  expect(madeInv47.lo).toEqual(0xF5571E03CDC21695);
  expect(madeInv47.hi).toEqual(0x1D3AE36D13BBCE35);
  const madeInv106 = invEntry(106);
  expect(madeInv106.lo).toEqual(0xA568B58E999D5086);
  expect(madeInv106.hi).toEqual(0x1D5B561574765B7C);
  const madeInv1 = invEntry(1);
  expect(madeInv1.lo).toEqual(0x999999999999999A);
  expect(madeInv1.hi).toEqual(0x1999999999999999);
  const madeInv2 = invEntry(2);
  expect(madeInv2.lo).toEqual(0x47AE147AE147AE15);
  expect(madeInv2.hi).toEqual(0x147AE147AE147AE1);
  const madeInv290 = invEntry(290);
  expect(madeInv290.lo).toEqual(0xBAB3BEB73DED4483);
  expect(madeInv290.hi).toEqual(0x18F2B061AEA07183);
}
