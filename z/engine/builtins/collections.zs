// Map, Set, WeakMap, WeakSet.
//
// A collection is an ordinary object holding a record under a hidden
// key: an array of keys and an array of values in insertion order (a
// deleted entry leaves the deleted marker in both), an open-addressed
// index from key hash to entry position, and the live count. Iteration
// walks the entry arrays by position, so entries added during a walk
// are visited and deleted ones skipped, as the specification requires.
// WeakMap and WeakSet keep theirs in the heap's weak records (see
// heap.zs, Weak records): keys held weakly, values by ephemeron marking,
// storage compacted as keys die.
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, int32Value, cellValue, asCell, isCell, isUndefined, isNull, isDeleted, deletedValue, asInt32, isNumber } from "../value.zs";
import { Runtime, toNumber, truncateDouble, FEATURE_COLLECTIONS } from "../runtime.zs";
import { PROP_METHOD, PROP_NONE, PROP_CONFIGURABLE, PROP_ACCESSOR, PROP_DEFAULT } from "../heap.zs";

const KIND_MAP: i32 = 0;
const KIND_SET: i32 = 1;
const KIND_WEAK_MAP: i32 = 2;
const KIND_WEAK_SET: i32 = 3;

function newRecord(inout runtime: Runtime, kind: i32): u32 {
  if (kind == KIND_WEAK_MAP || kind == KIND_WEAK_SET) return runtime.heap.allocateWeakRecord(kind);
  return runtime.heap.allocateTable(kind);
}

function recordOf(in runtime: Runtime, value: Value, kind: i32): u32 {
  if (!isCell(value) || asCell(value) == 0 || !runtime.heap.isObject(asCell(value))) return 0;
  const atomMapRecord = runtime.atomMapRecord;
  const slot = runtime.heap.objectFindSlot(asCell(value), atomMapRecord);
  if (slot < 0) return 0;
  const record = asCell(runtime.heap.slot(asCell(value), u32(slot)));
  const recordKind = runtime.heap.isTable(record) ? runtime.heap.tableKind(record) : runtime.heap.weakKind(record);
  if (recordKind != kind) return 0;
  return record;
}

function requireRecord(inout runtime: Runtime, value: Value, kind: i32, in what: String): u32 {
  const record = recordOf(in runtime, value, kind);
  if (record != 0) return record;
  const message: String = `${what} called on an incompatible receiver`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return 0;
}

// The entry position holding `key`, or -1.
function findEntry(inout runtime: Runtime, record: u32, key: Value): i32 {
  const hash = runtime.hashValue(key);
  return runtime.heap.tableFind(record, key, hash);
}

// Insert or update. -0 keys become +0.
function putEntry(inout runtime: Runtime, record: u32, key: Value, value: Value): void {
  let normalized = key;
  if (isNumberZero(key)) normalized = int32Value(0);
  // A set's element is its key: -0 added becomes +0 when iterated.
  const kind = runtime.heap.tableKind(record);
  const stored: Value = kind == KIND_SET ? normalized : value;
  const hash = runtime.hashValue(normalized);
  const existing = runtime.heap.tableFind(record, normalized, hash);
  if (existing >= 0) {
    runtime.heap.setTableValue(record, u32(existing), stored);
    return;
  }
  runtime.heap.tableAdd(record, normalized, stored, hash);
}

function isNumberZero(value: Value): boolean {
  return isNumber(value) && toNumber(value) == 0.0;
}

function deleteEntry(inout runtime: Runtime, record: u32, key: Value): boolean {
  const position = findEntry(inout runtime, record, key);
  if (position < 0) return false;
  runtime.heap.tableRemove(record, u32(position));
  return true;
}

function clearEntries(inout runtime: Runtime, record: u32): void {
  runtime.heap.tableClear(record);
}

// --- construction ---

function construct(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, kind: i32, in name: String): Value {
  if (!runtime.isObjectLike(thisValue)) {
    const message: String = `Constructor ${name} requires 'new'`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const object = asCell(thisValue);
  const record = newRecord(inout runtime, kind);
  const atomMapRecord = runtime.atomMapRecord;
  runtime.heap.objectDefine(object, atomMapRecord, cellValue(record), PROP_NONE);
  const iterable = runtime.argument(argsBase, argc, 0);
  if (isUndefined(iterable) || isNull(iterable)) return thisValue;
  // Entries come through the object's own add / set, as the spec has it.
  const adderName: String = (kind == KIND_MAP || kind == KIND_WEAK_MAP) ? "set" : "add";
  const adderKey = runtime.internText(in adderName);
  const adder = runtime.getProperty(thisValue, adderKey);
  if (runtime.pendingThrow) return undefinedValue();
  // A getter may have made the adder: it is held until the builtin
  // returns.
  runtime.pushTempRoot(adder);
  if (!runtime.isCallable(adder)) {
    const message: String = `${name}: adder is not a function`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const iterator = runtime.getIterator(iterable);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(iterator);
  while (true) {
    const item = runtime.iteratorStep(iterator);
    if (runtime.pendingThrow || isDeleted(item)) break;
    let args = Array<Value>();
    if (kind == KIND_MAP || kind == KIND_WEAK_MAP) {
      if (!runtime.isObjectLike(item)) {
        const message: String = `Iterator value is not an entry object`;
        const error = runtime.typeError(in message);
        runtime.raise(error);
        break;
      }
      runtime.pushTempRoot(item);
      const first = runtime.getProperty(item, int32Value(0));
      if (runtime.pendingThrow) { runtime.popTempRoot(); break; }
      args.push(first);
      const second = runtime.getProperty(item, int32Value(1));
      runtime.popTempRoot();
      if (runtime.pendingThrow) break;
      args.push(second);
    } else {
      args.push(item);
    }
    runtime.callValue(adder, thisValue, move args);
    if (runtime.pendingThrow) break;
  }
  runtime.popTempRoot();
  if (runtime.pendingThrow) {
    // A throw from the adder or an entry read closes the iterator, and
    // wins over anything the close throws.
    runtime.closeAfterThrow(iterator);
    return undefinedValue();
  }
  return thisValue;
}

function constructMap(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const name: String = "Map";
  return construct(inout runtime, thisValue, argsBase, argc, KIND_MAP, in name);
}
function constructSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const name: String = "Set";
  return construct(inout runtime, thisValue, argsBase, argc, KIND_SET, in name);
}
function constructWeakMap(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const name: String = "WeakMap";
  return construct(inout runtime, thisValue, argsBase, argc, KIND_WEAK_MAP, in name);
}
function constructWeakSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const name: String = "WeakSet";
  return construct(inout runtime, thisValue, argsBase, argc, KIND_WEAK_SET, in name);
}

