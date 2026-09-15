// Date: a time value in milliseconds since the epoch kept in a hidden
// slot, the specification's arithmetic over f64, local time through the
// host's libc (clock.h), and the ISO and toString forms parsed back.
import { thread } from "std/thread";
import math from "std/math";
import native from "clock.h";
import { Value, undefinedValue, nullValue, int32Value, doubleValue, cellValue, asCell, isUndefined, isNull, isNumber, asInt32, isDeleted } from "../value.zs";
import { PROP_METHOD, PROP_CONFIGURABLE, bytesOf } from "../heap.zs";
import { Runtime, HostFunction, HINT_DEFAULT, HINT_NUMBER, nanValue, toNumber } from "../runtime.zs";

const MS_PER_DAY: f64 = 86400000.0;
const MS_PER_HOUR: f64 = 3600000.0;
const MS_PER_MINUTE: f64 = 60000.0;
const MS_PER_SECOND: f64 = 1000.0;
const MAX_TIME: f64 = 8640000000000000.0;

// --- Time arithmetic (ECMA-262 21.4.1) ---

function isNan(value: f64): boolean {
  return value != value;
}

function finiteDouble(value: f64): boolean {
  return value - value == 0.0;
}

function floorDouble(value: f64): f64 {
  const truncated = math.trunc(value);
  return value < truncated ? truncated - 1.0 : truncated;
}

function posMod(value: f64, modulus: f64): f64 {
  return value - floorDouble(value / modulus) * modulus;
}

function toIntegerOrInfinity(value: f64): f64 {
  if (isNan(value)) return 0.0;
  return math.trunc(value);
}

function dayNumber(t: f64): f64 {
  return floorDouble(t / MS_PER_DAY);
}

function timeWithinDay(t: f64): f64 {
  return posMod(t, MS_PER_DAY);
}

function daysInYear(year: f64): f64 {
  if (posMod(year, 4.0) != 0.0) return 365.0;
  if (posMod(year, 100.0) != 0.0) return 366.0;
  if (posMod(year, 400.0) != 0.0) return 365.0;
  return 366.0;
}

function dayFromYear(year: f64): f64 {
  return 365.0 * (year - 1970.0) + floorDouble((year - 1969.0) / 4.0) - floorDouble((year - 1901.0) / 100.0) + floorDouble((year - 1601.0) / 400.0);
}

function timeFromYear(year: f64): f64 {
  return MS_PER_DAY * dayFromYear(year);
}

function yearFromTime(t: f64): f64 {
  let year = floorDouble(t / (MS_PER_DAY * 365.2425)) + 1970.0;
  while (timeFromYear(year) > t) { year = year - 1.0; }
  while (timeFromYear(year + 1.0) <= t) { year = year + 1.0; }
  return year;
}

function daysInMonth(month: u32, leap: boolean): f64 {
  if (month == 1) return leap ? 29.0 : 28.0;
  if (month == 3 || month == 5 || month == 8 || month == 10) return 30.0;
  return 31.0;
}

// Days from the start of the year to the start of `month`.
function monthStart(month: u32, leap: boolean): f64 {
  let total: f64 = 0.0;
  let m: u32 = 0;
  while (m < month) {
    total = total + daysInMonth(m, leap);
    m = m + 1;
  }
  return total;
}

function monthFromTime(t: f64): u32 {
  const year = yearFromTime(t);
  const leap = daysInYear(year) == 366.0;
  const dayInYear = dayNumber(t) - dayFromYear(year);
  let month: u32 = 0;
  while (month < 11 && dayInYear >= monthStart(month + 1, leap)) { month = month + 1; }
  return month;
}

function dateFromTime(t: f64): f64 {
  const year = yearFromTime(t);
  const leap = daysInYear(year) == 366.0;
  const dayInYear = dayNumber(t) - dayFromYear(year);
  return dayInYear - monthStart(monthFromTime(t), leap) + 1.0;
}

function weekDay(t: f64): f64 {
  return posMod(dayNumber(t) + 4.0, 7.0);
}

function hourFromTime(t: f64): f64 {
  return posMod(floorDouble(t / MS_PER_HOUR), 24.0);
}

function minFromTime(t: f64): f64 {
  return posMod(floorDouble(t / MS_PER_MINUTE), 60.0);
}

function secFromTime(t: f64): f64 {
  return posMod(floorDouble(t / MS_PER_SECOND), 60.0);
}

function msFromTime(t: f64): f64 {
  return posMod(t, MS_PER_SECOND);
}

function makeTime(hour: f64, minute: f64, second: f64, milli: f64): f64 {
  if (!finiteDouble(hour) || !finiteDouble(minute) || !finiteDouble(second) || !finiteDouble(milli)) return nanValue();
  // Each product is its own statement so the C compiler cannot fuse a
  // multiply into the following add; the rounding is observable.
  const hours = toIntegerOrInfinity(hour) * MS_PER_HOUR;
  const minutes = toIntegerOrInfinity(minute) * MS_PER_MINUTE;
  const seconds = toIntegerOrInfinity(second) * MS_PER_SECOND;
  const sum = hours + minutes;
  const withSeconds = sum + seconds;
  return withSeconds + toIntegerOrInfinity(milli);
}

function makeDay(year: f64, month: f64, date: f64): f64 {
  if (!finiteDouble(year) || !finiteDouble(month) || !finiteDouble(date)) return nanValue();
  const y = toIntegerOrInfinity(year);
  const m = toIntegerOrInfinity(month);
  const dt = toIntegerOrInfinity(date);
  const ym = y + floorDouble(m / 12.0);
  if (!finiteDouble(ym) || ym > 400000.0 || ym < -400000.0) return nanValue();
  const mn = posMod(m, 12.0);
  const leap = daysInYear(ym) == 366.0;
  const monthIndex = u32(math.trunc(mn));
  return dayFromYear(ym) + monthStart(monthIndex, leap) + dt - 1.0;
}

