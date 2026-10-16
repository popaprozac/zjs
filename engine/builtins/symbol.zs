// Symbol: the constructor (callable, not constructable), the registry,
// the well-known symbols, and the prototype.
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, cellValue, asCell, isCell, isUndefined } from "../value.zs";
import { Runtime } from "../runtime.zs";
import { PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE, PROP_ACCESSOR , FLAG_REGISTERED_SYMBOL } from "../heap.zs";

// The symbol behind `this`: itself or a wrapper's content.
function thisSymbol(inout runtime: Runtime, thisValue: Value, in method: String): u32 {
  if (runtime.isSymbolValue(thisValue)) return asCell(thisValue);
  if (isCell(thisValue) && asCell(thisValue) != 0 && runtime.heap.isObject(asCell(thisValue))) {
    const wrapped = runtime.wrappedPrimitive(asCell(thisValue));
    if (runtime.isSymbolValue(wrapped)) return asCell(wrapped);
  }
  const message: String = `Symbol.prototype.${method} requires that 'this' be a Symbol`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return 0;
}

function constructSymbol(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const given = runtime.argument(argsBase, argc, 0);
  let description = undefinedValue();
  if (!isUndefined(given)) {
    description = runtime.toStringValue(given);
    if (runtime.pendingThrow) return undefinedValue();
  }
  return runtime.newSymbol(description);
}

function symbolFor(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const key = runtime.toStringValue(runtime.argument(argsBase, argc, 0));
  if (runtime.pendingThrow) return undefinedValue();
  let index: usize = 0;
  while (index + 1 < runtime.symbolRegistry.length) {
    const registered = runtime.symbolRegistry[index];
    if (runtime.heap.stringsEqual(asCell(registered), asCell(key))) return runtime.symbolRegistry[index + 1];
    index = index + 2;
  }
  const created = runtime.newSymbol(key);
  // A registered symbol cannot be held weakly.
  const flags = runtime.heap.flagsOf(asCell(created));
  runtime.heap.setFlags(asCell(created), flags | FLAG_REGISTERED_SYMBOL);
  runtime.symbolRegistry.push(key);
  runtime.symbolRegistry.push(created);
  return created;
}

function symbolKeyFor(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const symbol = runtime.argument(argsBase, argc, 0);
  if (!runtime.isSymbolValue(symbol)) {
    const message: String = "Symbol.keyFor requires a symbol";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  let index: usize = 0;
  while (index + 1 < runtime.symbolRegistry.length) {
    if (runtime.symbolRegistry[index + 1].bits == symbol.bits) return runtime.symbolRegistry[index];
    index = index + 2;
  }
  return undefinedValue();
}

function symbolToString(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "toString";
  const symbol = thisSymbol(inout runtime, thisValue, in method);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.symbolDescriptiveString(symbol);
}

function symbolValueOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "valueOf";
  const symbol = thisSymbol(inout runtime, thisValue, in method);
  if (runtime.pendingThrow) return undefinedValue();
  return cellValue(symbol);
}

function symbolDescriptionGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const method: String = "description";
  const symbol = thisSymbol(inout runtime, thisValue, in method);
  if (runtime.pendingThrow) return undefinedValue();
  return runtime.heap.symbolDescription(symbol);
}

function defineSymbolConstant(inout runtime: Runtime, target: u32, in name: String, value: Value): void {
  const atom = runtime.atomOf(in name);
  runtime.defineOwnAttr(target, atom, value, PROP_NONE);
}

