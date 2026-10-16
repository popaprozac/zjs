// node:events — EventEmitter.

declare module 'node:events' {
  type Listener = (...args: any[]) => void;

  export class EventEmitter {
    on(event: string | symbol, listener: Listener): this;
    once(event: string | symbol, listener: Listener): this;
    off(event: string | symbol, listener: Listener): this;
    removeListener(event: string | symbol, listener: Listener): this;
    removeAllListeners(event?: string | symbol): this;
    emit(event: string | symbol, ...args: any[]): boolean;
    listenerCount(event: string | symbol): number;
    listeners(event: string | symbol): Listener[];
    eventNames(): (string | symbol)[];
    setMaxListeners(n: number): this;
    getMaxListeners(): number;
  }

  export default EventEmitter;
}