function makeDate(day: f64, time: f64): f64 {
  if (!finiteDouble(day) || !finiteDouble(time)) return nanValue();
  const days = day * MS_PER_DAY;
  const tv = days + time;
  if (!finiteDouble(tv)) return nanValue();
  return tv;
}

function timeClip(t: f64): f64 {
  if (!finiteDouble(t)) return nanValue();
  if (t > MAX_TIME || t < -MAX_TIME) return nanValue();
  return toIntegerOrInfinity(t) + 0.0;
}

// The local zone's offset from UTC at an instant. Given local time, the
// instant is found by a first guess at the offset.
function localOffset(t: f64, isUtc: boolean): f64 {
  if (isNan(t)) return 0.0;
  if (isUtc) return native.zjs_local_offset_ms(t);
  const guess = native.zjs_local_offset_ms(t);
  return native.zjs_local_offset_ms(t - guess);
}

function localTime(t: f64): f64 {
  return t + localOffset(t, true);
}

function utcFromLocal(t: f64): f64 {
  return t - localOffset(t, false);
}

// --- Formatting ---

function pushDigits(inout bytes: Array<u8>, value: f64, width: u32): void {
  let digits = Array<u8>();
  let remaining = value;
  if (remaining < 1.0) digits.push(48);
  while (remaining >= 1.0) {
    const next = floorDouble(remaining / 10.0);
    const digit = u32(math.trunc(remaining - next * 10.0));
    digits.push(u8(48 + digit));
    remaining = next;
  }
  let pad = width;
  while (pad > u32(digits.length)) {
    bytes.push(48);
    pad = pad - 1;
  }
  let index = digits.length;
  while (index > 0) {
    index = index - 1;
    bytes.push(digits[index]);
  }
}

function pushText(inout bytes: Array<u8>, in text: String): void {
  const source = bytesOf(in text);
  let i: usize = 0;
  while (i < source.length) {
    bytes.push(source[i]);
    i = i + 1;
  }
}

function pushName(inout bytes: Array<u8>, in names: String, index: u32): void {
  const source = bytesOf(in names);
  const start = usize(index) * 3;
  bytes.push(source[start]);
  bytes.push(source[start + 1]);
  bytes.push(source[start + 2]);
}

function pushMonthName(inout bytes: Array<u8>, month: u32): void {
  const names: String = "JanFebMarAprMayJunJulAugSepOctNovDec";
  pushName(inout bytes, in names, month);
}

function pushDayName(inout bytes: Array<u8>, day: u32): void {
  const names: String = "SunMonTueWedThuFriSat";
  pushName(inout bytes, in names, day);
}

function pushYear(inout bytes: Array<u8>, year: f64): void {
  if (year < 0.0) {
    bytes.push(45);
    pushDigits(inout bytes, 0.0 - year, 4);
  } else {
    pushDigits(inout bytes, year, 4);
  }
}

// "Www Mmm DD YYYY"
function pushDatePart(inout bytes: Array<u8>, t: f64): void {
  pushDayName(inout bytes, u32(math.trunc(weekDay(t))));
  bytes.push(32);
  pushMonthName(inout bytes, monthFromTime(t));
  bytes.push(32);
  pushDigits(inout bytes, dateFromTime(t), 2);
  bytes.push(32);
  pushYear(inout bytes, yearFromTime(t));
}

// "HH:mm:ss"
function pushTimePart(inout bytes: Array<u8>, t: f64): void {
  pushDigits(inout bytes, hourFromTime(t), 2);
  bytes.push(58);
  pushDigits(inout bytes, minFromTime(t), 2);
  bytes.push(58);
  pushDigits(inout bytes, secFromTime(t), 2);
}

// "GMT-0700 (PDT)": the offset in force at the UTC instant, and the
// zone's abbreviation when the host has one.
function pushZonePart(inout bytes: Array<u8>, utc: f64): void {
  const offset = localOffset(utc, true);
  const gmt: String = "GMT";
  pushText(inout bytes, in gmt);
  let magnitude = offset;
  if (offset < 0.0) {
    bytes.push(45);
    magnitude = 0.0 - offset;
  } else {
    bytes.push(43);
  }
  const minutes = floorDouble(magnitude / MS_PER_MINUTE);
  pushDigits(inout bytes, floorDouble(minutes / 60.0), 2);
  pushDigits(inout bytes, posMod(minutes, 60.0), 2);
  let name = Array<u8>();
  let index: i32 = 0;
  while (index < 64) {
    const byte = native.zjs_local_zone_byte(utc, index);
    if (byte < 0) break;
    name.push(u8(byte));
    index = index + 1;
  }
  if (name.length > 0) {
    bytes.push(32);
    bytes.push(40);
    let k: usize = 0;
    while (k < name.length) {
      bytes.push(name[k]);
      k = k + 1;
    }
    bytes.push(41);
  }
}

// "YYYY-MM-DDTHH:mm:ss.sssZ", the year expanded to six digits with a
// sign outside 0..9999.
function pushIso(inout bytes: Array<u8>, t: f64): void {
  const year = yearFromTime(t);
  if (year < 0.0) {
    bytes.push(45);
    pushDigits(inout bytes, 0.0 - year, 6);
  } else if (year > 9999.0) {
    bytes.push(43);
    pushDigits(inout bytes, year, 6);
  } else {
    pushDigits(inout bytes, year, 4);
  }
  bytes.push(45);
  pushDigits(inout bytes, f64(monthFromTime(t)) + 1.0, 2);
  bytes.push(45);
  pushDigits(inout bytes, dateFromTime(t), 2);
  bytes.push(84);
  pushTimePart(inout bytes, t);
  bytes.push(46);
  pushDigits(inout bytes, msFromTime(t), 3);
  bytes.push(90);
}

