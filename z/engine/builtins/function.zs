// Function.prototype: call and apply.
import { Value, undefinedValue, cellValue, int32Value, booleanValue, asCell, isCell, isUndefined, isNull } from "../value.zs";
import { thread } from "std/thread";
import { Runtime } from "../runtime.zs";
import { bytesOf, PROP_METHOD, PROP_NONE } from "../heap.zs";
import { parseProgram } from "../parser.zs";
import { compileProgram } from "../compiler.zs";

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

// bind(thisArg, ...args): a host function whose bound slot holds
// [target, thisArg, args...]; calling it prepends those, constructing it
// constructs the target.
function functionBind(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  if (!runtime.isCallable(thisValue)) {
    const message: String = "Bind must be called on a function";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const recordLength: u32 = argc < 1 ? 2 : argc + 1;
  const record = runtime.heap.allocateArray(recordLength);
  runtime.heap.setSlot(record, 0, thisValue);
  runtime.heap.setSlot(record, 1, runtime.argument(argsBase, argc, 0));
  let index: u32 = 1;
  while (index < argc) {
    const extra = runtime.argument(argsBase, argc, index);
    runtime.heap.setSlot(record, index + 1, extra);
    index = index + 1;
  }
  // length: the target's, less the bound arguments; name: "bound " + target's.
  const lengthKey = cellValue(runtime.atomLength);
  const targetLength = runtime.toLength(runtime.getProperty(thisValue, lengthKey));
  if (runtime.pendingThrow) return undefinedValue();
  const boundCount: u32 = argc > 1 ? argc - 1 : 0;
  const remaining: u32 = targetLength > boundCount ? targetLength - boundCount : 0;
  const nameKey = cellValue(runtime.atomName);
  const targetName = runtime.getProperty(thisValue, nameKey);
  if (runtime.pendingThrow) return undefinedValue();
  const prefix: String = "bound ";
  let nameBytes = bytesOf(in prefix);
  if (runtime.isStringValue(targetName)) {
    const more = runtime.heap.stringBytes(asCell(targetName));
    let k: usize = 0;
    while (k < more.length) {
      nameBytes.push(more[k]);
      k = k + 1;
    }
  }
  const bound = runtime.defineHostFunctionBytes(boundTrampoline, cellValue(record), remaining, move nameBytes);
  if (runtime.isConstructorValue(thisValue)) runtime.heap.setSlot(bound, 4, booleanValue(true));
  return cellValue(bound);
}

function boundTrampoline(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const record = asCell(runtime.heap.slot(callee, 0));
  const target = runtime.heap.slot(record, 0);
  const boundThis = runtime.heap.slot(record, 1);
  const recordLength = runtime.heap.arrayLength(record);
  let args = Array<Value>();
  let index: u32 = 2;
  while (index < recordLength) {
    args.push(runtime.heap.slot(record, index));
    index = index + 1;
  }
  index = 0;
  while (index < argc) {
    args.push(runtime.argument(argsBase, argc, index));
    index = index + 1;
  }
  // Constructed: `this` is the object newInvoke made, and the target is
  // constructed in its place.
  if (runtime.isObjectLike(thisValue) && runtime.heap.isObject(asCell(thisValue)) && runtime.heap.objectClass(asCell(thisValue)) == 0 && runtime.heap.objectProto(asCell(thisValue)) == runtime.prototypeOf(callee) && runtime.isConstructorValue(target)) {
    return runtime.constructValue(target, move args, target);
  }
  return runtime.callValue(target, boundThis, move args);
}

// Function(p1, ..., body): compiled from source through the parser.
function constructFunction(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const head: String = "(function anonymous(";
  let source = bytesOf(in head);
  let index: u32 = 0;
  while (index + 1 < argc) {
    if (index > 0) source.push(44);
    const parameter = runtime.toStringValue(runtime.argument(argsBase, argc, index));
    if (runtime.pendingThrow) return undefinedValue();
    const bytes = runtime.heap.stringBytes(asCell(parameter));
    let k: usize = 0;
    while (k < bytes.length) {
      source.push(bytes[k]);
      k = k + 1;
    }
    index = index + 1;
  }
  const middle: String = "\n) {\n";
  const middleBytes = bytesOf(in middle);
  let m: usize = 0;
  while (m < middleBytes.length) {
    source.push(middleBytes[m]);
    m = m + 1;
  }
  if (argc > 0) {
    const body = runtime.toStringValue(runtime.argument(argsBase, argc, argc - 1));
    if (runtime.pendingThrow) return undefinedValue();
    const bytes = runtime.heap.stringBytes(asCell(body));
    let k: usize = 0;
    while (k < bytes.length) {
      source.push(bytes[k]);
      k = k + 1;
    }
  }
  const tail: String = "\n})";
  const tailBytes = bytesOf(in tail);
  let t: usize = 0;
  while (t < tailBytes.length) {
    source.push(tailBytes[t]);
    t = t + 1;
  }
  const parsed = parseProgram(move source, false);
  if (parsed.hadError) {
    const message: String = "parse error";
    const error = runtime.syntaxError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const functionIndex = compileProgram(in parsed.parser, parsed.root, inout runtime);
  if (functionIndex < 0) {
    const message: String = "compile error";
    const error = runtime.syntaxError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const outcome = runtime.run(u32(functionIndex));
  if (outcome.isThrow) {
    runtime.raise(outcome.value);
    return undefinedValue();
  }
  return outcome.value;
}

// Function.prototype[Symbol.hasInstance]: OrdinaryHasInstance.
function functionHasInstance(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return booleanValue(runtime.ordinaryHasInstance(thisValue, runtime.argument(argsBase, argc, 0)));
}

function functionToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const text: String = "function () { [native code] }";
  const textValue = runtime.internText(in text);
  return textValue;
}

export function installFunction(inout runtime: Runtime): void {
  const functionProto = runtime.functionProto;
  const functionText: String = "Function";
  const ctor = runtime.defineConstructor(constructFunction, undefinedValue(), 1, in functionText);
  runtime.heap.setLink(ctor, functionProto);
  const atomConstructor = runtime.atomConstructor;
  runtime.defineOwnAttr(functionProto, atomConstructor, cellValue(ctor), PROP_METHOD);
  runtime.setGlobal("Function", cellValue(ctor));
  const bindText: String = "bind";
  runtime.defineMethod(functionProto, in bindText, functionBind, 1);
  const callText: String = "call";
  runtime.defineMethod(functionProto, in callText, functionCall, 1);
  const applyText: String = "apply";
  runtime.defineMethod(functionProto, in applyText, functionApply, 2);
  const toStringText: String = "toString";
  runtime.defineMethod(functionProto, in toStringText, functionToString, 0);
  const hasInstanceName: String = "[Symbol.hasInstance]";
  const hasInstanceFn = runtime.defineHostFunction(functionHasInstance, undefinedValue(), 1, in hasInstanceName);
  const symbolHasInstanceBound = runtime.symbolHasInstance;
  const hasInstanceKey = runtime.propertyKey(symbolHasInstanceBound);
  runtime.heap.objectDefine(functionProto, hasInstanceKey, cellValue(hasInstanceFn), PROP_NONE);
}
