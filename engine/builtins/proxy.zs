// Proxy (ECMA-262 10.5 and 28.2), installed by installProxy:
// zjs_new_context installs it, a core context when zjs_install_proxy
// asks. A proxy is a cell of its own (heap TAG_PROXY) holding a target
// and a handler; the runtime's property operations hand one to
// proxyOperate here, through the host table, so a build that never
// installs Proxy links none of this.
//
// Here so far: the traps get, set, has and deleteProperty, each with the
// specification's checks of its answer against the target. Every other
// internal method goes to the target as it is (the runtime's arms).
// Until their traps are here, `new Proxy` refuses what they would be
// needed for, with a TypeError that says so: a handler that has
// getOwnPropertyDescriptor, defineProperty, ownKeys, getPrototypeOf,
// setPrototypeOf, isExtensible or preventExtensions, and a target that
// is a function (apply and construct).
import { thread } from "std/thread";
import { Value, undefinedValue, nullValue, booleanValue, cellValue, asCell, asInt32, isCell, isUndefined, isNull } from "../value.zs";
import { Runtime, FEATURE_PROXY, HOST_PROXY, HOST_PROXY_REVOKE, PROXY_GET, PROXY_SET, PROXY_HAS, PROXY_DELETE } from "../runtime.zs";
import { PROP_WRITABLE, PROP_CONFIGURABLE, PROP_ACCESSOR } from "../heap.zs";

function throwTypeError(inout runtime: Runtime, in message: String): Value {
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return undefinedValue();
}

// GetMethod(handler, name): the trap, or undefined for none. A throw is
// left pending.
function trapOf(inout runtime: Runtime, handler: Value, in name: String): Value {
  const atom = runtime.atomOf(in name);
  const trap = runtime.getProperty(handler, cellValue(atom));
  if (runtime.pendingThrow) return undefinedValue();
  if (isUndefined(trap) || isNull(trap)) return undefinedValue();
  if (!runtime.isCallable(trap)) {
    const message: String = `The Proxy handler's ${name} trap is not a function`;
    return throwTypeError(inout runtime, in message);
  }
  return trap;
}

// [[Get]]: the trap's answer must be the target's value for a property
// the target holds read-only and non-configurable, and undefined for a
// non-configurable accessor with no getter.
function proxyGet(inout runtime: Runtime, target: Value, handler: Value, key: Value, receiver: Value): Value {
  const name: String = "get";
  const trap = trapOf(inout runtime, handler, in name);
  if (runtime.pendingThrow) return undefinedValue();
  if (isUndefined(trap)) return runtime.getWithReceiver(target, key, receiver);
  const result = runtime.callValue3(trap, handler, target, key, receiver);
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(result);
  const own = runtime.getOwnDescriptor(target, key);
  if (runtime.pendingThrow) return undefinedValue();
  if (own.present && (own.attr & PROP_CONFIGURABLE) == 0) {
    if ((own.attr & PROP_ACCESSOR) == 0) {
      if ((own.attr & PROP_WRITABLE) == 0 && !runtime.sameValue(result, own.value)) {
        const message: String = "The Proxy's get trap gave another value for a read-only, non-configurable property of the target";
        return throwTypeError(inout runtime, in message);
      }
    } else if (isUndefined(own.getter) && !isUndefined(result)) {
      const message: String = "The Proxy's get trap gave a value for a non-configurable accessor of the target that has no getter";
      return throwTypeError(inout runtime, in message);
    }
  }
  return result;
}

// [[Set]]: a trap may not report a write the target's read-only,
// non-configurable property (or setterless accessor) would refuse.
function proxySet(inout runtime: Runtime, target: Value, handler: Value, key: Value, value: Value, receiver: Value): Value {
  const name: String = "set";
  const trap = trapOf(inout runtime, handler, in name);
  if (runtime.pendingThrow) return undefinedValue();
  if (isUndefined(trap)) return booleanValue(runtime.superSet(asCell(target), key, value, receiver));
  const answer = runtime.callValue4(trap, handler, target, key, value, receiver);
  if (runtime.pendingThrow) return undefinedValue();
  if (!runtime.toBooleanValue(answer)) return booleanValue(false);
  const own = runtime.getOwnDescriptor(target, key);
  if (runtime.pendingThrow) return undefinedValue();
  if (own.present && (own.attr & PROP_CONFIGURABLE) == 0) {
    if ((own.attr & PROP_ACCESSOR) == 0) {
      if ((own.attr & PROP_WRITABLE) == 0 && !runtime.sameValue(value, own.value)) {
        const message: String = "The Proxy's set trap accepted another value for a read-only, non-configurable property of the target";
        return throwTypeError(inout runtime, in message);
      }
    } else if (isUndefined(own.setter)) {
      const message: String = "The Proxy's set trap accepted a value for a non-configurable accessor of the target that has no setter";
      return throwTypeError(inout runtime, in message);
    }
  }
  return booleanValue(true);
}