function requireWeakKey(inout runtime: Runtime, key: Value, in what: String): boolean {
  if (runtime.canBeHeldWeakly(key)) return true;
  const message: String = `Invalid value used ${what}`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return false;
}

// --- Map.prototype ---

function mapGet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.get";
  const record = requireRecord(inout runtime, thisValue, KIND_MAP, in what);
  if (record == 0) return undefinedValue();
  const position = findEntry(inout runtime, record, runtime.argument(argsBase, argc, 0));
  if (position < 0) return undefinedValue();
  return runtime.heap.tableValue(record, u32(position));
}

function mapSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.set";
  const record = requireRecord(inout runtime, thisValue, KIND_MAP, in what);
  if (record == 0) return undefinedValue();
  putEntry(inout runtime, record, runtime.argument(argsBase, argc, 0), runtime.argument(argsBase, argc, 1));
  return thisValue;
}

function mapHas(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.has";
  const record = requireRecord(inout runtime, thisValue, KIND_MAP, in what);
  if (record == 0) return undefinedValue();
  return booleanValue(findEntry(inout runtime, record, runtime.argument(argsBase, argc, 0)) >= 0);
}

function mapDelete(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.delete";
  const record = requireRecord(inout runtime, thisValue, KIND_MAP, in what);
  if (record == 0) return undefinedValue();
  return booleanValue(deleteEntry(inout runtime, record, runtime.argument(argsBase, argc, 0)));
}

function mapClear(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.clear";
  const record = requireRecord(inout runtime, thisValue, KIND_MAP, in what);
  if (record == 0) return undefinedValue();
  clearEntries(inout runtime, record);
  return undefinedValue();
}

function mapSize(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "get Map.prototype.size";
  const record = requireRecord(inout runtime, thisValue, KIND_MAP, in what);
  if (record == 0) return undefinedValue();
  return int32Value(i32(runtime.heap.tableLive(record)));
}

// forEach over the live entries, in insertion order, seeing additions.
function forEachEntry(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, kind: i32, in what: String): Value {
  const record = requireRecord(inout runtime, thisValue, kind, in what);
  if (record == 0) return undefinedValue();
  const callback = runtime.argument(argsBase, argc, 0);
  if (!runtime.isCallable(callback)) {
    const message: String = `${what}: callback is not a function`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const receiver = runtime.argument(argsBase, argc, 1);
  let position: u32 = 0;
  while (position < runtime.heap.tableExtent(record)) {
    const key = runtime.heap.tableKey(record, position);
    if (!isDeleted(key)) {
      const value = runtime.heap.tableValue(record, position);
      runtime.callValue3(callback, receiver, kind == KIND_MAP ? value : key, key, thisValue);
      if (runtime.pendingThrow) return undefinedValue();
    }
    position = position + 1;
  }
  return undefinedValue();
}

function mapForEach(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.forEach";
  return forEachEntry(inout runtime, thisValue, argsBase, argc, KIND_MAP, in what);
}

// --- Set.prototype ---

function setAdd(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.add";
  const record = requireRecord(inout runtime, thisValue, KIND_SET, in what);
  if (record == 0) return undefinedValue();
  const value = runtime.argument(argsBase, argc, 0);
  putEntry(inout runtime, record, value, value);
  return thisValue;
}

function setHas(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.has";
  const record = requireRecord(inout runtime, thisValue, KIND_SET, in what);
  if (record == 0) return undefinedValue();
  return booleanValue(findEntry(inout runtime, record, runtime.argument(argsBase, argc, 0)) >= 0);
}

function setDelete(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.delete";
  const record = requireRecord(inout runtime, thisValue, KIND_SET, in what);
  if (record == 0) return undefinedValue();
  return booleanValue(deleteEntry(inout runtime, record, runtime.argument(argsBase, argc, 0)));
}

function setClear(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.clear";
  const record = requireRecord(inout runtime, thisValue, KIND_SET, in what);
  if (record == 0) return undefinedValue();
  clearEntries(inout runtime, record);
  return undefinedValue();
}

function setSize(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "get Set.prototype.size";
  const record = requireRecord(inout runtime, thisValue, KIND_SET, in what);
  if (record == 0) return undefinedValue();
  return int32Value(i32(runtime.heap.tableLive(record)));
}

function setForEach(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.forEach";
  return forEachEntry(inout runtime, thisValue, argsBase, argc, KIND_SET, in what);
}

// --- WeakMap / WeakSet ---

// The weak-record position of `key`, or -1 (a key that cannot be held
// weakly is simply absent).
function weakPosition(in runtime: Runtime, record: u32, key: Value): i32 {
  if (!runtime.canBeHeldWeakly(key)) return -1;
  return runtime.heap.weakFind(record, asCell(key));
}

function weakMapGet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakMap.prototype.get";
  const record = requireRecord(inout runtime, thisValue, KIND_WEAK_MAP, in what);
  if (record == 0) return undefinedValue();
  const position = weakPosition(in runtime, record, runtime.argument(argsBase, argc, 0));
  if (position < 0) return undefinedValue();
  return runtime.heap.weakGet(record, u32(position));
}

