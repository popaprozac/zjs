// node:fs — POSIX-backed sync + promise-based file I/O.
//
// Mirrors the surface zjs ships (see src/stdlib/node_fs.zc). Anything
// not listed here isn't implemented. Errors carry .code / .errno /
// .syscall / .path (POSIX-style).

declare module 'node:fs' {
  export interface Stats {
    size: number;
    mode: number;
    nlink: number;
    uid: number;
    gid: number;
    ino: number;
    mtimeMs: number;
    atimeMs: number;
    ctimeMs: number;
    birthtimeMs: number;
    mtime: Date;
    atime: Date;
    ctime: Date;
    birthtime: Date;
    isFile(): boolean;
    isDirectory(): boolean;
    isSymbolicLink(): boolean;
  }

  export interface RmOptions {
    recursive?: boolean;
    force?: boolean;
  }

  export interface MkdirOptions {
    recursive?: boolean;
    mode?: number;
  }

  export type ReadFileEncoding = 'utf-8' | 'utf8' | 'ascii' | 'latin1';

  export function readFileSync(path: string): Uint8Array;
  export function readFileSync(path: string, encoding: ReadFileEncoding): string;
  export function readFileSync(path: string, options: { encoding: ReadFileEncoding }): string;

  export function writeFileSync(
    path: string,
    data: string | Uint8Array,
    options?: ReadFileEncoding | { encoding?: ReadFileEncoding },
  ): void;

  export function readdirSync(path: string): string[];
  export function statSync(path: string): Stats;
  export function lstatSync(path: string): Stats;
  export function mkdirSync(path: string, options?: MkdirOptions): string | undefined;
  export function unlinkSync(path: string): void;
  export function rmSync(path: string, options?: RmOptions): void;
  export function copyFileSync(src: string, dest: string): void;
  export function renameSync(oldPath: string, newPath: string): void;
  export function accessSync(path: string, mode?: number): void;
  export function existsSync(path: string): boolean;

  export const F_OK: 0;
  export const R_OK: 4;
  export const W_OK: 2;
  export const X_OK: 1;

  export const promises: typeof import('node:fs/promises');
}

declare module 'node:fs/promises' {
  import type { Stats, RmOptions, MkdirOptions, ReadFileEncoding } from 'node:fs';

  export function readFile(path: string): Promise<Uint8Array>;
  export function readFile(path: string, encoding: ReadFileEncoding): Promise<string>;
  export function readFile(path: string, options: { encoding: ReadFileEncoding }): Promise<string>;

  export function writeFile(
    path: string,
    data: string | Uint8Array,
    options?: ReadFileEncoding | { encoding?: ReadFileEncoding },
  ): Promise<void>;

  export function readdir(path: string): Promise<string[]>;
  export function stat(path: string): Promise<Stats>;
  export function lstat(path: string): Promise<Stats>;
  export function mkdir(path: string, options?: MkdirOptions): Promise<string | undefined>;
  export function unlink(path: string): Promise<void>;
  export function rm(path: string, options?: RmOptions): Promise<void>;
  export function copyFile(src: string, dest: string): Promise<void>;
  export function rename(oldPath: string, newPath: string): Promise<void>;
  export function access(path: string, mode?: number): Promise<void>;
}
