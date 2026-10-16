// Mandelbrot escape-iteration over a fixed grid. Pure numeric loop
// — measures float arithmetic + tight nested loops with conditionals.
let w = 256;
let h = 256;
let max_iter = 100;
let count = 0;
let y = 0;
while (y < h) {
  let x = 0;
  while (x < w) {
    let cx = (x - w / 2) * 4 / w;
    let cy = (y - h / 2) * 4 / h;
    let zx = 0;
    let zy = 0;
    let i = 0;
    while (i < max_iter && zx * zx + zy * zy < 4) {
      let nx = zx * zx - zy * zy + cx;
      zy = 2 * zx * zy + cy;
      zx = nx;
      i = i + 1;
    }
    if (i == max_iter) count = count + 1;
    x = x + 1;
  }
  y = y + 1;
}
count