function weakMapSet(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakMap.prototype.set";
  const record = requireRecord(inout runtime, thisValue, KIND_WEAK_MAP, in what);
  if (record == 0) return undefinedValue();
  const key = runtime.argument(argsBase, argc, 0);
  const keyWhat: String = "as weak map key";
  if (!requireWeakKey(inout runtime, key, in keyWhat)) return undefinedValue();
  runtime.heap.weakPut(record, asCell(key), runtime.argument(argsBase, argc, 1));
  return thisValue;
}

function weakMapHas(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakMap.prototype.has";
  const record = requireRecord(inout runtime, thisValue, KIND_WEAK_MAP, in what);
  if (record == 0) return undefinedValue();
  return booleanValue(weakPosition(in runtime, record, runtime.argument(argsBase, argc, 0)) >= 0);
}

function weakMapDelete(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakMap.prototype.delete";
  const record = requireRecord(inout runtime, thisValue, KIND_WEAK_MAP, in what);
  if (record == 0) return undefinedValue();
  const key = runtime.argument(argsBase, argc, 0);
  if (!runtime.canBeHeldWeakly(key)) return booleanValue(false);
  return booleanValue(runtime.heap.weakDelete(record, asCell(key)));
}

function weakSetAdd(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakSet.prototype.add";
  const record = requireRecord(inout runtime, thisValue, KIND_WEAK_SET, in what);
  if (record == 0) return undefinedValue();
  const value = runtime.argument(argsBase, argc, 0);
  const keyWhat: String = "in weak set";
  if (!requireWeakKey(inout runtime, value, in keyWhat)) return undefinedValue();
  runtime.heap.weakPut(record, asCell(value), value);
  return thisValue;
}

function weakSetHas(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakSet.prototype.has";
  const record = requireRecord(inout runtime, thisValue, KIND_WEAK_SET, in what);
  if (record == 0) return undefinedValue();
  return booleanValue(weakPosition(in runtime, record, runtime.argument(argsBase, argc, 0)) >= 0);
}

function weakSetDelete(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakSet.prototype.delete";
  const record = requireRecord(inout runtime, thisValue, KIND_WEAK_SET, in what);
  if (record == 0) return undefinedValue();
  const key = runtime.argument(argsBase, argc, 0);
  if (!runtime.canBeHeldWeakly(key)) return booleanValue(false);
  return booleanValue(runtime.heap.weakDelete(record, asCell(key)));
}

// --- iterators ---
//
// A collection iterator holds [record, position, kind] under a hidden
// key: kind 0 keys, 1 values, 2 entries.

function makeIterator(inout runtime: Runtime, thisValue: Value, collectionKind: i32, iterKind: i32, proto: u32, in what: String): Value {
  const record = requireRecord(inout runtime, thisValue, collectionKind, in what);
  if (record == 0) return undefinedValue();
  const iterator = runtime.heap.allocateObject(proto);
  const state = runtime.heap.allocateArray(3);
  runtime.heap.setSlot(state, 0, cellValue(record));
  runtime.heap.setSlot(state, 1, int32Value(0));
  runtime.heap.setSlot(state, 2, int32Value(iterKind));
  const atomMapIter = runtime.atomMapIter;
  runtime.heap.objectDefine(iterator, atomMapIter, cellValue(state), PROP_NONE);
  return cellValue(iterator);
}

