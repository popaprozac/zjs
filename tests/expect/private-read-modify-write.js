// Private fields and accessors under compound, logical, and update
// assignment: read through the private name, written back through it,
// a missing brand a TypeError.
class Counter {
  #n = 0;
  #flag = null;
  #log = [];
  get #doubled() { return this.#n * 2; }
  set #doubled(v) { this.#log.push("set " + v); this.#n = v / 2; }
  step() {
    this.#n += 5;
    this.#n -= 1;
    this.#n *= 3;
    const before = this.#n++;
    const after = ++this.#n;
    --this.#n;
    this.#flag ||= "first";
    this.#flag ||= "second";
    this.#flag &&= this.#flag + "!";
    this.#log ??= "never";
    this.#doubled += 4;
    return [before, after, this.#n, this.#flag, this.#log.join(","), this.#doubled];
  }
  static poke(other) {
    try { other.#n += 1; } catch (e) { return e.constructor.name; }
    return "no throw";
  }
}
console.log(new Counter().step().join(" "));
console.log(Counter.poke({}));
