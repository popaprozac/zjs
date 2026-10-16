// node:os — Apple via sysctl + mach; Linux via sysinfo + /proc/cpuinfo.

declare module 'node:os' {
  export interface CpuTimes {
    user: number;
    nice: number;
    sys: number;
    idle: number;
    irq: number;
  }
  export interface CpuInfo {
    model: string;
    speed: number;
    times: CpuTimes;
  }
  export interface UserInfo {
    uid: number;
    gid: number;
    username: string;
    homedir: string;
    shell: string | null;
  }

  export function tmpdir(): string;
  export function homedir(): string;
  export function platform(): string;
  export function arch(): string;
  export function type(): string;
  export function release(): string;
  export function hostname(): string;
  export function cpus(): CpuInfo[];
  export function totalmem(): number;
  export function freemem(): number;
  export function userInfo(): UserInfo;
  export const EOL: '\n' | '\r\n';
}