function iteratorNext(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const atomMapIter = runtime.atomMapIter;
  if (!isCell(thisValue) || asCell(thisValue) == 0 || !runtime.heap.isObject(asCell(thisValue)) || runtime.heap.objectFindSlot(asCell(thisValue), atomMapIter) < 0) {
    const message: String = "next called on an incompatible receiver";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  const handle = asCell(thisValue);
  const stateSlot = runtime.heap.objectFindSlot(handle, atomMapIter);
  const state = asCell(runtime.heap.slot(handle, u32(stateSlot)));
  const recordValue = runtime.heap.slot(state, 0);
  if (isUndefined(recordValue)) return runtime.createIterResult(undefinedValue(), true);
  const record = asCell(recordValue);
  let position = u32(asInt32(runtime.heap.slot(state, 1)));
  const kind = asInt32(runtime.heap.slot(state, 2));
  const count = runtime.heap.tableExtent(record);
  while (position < count && isDeleted(runtime.heap.tableKey(record, position))) { position = position + 1; }
  if (position >= count) {
    runtime.heap.setSlot(state, 0, undefinedValue());
    runtime.heap.setSlot(state, 1, int32Value(i32(position)));
    return runtime.createIterResult(undefinedValue(), true);
  }
  runtime.heap.setSlot(state, 1, int32Value(i32(position + 1)));
  const key = runtime.heap.tableKey(record, position);
  const value = runtime.heap.tableValue(record, position);
  if (kind == 0) return runtime.createIterResult(key, false);
  if (kind == 1) return runtime.createIterResult(value, false);
  const pair = runtime.heap.allocateArray(2);
  runtime.heap.setSlot(pair, 0, key);
  runtime.heap.setSlot(pair, 1, value);
  return runtime.createIterResult(cellValue(pair), false);
}

function mapKeys(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.keys";
  const proto = runtime.mapIteratorProto;
  return makeIterator(inout runtime, thisValue, KIND_MAP, 0, proto, in what);
}
function mapValues(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.values";
  const proto = runtime.mapIteratorProto;
  return makeIterator(inout runtime, thisValue, KIND_MAP, 1, proto, in what);
}
function mapEntries(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.entries";
  const proto = runtime.mapIteratorProto;
  return makeIterator(inout runtime, thisValue, KIND_MAP, 2, proto, in what);
}
function setValues(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.values";
  const proto = runtime.setIteratorProto;
  return makeIterator(inout runtime, thisValue, KIND_SET, 1, proto, in what);
}
function setEntries(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.entries";
  const proto = runtime.setIteratorProto;
  return makeIterator(inout runtime, thisValue, KIND_SET, 2, proto, in what);
}

// --- upsert: getOrInsert / getOrInsertComputed ---

function getOrInsert(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, kind: i32, in what: String): Value {
  const record = requireRecord(inout runtime, thisValue, kind, in what);
  if (record == 0) return undefinedValue();
  let key = runtime.argument(argsBase, argc, 0);
  if (kind == KIND_WEAK_MAP) {
    const keyWhat: String = "as weak map key";
    if (!requireWeakKey(inout runtime, key, in keyWhat)) return undefinedValue();
  } else if (isNumberZero(key)) {
    key = int32Value(0);
  }
  const value = runtime.argument(argsBase, argc, 1);
  if (kind == KIND_WEAK_MAP) {
    const held = runtime.heap.weakFind(record, asCell(key));
    if (held >= 0) return runtime.heap.weakGet(record, u32(held));
    runtime.heap.weakPut(record, asCell(key), value);
    return value;
  }
  const position = findEntry(inout runtime, record, key);
  if (position >= 0) {
    return runtime.heap.tableValue(record, u32(position));
  }
  putEntry(inout runtime, record, key, value);
  return value;
}

function getOrInsertComputed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, kind: i32, in what: String): Value {
  const record = requireRecord(inout runtime, thisValue, kind, in what);
  if (record == 0) return undefinedValue();
  let key = runtime.argument(argsBase, argc, 0);
  if (kind == KIND_WEAK_MAP) {
    const keyWhat: String = "as weak map key";
    if (!requireWeakKey(inout runtime, key, in keyWhat)) return undefinedValue();
  } else if (isNumberZero(key)) {
    key = int32Value(0);
  }
  const callback = runtime.argument(argsBase, argc, 1);
  if (!runtime.isCallable(callback)) {
    const message: String = `${what}: callback is not a function`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  if (kind == KIND_WEAK_MAP) {
    const held = runtime.heap.weakFind(record, asCell(key));
    if (held >= 0) return runtime.heap.weakGet(record, u32(held));
  } else {
    const position = findEntry(inout runtime, record, key);
    if (position >= 0) {
      return runtime.heap.tableValue(record, u32(position));
    }
  }
  let args = Array<Value>();
  args.push(key);
  // The key and the receiver stay rooted in the call's registers while
  // the callback runs (which may collect).
  const value = runtime.callValue(callback, undefinedValue(), move args);
  if (runtime.pendingThrow) return undefinedValue();
  // The callback may have added the key itself.
  if (kind == KIND_WEAK_MAP) {
    runtime.heap.weakPut(record, asCell(key), value);
    return value;
  }
  putEntry(inout runtime, record, key, value);
  return value;
}

function mapGetOrInsert(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.getOrInsert";
  return getOrInsert(inout runtime, thisValue, argsBase, argc, KIND_MAP, in what);
}
function mapGetOrInsertComputed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.prototype.getOrInsertComputed";
  return getOrInsertComputed(inout runtime, thisValue, argsBase, argc, KIND_MAP, in what);
}
function weakMapGetOrInsert(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakMap.prototype.getOrInsert";
  return getOrInsert(inout runtime, thisValue, argsBase, argc, KIND_WEAK_MAP, in what);
}
function weakMapGetOrInsertComputed(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "WeakMap.prototype.getOrInsertComputed";
  return getOrInsertComputed(inout runtime, thisValue, argsBase, argc, KIND_WEAK_MAP, in what);
}

// --- groupBy ---

// GroupBy: the keys in first-seen order and, for each, the array of the
// items the callback mapped to it. Keys are canonicalized as Map keys
// when `asMap`, and as property keys otherwise.
function groupItems(inout runtime: Runtime, argsBase: u32, argc: u32, asMap: boolean, in what: String): u32 {
  const items = runtime.argument(argsBase, argc, 0);
  if (isUndefined(items) || isNull(items)) {
    const message: String = `${what}: items is null or undefined`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return 0;
  }
  const callback = runtime.argument(argsBase, argc, 1);
  if (!runtime.isCallable(callback)) {
    const message: String = `${what}: callback is not a function`;
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return 0;
  }
  // A Map record collects the groups: key to array of elements.
  const groups = newRecord(inout runtime, KIND_MAP);
  runtime.pushTempRoot(cellValue(groups));
  const iterator = runtime.getIterator(items);
  if (runtime.pendingThrow) { runtime.popTempRoot(); return 0; }
  runtime.pushTempRoot(iterator);
  let index: i32 = 0;
  while (true) {
    const item = runtime.iteratorStep(iterator);
    if (runtime.pendingThrow || isDeleted(item)) break;
    runtime.pushTempRoot(item);
    let args = Array<Value>();
    args.push(item);
    args.push(int32Value(index));
    let key = runtime.callValue(callback, undefinedValue(), move args);
    if (runtime.pendingThrow) {
      runtime.popTempRoot();
      runtime.closeAfterThrow(iterator);
      break;
    }
    if (asMap) {
      if (isNumberZero(key)) key = int32Value(0);
    } else {
      runtime.pushTempRoot(key);
      const atom = runtime.propertyKey(key);
      runtime.popTempRoot();
      if (runtime.pendingThrow) {
        runtime.popTempRoot();
        runtime.closeAfterThrow(iterator);
        break;
      }
      key = cellValue(atom);
    }
    const position = findEntry(inout runtime, groups, key);
    if (position >= 0) {
      const list = asCell(runtime.heap.tableValue(groups, u32(position)));
      const count = runtime.heap.arrayLength(list);
      runtime.heap.arraySet(list, count, item);
    } else {
      const list = runtime.heap.allocateArray(1);
      runtime.heap.setSlot(list, 0, item);
      putEntry(inout runtime, groups, key, cellValue(list));
    }
    runtime.popTempRoot();
    index = index + 1;
  }
  runtime.popTempRoot();
  runtime.popTempRoot();
  if (runtime.pendingThrow) return 0;
  return groups;
}

