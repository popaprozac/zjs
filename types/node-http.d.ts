// node:http — HTTP/1.1 server-side. No client (use global fetch), no
// keep-alive, no chunked transfer-encoding.

declare module 'node:http' {
  import type { EventEmitter } from 'node:events';
  import type { Server as NetServer, Socket } from 'node:net';

  export interface IncomingMessage extends EventEmitter {
    method: string;
    url: string;
    httpVersion: string;
    headers: Record<string, string | string[]>;
    socket: Socket;
  }

  export interface ServerResponse extends EventEmitter {
    statusCode: number;
    statusMessage?: string;
    setHeader(name: string, value: string | number | string[]): void;
    getHeader(name: string): string | number | string[] | undefined;
    removeHeader(name: string): void;
    writeHead(
      statusCode: number,
      statusMessage?: string,
      headers?: Record<string, string | number | string[]>,
    ): this;
    write(chunk: string | Uint8Array): boolean;
    end(chunk?: string | Uint8Array): void;
  }

  export type RequestListener = (req: IncomingMessage, res: ServerResponse) => void;

  export class Server extends NetServer {}

  export function createServer(listener?: RequestListener): Server;
  export function createServer(
    options: Record<string, unknown>,
    listener?: RequestListener,
  ): Server;

  export const METHODS: readonly string[];
  export const STATUS_CODES: Readonly<Record<number, string>>;
}
