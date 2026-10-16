// node:assert — Node-style assertion functions.

declare module 'node:assert' {
  type AssertFn = (value: unknown, message?: string | Error) => asserts value;

  interface AssertNamespace extends AssertFn {
    ok: AssertFn;
    equal(actual: unknown, expected: unknown, message?: string | Error): void;
    notEqual(actual: unknown, expected: unknown, message?: string | Error): void;
    strictEqual<T>(actual: unknown, expected: T, message?: string | Error): asserts actual is T;
    notStrictEqual(actual: unknown, expected: unknown, message?: string | Error): void;
    deepEqual(actual: unknown, expected: unknown, message?: string | Error): void;
    deepStrictEqual(actual: unknown, expected: unknown, message?: string | Error): void;
    throws(
      block: () => unknown,
      error?: RegExp | ((err: unknown) => boolean) | (new (...args: any[]) => Error),
      message?: string | Error,
    ): void;
    doesNotThrow(block: () => unknown, message?: string | Error): void;
    rejects(
      block: Promise<unknown> | (() => Promise<unknown>),
      error?: RegExp | ((err: unknown) => boolean) | (new (...args: any[]) => Error),
      message?: string | Error,
    ): Promise<void>;
    fail(message?: string | Error): never;
    match(actual: string, regexp: RegExp, message?: string | Error): void;
    strict: AssertNamespace;
  }

  const assert: AssertNamespace;
  export default assert;
  export const ok: AssertFn;
  export const equal: AssertNamespace['equal'];
  export const notEqual: AssertNamespace['notEqual'];
  export const strictEqual: AssertNamespace['strictEqual'];
  export const notStrictEqual: AssertNamespace['notStrictEqual'];
  export const deepEqual: AssertNamespace['deepEqual'];
  export const deepStrictEqual: AssertNamespace['deepStrictEqual'];
  export const throws: AssertNamespace['throws'];
  export const doesNotThrow: AssertNamespace['doesNotThrow'];
  export const rejects: AssertNamespace['rejects'];
  export const fail: AssertNamespace['fail'];
  export const match: AssertNamespace['match'];
  export const strict: AssertNamespace;
}