function mapGroupBy(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Map.groupBy";
  const groups = groupItems(inout runtime, argsBase, argc, true, in what);
  if (groups == 0) return undefinedValue();
  const mapProto = runtime.mapProto;
  const object = runtime.heap.allocateObject(mapProto);
  const atomMapRecord = runtime.atomMapRecord;
  runtime.heap.objectDefine(object, atomMapRecord, cellValue(groups), PROP_NONE);
  return cellValue(object);
}

function objectGroupBy(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Object.groupBy";
  const groups = groupItems(inout runtime, argsBase, argc, false, in what);
  if (groups == 0) return undefinedValue();
  runtime.pushTempRoot(cellValue(groups));
  const object = runtime.heap.allocateObject(0);
  const count = runtime.heap.tableExtent(groups);
  let position: u32 = 0;
  while (position < count) {
    const atom = asCell(runtime.heap.tableKey(groups, position));
    const list = runtime.heap.tableValue(groups, position);
    runtime.heap.objectDefine(object, atom, list, PROP_DEFAULT);
    position = position + 1;
  }
  runtime.popTempRoot();
  return cellValue(object);
}

// --- Set methods (union, intersection, ...) ---

// GetSetRecord: the other operand's size (as a double, so +Infinity is
// representable), its `has`, and its `keys`.
struct SetRecord {
  set: Value;
  size: f64;
  has: Value;
  keys: Value;
  ok: boolean;
}

function getSetRecord(inout runtime: Runtime, other: Value): SetRecord {
  const failed = SetRecord({ set: undefinedValue(), size: 0.0, has: undefinedValue(), keys: undefinedValue(), ok: false });
  if (!runtime.isObjectLike(other)) {
    const message: String = "Set operation argument must be an object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return failed;
  }
  const sizeText: String = "size";
  const sizeKey = runtime.internText(in sizeText);
  const rawSize = runtime.getProperty(other, sizeKey);
  if (runtime.pendingThrow) return failed;
  const number = runtime.toNumberValue(rawSize);
  if (runtime.pendingThrow) return failed;
  if (number != number) {
    const message: String = "Set operation argument has a NaN size";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return failed;
  }
  const size = truncateDouble(number);
  if (size < 0.0) {
    const message: String = "Set operation argument has a negative size";
    const error = runtime.rangeError(in message);
    runtime.raise(error);
    return failed;
  }
  const hasText: String = "has";
  const hasKey = runtime.internText(in hasText);
  const has = runtime.getProperty(other, hasKey);
  if (runtime.pendingThrow) return failed;
  if (!runtime.isCallable(has)) {
    const message: String = "Set operation argument has no callable 'has'";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return failed;
  }
  const keysText: String = "keys";
  const keysKey = runtime.internText(in keysText);
  const keys = runtime.getProperty(other, keysKey);
  if (runtime.pendingThrow) return failed;
  if (!runtime.isCallable(keys)) {
    const message: String = "Set operation argument has no callable 'keys'";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return failed;
  }
  return SetRecord({ set: other, size: size, has: has, keys: keys, ok: true });
}

function recordSize(in runtime: Runtime, record: u32): f64 {
  return f64(asInt32(int32Value(i32(runtime.heap.tableLive(record)))));
}

// Call the other set's `has` with one element.
function otherHas(inout runtime: Runtime, in other: SetRecord, element: Value): boolean {
  const result = runtime.callValue1(other.has, other.set, element);
  if (runtime.pendingThrow) return false;
  return runtime.toBooleanValue(result);
}

// The iterator from the other set's `keys`.
function otherKeys(inout runtime: Runtime, in other: SetRecord): Value {
  const iterator = runtime.callValue0(other.keys, other.set);
  if (runtime.pendingThrow) return undefinedValue();
  if (!runtime.isObjectLike(iterator)) {
    const message: String = "Set operation argument's keys() did not return an object";
    const error = runtime.typeError(in message);
    runtime.raise(error);
    return undefinedValue();
  }
  return iterator;
}

// A fresh Set holding the live elements of `record`, in order.
function copySet(inout runtime: Runtime, record: u32): u32 {
  const result = newRecord(inout runtime, KIND_SET);
  runtime.pushTempRoot(cellValue(result));
  const count = runtime.heap.tableExtent(record);
  let position: u32 = 0;
  while (position < count) {
    const key = runtime.heap.tableKey(record, position);
    if (!isDeleted(key)) putEntry(inout runtime, result, key, key);
    position = position + 1;
  }
  runtime.popTempRoot();
  return result;
}

function setFromRecord(inout runtime: Runtime, record: u32): Value {
  const setProto = runtime.setProto;
  const object = runtime.heap.allocateObject(setProto);
  const atomMapRecord = runtime.atomMapRecord;
  runtime.heap.objectDefine(object, atomMapRecord, cellValue(record), PROP_NONE);
  return cellValue(object);
}

const SET_UNION: i32 = 0;
const SET_INTERSECTION: i32 = 1;
const SET_DIFFERENCE: i32 = 2;
const SET_SYMMETRIC_DIFFERENCE: i32 = 3;
const SET_IS_SUBSET: i32 = 4;
const SET_IS_SUPERSET: i32 = 5;
const SET_IS_DISJOINT: i32 = 6;

function setOperation(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, op: i32, in what: String): Value {
  const record = requireRecord(inout runtime, thisValue, KIND_SET, in what);
  if (record == 0) return undefinedValue();
  const other = getSetRecord(inout runtime, runtime.argument(argsBase, argc, 0));
  if (!other.ok) return undefinedValue();
  runtime.pushTempRoot(other.has);
  runtime.pushTempRoot(other.keys);
  const result = setOperationBody(inout runtime, record, in other, op);
  runtime.popTempRoot();
  runtime.popTempRoot();
  return result;
}

