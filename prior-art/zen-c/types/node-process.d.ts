// node:process — re-export of the global `process`. Importing the
// module gets you the same object available as `globalThis.process`.

declare module 'node:process' {
  const process: NodeJSProcess;
  export default process;
  export const argv: string[];
  export const env: Record<string, string | undefined>;
  export const platform: string;
  export const arch: string;
  export const pid: number;
  export const versions: ProcessVersions;
  export function cwd(): string;
  export function chdir(directory: string): void;
  export function exit(code?: number): never;
  export const hrtime: ProcessHrtime;
  export function nextTick(callback: (...args: unknown[]) => void, ...args: unknown[]): void;
}
