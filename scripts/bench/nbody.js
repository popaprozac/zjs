// Simple N-body gravity simulation. Adapted from the classic
// "n-body" benchmark style — uses plain objects for vectors so it
// exercises property accesses + numeric loops + Math.sqrt.
function vec(x, y, z) { return { x: x, y: y, z: z }; }

function body(pos, vel, mass) {
  return { pos: pos, vel: vel, mass: mass };
}

let bodies = [];
bodies[0] = body(vec(0, 0, 0),      vec(0,    0,    0),    1.0);
bodies[1] = body(vec(1, 0, 0),      vec(0,    1.0,  0),    0.01);
bodies[2] = body(vec(0, 1.5, 0),    vec(-0.8, 0,    0),    0.008);
bodies[3] = body(vec(0, 0, 2),      vec(0.5,  0.5,  0),    0.005);
bodies[4] = body(vec(-1, -1, 1),    vec(0.6, -0.4,  0.3),  0.006);

function step(dt) {
  let n = 5;
  for (let i = 0; i < n; i = i + 1) {
    for (let j = i + 1; j < n; j = j + 1) {
      let bi = bodies[i];
      let bj = bodies[j];
      let dx = bj.pos.x - bi.pos.x;
      let dy = bj.pos.y - bi.pos.y;
      let dz = bj.pos.z - bi.pos.z;
      let d2 = dx * dx + dy * dy + dz * dz + 0.001;
      let d  = Math.sqrt(d2);
      let f  = dt / (d2 * d);
      let fi = f * bj.mass;
      let fj = f * bi.mass;
      bi.vel.x = bi.vel.x + dx * fi;
      bi.vel.y = bi.vel.y + dy * fi;
      bi.vel.z = bi.vel.z + dz * fi;
      bj.vel.x = bj.vel.x - dx * fj;
      bj.vel.y = bj.vel.y - dy * fj;
      bj.vel.z = bj.vel.z - dz * fj;
    }
  }
  for (let i = 0; i < 5; i = i + 1) {
    let b = bodies[i];
    b.pos.x = b.pos.x + b.vel.x * dt;
    b.pos.y = b.pos.y + b.vel.y * dt;
    b.pos.z = b.pos.z + b.vel.z * dt;
  }
}

let steps = 30000;
for (let s = 0; s < steps; s = s + 1) step(0.01);
bodies[0].pos.x + bodies[1].pos.y + bodies[2].pos.z