function setOperationBody(inout runtime: Runtime, record: u32, in other: SetRecord, op: i32): Value {
  const thisSize = recordSize(in runtime, record);
  if (op == SET_UNION) {
    const result = copySet(inout runtime, record);
    runtime.pushTempRoot(cellValue(result));
    const iterator = otherKeys(inout runtime, in other);
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    runtime.pushTempRoot(iterator);
    while (true) {
      const next = runtime.iteratorStep(iterator);
      if (runtime.pendingThrow || isDeleted(next)) break;
      putEntry(inout runtime, result, next, next);
    }
    runtime.popTempRoot();
    runtime.popTempRoot();
    if (runtime.pendingThrow) return undefinedValue();
    return setFromRecord(inout runtime, result);
  }
  if (op == SET_INTERSECTION) {
    const result = newRecord(inout runtime, KIND_SET);
    runtime.pushTempRoot(cellValue(result));
    if (thisSize <= other.size) {
      let position: u32 = 0;
      while (position < runtime.heap.tableExtent(record)) {
        const element = runtime.heap.tableKey(record, position);
        position = position + 1;
        if (isDeleted(element)) continue;
        const inOther = otherHas(inout runtime, in other, element);
        if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
        if (inOther) putEntry(inout runtime, result, element, element);
      }
    } else {
      const iterator = otherKeys(inout runtime, in other);
      if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
      runtime.pushTempRoot(iterator);
      while (true) {
        const next = runtime.iteratorStep(iterator);
        if (runtime.pendingThrow || isDeleted(next)) break;
        if (findEntry(inout runtime, record, next) >= 0) putEntry(inout runtime, result, next, next);
      }
      runtime.popTempRoot();
      if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    }
    runtime.popTempRoot();
    return setFromRecord(inout runtime, result);
  }
  if (op == SET_DIFFERENCE) {
    const result = copySet(inout runtime, record);
    runtime.pushTempRoot(cellValue(result));
    if (thisSize <= other.size) {
      let position: u32 = 0;
      while (position < runtime.heap.tableExtent(record)) {
        const element = runtime.heap.tableKey(record, position);
        position = position + 1;
        if (isDeleted(element)) continue;
        const inOther = otherHas(inout runtime, in other, element);
        if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
        if (inOther) deleteEntry(inout runtime, result, element);
      }
    } else {
      const iterator = otherKeys(inout runtime, in other);
      if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
      runtime.pushTempRoot(iterator);
      while (true) {
        const next = runtime.iteratorStep(iterator);
        if (runtime.pendingThrow || isDeleted(next)) break;
        deleteEntry(inout runtime, result, next);
      }
      runtime.popTempRoot();
      if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    }
    runtime.popTempRoot();
    return setFromRecord(inout runtime, result);
  }
  if (op == SET_SYMMETRIC_DIFFERENCE) {
    const result = copySet(inout runtime, record);
    runtime.pushTempRoot(cellValue(result));
    const iterator = otherKeys(inout runtime, in other);
    if (runtime.pendingThrow) { runtime.popTempRoot(); return undefinedValue(); }
    runtime.pushTempRoot(iterator);
    while (true) {
      let next = runtime.iteratorStep(iterator);
      if (runtime.pendingThrow || isDeleted(next)) break;
      if (isNumberZero(next)) next = int32Value(0);
      if (findEntry(inout runtime, record, next) >= 0) {
        deleteEntry(inout runtime, result, next);
      } else {
        putEntry(inout runtime, result, next, next);
      }
    }
    runtime.popTempRoot();
    runtime.popTempRoot();
    if (runtime.pendingThrow) return undefinedValue();
    return setFromRecord(inout runtime, result);
  }
  if (op == SET_IS_SUBSET) {
    if (thisSize > other.size) return booleanValue(false);
    let position: u32 = 0;
    while (position < runtime.heap.tableExtent(record)) {
      const element = runtime.heap.tableKey(record, position);
      position = position + 1;
      if (isDeleted(element)) continue;
      const inOther = otherHas(inout runtime, in other, element);
      if (runtime.pendingThrow) return undefinedValue();
      if (!inOther) return booleanValue(false);
    }
    return booleanValue(true);
  }
  if (op == SET_IS_SUPERSET) {
    if (thisSize < other.size) return booleanValue(false);
    const iterator = otherKeys(inout runtime, in other);
    if (runtime.pendingThrow) return undefinedValue();
    runtime.pushTempRoot(iterator);
    let outcome = true;
    while (true) {
      const next = runtime.iteratorStep(iterator);
      if (runtime.pendingThrow || isDeleted(next)) break;
      if (findEntry(inout runtime, record, next) < 0) {
        outcome = false;
        runtime.iteratorClose(iterator);
        break;
      }
    }
    runtime.popTempRoot();
    if (runtime.pendingThrow) return undefinedValue();
    return booleanValue(outcome);
  }
  // SET_IS_DISJOINT
  if (thisSize <= other.size) {
    let position: u32 = 0;
    while (position < runtime.heap.tableExtent(record)) {
      const element = runtime.heap.tableKey(record, position);
      position = position + 1;
      if (isDeleted(element)) continue;
      const inOther = otherHas(inout runtime, in other, element);
      if (runtime.pendingThrow) return undefinedValue();
      if (inOther) return booleanValue(false);
    }
    return booleanValue(true);
  }
  const iterator = otherKeys(inout runtime, in other);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(iterator);
  let disjoint = true;
  while (true) {
    const next = runtime.iteratorStep(iterator);
    if (runtime.pendingThrow || isDeleted(next)) break;
    if (findEntry(inout runtime, record, next) >= 0) {
      disjoint = false;
      runtime.iteratorClose(iterator);
      break;
    }
  }
  runtime.popTempRoot();
  if (runtime.pendingThrow) return undefinedValue();
  return booleanValue(disjoint);
}

