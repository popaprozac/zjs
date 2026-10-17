import { hoistedA, lateA, constA } from "./cycle-a.mjs";
console.log("b runs first:", hoistedA());
try { lateA; } catch (e) { console.log(e.constructor.name, e.message); }
try { console.log(constA); } catch (e) { console.log(e.constructor.name, e.message); }
export const fromB = "b value";
export function hoistedB() { return "hoisted in b, sees " + lateA; }
