// Imports plain.mjs, which the test leaves as source: a runtime without
// a module compiler refuses the graph.
import { plain } from "./plain.mjs";
export const seen = plain;
