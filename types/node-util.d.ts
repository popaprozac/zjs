// node:util — promisify / callbackify / inspect / format / types.

declare module 'node:util' {
  export function promisify<T extends (...args: any[]) => any>(fn: T): (
    ...args: T extends (...args: infer A) => any
      ? A extends [...infer Rest, (err: any, result: any) => any]
        ? Rest
        : A
      : never
  ) => Promise<any>;

  export function callbackify<T extends (...args: any[]) => Promise<any>>(
    fn: T,
  ): (...args: [...Parameters<T>, (err: unknown, result?: any) => void]) => void;

  export function inspect(value: unknown, options?: { depth?: number; colors?: boolean }): string;
  export function format(format: string, ...args: unknown[]): string;

  export const types: {
    isPromise(v: unknown): boolean;
    isMap(v: unknown): v is Map<unknown, unknown>;
    isSet(v: unknown): v is Set<unknown>;
    isDate(v: unknown): v is Date;
    isRegExp(v: unknown): v is RegExp;
    isArrayBuffer(v: unknown): v is ArrayBuffer;
    isUint8Array(v: unknown): v is Uint8Array;
    isTypedArray(v: unknown): boolean;
  };
}
