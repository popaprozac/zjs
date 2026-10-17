import { fromB, hoistedB } from "./cycle-b.mjs";
export function hoistedA() { return "hoisted in a"; }
export let lateA = "late a";
export const constA = 1;
console.log("a runs: b gave", fromB, hoistedB());
