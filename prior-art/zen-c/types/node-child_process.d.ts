// node:child_process — sync trio + thin async wrappers. Real async
// spawn() with ChildProcess EventEmitter is not yet implemented.

declare module 'node:child_process' {
  export interface SpawnSyncOptions {
    cwd?: string;
    env?: Record<string, string>;
    input?: string | Uint8Array;
    encoding?: 'utf-8' | 'utf8' | 'buffer';
    timeout?: number;
    maxBuffer?: number;
    shell?: boolean | string;
  }

  export interface SpawnSyncResult {
    pid: number;
    status: number | null;
    signal: string | null;
    stdout: Uint8Array | string;
    stderr: Uint8Array | string;
    error?: Error;
  }

  export function spawnSync(
    command: string,
    args?: string[],
    options?: SpawnSyncOptions,
  ): SpawnSyncResult;

  export function execSync(command: string, options?: SpawnSyncOptions): Uint8Array | string;

  export function execFileSync(
    file: string,
    args?: string[],
    options?: SpawnSyncOptions,
  ): Uint8Array | string;

  export interface ExecCallback {
    (error: Error | null, stdout: string, stderr: string): void;
  }

  export function exec(command: string, callback?: ExecCallback): void;
  export function exec(
    command: string,
    options: SpawnSyncOptions,
    callback?: ExecCallback,
  ): void;

  export function execFile(file: string, callback?: ExecCallback): void;
  export function execFile(
    file: string,
    args: string[],
    callback?: ExecCallback,
  ): void;
  export function execFile(
    file: string,
    args: string[],
    options: SpawnSyncOptions,
    callback?: ExecCallback,
  ): void;
}