const FORMAT_STRING: i32 = 0;
const FORMAT_DATE: i32 = 1;
const FORMAT_TIME: i32 = 2;
const FORMAT_UTC: i32 = 3;
const FORMAT_ISO: i32 = 4;

// The string forms of a valid time value.
function formatDate(inout runtime: Runtime, t: f64, format: i32): Value {
  let bytes = Array<u8>();
  if (format == FORMAT_ISO) {
    pushIso(inout bytes, t);
    return runtime.newString(move bytes);
  }
  if (format == FORMAT_UTC) {
    pushDayName(inout bytes, u32(math.trunc(weekDay(t))));
    bytes.push(44);
    bytes.push(32);
    pushDigits(inout bytes, dateFromTime(t), 2);
    bytes.push(32);
    pushMonthName(inout bytes, monthFromTime(t));
    bytes.push(32);
    pushYear(inout bytes, yearFromTime(t));
    bytes.push(32);
    pushTimePart(inout bytes, t);
    const gmt: String = " GMT";
    pushText(inout bytes, in gmt);
    return runtime.newString(move bytes);
  }
  const local = localTime(t);
  if (format == FORMAT_DATE) {
    pushDatePart(inout bytes, local);
    return runtime.newString(move bytes);
  }
  if (format == FORMAT_STRING) {
    pushDatePart(inout bytes, local);
    bytes.push(32);
  }
  pushTimePart(inout bytes, local);
  bytes.push(32);
  pushZonePart(inout bytes, t);
  return runtime.newString(move bytes);
}

// --- Parsing ---

function isDigit(byte: u8): boolean {
  return byte >= 48 && byte <= 57;
}

function isAlpha(byte: u8): boolean {
  return (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122);
}

function lowerByte(byte: u8): u8 {
  if (byte >= 65 && byte <= 90) return byte + 32;
  return byte;
}

// Exactly `count` digits at `pos`, advancing past them; -1 if fewer.
function readDigits(in bytes: Array<u8>, inout pos: usize, count: usize): f64 {
  let value: f64 = 0.0;
  let seen: usize = 0;
  while (seen < count) {
    if (pos >= bytes.length || !isDigit(bytes[pos])) return -1.0;
    value = value * 10.0 + f64(bytes[pos] - 48);
    pos = pos + 1;
    seen = seen + 1;
  }
  return value;
}

// The Date Time String Format: YYYY[-MM[-DD]][THH:mm[:ss[.sss]][Z|+HH:mm]]
// with a six-digit signed year allowed. A date-only form is UTC; a
// date-time without an offset is local time.
function parseIso(in bytes: Array<u8>): f64 {
  let pos: usize = 0;
  const length = bytes.length;
  let sign: f64 = 1.0;
  let yearDigits: usize = 4;
  if (pos < length && (bytes[pos] == 43 || bytes[pos] == 45)) {
    if (bytes[pos] == 45) sign = -1.0;
    pos = pos + 1;
    yearDigits = 6;
  }
  const yearMagnitude = readDigits(in bytes, inout pos, yearDigits);
  if (yearMagnitude < 0.0) return nanValue();
  if (yearDigits == 6 && sign < 0.0 && yearMagnitude == 0.0) return nanValue();
  const year = sign * yearMagnitude;
  let month: f64 = 1.0;
  let day: f64 = 1.0;
  if (pos < length && bytes[pos] == 45) {
    pos = pos + 1;
    month = readDigits(in bytes, inout pos, 2);
    if (month < 1.0 || month > 12.0) return nanValue();
    if (pos < length && bytes[pos] == 45) {
      pos = pos + 1;
      day = readDigits(in bytes, inout pos, 2);
      if (day < 1.0 || day > 31.0) return nanValue();
    }
  }
  let hour: f64 = 0.0;
  let minute: f64 = 0.0;
  let second: f64 = 0.0;
  let milli: f64 = 0.0;
  let hasTime = false;
  let hasOffset = false;
  let offset: f64 = 0.0;
  if (pos < length && bytes[pos] == 84) {
    pos = pos + 1;
    hasTime = true;
    hour = readDigits(in bytes, inout pos, 2);
    if (hour < 0.0 || pos >= length || bytes[pos] != 58) return nanValue();
    pos = pos + 1;
    minute = readDigits(in bytes, inout pos, 2);
    if (minute < 0.0) return nanValue();
    if (pos < length && bytes[pos] == 58) {
      pos = pos + 1;
      second = readDigits(in bytes, inout pos, 2);
      if (second < 0.0) return nanValue();
      if (pos < length && bytes[pos] == 46) {
        pos = pos + 1;
        let scale: f64 = 100.0;
        let seen: usize = 0;
        while (pos < length && isDigit(bytes[pos])) {
          if (seen < 3) milli = milli + f64(bytes[pos] - 48) * scale;
          scale = scale / 10.0;
          seen = seen + 1;
          pos = pos + 1;
        }
        if (seen == 0) return nanValue();
      }
    }
    if (hour > 24.0 || minute > 59.0 || second > 59.0) return nanValue();
    if (hour == 24.0 && (minute != 0.0 || second != 0.0 || milli != 0.0)) return nanValue();
    if (pos < length && bytes[pos] == 90) {
      pos = pos + 1;
      hasOffset = true;
    } else if (pos < length && (bytes[pos] == 43 || bytes[pos] == 45)) {
      const offsetSign: f64 = bytes[pos] == 45 ? -1.0 : 1.0;
      pos = pos + 1;
      const offsetHours = readDigits(in bytes, inout pos, 2);
      if (offsetHours < 0.0 || offsetHours > 23.0 || pos >= length || bytes[pos] != 58) return nanValue();
      pos = pos + 1;
      const offsetMinutes = readDigits(in bytes, inout pos, 2);
      if (offsetMinutes < 0.0 || offsetMinutes > 59.0) return nanValue();
      offset = offsetSign * (offsetHours * 60.0 + offsetMinutes) * MS_PER_MINUTE;
      hasOffset = true;
    }
  }
  if (pos != length) return nanValue();
  let t = makeDate(makeDay(year, month - 1.0, day), makeTime(hour, minute, second, milli));
  if (hasTime && !hasOffset) {
    t = utcFromLocal(t);
  } else {
    t = t - offset;
  }
  return timeClip(t);
}

