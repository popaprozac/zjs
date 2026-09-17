// Function.prototype: call and apply.
import { unitsOf } from "../text.zs";
import { Value, undefinedValue, nullValue, cellValue, int32Value, doubleValue, booleanValue, asCell, isCell, isUndefined, isNull, isNumber } from "../value.zs";
import { thread } from "std/thread";
import { Runtime, HOST_BOUND_TRAMPOLINE, truncateDouble } from "../runtime.zs";
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

// bind(thisArg, ...args): an instance of the bound trampoline whose
// bound data is [target, boundThis, args...]. It is constructable exactly
// when its target is, inherits from what its target inherits from, and
// has no `prototype` of its own. `length` comes from the target's own
// `length` when that is a Number (as an integer, less the bound
// arguments, never below zero, infinity kept); `name` is "bound " and
// the target's `name` when that is a String. Both reads are the
// program's to observe, length first.
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
  runtime.pushTempRoot(cellValue(record));
  let length: f64 = 0.0;
  const lengthKey = cellValue(runtime.atomLength);
  if (runtime.hasOwnProperty(thisValue, lengthKey)) {
    const held = runtime.getProperty(thisValue, lengthKey);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      return undefinedValue();
    }
    if (isNumber(held)) {
      const number = runtime.toNumberValue(held);
      const boundCount: f64 = argc > 1 ? f64(argc - 1) : 0.0;
      if (number == 1.0 / 0.0) {
        length = number;
      } else if (number == number && number != -1.0 / 0.0) {
        length = truncateDouble(number) - boundCount;
        if (length < 0.0) length = 0.0;
      }
    }
  }
  const nameKey = cellValue(runtime.atomName);
  const targetName = runtime.getProperty(thisValue, nameKey);
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  const prefix: String = "bound ";
  let nameUnits = unitsOf(in prefix);
  if (runtime.isStringValue(targetName)) {
    const more = runtime.heap.stringUnits(asCell(targetName));
    let k: usize = 0;
    while (k < more.length) {
      nameUnits.push(more[k]);
      k = k + 1;
    }
  }
  const bound = runtime.newSharedHostNamed(HOST_BOUND_TRAMPOLINE, cellValue(record), 0, move nameUnits);
  if (length <= 2147483647.0) {
    runtime.heap.setSlot(bound, 1, int32Value(i32(length)));
  } else {
    runtime.heap.setSlot(bound, 1, doubleValue(length));
  }
  if (runtime.isConstructorValue(thisValue)) runtime.markAllocatingConstructor(bound);
  const inherited = runtime.protoOfValue(thisValue);
  if (inherited != runtime.functionProto) {
    const atomFunctionProto = runtime.atomFunctionProto;
    runtime.setFunctionHidden(bound, atomFunctionProto, inherited == 0 ? nullValue() : cellValue(inherited));
  }
  return cellValue(bound);
}

// [[Call]] and [[Construct]] of a bound function. Which one this is
// comes from the construct protocol, never from the shape of `this`: a
// construct hands over its new target, a call does not. A call uses
// boundThis; a construct ignores it and constructs the target, with the
// target as new target when the new target was this bound function
// itself. Both prepend the bound arguments.
function boundTrampoline(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const newTarget = runtime.takeHostNewTarget();
  const record = asCell(runtime.heap.slot(callee, 0));
  const target = runtime.heap.slot(record, 0);
  const boundThis = runtime.heap.slot(record, 1);
  const recordLength = runtime.heap.arrayLength(record);
  let args = Array<Value>.withCapacity(usize(recordLength - 2 + argc));
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
  if (!isUndefined(newTarget)) {
    const forwarded = (isCell(newTarget) && asCell(newTarget) == callee) ? target : newTarget;
    return runtime.constructValue(target, move args, forwarded);
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
    const bytes = runtime.heap.stringWtf8(asCell(parameter));
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
    const bytes = runtime.heap.stringWtf8(asCell(body));
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
  runtime.registerSharedHost(HOST_BOUND_TRAMPOLINE, boundTrampoline);
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
  runtime.hasInstanceBuiltin = hasInstanceFn;
}