function setUnion(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.union";
  return setOperation(inout runtime, thisValue, argsBase, argc, SET_UNION, in what);
}
function setIntersection(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.intersection";
  return setOperation(inout runtime, thisValue, argsBase, argc, SET_INTERSECTION, in what);
}
function setDifference(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.difference";
  return setOperation(inout runtime, thisValue, argsBase, argc, SET_DIFFERENCE, in what);
}
function setSymmetricDifference(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.symmetricDifference";
  return setOperation(inout runtime, thisValue, argsBase, argc, SET_SYMMETRIC_DIFFERENCE, in what);
}
function setIsSubsetOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.isSubsetOf";
  return setOperation(inout runtime, thisValue, argsBase, argc, SET_IS_SUBSET, in what);
}
function setIsSupersetOf(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.isSupersetOf";
  return setOperation(inout runtime, thisValue, argsBase, argc, SET_IS_SUPERSET, in what);
}
function setIsDisjointFrom(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const what: String = "Set.prototype.isDisjointFrom";
  return setOperation(inout runtime, thisValue, argsBase, argc, SET_IS_DISJOINT, in what);
}

// --- Symbol.species ---

function speciesGetter(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  return thisValue;
}

// `get [Symbol.species]` on a constructor, returning `this`.
export function defineSpecies(inout runtime: Runtime, ctor: u32): void {
  const name: String = "get [Symbol.species]";
  const getter = runtime.defineHostFunction(speciesGetter, undefinedValue(), 0, in name);
  const accessor = runtime.heap.allocateAccessor(cellValue(getter), undefinedValue());
  const symbolSpecies = runtime.symbolSpecies;
  const key = runtime.propertyKey(symbolSpecies);
  runtime.defineOwnAttr(ctor, key, cellValue(accessor), PROP_CONFIGURABLE | PROP_ACCESSOR);
}

// --- installation ---

function defineAccessor(inout runtime: Runtime, target: u32, in name: String, getter: Value): void {
  const accessor = runtime.heap.allocateAccessor(getter, undefinedValue());
  const atom = runtime.atomOf(in name);
  runtime.heap.objectDefine(target, atom, cellValue(accessor), PROP_CONFIGURABLE | PROP_ACCESSOR);
}

function defineTag(inout runtime: Runtime, target: u32, in tag: String): void {
  const symbolToStringTag = runtime.symbolToStringTag;
  const tagKey = runtime.propertyKey(symbolToStringTag);
  const tagValue = runtime.internText(in tag);
  runtime.heap.objectDefine(target, tagKey, tagValue, PROP_CONFIGURABLE);
}