// The index of the month or weekday whose three-letter name starts the
// word at `start`, or -1.
function nameIndex(in bytes: Array<u8>, start: usize, length: usize, in names: String, count: u32): i32 {
  if (length < 3) return -1;
  const source = bytesOf(in names);
  let index: u32 = 0;
  while (index < count) {
    const base = usize(index) * 3;
    if (lowerByte(bytes[start]) == lowerByte(source[base]) && lowerByte(bytes[start + 1]) == lowerByte(source[base + 1]) && lowerByte(bytes[start + 2]) == lowerByte(source[base + 2])) return i32(index);
    index = index + 1;
  }
  return -1;
}

function wordIs(in bytes: Array<u8>, start: usize, length: usize, in text: String): boolean {
  const source = bytesOf(in text);
  if (source.length != length) return false;
  let i: usize = 0;
  while (i < length) {
    if (lowerByte(bytes[start + i]) != source[i]) return false;
    i = i + 1;
  }
  return true;
}

// The forms toString and toUTCString produce, and the like: a month
// name, a day, a year, an optional time, an optional zone with offset.
function parseLoose(in bytes: Array<u8>): f64 {
  const length = bytes.length;
  let pos: usize = 0;
  let year: f64 = 0.0;
  let hasYear = false;
  let month: i32 = -1;
  let day: f64 = 1.0;
  let hasDay = false;
  let hour: f64 = 0.0;
  let minute: f64 = 0.0;
  let second: f64 = 0.0;
  let milli: f64 = 0.0;
  let hasTime = false;
  let offset: f64 = 0.0;
  let hasOffset = false;
  while (pos < length) {
    const byte = bytes[pos];
    if (byte == 40) {
      while (pos < length && bytes[pos] != 41) { pos = pos + 1; }
      pos = pos + 1;
      continue;
    }
    if (isAlpha(byte)) {
      const start = pos;
      while (pos < length && isAlpha(bytes[pos])) { pos = pos + 1; }
      const wordLength = pos - start;
      const monthNames: String = "JanFebMarAprMayJunJulAugSepOctNovDec";
      const dayNames: String = "SunMonTueWedThuFriSat";
      const monthFound = nameIndex(in bytes, start, wordLength, in monthNames, 12);
      const dayFound = nameIndex(in bytes, start, wordLength, in dayNames, 7);
      const gmtText: String = "gmt";
      const utcText: String = "utc";
      const utText: String = "ut";
      const zText: String = "z";
      const amText: String = "am";
      const pmText: String = "pm";
      const tText: String = "t";
      if (monthFound >= 0) {
        if (month >= 0) return nanValue();
        month = monthFound;
      } else if (dayFound >= 0 || wordIs(in bytes, start, wordLength, in tText)) {
        // A weekday name carries no information; T separates.
      } else if (wordIs(in bytes, start, wordLength, in gmtText) || wordIs(in bytes, start, wordLength, in utcText) || wordIs(in bytes, start, wordLength, in utText) || wordIs(in bytes, start, wordLength, in zText)) {
        hasOffset = true;
      } else if (wordIs(in bytes, start, wordLength, in amText)) {
        if (hour == 12.0) hour = 0.0;
      } else if (wordIs(in bytes, start, wordLength, in pmText)) {
        if (hour < 12.0) hour = hour + 12.0;
      } else {
        return nanValue();
      }
      continue;
    }
    if (isDigit(byte)) {
      const start = pos;
      let value: f64 = 0.0;
      while (pos < length && isDigit(bytes[pos])) {
        value = value * 10.0 + f64(bytes[pos] - 48);
        pos = pos + 1;
      }
      const digitCount = pos - start;
      if (pos < length && bytes[pos] == 58) {
        if (hasTime) return nanValue();
        hasTime = true;
        hour = value;
        pos = pos + 1;
        minute = readDigits(in bytes, inout pos, 2);
        if (minute < 0.0) return nanValue();
        if (pos < length && bytes[pos] == 58) {
          pos = pos + 1;
          second = readDigits(in bytes, inout pos, 2);
          if (second < 0.0) return nanValue();
          if (pos < length && bytes[pos] == 46) {
            pos = pos + 1;
            let scale: f64 = 100.0;
            while (pos < length && isDigit(bytes[pos])) {
              milli = milli + f64(bytes[pos] - 48) * scale;
              scale = scale / 10.0;
              pos = pos + 1;
            }
          }
        }
        if (hour > 24.0 || minute > 59.0 || second > 59.0) return nanValue();
      } else if (digitCount >= 3 || value > 31.0) {
        if (hasYear) return nanValue();
        year = value;
        hasYear = true;
      } else if (!hasDay) {
        day = value;
        hasDay = true;
      } else if (!hasYear) {
        year = value;
        hasYear = true;
      } else {
        return nanValue();
      }
      continue;
    }
    if ((byte == 43 || byte == 45) && (hasOffset || hasTime) && pos + 1 < length && isDigit(bytes[pos + 1])) {
      const offsetSign: f64 = byte == 45 ? -1.0 : 1.0;
      pos = pos + 1;
      const offsetHours = readDigits(in bytes, inout pos, 2);
      if (offsetHours < 0.0) return nanValue();
      let offsetMinutes: f64 = 0.0;
      if (pos < length && bytes[pos] == 58) pos = pos + 1;
      if (pos < length && isDigit(bytes[pos])) {
        offsetMinutes = readDigits(in bytes, inout pos, 2);
        if (offsetMinutes < 0.0) return nanValue();
      }
      offset = offsetSign * (offsetHours * 60.0 + offsetMinutes) * MS_PER_MINUTE;
      hasOffset = true;
      continue;
    }
    pos = pos + 1;
  }
  if (!hasYear || month < 0) return nanValue();
  let t = makeDate(makeDay(year, f64(month), day), makeTime(hour, minute, second, milli));
  if (hasOffset) {
    t = t - offset;
  } else {
    t = utcFromLocal(t);
  }
  return timeClip(t);
}