// [[HasProperty]]: a trap may not hide a non-configurable property, or
// any property of a target that takes no new ones.
function proxyHas(inout runtime: Runtime, target: Value, handler: Value, key: Value): Value {
  const name: String = "has";
  const trap = trapOf(inout runtime, handler, in name);
  if (runtime.pendingThrow) return undefinedValue();
  if (isUndefined(trap)) return booleanValue(runtime.hasProperty(target, key));
  const answer = runtime.callValue2(trap, handler, target, key);
  if (runtime.pendingThrow) return undefinedValue();
  if (runtime.toBooleanValue(answer)) return booleanValue(true);
  const own = runtime.getOwnDescriptor(target, key);
  if (runtime.pendingThrow) return undefinedValue();
  if (own.present) {
    if ((own.attr & PROP_CONFIGURABLE) == 0) {
      const message: String = "The Proxy's has trap hid a non-configurable property of the target";
      return throwTypeError(inout runtime, in message);
    }
    if (!runtime.isExtensible(target)) {
      const message: String = "The Proxy's has trap hid a property of a target that is not extensible";
      return throwTypeError(inout runtime, in message);
    }
  }
  return booleanValue(false);
}

// [[Delete]]: a trap may not report gone a non-configurable property,
// or any property of a target that takes no new ones.
function proxyDelete(inout runtime: Runtime, target: Value, handler: Value, key: Value): Value {
  const name: String = "deleteProperty";
  const trap = trapOf(inout runtime, handler, in name);
  if (runtime.pendingThrow) return undefinedValue();
  if (isUndefined(trap)) return booleanValue(runtime.deleteProperty(target, key));
  const answer = runtime.callValue2(trap, handler, target, key);
  if (runtime.pendingThrow) return undefinedValue();
  if (!runtime.toBooleanValue(answer)) return booleanValue(false);
  const own = runtime.getOwnDescriptor(target, key);
  if (runtime.pendingThrow) return undefinedValue();
  if (!own.present) return booleanValue(true);
  if ((own.attr & PROP_CONFIGURABLE) == 0) {
    const message: String = "The Proxy's deleteProperty trap deleted a non-configurable property of the target";
    return throwTypeError(inout runtime, in message);
  }
  if (!runtime.isExtensible(target)) {
    const message: String = "The Proxy's deleteProperty trap deleted a property of a target that is not extensible";
    return throwTypeError(inout runtime, in message);
  }
  return booleanValue(true);
}

// A proxy's internal method (the runtime's proxyOperation): `this` the
// proxy, then the operation's number, the key as the runtime's atom, a
// value and a receiver for those that take them. Booleans come back as
// values; a throw is left pending.
function proxyOperate(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const proxy = asCell(thisValue);
  const operation = asInt32(runtime.argument(argsBase, argc, 0));
  const atom = asCell(runtime.argument(argsBase, argc, 1));
  const handler = runtime.heap.proxyHandler(proxy);
  if (isNull(handler)) {
    const message: String = "Cannot perform an operation on a revoked proxy";
    return throwTypeError(inout runtime, in message);
  }
  const target = runtime.heap.proxyTarget(proxy);
  // A class's private name is no property: a proxy has none, and no trap
  // or target is asked.
  if (runtime.isPrivateKeyAtom(atom)) {
    if (operation == PROXY_GET) return undefinedValue();
    return booleanValue(operation == PROXY_DELETE);
  }
  // A trap may revoke the proxy: its target and handler are used after.
  runtime.pushTempRoot(handler);
  runtime.pushTempRoot(target);
  // The key as a program sees it: the symbol, for a symbol's atom.
  const key = runtime.isSymbolKeyAtom(atom) ? runtime.symbolOfKeyAtom(atom) : cellValue(atom);
  if (operation == PROXY_GET) return proxyGet(inout runtime, target, handler, key, runtime.argument(argsBase, argc, 3));
  if (operation == PROXY_SET) return proxySet(inout runtime, target, handler, key, runtime.argument(argsBase, argc, 2), runtime.argument(argsBase, argc, 3));
  if (operation == PROXY_HAS) return proxyHas(inout runtime, target, handler, key);
  return proxyDelete(inout runtime, target, handler, key);
}

