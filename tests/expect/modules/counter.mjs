export let count = 1;
export function bump() { count = count + 1; }
export const double = (x) => x * 2;
export default function () { return "anonymous default"; }
export var later;
later = "assigned";