function parseDate(in bytes: Array<u8>): f64 {
  // Leading and trailing whitespace is tolerated.
  let start: usize = 0;
  let end = bytes.length;
  while (start < end && (bytes[start] == 32 || bytes[start] == 9 || bytes[start] == 10 || bytes[start] == 13)) { start = start + 1; }
  while (end > start && (bytes[end - 1] == 32 || bytes[end - 1] == 9 || bytes[end - 1] == 10 || bytes[end - 1] == 13)) { end = end - 1; }
  let trimmed = Array<u8>();
  let i = start;
  while (i < end) {
    trimmed.push(bytes[i]);
    i = i + 1;
  }
  const iso = parseIso(in trimmed);
  if (!isNan(iso)) return iso;
  return parseLoose(in trimmed);
}

// --- The builtin ---

function thisTimeValue(inout runtime: Runtime, thisValue: Value): f64 {
  if (!runtime.isDateObject(thisValue)) {
    const message: String = "this is not a Date object.";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return nanValue();
  }
  return runtime.dateTimeValue(asCell(thisValue));
}

// year, month[, date[, hours[, minutes[, seconds[, ms]]]]] to a time
// value, a two-digit year meaning 19xx; local unless `utc`.
function timeFromComponents(inout runtime: Runtime, argsBase: u32, argc: u32, utc: boolean): f64 {
  const year = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return nanValue();
  let month: f64 = 0.0;
  if (argc > 1) {
    month = runtime.toNumberValue(runtime.argument(argsBase, argc, 1));
    if (runtime.pendingThrow) return nanValue();
  }
  let date: f64 = 1.0;
  if (argc > 2) {
    date = runtime.toNumberValue(runtime.argument(argsBase, argc, 2));
    if (runtime.pendingThrow) return nanValue();
  }
  let hours: f64 = 0.0;
  if (argc > 3) {
    hours = runtime.toNumberValue(runtime.argument(argsBase, argc, 3));
    if (runtime.pendingThrow) return nanValue();
  }
  let minutes: f64 = 0.0;
  if (argc > 4) {
    minutes = runtime.toNumberValue(runtime.argument(argsBase, argc, 4));
    if (runtime.pendingThrow) return nanValue();
  }
  let seconds: f64 = 0.0;
  if (argc > 5) {
    seconds = runtime.toNumberValue(runtime.argument(argsBase, argc, 5));
    if (runtime.pendingThrow) return nanValue();
  }
  let milli: f64 = 0.0;
  if (argc > 6) {
    milli = runtime.toNumberValue(runtime.argument(argsBase, argc, 6));
    if (runtime.pendingThrow) return nanValue();
  }
  let fullYear = year;
  if (!isNan(year)) {
    const integral = toIntegerOrInfinity(year);
    if (integral >= 0.0 && integral <= 99.0) fullYear = 1900.0 + integral;
  }
  const finalDate = makeDate(makeDay(fullYear, month, date), makeTime(hours, minutes, seconds, milli));
  if (utc) return timeClip(finalDate);
  return timeClip(utcFromLocal(finalDate));
}

// Date(...) as a function is the current time as a string; new Date()
// constructs from nothing (now), one value (a Date, a string to parse,
// or a number), or components.
function constructDate(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    return formatDate(inout runtime, timeClip(native.zjs_clock_now_ms()), FORMAT_STRING);
  }
  let tv = nanValue();
  if (argc == 0) {
    tv = timeClip(native.zjs_clock_now_ms());
  } else if (argc == 1) {
    const value = runtime.argument(argsBase, argc, 0);
    if (runtime.isDateObject(value)) {
      tv = runtime.dateTimeValue(asCell(value));
    } else {
      const primitive = runtime.toPrimitiveWithHint(value, HINT_DEFAULT);
      if (runtime.pendingThrow) return undefinedValue();
      if (runtime.isStringValue(primitive)) {
        const text = runtime.heap.stringBytes(asCell(primitive));
        tv = parseDate(in text);
      } else {
        const number = runtime.toNumberValue(primitive);
        if (runtime.pendingThrow) return undefinedValue();
        tv = timeClip(number);
      }
    }
  } else {
    tv = timeFromComponents(inout runtime, argsBase, argc, false);
    if (runtime.pendingThrow) return undefinedValue();
  }
  runtime.setDateTimeValue(asCell(thisValue), tv);
  return thisValue;
}

function dateNow(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return doubleValue(timeClip(native.zjs_clock_now_ms()));
}

function dateParse(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  const bytes = runtime.heap.stringBytes(asCell(text));
  return doubleValue(parseDate(in bytes));
}

function dateUtc(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const tv = timeFromComponents(inout runtime, argsBase, argc, true);
  if (runtime.pendingThrow) return undefinedValue();
  return doubleValue(tv);
}