export function installSymbol(inout runtime: Runtime): void {
  const symbolProto = runtime.symbolProto;
  const symbolText: String = "Symbol";
  const ctor = runtime.defineHostFunction(constructSymbol, undefinedValue(), 0, in symbolText);
  runtime.heap.setLink(ctor, symbolProto);
  const atomConstructor = runtime.atomConstructor;
  runtime.defineOwnAttr(symbolProto, atomConstructor, cellValue(ctor), PROP_METHOD);
  runtime.setGlobal("Symbol", cellValue(ctor));
  const forText: String = "for";
  runtime.defineMethod(ctor, in forText, symbolFor, 1);
  const keyForText: String = "keyFor";
  runtime.defineMethod(ctor, in keyForText, symbolKeyFor, 1);
  const iteratorText: String = "iterator";
  const symbolIteratorBound = runtime.symbolIterator;
  defineSymbolConstant(inout runtime, ctor, in iteratorText, symbolIteratorBound);
  const toPrimitiveText: String = "toPrimitive";
  const symbolToPrimitiveBound = runtime.symbolToPrimitive;
  defineSymbolConstant(inout runtime, ctor, in toPrimitiveText, symbolToPrimitiveBound);
  const toStringTagText: String = "toStringTag";
  const symbolToStringTagBound = runtime.symbolToStringTag;
  defineSymbolConstant(inout runtime, ctor, in toStringTagText, symbolToStringTagBound);
  const hasInstanceText: String = "hasInstance";
  const symbolHasInstanceBound = runtime.symbolHasInstance;
  defineSymbolConstant(inout runtime, ctor, in hasInstanceText, symbolHasInstanceBound);
  // The remaining well-known symbols exist so code can name them.
  const asyncIteratorText: String = "asyncIterator";
  const symbolAsyncIteratorBound = runtime.symbolAsyncIterator;
  defineSymbolConstant(inout runtime, ctor, in asyncIteratorText, symbolAsyncIteratorBound);
  const speciesText: String = "species";
  const symbolSpeciesBound = runtime.symbolSpecies;
  defineSymbolConstant(inout runtime, ctor, in speciesText, symbolSpeciesBound);
  const isConcatSpreadableText: String = "isConcatSpreadable";
  const symbolIsConcatSpreadableBound = runtime.symbolIsConcatSpreadable;
  defineSymbolConstant(inout runtime, ctor, in isConcatSpreadableText, symbolIsConcatSpreadableBound);
  const unscopablesText: String = "unscopables";
  const symbolUnscopablesBound = runtime.symbolUnscopables;
  defineSymbolConstant(inout runtime, ctor, in unscopablesText, symbolUnscopablesBound);
  const matchText: String = "match";
  const symbolMatchBound = runtime.symbolMatch;
  defineSymbolConstant(inout runtime, ctor, in matchText, symbolMatchBound);
  const matchAllText: String = "matchAll";
  const symbolMatchAllBound = runtime.symbolMatchAll;
  defineSymbolConstant(inout runtime, ctor, in matchAllText, symbolMatchAllBound);
  const replaceText: String = "replace";
  const symbolReplaceBound = runtime.symbolReplace;
  defineSymbolConstant(inout runtime, ctor, in replaceText, symbolReplaceBound);
  const searchText: String = "search";
  const symbolSearchBound = runtime.symbolSearch;
  defineSymbolConstant(inout runtime, ctor, in searchText, symbolSearchBound);
  const splitText: String = "split";
  const symbolSplitBound = runtime.symbolSplit;
  defineSymbolConstant(inout runtime, ctor, in splitText, symbolSplitBound);

  const toStringText: String = "toString";
  runtime.defineMethod(symbolProto, in toStringText, symbolToString, 0);
  const valueOfText: String = "valueOf";
  runtime.defineMethod(symbolProto, in valueOfText, symbolValueOf, 0);
  // description: an accessor.
  const descriptionText: String = "description";
  const getterName: String = "get description";
  const getter = runtime.defineHostFunction(symbolDescriptionGetter, undefinedValue(), 0, in getterName);
  const accessor = runtime.heap.allocateAccessor(cellValue(getter), undefinedValue());
  const descriptionAtom = runtime.atomOf(in descriptionText);
  runtime.heap.objectDefine(symbolProto, descriptionAtom, cellValue(accessor), PROP_CONFIGURABLE | PROP_ACCESSOR);
  // [Symbol.toPrimitive] and [Symbol.toStringTag]
  const toPrimitiveName: String = "[Symbol.toPrimitive]";
  const toPrimitiveFn = runtime.defineHostFunction(symbolValueOf, undefinedValue(), 1, in toPrimitiveName);
  const toPrimitiveKey = runtime.propertyKey(symbolToPrimitiveBound);
  runtime.heap.objectDefine(symbolProto, toPrimitiveKey, cellValue(toPrimitiveFn), PROP_CONFIGURABLE);
  const tagKey = runtime.propertyKey(symbolToStringTagBound);
  const tagValue = runtime.internText(in symbolText);
  runtime.heap.objectDefine(symbolProto, tagKey, tagValue, PROP_CONFIGURABLE);
}
