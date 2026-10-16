// node:path — POSIX-only path manipulation. zjs does not implement the
// win32 sub-namespace.

declare module 'node:path' {
  export const sep: '/';
  export const delimiter: ':';

  export function isAbsolute(p: string): boolean;
  export function normalize(p: string): string;
  export function join(...segments: string[]): string;
  export function resolve(...segments: string[]): string;
  export function relative(from: string, to: string): string;
  export function dirname(p: string): string;
  export function basename(p: string, ext?: string): string;
  export function extname(p: string): string;

  export interface ParsedPath {
    root: string;
    dir: string;
    base: string;
    name: string;
    ext: string;
  }

  export function parse(p: string): ParsedPath;
  export function format(pathObject: Partial<ParsedPath>): string;

  const _default: {
    sep: typeof sep;
    delimiter: typeof delimiter;
    isAbsolute: typeof isAbsolute;
    normalize: typeof normalize;
    join: typeof join;
    resolve: typeof resolve;
    relative: typeof relative;
    dirname: typeof dirname;
    basename: typeof basename;
    extname: typeof extname;
    parse: typeof parse;
    format: typeof format;
  };
  export default _default;
}