// Getters: the callee's slot 0 names the field (0 date, 1 day, 2 full
// year, 3 hours, 4 milliseconds, 5 minutes, 6 month, 7 seconds), plus 8
// for the UTC variants; 16 getTime / valueOf, 17 getTimezoneOffset, 18
// getYear.
const GET_TIME: i32 = 16;
const GET_TIMEZONE_OFFSET: i32 = 17;
const GET_YEAR: i32 = 18;

function dateGet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const op = asInt32(runtime.heap.slot(callee, 0));
  const t = thisTimeValue(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  if (op == GET_TIME || isNan(t)) return doubleValue(t);
  if (op == GET_TIMEZONE_OFFSET) return doubleValue((t - localTime(t)) / MS_PER_MINUTE);
  if (op == GET_YEAR) return doubleValue(yearFromTime(localTime(t)) - 1900.0);
  const isUtc = op >= 8;
  const field = isUtc ? op - 8 : op;
  const local = isUtc ? t : localTime(t);
  if (field == 0) return doubleValue(dateFromTime(local));
  if (field == 1) return doubleValue(weekDay(local));
  if (field == 2) return doubleValue(yearFromTime(local));
  if (field == 3) return doubleValue(hourFromTime(local));
  if (field == 4) return doubleValue(msFromTime(local));
  if (field == 5) return doubleValue(minFromTime(local));
  if (field == 6) return doubleValue(f64(monthFromTime(local)));
  return doubleValue(secFromTime(local));
}

// Setters: slot 0 is the field (0 milliseconds, 1 seconds, 2 minutes,
// 3 hours, 4 date, 5 month, 6 full year), plus 8 for UTC; 16 setTime,
// 17 setYear. The given arguments are converted first, in order, and the
// fields not given keep their current values.
const SET_TIME: i32 = 16;
const SET_YEAR: i32 = 17;

function setterArgCount(field: i32): u32 {
  if (field == 0 || field == 4) return 1;
  if (field == 1 || field == 5) return 2;
  if (field == 2 || field == 6) return 3;
  return 4;
}

function dateSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const op = asInt32(runtime.heap.slot(callee, 0));
  const t = thisTimeValue(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  const handle = asCell(thisValue);
  if (op == SET_TIME) {
    const given = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
    if (runtime.pendingThrow) return undefinedValue();
    const clipped = timeClip(given);
    runtime.setDateTimeValue(handle, clipped);
    return doubleValue(clipped);
  }
  if (op == SET_YEAR) {
    const given = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
    if (runtime.pendingThrow) return undefinedValue();
    const base = isNan(t) ? 0.0 : localTime(t);
    if (isNan(given)) {
      runtime.setDateTimeValue(handle, nanValue());
      return doubleValue(nanValue());
    }
    const integral = toIntegerOrInfinity(given);
    let fullYear = integral;
    if (integral >= 0.0 && integral <= 99.0) fullYear = 1900.0 + integral;
    const day = makeDay(fullYear, f64(monthFromTime(base)), dateFromTime(base));
    const clipped = timeClip(utcFromLocal(makeDate(day, timeWithinDay(base))));
    runtime.setDateTimeValue(handle, clipped);
    return doubleValue(clipped);
  }
  const isUtc = op >= 8;
  const field = isUtc ? op - 8 : op;
  const wanted = setterArgCount(field);
  const first = runtime.toNumberValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  let second: f64 = 0.0;
  let hasSecond = false;
  if (argc > 1 && wanted > 1) {
    second = runtime.toNumberValue(runtime.argument(argsBase, argc, 1));
    if (runtime.pendingThrow) return undefinedValue();
    hasSecond = true;
  }
  let third: f64 = 0.0;
  let hasThird = false;
  if (argc > 2 && wanted > 2) {
    third = runtime.toNumberValue(runtime.argument(argsBase, argc, 2));
    if (runtime.pendingThrow) return undefinedValue();
    hasThird = true;
  }
  let fourth: f64 = 0.0;
  let hasFourth = false;
  if (argc > 3 && wanted > 3) {
    fourth = runtime.toNumberValue(runtime.argument(argsBase, argc, 3));
    if (runtime.pendingThrow) return undefinedValue();
    hasFourth = true;
  }
  let base = t;
  if (isNan(t)) {
    if (field != 6) return doubleValue(t);
    base = 0.0;
  } else if (!isUtc) {
    base = localTime(t);
  }
  let year = yearFromTime(base);
  let month = f64(monthFromTime(base));
  let date = dateFromTime(base);
  let hour = hourFromTime(base);
  let minute = minFromTime(base);
  let seconds = secFromTime(base);
  let milli = msFromTime(base);
  if (field == 0) {
    milli = first;
  } else if (field == 1) {
    seconds = first;
    if (hasSecond) milli = second;
  } else if (field == 2) {
    minute = first;
    if (hasSecond) seconds = second;
    if (hasThird) milli = third;
  } else if (field == 3) {
    hour = first;
    if (hasSecond) minute = second;
    if (hasThird) seconds = third;
    if (hasFourth) milli = fourth;
  } else if (field == 4) {
    date = first;
  } else if (field == 5) {
    month = first;
    if (hasSecond) date = second;
  } else {
    year = first;
    if (hasSecond) month = second;
    if (hasThird) date = third;
  }
  const newDate = makeDate(makeDay(year, month, date), makeTime(hour, minute, seconds, milli));
  const clipped = timeClip(isUtc ? newDate : utcFromLocal(newDate));
  runtime.setDateTimeValue(handle, clipped);
  return doubleValue(clipped);
}

// toString and its relatives: slot 0 is the format. An invalid date
// prints "Invalid Date"; toISOString throws on it instead.
function dateToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const format = asInt32(runtime.heap.slot(callee, 0));
  const t = thisTimeValue(inout runtime, thisValue);
  if (runtime.pendingThrow) return undefinedValue();
  if (isNan(t)) {
    if (format == FORMAT_ISO) {
      const message: String = "Invalid time value";
      const error = runtime.rangeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    const invalid: String = "Invalid Date";
    return runtime.internText(in invalid);
  }
  return formatDate(inout runtime, t, format);
}

