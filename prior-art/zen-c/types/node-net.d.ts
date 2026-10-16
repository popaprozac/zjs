// node:net — TCP server-side. zjs does NOT implement net.connect.

declare module 'node:net' {
  import type { EventEmitter } from 'node:events';

  export interface Socket extends EventEmitter {
    write(data: string | Uint8Array): boolean;
    end(data?: string | Uint8Array): void;
    destroy(): void;
    remoteAddress?: string;
    remotePort?: number;
    localAddress?: string;
    localPort?: number;
  }

  export interface ListenOptions {
    port?: number;
    host?: string;
    backlog?: number;
  }

  export class Server extends EventEmitter {
    listen(port?: number, host?: string, listener?: () => void): this;
    listen(options: ListenOptions, listener?: () => void): this;
    close(callback?: (err?: Error) => void): this;
    address(): { address: string; family: string; port: number } | null;
  }

  export function createServer(
    connectionListener?: (socket: Socket) => void,
  ): Server;
}
