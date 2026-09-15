// Function.prototype: call and apply.
import { Value, undefinedValue, cellValue, int32Value, asCell, isCell, isUndefined, isNull } from "../value.zs";
import { thread } from "std/thread";
import { Runtime } from "../runtime.zs";

function functionCall(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isCallable(thisValue)) {
    const message: String = "Function.prototype.call called on a non-function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const receiver = runtime.argument(argsBase, argc, 0);
  let args = Array<Value>();
  let index: u32 = 1;
  while (index < argc) {
    args.push(runtime.argument(argsBase, argc, index));
    index = index + 1;
  }
  return runtime.callValue(thisValue, receiver, move args);
}

function functionApply(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isCallable(thisValue)) {
    const message: String = "Function.prototype.apply called on a non-function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const receiver = runtime.argument(argsBase, argc, 0);
  const list = runtime.argument(argsBase, argc, 1);
  let args = Array<Value>();
  if (!isUndefined(list) && !isNull(list)) {
    if (!runtime.isObjectLike(list)) {
      const message: String = "CreateListFromArrayLike called on non-object";
      const error = runtime.typeError(in message);
      runtime.raise(error);
      return undefinedValue();
    }
    const lengthKey = cellValue(runtime.atomLength);
    const lengthValue = runtime.getProperty(list, lengthKey);
    if (runtime.pendingThrow) return undefinedValue();
    const length = runtime.toLength(lengthValue);
    if (runtime.pendingThrow) return undefinedValue();
    let index: u32 = 0;
    while (index < length) {
      const element = runtime.getProperty(list, int32Value(i32(index)));
      if (runtime.pendingThrow) return undefinedValue();
      args.push(element);
      index = index + 1;
    }
  }
  return runtime.callValue(thisValue, receiver, move args);
}

function functionToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "function () { [native code] }";
  return runtime.internText(in text);
}

export function installFunction(inout runtime: Runtime): void {
  const functionProto = runtime.functionProto;
  const callText: String = "call";
  runtime.defineMethod(functionProto, in callText, functionCall, 1);
  const applyText: String = "apply";
  runtime.defineMethod(functionProto, in applyText, functionApply, 2);
  const toStringText: String = "toString";
  runtime.defineMethod(functionProto, in toStringText, functionToString, 0);
}
