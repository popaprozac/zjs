// node:tty — minimal terminal detection. chalk depends on isatty.

declare module 'node:tty' {
  export function isatty(fd: number): boolean;
  export class ReadStream {}
  export class WriteStream {}
}
