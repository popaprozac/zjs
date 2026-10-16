// Date: construction, UTC fields, ISO round-trips, arithmetic, and
// coercion. Local-time forms are not here: the reference has no local
// time zone; the rest of what it lacks is listed in the README.
var log = [];
var d = new Date(Date.UTC(2026, 8, 15, 10, 30, 45, 123));
log.push(d.getTime(), d.valueOf(), d.toISOString(), +d, d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), d.getUTCMilliseconds());
log.push(Date.parse("2026-09-15"), Date.parse("2026-09-15T10:30:45.123Z"), Date.parse("+020026-09-15T00:00:00Z"), Date.parse("nonsense"), Date.parse("2026-09-15T24:00:00Z"));
log.push(new Date(0).toISOString(), new Date(-1).toISOString(), new Date(8.64e15 + 1).getTime(), new Date(NaN).getTime(), new Date("2026-09-15T10:30:45.123Z").getTime());
log.push(new Date(Date.UTC(99, 0)).getUTCFullYear(), new Date(Date.UTC(100, 0)).getUTCFullYear(), Date.UTC(2026), Date.UTC(), Date.UTC(2026, 0, 1, 0, 0, 0, 0.9), new Date(2026, 8, 15).getFullYear(), new Date(d).getTime() === d.getTime(), new Date(new Date(0)).getTime());
var s = new Date(Date.UTC(2020, 1, 29, 12, 0, 0, 0));
log.push(s.setUTCFullYear(2021), s.toISOString(), s.setUTCMonth(11, 31), s.toISOString(), s.setUTCDate(32), s.toISOString(), s.setUTCHours(25, 61, 61, 1001), s.toISOString(), s.setUTCMilliseconds(-1), s.toISOString(), s.setTime(1), s.getTime());
log.push(new Date(NaN).setUTCFullYear(2000), new Date(NaN).setUTCMonth(1), Object.prototype.toString.call(d), typeof Date.now(), Date.now() > 1.7e12, Date.length, Date.UTC.length, Date.prototype.setHours.length, Date.prototype.constructor === Date);
log.push(d > new Date(0), d - new Date(0), d + "" === d.toString());
try { Date.prototype.getTime.call({}); } catch (e) { log.push(e instanceof TypeError); }
try { new Date(NaN).toISOString(); } catch (e) { log.push(e instanceof RangeError); }
log.push(new Date(2026, 8, 15, 10, 30).getHours(), new Date(2026, 8, 15).getMonth(), new Date(2026, 8, 15).getDate());
class MyDate extends Date { extra() { return this.getUTCFullYear() + 1; } }
var m = new MyDate(Date.UTC(2000, 0, 1));
log.push(m.extra(), m instanceof Date, m instanceof MyDate, Object.getPrototypeOf(m) === MyDate.prototype, m.toISOString());
log.push(new Date(Date.parse(new Date(0).toUTCString())).getTime());
log.join("|");