// toJSON is generic: the receiver's number form decides finiteness,
// then its own toISOString renders.
function dateToJson(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (isUndefined(thisValue) || isNull(thisValue)) {
    const message: String = "Date.prototype.toJSON called on null or undefined";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const primitive = runtime.toPrimitiveWithHint(thisValue, HINT_NUMBER);
  if (runtime.pendingThrow) return undefinedValue();
  if (isNumber(primitive) && !finiteDouble(toNumber(primitive))) return nullValue();
  const isoText: String = "toISOString";
  const isoKey = runtime.internText(in isoText);
  const method = runtime.getProperty(thisValue, isoKey);
  if (runtime.pendingThrow) return undefinedValue();
  if (!runtime.isCallable(method)) {
    const message: String = "toISOString is not a function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  return runtime.callValue(method, thisValue, Array<Value>());
}

function hintIs(in bytes: Array<u8>, in text: String): boolean {
  const source = bytesOf(in text);
  if (source.length != bytes.length) return false;
  let i: usize = 0;
  while (i < bytes.length) {
    if (bytes[i] != source[i]) return false;
    i = i + 1;
  }
  return true;
}

// [Symbol.toPrimitive](hint): "string" and "default" try toString first,
// "number" tries valueOf first; anything else is a TypeError.
function dateToPrimitive(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = "Date.prototype[Symbol.toPrimitive] called on a non-object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const hint = runtime.argument(argsBase, argc, 0);
  let preferString = false;
  let valid = false;
  if (runtime.isStringValue(hint)) {
    const hintBytes = runtime.heap.stringBytes(asCell(hint));
    const stringText: String = "string";
    const defaultText: String = "default";
    const numberText: String = "number";
    if (hintIs(in hintBytes, in stringText) || hintIs(in hintBytes, in defaultText)) {
      preferString = true;
      valid = true;
    } else if (hintIs(in hintBytes, in numberText)) {
      valid = true;
    }
  }
  if (!valid) {
    const message: String = "Invalid hint";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const valueOfText: String = "valueOf";
  const toStringText: String = "toString";
  let first = undefinedValue();
  if (preferString) {
    first = runtime.tryPrimitiveMethod(thisValue, in toStringText);
  } else {
    first = runtime.tryPrimitiveMethod(thisValue, in valueOfText);
  }
  if (runtime.pendingThrow) return undefinedValue();
  if (!isDeleted(first)) return first;
  let second = undefinedValue();
  if (preferString) {
    second = runtime.tryPrimitiveMethod(thisValue, in valueOfText);
  } else {
    second = runtime.tryPrimitiveMethod(thisValue, in toStringText);
  }
  if (runtime.pendingThrow) return undefinedValue();
  if (!isDeleted(second)) return second;
  const message: String = "Cannot convert object to primitive value";
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return undefinedValue();
}

function defineOp(inout runtime: Runtime, target: u32, in name: String, fn: HostFunction, op: i32, length: u32): u32 {
  const handle = runtime.defineHostFunction(fn, int32Value(op), length, in name);
  const atom = runtime.atomOf(in name);
  runtime.defineOwnAttr(target, atom, cellValue(handle), PROP_METHOD);
  return handle;
}

export function installDate(inout runtime: Runtime): void {
  const objectProto = runtime.objectProto;
  const proto = runtime.heap.allocateObject(objectProto);
  const dateText: String = "Date";
  const ctor = runtime.defineConstructor(constructDate, undefinedValue(), 7, in dateText);
  runtime.heap.setLink(ctor, proto);
  const atomConstructor = runtime.atomConstructor;
  runtime.defineOwnAttr(proto, atomConstructor, cellValue(ctor), PROP_METHOD);
  runtime.setGlobal("Date", cellValue(ctor));

  const nowText: String = "now";
  runtime.defineMethod(ctor, in nowText, dateNow, 0);
  const parseText: String = "parse";
  runtime.defineMethod(ctor, in parseText, dateParse, 1);
  const utcText: String = "UTC";
  runtime.defineMethod(ctor, in utcText, dateUtc, 7);

  const getDateText: String = "getDate"; defineOp(inout runtime, proto, in getDateText, dateGet, 0, 0);
  const getDayText: String = "getDay"; defineOp(inout runtime, proto, in getDayText, dateGet, 1, 0);
  const getFullYearText: String = "getFullYear"; defineOp(inout runtime, proto, in getFullYearText, dateGet, 2, 0);
  const getHoursText: String = "getHours"; defineOp(inout runtime, proto, in getHoursText, dateGet, 3, 0);
  const getMillisecondsText: String = "getMilliseconds"; defineOp(inout runtime, proto, in getMillisecondsText, dateGet, 4, 0);
  const getMinutesText: String = "getMinutes"; defineOp(inout runtime, proto, in getMinutesText, dateGet, 5, 0);
  const getMonthText: String = "getMonth"; defineOp(inout runtime, proto, in getMonthText, dateGet, 6, 0);
  const getSecondsText: String = "getSeconds"; defineOp(inout runtime, proto, in getSecondsText, dateGet, 7, 0);
  const getUTCDateText: String = "getUTCDate"; defineOp(inout runtime, proto, in getUTCDateText, dateGet, 8, 0);
  const getUTCDayText: String = "getUTCDay"; defineOp(inout runtime, proto, in getUTCDayText, dateGet, 9, 0);
  const getUTCFullYearText: String = "getUTCFullYear"; defineOp(inout runtime, proto, in getUTCFullYearText, dateGet, 10, 0);
  const getUTCHoursText: String = "getUTCHours"; defineOp(inout runtime, proto, in getUTCHoursText, dateGet, 11, 0);
  const getUTCMillisecondsText: String = "getUTCMilliseconds"; defineOp(inout runtime, proto, in getUTCMillisecondsText, dateGet, 12, 0);
  const getUTCMinutesText: String = "getUTCMinutes"; defineOp(inout runtime, proto, in getUTCMinutesText, dateGet, 13, 0);
  const getUTCMonthText: String = "getUTCMonth"; defineOp(inout runtime, proto, in getUTCMonthText, dateGet, 14, 0);
  const getUTCSecondsText: String = "getUTCSeconds"; defineOp(inout runtime, proto, in getUTCSecondsText, dateGet, 15, 0);
  const getTimeText: String = "getTime"; defineOp(inout runtime, proto, in getTimeText, dateGet, GET_TIME, 0);
  const valueOfText: String = "valueOf"; defineOp(inout runtime, proto, in valueOfText, dateGet, GET_TIME, 0);
  const getTimezoneOffsetText: String = "getTimezoneOffset"; defineOp(inout runtime, proto, in getTimezoneOffsetText, dateGet, GET_TIMEZONE_OFFSET, 0);
  const getYearText: String = "getYear"; defineOp(inout runtime, proto, in getYearText, dateGet, GET_YEAR, 0);

  const setMillisecondsText: String = "setMilliseconds"; defineOp(inout runtime, proto, in setMillisecondsText, dateSet, 0, 1);
  const setSecondsText: String = "setSeconds"; defineOp(inout runtime, proto, in setSecondsText, dateSet, 1, 2);
  const setMinutesText: String = "setMinutes"; defineOp(inout runtime, proto, in setMinutesText, dateSet, 2, 3);
  const setHoursText: String = "setHours"; defineOp(inout runtime, proto, in setHoursText, dateSet, 3, 4);
  const setDateText: String = "setDate"; defineOp(inout runtime, proto, in setDateText, dateSet, 4, 1);
  const setMonthText: String = "setMonth"; defineOp(inout runtime, proto, in setMonthText, dateSet, 5, 2);
  const setFullYearText: String = "setFullYear"; defineOp(inout runtime, proto, in setFullYearText, dateSet, 6, 3);
  const setUTCMillisecondsText: String = "setUTCMilliseconds"; defineOp(inout runtime, proto, in setUTCMillisecondsText, dateSet, 8, 1);
  const setUTCSecondsText: String = "setUTCSeconds"; defineOp(inout runtime, proto, in setUTCSecondsText, dateSet, 9, 2);
  const setUTCMinutesText: String = "setUTCMinutes"; defineOp(inout runtime, proto, in setUTCMinutesText, dateSet, 10, 3);
  const setUTCHoursText: String = "setUTCHours"; defineOp(inout runtime, proto, in setUTCHoursText, dateSet, 11, 4);
  const setUTCDateText: String = "setUTCDate"; defineOp(inout runtime, proto, in setUTCDateText, dateSet, 12, 1);
  const setUTCMonthText: String = "setUTCMonth"; defineOp(inout runtime, proto, in setUTCMonthText, dateSet, 13, 2);
  const setUTCFullYearText: String = "setUTCFullYear"; defineOp(inout runtime, proto, in setUTCFullYearText, dateSet, 14, 3);
  const setTimeText: String = "setTime"; defineOp(inout runtime, proto, in setTimeText, dateSet, SET_TIME, 1);
  const setYearText: String = "setYear"; defineOp(inout runtime, proto, in setYearText, dateSet, SET_YEAR, 1);

  const toStringText: String = "toString"; defineOp(inout runtime, proto, in toStringText, dateToString, FORMAT_STRING, 0);
  const toDateStringText: String = "toDateString"; defineOp(inout runtime, proto, in toDateStringText, dateToString, FORMAT_DATE, 0);
  const toTimeStringText: String = "toTimeString"; defineOp(inout runtime, proto, in toTimeStringText, dateToString, FORMAT_TIME, 0);
  const toISOStringText: String = "toISOString"; defineOp(inout runtime, proto, in toISOStringText, dateToString, FORMAT_ISO, 0);
  const toLocaleStringText: String = "toLocaleString"; defineOp(inout runtime, proto, in toLocaleStringText, dateToString, FORMAT_STRING, 0);
  const toLocaleDateStringText: String = "toLocaleDateString"; defineOp(inout runtime, proto, in toLocaleDateStringText, dateToString, FORMAT_DATE, 0);
  const toLocaleTimeStringText: String = "toLocaleTimeString"; defineOp(inout runtime, proto, in toLocaleTimeStringText, dateToString, FORMAT_TIME, 0);
  // toGMTString is the same function object as toUTCString.
  const toUTCStringText: String = "toUTCString";
  const utcString = defineOp(inout runtime, proto, in toUTCStringText, dateToString, FORMAT_UTC, 0);
  const toGMTStringText: String = "toGMTString";
  const gmtAtom = runtime.atomOf(in toGMTStringText);
  runtime.defineOwnAttr(proto, gmtAtom, cellValue(utcString), PROP_METHOD);
  const toJSONText: String = "toJSON";
  runtime.defineMethod(proto, in toJSONText, dateToJson, 1);

  const toPrimitiveName: String = "[Symbol.toPrimitive]";
  const toPrimitiveFn = runtime.defineHostFunction(dateToPrimitive, undefinedValue(), 1, in toPrimitiveName);
  const symbolToPrimitive = runtime.symbolToPrimitive;
  const toPrimitiveKey = runtime.propertyKey(symbolToPrimitive);
  runtime.heap.objectDefine(proto, toPrimitiveKey, cellValue(toPrimitiveFn), PROP_CONFIGURABLE);
}
