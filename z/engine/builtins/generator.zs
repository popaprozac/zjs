// %GeneratorPrototype%: next, return, throw.
import { thread } from "std/thread";
import { Value, undefinedValue, cellValue, asCell } from "../value.zs";
import { Runtime } from "../runtime.zs";
import { PROP_CONFIGURABLE } from "../heap.zs";

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

export function installGenerator(inout runtime: Runtime): void {
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
