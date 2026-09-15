// %GeneratorPrototype%: next, return, throw.
import { thread } from "std/thread";
import { Value, undefinedValue, cellValue, asCell } from "../value.zs";
import { Runtime, asyncFromSyncNext, asyncFromSyncReturn, asyncFromSyncThrow } from "../runtime.zs";
import { PROP_CONFIGURABLE, PROP_METHOD } from "../heap.zs";

function requireGenerator(inout runtime: Runtime, thisValue: Value, in method: String): boolean {
  if (runtime.isGeneratorObject(thisValue)) return true;
  const message: String = `Generator.prototype.${method} called on incompatible receiver`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

function generatorNext(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "next";
  if (!requireGenerator(inout runtime, thisValue, in method)) return undefinedValue();
  return runtime.generatorResume(asCell(thisValue), runtime.argument(argsBase, argc, 0), 0);
}

function generatorReturn(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "return";
  if (!requireGenerator(inout runtime, thisValue, in method)) return undefinedValue();
  return runtime.generatorResume(asCell(thisValue), runtime.argument(argsBase, argc, 0), 2);
}

function generatorThrow(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "throw";
  if (!requireGenerator(inout runtime, thisValue, in method)) return undefinedValue();
  return runtime.generatorResume(asCell(thisValue), runtime.argument(argsBase, argc, 0), 1);
}

function requireAsyncGenerator(inout runtime: Runtime, thisValue: Value, in method: String): boolean {
  if (runtime.isAsyncGeneratorObject(thisValue)) return true;
  const message: String = `AsyncGenerator.prototype.${method} called on incompatible receiver`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

// AsyncGenerator.prototype.next / return / throw: a promise for the
// request, queued on the generator. An incompatible receiver rejects.
function asyncGeneratorRequest(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, mode: u32, in method: String): Value {
  if (!requireAsyncGenerator(inout runtime, thisValue, in method)) {
    const thrown = runtime.takePending();
    const promise = runtime.newPromise();
    runtime.rejectPromise(asCell(promise), thrown);
    return promise;
  }
  return runtime.asyncGeneratorEnqueue(asCell(thisValue), mode, runtime.argument(argsBase, argc, 0));
}

function asyncGeneratorNext(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "next";
  return asyncGeneratorRequest(inout runtime, thisValue, argsBase, argc, 0, in method);
}

function asyncGeneratorReturn(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "return";
  return asyncGeneratorRequest(inout runtime, thisValue, argsBase, argc, 2, in method);
}

function asyncGeneratorThrow(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "throw";
  return asyncGeneratorRequest(inout runtime, thisValue, argsBase, argc, 1, in method);
}

// %AsyncIteratorPrototype%[@@asyncIterator]: itself.
function asyncIteratorSelf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return thisValue;
}

export function installGenerator(inout runtime: Runtime): void {
  const asyncIteratorProto = runtime.asyncIteratorProto;
  const symbolAsyncIterator = runtime.symbolAsyncIterator;
  const asyncIteratorKey = runtime.propertyKey(symbolAsyncIterator);
  const asyncIteratorName: String = "[Symbol.asyncIterator]";
  const selfFn = runtime.defineHostFunction(asyncIteratorSelf, undefinedValue(), 0, in asyncIteratorName);
  runtime.heap.objectDefine(asyncIteratorProto, asyncIteratorKey, cellValue(selfFn), PROP_METHOD);
  const asyncGeneratorProto = runtime.asyncGeneratorProto;
  const asyncNextText: String = "next";
  runtime.defineMethod(asyncGeneratorProto, in asyncNextText, asyncGeneratorNext, 1);
  const asyncReturnText: String = "return";
  runtime.defineMethod(asyncGeneratorProto, in asyncReturnText, asyncGeneratorReturn, 1);
  const asyncThrowText: String = "throw";
  runtime.defineMethod(asyncGeneratorProto, in asyncThrowText, asyncGeneratorThrow, 1);
  const symbolToStringTagBound = runtime.symbolToStringTag;
  const asyncTagKey = runtime.propertyKey(symbolToStringTagBound);
  const asyncFromSyncProto = runtime.asyncFromSyncProto;
  runtime.defineMethod(asyncFromSyncProto, in asyncNextText, asyncFromSyncNext, 1);
  runtime.defineMethod(asyncFromSyncProto, in asyncReturnText, asyncFromSyncReturn, 1);
  runtime.defineMethod(asyncFromSyncProto, in asyncThrowText, asyncFromSyncThrow, 1);
  const asyncTagText: String = "AsyncGenerator";
  const asyncTagValue = runtime.internText(in asyncTagText);
  runtime.heap.objectDefine(asyncGeneratorProto, asyncTagKey, asyncTagValue, PROP_CONFIGURABLE);

  const generatorProto = runtime.generatorProto;
  const nextText: String = "next";
  runtime.defineMethod(generatorProto, in nextText, generatorNext, 1);
  const returnText: String = "return";
  runtime.defineMethod(generatorProto, in returnText, generatorReturn, 1);
  const throwText: String = "throw";
  runtime.defineMethod(generatorProto, in throwText, generatorThrow, 1);
  const symbolToStringTag = runtime.symbolToStringTag;
  const tagKey = runtime.propertyKey(symbolToStringTag);
  const tagText: String = "Generator";
  const tagValue = runtime.internText(in tagText);
  runtime.heap.objectDefine(generatorProto, tagKey, tagValue, PROP_CONFIGURABLE);
}
