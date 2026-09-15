import 'side-effect';
import def from 'mod';
import * as ns from 'mod';
import { a, b as c, default as d, if as e } from 'mod';
import def2, { x } from 'mod';
import def3, * as ns2 from 'mod';
export const one = 1;
export let two = 2, three = 3;
export var four;
export function fn() {}
export async function afn() {}
export class Cls {}
export default expression + 1;
export { one, two as deux, three as default };
export { re } from 'other';
const meta = import.meta;
const dyn = import('./x.js');
const dyn2 = import('./y.js', { with: { type: 'json' } });