// Whether `handler` has the trap `name`, one of those not written yet:
// a TypeError naming it is then pending (as is whatever reading it threw).
function unsupportedTrap(inout runtime: Runtime, handler: Value, in name: String): boolean {
  const atom = runtime.atomOf(in name);
  const trap = runtime.getProperty(handler, cellValue(atom));
  if (runtime.pendingThrow) return true;
  if (isUndefined(trap) || isNull(trap)) return false;
  const message: String = `The Proxy handler's ${name} trap is not supported yet`;
  const error = runtime.typeError(in message);
  runtime.raise(error);
  return true;
}

// ProxyCreate.
function proxyCreate(inout runtime: Runtime, target: Value, handler: Value): Value {
  if (!runtime.isObjectLike(target) || !runtime.isObjectLike(handler)) {
    const message: String = "Cannot create proxy with a non-object as target or handler";
    return throwTypeError(inout runtime, in message);
  }
  // shortcut: a function as the target (apply and construct), and the
  // seven traps below, are refused here until their internal methods are
  // written. Each check goes when its trap lands.
  if (runtime.isCallable(target)) {
    const message: String = "A Proxy for a function is not supported yet";
    return throwTypeError(inout runtime, in message);
  }
  const t1: String = "getOwnPropertyDescriptor";
  if (unsupportedTrap(inout runtime, handler, in t1)) return undefinedValue();
  const t2: String = "defineProperty";
  if (unsupportedTrap(inout runtime, handler, in t2)) return undefinedValue();
  const t3: String = "ownKeys";
  if (unsupportedTrap(inout runtime, handler, in t3)) return undefinedValue();
  const t4: String = "getPrototypeOf";
  if (unsupportedTrap(inout runtime, handler, in t4)) return undefinedValue();
  const t5: String = "setPrototypeOf";
  if (unsupportedTrap(inout runtime, handler, in t5)) return undefinedValue();
  const t6: String = "isExtensible";
  if (unsupportedTrap(inout runtime, handler, in t6)) return undefinedValue();
  const t7: String = "preventExtensions";
  if (unsupportedTrap(inout runtime, handler, in t7)) return undefinedValue();
  return cellValue(runtime.heap.allocateProxy(target, handler));
}

// new Proxy(target, handler)
function constructProxy(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const newTarget = runtime.takeHostNewTarget();
  if (isUndefined(newTarget)) {
    const message: String = "Constructor Proxy requires 'new'";
    return throwTypeError(inout runtime, in message);
  }
  return proxyCreate(inout runtime, runtime.argument(argsBase, argc, 0), runtime.argument(argsBase, argc, 1));
}

// The function Proxy.revocable hands out: slot 0 holds its proxy, null
// once it has run.
function proxyRevoke(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const held = runtime.heap.slot(callee, 0);
  if (!isCell(held) || asCell(held) == 0) return undefinedValue();
  runtime.heap.setSlot(callee, 0, nullValue());
  runtime.heap.setSlot(asCell(held), 1, nullValue());
  runtime.heap.setSlot(asCell(held), 2, nullValue());
  return undefinedValue();
}

// Proxy.revocable(target, handler): { proxy, revoke }
function proxyRevocable(inout runtime: Runtime, thisValue: Value, argsBase: u32, argc: u32, callee: u32): Value on thread.any {
  const proxy = proxyCreate(inout runtime, runtime.argument(argsBase, argc, 0), runtime.argument(argsBase, argc, 1));
  if (runtime.pendingThrow) return undefinedValue();
  runtime.pushTempRoot(proxy);
  const revoke = runtime.newSharedHost(HOST_PROXY_REVOKE, proxy, 0);
  runtime.pushTempRoot(cellValue(revoke));
  const objectProto = runtime.objectProto;
  const result = runtime.heap.allocateObject(objectProto);
  runtime.pushTempRoot(cellValue(result));
  const proxyText: String = "proxy";
  const proxyAtom = runtime.atomOf(in proxyText);
  runtime.defineOwn(result, proxyAtom, proxy);
  const revokeText: String = "revoke";
  const revokeAtom = runtime.atomOf(in revokeText);
  runtime.defineOwn(result, revokeAtom, cellValue(revoke));
  return cellValue(result);
}

export function installProxy(inout runtime: Runtime): void {
  if ((runtime.features & FEATURE_PROXY) != 0) return;
  runtime.features = runtime.features | FEATURE_PROXY;
  runtime.registerSharedHost(HOST_PROXY, proxyOperate);
  runtime.registerSharedHost(HOST_PROXY_REVOKE, proxyRevoke);
  const proxyText: String = "Proxy";
  const proxyCtor = runtime.defineAllocatingConstructor(constructProxy, undefinedValue(), 2, in proxyText);
  runtime.setGlobal("Proxy", cellValue(proxyCtor));
  const revocableText: String = "revocable";
  runtime.defineMethod(proxyCtor, in revocableText, proxyRevocable, 2);
}
