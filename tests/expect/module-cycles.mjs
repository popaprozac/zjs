// A cycle evaluates its modules depth first, each once: a function
// declaration is callable before its module runs, a let read early throws.
import "./modules/order-left.mjs";
import "./modules/order-right.mjs";
import { hoistedA, lateA } from "./modules/cycle-a.mjs";
import "./modules/order-leaf.mjs";
console.log("entry:", hoistedA(), lateA);