export function installCollections(inout runtime: Runtime): void {
  if ((runtime.features & FEATURE_COLLECTIONS) != 0) return;
  runtime.features = runtime.features | FEATURE_COLLECTIONS;
  const objectProto = runtime.objectProto;
  const iteratorProto = runtime.iteratorProto;
  const atomConstructor = runtime.atomConstructor;
  const symbolIterator = runtime.symbolIterator;
  const iteratorKey = runtime.propertyKey(symbolIterator);

  // Map
  runtime.mapProto = runtime.heap.allocateObject(objectProto);
  const mapProto = runtime.mapProto;
  const mapText: String = "Map";
  const mapCtor = runtime.defineConstructor(constructMap, undefinedValue(), 0, in mapText);
  runtime.heap.setLink(mapCtor, mapProto);
  runtime.defineOwnAttr(mapProto, atomConstructor, cellValue(mapCtor), PROP_METHOD);
  runtime.setGlobal("Map", cellValue(mapCtor));
  const getText: String = "get"; runtime.defineMethod(mapProto, in getText, mapGet, 1);
  const setText: String = "set"; runtime.defineMethod(mapProto, in setText, mapSet, 2);
  const hasText: String = "has"; runtime.defineMethod(mapProto, in hasText, mapHas, 1);
  const deleteText: String = "delete"; runtime.defineMethod(mapProto, in deleteText, mapDelete, 1);
  const clearText: String = "clear"; runtime.defineMethod(mapProto, in clearText, mapClear, 0);
  const forEachText: String = "forEach"; runtime.defineMethod(mapProto, in forEachText, mapForEach, 1);
  const keysText: String = "keys"; runtime.defineMethod(mapProto, in keysText, mapKeys, 0);
  const valuesText: String = "values"; runtime.defineMethod(mapProto, in valuesText, mapValues, 0);
  const entriesText: String = "entries";
  const mapEntriesFn = runtime.defineMethod(mapProto, in entriesText, mapEntries, 0);
  runtime.heap.objectDefine(mapProto, iteratorKey, cellValue(mapEntriesFn), PROP_METHOD);
  const sizeText: String = "size";
  const mapSizeName: String = "get size";
  const mapSizeFn = runtime.defineHostFunction(mapSize, undefinedValue(), 0, in mapSizeName);
  defineAccessor(inout runtime, mapProto, in sizeText, cellValue(mapSizeFn));
  defineTag(inout runtime, mapProto, in mapText);
  const getOrInsertText: String = "getOrInsert"; runtime.defineMethod(mapProto, in getOrInsertText, mapGetOrInsert, 2);
  const getOrInsertComputedText: String = "getOrInsertComputed"; runtime.defineMethod(mapProto, in getOrInsertComputedText, mapGetOrInsertComputed, 2);
  const groupByText: String = "groupBy";
  runtime.defineMethod(mapCtor, in groupByText, mapGroupBy, 2);
  defineSpecies(inout runtime, mapCtor);
  const objectSlot = runtime.globalSlot("Object");
  const objectCtor = asCell(runtime.globals[usize(objectSlot)].value);
  runtime.defineMethod(objectCtor, in groupByText, objectGroupBy, 2);
  const arraySlot = runtime.globalSlot("Array");
  const arrayCtor = asCell(runtime.globals[usize(arraySlot)].value);
  defineSpecies(inout runtime, arrayCtor);

  // Set
  runtime.setProto = runtime.heap.allocateObject(objectProto);
  const setProto = runtime.setProto;
  const setCtorText: String = "Set";
  const setCtor = runtime.defineConstructor(constructSet, undefinedValue(), 0, in setCtorText);
  runtime.heap.setLink(setCtor, setProto);
  runtime.defineOwnAttr(setProto, atomConstructor, cellValue(setCtor), PROP_METHOD);
  runtime.setGlobal("Set", cellValue(setCtor));
  const addText: String = "add"; runtime.defineMethod(setProto, in addText, setAdd, 1);
  runtime.defineMethod(setProto, in hasText, setHas, 1);
  runtime.defineMethod(setProto, in deleteText, setDelete, 1);
  runtime.defineMethod(setProto, in clearText, setClear, 0);
  runtime.defineMethod(setProto, in forEachText, setForEach, 1);
  const setValuesFn = runtime.defineMethod(setProto, in valuesText, setValues, 0);
  const keysAtom = runtime.atomOf(in keysText);
  runtime.heap.objectDefine(setProto, keysAtom, cellValue(setValuesFn), PROP_METHOD);
  runtime.heap.objectDefine(setProto, iteratorKey, cellValue(setValuesFn), PROP_METHOD);
  runtime.defineMethod(setProto, in entriesText, setEntries, 0);
  const setSizeName: String = "get size";
  const setSizeFn = runtime.defineHostFunction(setSize, undefinedValue(), 0, in setSizeName);
  defineAccessor(inout runtime, setProto, in sizeText, cellValue(setSizeFn));
  defineTag(inout runtime, setProto, in setCtorText);
  defineSpecies(inout runtime, setCtor);
  const unionText: String = "union"; runtime.defineMethod(setProto, in unionText, setUnion, 1);
  const intersectionText: String = "intersection"; runtime.defineMethod(setProto, in intersectionText, setIntersection, 1);
  const differenceText: String = "difference"; runtime.defineMethod(setProto, in differenceText, setDifference, 1);
  const symmetricDifferenceText: String = "symmetricDifference"; runtime.defineMethod(setProto, in symmetricDifferenceText, setSymmetricDifference, 1);
  const isSubsetOfText: String = "isSubsetOf"; runtime.defineMethod(setProto, in isSubsetOfText, setIsSubsetOf, 1);
  const isSupersetOfText: String = "isSupersetOf"; runtime.defineMethod(setProto, in isSupersetOfText, setIsSupersetOf, 1);
  const isDisjointFromText: String = "isDisjointFrom"; runtime.defineMethod(setProto, in isDisjointFromText, setIsDisjointFrom, 1);

  // WeakMap / WeakSet
  runtime.weakMapProto = runtime.heap.allocateObject(objectProto);
  const weakMapProto = runtime.weakMapProto;
  const weakMapText: String = "WeakMap";
  const weakMapCtor = runtime.defineConstructor(constructWeakMap, undefinedValue(), 0, in weakMapText);
  runtime.heap.setLink(weakMapCtor, weakMapProto);
  runtime.defineOwnAttr(weakMapProto, atomConstructor, cellValue(weakMapCtor), PROP_METHOD);
  runtime.setGlobal("WeakMap", cellValue(weakMapCtor));
  runtime.defineMethod(weakMapProto, in getText, weakMapGet, 1);
  runtime.defineMethod(weakMapProto, in setText, weakMapSet, 2);
  runtime.defineMethod(weakMapProto, in hasText, weakMapHas, 1);
  runtime.defineMethod(weakMapProto, in deleteText, weakMapDelete, 1);
  runtime.defineMethod(weakMapProto, in getOrInsertText, weakMapGetOrInsert, 2);
  runtime.defineMethod(weakMapProto, in getOrInsertComputedText, weakMapGetOrInsertComputed, 2);
  defineTag(inout runtime, weakMapProto, in weakMapText);
  runtime.weakSetProto = runtime.heap.allocateObject(objectProto);
  const weakSetProto = runtime.weakSetProto;
  const weakSetText: String = "WeakSet";
  const weakSetCtor = runtime.defineConstructor(constructWeakSet, undefinedValue(), 0, in weakSetText);
  runtime.heap.setLink(weakSetCtor, weakSetProto);
  runtime.defineOwnAttr(weakSetProto, atomConstructor, cellValue(weakSetCtor), PROP_METHOD);
  runtime.setGlobal("WeakSet", cellValue(weakSetCtor));
  runtime.defineMethod(weakSetProto, in addText, weakSetAdd, 1);
  runtime.defineMethod(weakSetProto, in hasText, weakSetHas, 1);
  runtime.defineMethod(weakSetProto, in deleteText, weakSetDelete, 1);
  defineTag(inout runtime, weakSetProto, in weakSetText);

  // Iterator prototypes
  runtime.mapIteratorProto = runtime.heap.allocateObject(iteratorProto);
  const mapIteratorProto = runtime.mapIteratorProto;
  const nextText: String = "next";
  runtime.defineMethod(mapIteratorProto, in nextText, iteratorNext, 0);
  const mapIteratorTag: String = "Map Iterator";
  defineTag(inout runtime, mapIteratorProto, in mapIteratorTag);
  runtime.setIteratorProto = runtime.heap.allocateObject(iteratorProto);
  const setIteratorProto = runtime.setIteratorProto;
  runtime.defineMethod(setIteratorProto, in nextText, iteratorNext, 0);
  const setIteratorTag: String = "Set Iterator";
  defineTag(inout runtime, setIteratorProto, in setIteratorTag);
}
