// Hot object-field FUNCTION: reads array elements and object properties in a
// loop — the LoadElem (J8) + LoadProp (J9) JIT fast paths, with arithmetic.
// Function-based + monomorphic objects, so it JITs. (The legacy top-level
// property benches — property_mono, nbody — stay interpreted: their hot loops
// live at script top level → globals, and/or call out to Math.sqrt.)
function sumField(pts, n) {
  let s = 0;
  for (let i = 0; i < n; i = i + 1) {
    let p = pts[i];
    s = s + p.x * p.x + p.y * p.y;
  }
  return s;
}

let pts = [];
for (let i = 0; i < 20000; i = i + 1) {
  pts[i] = { x: i, y: i + 1 };
}

let total = 0;
for (let k = 0; k < 400; k = k + 1) {
  total = total + sumField(pts, 20000);   // hot fn: 8e6 elem+prop reads / call
}
total
