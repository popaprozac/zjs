export * from "./source.mjs";
export * from "./other.mjs";
export * as sourceSpace from "./source.mjs";
export { default as sourceDefault, a as renamed } from "./source.mjs";
import { c } from "./other.mjs";
export { c as passedOn };
import * as otherSpace from "./other.mjs";
export { otherSpace };
