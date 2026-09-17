// Handle-based cell heap.
//
// The Phase 0 spike measured this against a malloc/raw-pointer heap: it costs
// roughly 5% on a dispatch-heavy microbenchmark, and buys a great deal. No raw
// pointer touches the object graph, so the GC will operate over Z-owned values
// with ownership intact; handles are position-independent, which makes the
// mmap-ready zero-copy AOT bundle nearly free; and it is trivially
// cross-platform. See z/spike/RESULTS.md.
//
// Layout is two parallel arrays rather than one packed slab:
//
//   headers[handle]  -> tag, mark bit, and the cell's slot range
//   slots[start..]   -> the cell's payload words, contiguous
//
// A handle indexes `headers`. Handle 0 is reserved and never allocated, so a
// live cell handle is always >= 1 and `cellValue(0)` can mean "no cell".
//
// Collection is mark-sweep with stable handles. Marking walks from the
// roots the runtime supplies; sweeping frees dead headers onto a free list
// for reuse and compacts every live cell's slots into a fresh arena, so an
// object that outgrew its range leaves no permanent hole. Nothing outside
// the heap has to be updated: a handle never changes, only the slot range
// behind it.

import { utf8ToUnits, unitsToUtf8, unitsToWtf8, isAsciiBytes, isNarrowUnits, unitsToLatin1 } from "./text.zs";
import { expect } from "std/test";
import { replace } from "std/memory";
import { Value, undefinedValue, deletedValue, isDeleted, cellValue, asCell, isCell, int32Value, asInt32 } from "./value.zs";

// Tags mirror the reference engine (src/value.zc) so the two implementations
// stay legible against each other during the migration.
export const TAG_FUNCTION: u8 = 0;
export const TAG_STRING: u8 = 1;
export const TAG_OBJECT: u8 = 2;
export const TAG_ARRAY: u8 = 3;
export const TAG_HOST_FUNCTION: u8 = 4;
export const TAG_HIDDEN_CLASS: u8 = 5;
export const TAG_CLOSURE: u8 = 6;
export const TAG_ACCESSOR: u8 = 7;
export const TAG_PROMISE: u8 = 8;
export const TAG_REGEXP: u8 = 9;
export const TAG_SYMBOL: u8 = 15;
// A weak collection's record, and the two arrays behind it (keys and
// values), which the collector never traces through: see Weak records.
export const TAG_WEAK_RECORD: u8 = 16;
export const TAG_WEAK_ARRAY: u8 = 17;

// Beyond the reference's tags: an environment is its own cell here, where
// the reference keeps captured bindings in a property bag.
export const TAG_ENV: u8 = 200;
// A swept cell whose handle is on the free list.
export const TAG_FREE: u8 = 201;
// Reserved for the unallocatable handle 0.
export const TAG_RESERVED: u8 = 255;

// Property attributes, one byte per slot beside the value. A slot with
// PROP_ACCESSOR holds an accessor cell rather than a value.
export const PROP_WRITABLE: u8 = 1;
export const PROP_ENUMERABLE: u8 = 2;
export const PROP_CONFIGURABLE: u8 = 4;
export const PROP_ACCESSOR: u8 = 8;
export const PROP_DEFAULT: u8 = 7;
// A builtin method: writable and configurable, not enumerable.
export const PROP_METHOD: u8 = 5;
export const PROP_NONE: u8 = 0;

// Per-cell flags.
export const FLAG_NON_EXTENSIBLE: u8 = 1;
export const FLAG_LENGTH_READONLY: u8 = 2;
// A symbol cell minted as a class private name: never an own key.
export const FLAG_PRIVATE_NAME: u8 = 4;
// A string cell that is the runtime's atom for its bytes.
export const FLAG_INTERNED: u8 = 8;
// A string cell whose units are stored two bytes each (some unit is above
// 0xFF); otherwise one byte per unit.
export const FLAG_WIDE: u8 = 16;
// A string cell used as an engine-internal key: never interned by
// content, so no program string can name it.
export const FLAG_HIDDEN: u8 = 32;
// A symbol from the global registry (Symbol.for): not weakly holdable.
export const FLAG_REGISTERED_SYMBOL: u8 = 64;

struct CellHeader {
  tag: u8;
  marked: boolean;
  // FLAG_* bits: extensibility, an array's read-only length.
  flags: u8;
  slotStart: u32;
  slotCount: u32;
  // Tag-specific words. `payload`: a string's index into `strings`, a
  // function's index into the runtime's function table, an object's hidden
  // class, an array's length, a host function's builtin id. `link`: a
  // second cell handle -- an object's prototype, a function's `prototype`
  // object, an array's bag of named properties; 0 for none.
  payload: u32;
  link: u32;
}

// A hidden class describes the property layout shared by every object that
// acquired the same names in the same order: `parent` plus one added name
// at slot `transitionSlot`. Lookup walks the parent chain comparing atom
// handles; interned names make that a pointer comparison. Class 0 is the
// empty root.
//
// An object that grows past `dictThreshold` properties, or loses one that
// is not its newest, leaves the class tree for dictionary mode: its
// header's payload carries DICT_BIT and a dictionary index, its slots
// hold (key, value) pairs in insertion order (the key as the atom's cell
// value, so the collector traces it; a removed pair's key is the deleted
// marker), and a side hash index maps atoms to pairs. No cached class ever
// equals such a payload, so inline caches miss on it; the runtime never
// records one either. Lookup, insertion, and deletion are constant time;
// enumeration walks the pairs.
struct HiddenClass {
  parent: u32;
  transitionName: u32;
  transitionSlot: u32;
  propCount: u32;
  transitionNames: Array<u32>;
  transitionChildren: Array<u32>;
}

export const DICT_BIT: u32 = 2147483648;

// The most pending-ephemeron scratch kept between collections.
const PENDING_RETAIN_BYTES: usize = 262144;

// A weak record's slots and index markers (see Weak records).
const WEAK_KEYS: u32 = 0;
const WEAK_VALUES: u32 = 1;
const WEAK_INDEX: u32 = 2;
const WEAK_SIZE: u32 = 3;
const WEAK_KIND: u32 = 4;
const WEAK_EMPTY: i32 = -1;
const WEAK_TOMBSTONE: i32 = -2;

// The side index of a dictionary-mode object: open addressing over pair
// numbers plus one (0 is empty), sized to at least twice the pair
// capacity. A removed pair stays in the index as a tombstone until the
// next rehash; `used` counts pairs taken, removed ones included, `live`
// the ones present.
struct Dictionary {
  index: Array<u32>;
  mask: u32;
  used: u32;
  live: u32;
}

// String cells keep their bytes in a Z-owned Array<u8>, held in a side
// table indexed through the cell header's payload. The reference stores
// plain bytes with a byte length and byte-indexed access -- including
// embedded NULs, which is why the storage is bytes rather than a Z String.
export struct Heap {
  headers: Array<CellHeader>;
  slots: Array<Value>;
  // One attribute byte per slot, in step with `slots`.
  attrs: Array<u8>;
  // The arena a sweep compacts into. While the heap is small the two
  // arenas change places at every collection, so neither is allocated
  // or grown again; a large heap sizes a fresh one exactly and frees
  // the old, keeping nothing spare. Never holds a live cell's slots
  // between collections.
  spareSlots: Array<Value>;
  spareAttrs: Array<u8>;
  // Slots in use right after the last sweep, to tell how many the cycle
  // since has allocated.
  slotsAfterSweep: usize;
  // The table's extent: one past the highest handle in use or on the
  // free list. The array behind it may be longer -- a sweep cuts the
  // extent back without touching the entries above it, which the next
  // allocations overwrite.
  headerCount: usize;
  // Cells and slots allocated in completed cycles, for reports; the
  // current cycle's are added when asked.
  cellsBeforeCycle: f64;
  slotsBeforeCycle: f64;
  strings: Array<Array<u8>>;
  classes: Array<HiddenClass>;
  // Weak records reached during the current collection (see Weak
  // records); emptied when the collection ends, never a root.
  weakRecords: Array<u32>;
  // Pending ephemeron work, indexed by key: an entry whose key was not
  // yet marked when its record was reached waits here (a chained hash
  // table over the key's handle) and is activated when the key is
  // popped from the mark stack. Collection-local scratch; no cell is
  // reachable through it. A consumed entry has key 0.
  pendingKeys: Array<u32>;
  pendingValues: Array<Value>;
  pendingNext: Array<u32>;
  pendingBuckets: Array<u32>;
  pendingMask: u32;
  pendingCount: u32;
  // Entries dropped for dead keys, cumulative; passes the verification
  // scan took after the last collection (1 when the pending index left
  // nothing to find); weak entries examined and cells traced in the
  // last collection. For the harness.
  weakCleared: u32;
  ephemeronPasses: u32;
  weakVisits: u32;
  markedCells: u32;
  // Slots of the cells traced in this collection: what the sweep will
  // keep, known before it copies anything.
  markedSlots: usize;
  // Dictionary-mode indexes, one per such object, reused after a sweep.
  dictionaries: Array<Dictionary>;
  freeDictionaries: Array<u32>;
  freeDictionaryCount: usize;
  // The property count past which an object leaves the class tree.
  dictThreshold: u32;
  // Handles and string-table indices released by a sweep, reused before
  // the arrays grow. `freeHandleCount` / `freeStringCount` mark the live
  // extent, since Z's Array cannot pop.
  freeHandles: Array<u32>;
  freeHandleCount: usize;
  freeStrings: Array<u32>;
  freeStringCount: usize;
  // Marking worklist, reused across collections.
  markStack: Array<u32>;
  markCount: usize;
  // Cells allocated since the last collection, and how many trigger the
  // next one: at least a floor, otherwise proportional to what survived.
  allocatedSinceCollect: u32;
  collectThreshold: u32;
  collections: u32;
  // The policy's two numbers, settable by the host for measurement: the
  // least allocation between collections, and the survivors' multiple
  // (in percent) that replaces it once that is larger.
  collectFloor: u32;
  collectGrowthPercent: u32;

  // These are methods rather than free functions for a concrete reason.
  // Z rejects `inout` on a place expression -- `allocate(inout
  // registry.slots[i].heap, ...)` is an error, because an `inout` argument
  // must be a plain mutable binding. A method call on the same projection is
  // accepted, so the heap API has to be methods for the engine to reach a
  // per-context heap at all.
  function allocate(inout this, tag: u8, slotCount: u32): u32 {
    const start = u32(this.slots.length);
    let index: u32 = 0;
    while (index < slotCount) {
      this.slots.push(undefinedValue());
      this.attrs.push(PROP_DEFAULT);
      index = index + 1;
    }
    this.allocatedSinceCollect = this.allocatedSinceCollect + 1;
    const header = CellHeader({
      tag: tag,
      marked: false,
      flags: 0,
      slotStart: start,
      slotCount: slotCount,
      payload: 0,
      link: 0,
    });
    if (this.freeHandleCount > 0) {
      this.freeHandleCount = this.freeHandleCount - 1;
      const handle = this.freeHandles[this.freeHandleCount];
      this.headers[usize(handle)] = header;
      return handle;
    }
    // Past the free list, the table's next entry: one a sweep cut off
    // and left in place, or a new one.
    const next = this.headerCount;
    if (next < this.headers.length) {
      this.headers[next] = header;
    } else {
      this.headers.push(header);
    }
    this.headerCount = next + 1;
    return u32(next);
  }

  // Whether enough has been allocated since the last collection for the
  // runtime to collect at its next safe point.
  function shouldCollect(): boolean {
    return this.allocatedSinceCollect >= this.collectThreshold;
  }

  // --- Collection ---
  //
  // The runtime marks its roots with `markValue`, then calls `sweep`.

  function markValue(inout this, value: Value): void {
    if (!isCell(value)) return;
    this.markHandle(asCell(value));
  }

  function markHandle(inout this, handle: u32): void {
    if (handle == 0) return;
    if (this.headers[usize(handle)].marked) return;
    this.headers[usize(handle)].marked = true;
    if (this.markCount < this.markStack.length) {
      this.markStack[this.markCount] = handle;
    } else {
      this.markStack.push(handle);
    }
    this.markCount = this.markCount + 1;
    this.drainMarks();
  }

  // Trace every marked cell's references until the worklist is empty.
  function drainMarks(inout this): void {
    while (this.markCount > 0) {
      this.markCount = this.markCount - 1;
      const handle = this.markStack[this.markCount];
      this.markedCells = this.markedCells + 1;
      this.markedSlots = this.markedSlots + usize(this.headers[usize(handle)].slotCount);
      // A key some weak record was waiting on: its values go live now.
      if (this.pendingCount > 0) this.activatePending(handle);
      const tag = this.headers[usize(handle)].tag;
      const link = this.headers[usize(handle)].link;
      if (link != 0 && !this.headers[usize(link)].marked) {
        this.headers[usize(link)].marked = true;
        this.pushMark(link);
      }
      // A weak record is traced like any cell (its index and counts, and
      // the two weak arrays as cells), queued for the clearing pass, and
      // its entries registered: a marked key's value is marked now, the
      // rest wait on their keys. A weak array's elements are never traced
      // from here.
      if (tag == TAG_WEAK_RECORD) {
        this.weakRecords.push(handle);
        this.registerWeakRecord(handle);
      }
      // Slots hold values for every tag but strings and weak arrays.
      if (tag != TAG_STRING && tag != TAG_WEAK_ARRAY) {
        const start = this.headers[usize(handle)].slotStart;
        const count = this.headers[usize(handle)].slotCount;
        let index: u32 = 0;
        while (index < count) {
          const value = this.slots[usize(start + index)];
          if (isCell(value) && asCell(value) != 0 && !this.headers[usize(asCell(value))].marked) {
            this.headers[usize(asCell(value))].marked = true;
            this.pushMark(asCell(value));
          }
          index = index + 1;
        }
      }
    }
  }

  function pushMark(inout this, handle: u32): void {
    if (this.markCount < this.markStack.length) {
      this.markStack[this.markCount] = handle;
    } else {
      this.markStack.push(handle);
    }
    this.markCount = this.markCount + 1;
  }

  // Free every unmarked cell, compact the live slots into the other
  // arena, and clear the marks. When a large table's survivors all sit in
  // its lowest quarter, the dead cells above the highest of them are not
  // listed for reuse: the table's extent is cut back to that survivor, so
  // a collection after a spike costs what is alive and not what once
  // was, and a table left far larger than it needs gives its storage
  // back. The arena is sized before the copy: the
  // survivors' slots plus what the next cycle is expected to allocate
  // (its threshold in cells times the slots a cell has been taking), so
  // neither the copy nor the allocation that follows grows it.
  function sweep(inout this): void {
    const count = u32(this.headerCount);
    const liveSlots = this.markedSlots;
    const survivors = this.markedCells;
    const proportional = u32(u64(survivors) * u64(this.collectGrowthPercent) / 100);
    const nextThreshold = proportional > this.collectFloor ? proportional : this.collectFloor;
    let cycleSlots: usize = 0;
    if (this.slots.length > this.slotsAfterSweep) cycleSlots = this.slots.length - this.slotsAfterSweep;
    let cycleCells: usize = 1;
    if (this.allocatedSinceCollect > 0) cycleCells = usize(this.allocatedSinceCollect);
    let perCell = cycleSlots / cycleCells + 1;
    if (survivors > 0 && liveSlots / usize(survivors) + 1 > perCell) perCell = liveSlots / usize(survivors) + 1;
    const headroom = usize(nextThreshold) * perCell;
    const needed = liveSlots + headroom + headroom / 8 + 64;
    const retain = needed <= SPARE_RETAIN_SLOTS;
    // The arena being filled is a local while it is filled.
    let compacted = replace(inout this.spareSlots, Array<Value>());
    let compactedAttrs = replace(inout this.spareAttrs, Array<u8>());
    if (retain) {
      compacted.clear();
      compactedAttrs.clear();
      compacted.reserveCapacity(needed);
      compactedAttrs.reserveCapacity(needed);
    } else {
      compacted = Array<Value>.withCapacity(needed);
      compactedAttrs = Array<u8>.withCapacity(needed);
    }
    // The highest survivor, found by looking down from the top -- but
    // the table is cut back to it only when that is worth a pass over
    // the free list: a large table that would shrink at least fourfold.
    // A small heap's top survivor moves at every collection, and its
    // table is cheap to walk whole.
    let top: u32 = count - 1;
    if (usize(count) >= HANDLE_TABLE_CUT_AT) {
      while (top >= 1 && !this.headers[usize(top)].marked) { top = top - 1; }
      if ((usize(top) + 1) * 4 >= usize(count)) top = count - 1;
    }
    const cutting = top != count - 1;
    // Handles are visited from the top down, so the cells this sweep
    // frees are listed highest first and the next allocations take the
    // lowest of them: survivors gather low in the table, which is what
    // lets a later sweep cut it back.
    const listBelow: u32 = cutting ? top : count;
    let handle: u32 = count - 1;
    while (handle >= 1) {
      const tag = this.headers[usize(handle)].tag;
      if (tag == TAG_FREE) {
        handle = handle - 1;
        continue;
      }
      if (!this.headers[usize(handle)].marked) {
        if (tag == TAG_OBJECT && (this.headers[usize(handle)].payload & DICT_BIT) != 0) {
          this.releaseDictionary(this.headers[usize(handle)].payload & (DICT_BIT - 1));
        }
        if (tag == TAG_STRING) {
          const stringIndex = this.headers[usize(handle)].payload;
          this.strings[usize(stringIndex)] = Array<u8>();
          if (this.freeStringCount < this.freeStrings.length) {
            this.freeStrings[this.freeStringCount] = stringIndex;
          } else {
            this.freeStrings.push(stringIndex);
          }
          this.freeStringCount = this.freeStringCount + 1;
        }
        this.headers[usize(handle)] = CellHeader({ tag: TAG_FREE, marked: false, flags: 0, slotStart: 0, slotCount: 0, payload: 0, link: 0 });
        // A cell above the highest survivor is cut off with the table,
        // not listed.
        if (handle < listBelow) {
          if (this.freeHandleCount < this.freeHandles.length) {
            this.freeHandles[this.freeHandleCount] = handle;
          } else {
            this.freeHandles.push(handle);
          }
          this.freeHandleCount = this.freeHandleCount + 1;
        }
        handle = handle - 1;
        continue;
      }
      this.headers[usize(handle)].marked = false;
      const start = this.headers[usize(handle)].slotStart;
      const slotCount = this.headers[usize(handle)].slotCount;
      this.headers[usize(handle)].slotStart = u32(compacted.length);
      let index: u32 = 0;
      while (index < slotCount) {
        const kept = this.slots[usize(start + index)];
        const keptAttr = this.attrs[usize(start + index)];
        compacted.push(kept);
        compactedAttrs.push(keptAttr);
        index = index + 1;
      }
      handle = handle - 1;
    }
    if (cutting) this.trimHandleTable(top);
    // The arenas change places. A large heap lets the old one go.
    // An arena far larger than the heap now needs is let go rather than
    // kept as the spare, so what a burst took goes back once it has passed.
    const oldCapacity = this.slots.capacity;
    const oldSlots = replace(inout this.slots, move compacted);
    const oldAttrs = replace(inout this.attrs, move compactedAttrs);
    if (retain && oldCapacity <= needed * 4 + 65536) {
      const emptySlots = replace(inout this.spareSlots, move oldSlots);
      const emptyAttrs = replace(inout this.spareAttrs, move oldAttrs);
    }
    this.cellsBeforeCycle = this.cellsBeforeCycle + f64(this.allocatedSinceCollect);
    this.slotsBeforeCycle = this.slotsBeforeCycle + f64(cycleSlots);
    this.slotsAfterSweep = this.slots.length;
    this.allocatedSinceCollect = 0;
    this.collectThreshold = nextThreshold;
    this.collections = this.collections + 1;
  }

  // Cut the table back to its highest live handle. When that leaves it
  // under a quarter of the capacity its storage holds, the table, the
  // free list, and the mark stack are rebuilt small and the old storage
  // is freed.
  function trimHandleTable(inout this, top: u32): void {
    this.headerCount = usize(top) + 1;
    // Handles listed by earlier sweeps that the table no longer holds
    // leave the list.
    let kept: usize = 0;
    let at: usize = 0;
    while (at < this.freeHandleCount) {
      const listed = this.freeHandles[at];
      if (listed <= top) {
        this.freeHandles[kept] = listed;
        kept = kept + 1;
      }
      at = at + 1;
    }
    this.freeHandleCount = kept;
    if (this.headers.capacity < HANDLE_TABLE_SHRINK_AT || this.headerCount * 4 >= this.headers.capacity) return;
    let smaller = Array<CellHeader>.withCapacity(this.headerCount * 2);
    let index: usize = 0;
    while (index < this.headerCount) {
      smaller.push(this.headers[index]);
      index = index + 1;
    }
    const oldHeaders = replace(inout this.headers, move smaller);
    let list = Array<u32>.withCapacity(this.freeHandleCount);
    index = 0;
    while (index < this.freeHandleCount) {
      list.push(this.freeHandles[index]);
      index = index + 1;
    }
    const oldList = replace(inout this.freeHandles, move list);
    const oldStack = replace(inout this.markStack, Array<u32>());
  }

  // Move a cell's slots to a fresh, larger range. The old range is
  // abandoned until the collector compacts.
  function growSlots(inout this, handle: u32, newCount: u32): void {
    const oldStart = this.headers[usize(handle)].slotStart;
    const oldCount = this.headers[usize(handle)].slotCount;
    const start = u32(this.slots.length);
    let index: u32 = 0;
    while (index < oldCount) {
      const kept = this.slots[usize(oldStart + index)];
      const keptAttr = this.attrs[usize(oldStart + index)];
      this.slots.push(kept);
      this.attrs.push(keptAttr);
      index = index + 1;
    }
    while (index < newCount) {
      this.slots.push(undefinedValue());
      this.attrs.push(PROP_DEFAULT);
      index = index + 1;
    }
    this.headers[usize(handle)].slotStart = start;
    this.headers[usize(handle)].slotCount = newCount;
  }

  function linkOf(handle: u32): u32 {
    return this.headers[usize(handle)].link;
  }

  function setLink(inout this, handle: u32, link: u32): void {
    this.headers[usize(handle)].link = link;
  }

  // --- Hidden classes ---

  function classPropCount(classId: u32): u32 {
    return this.classes[usize(classId)].propCount;
  }

  // The slot holding `atom` under `classId`, or -1.
  function classFindSlot(classId: u32, atom: u32): i32 {
    let current = classId;
    while (current != 0) {
      if (this.classes[usize(current)].transitionName == atom) return i32(this.classes[usize(current)].transitionSlot);
      current = this.classes[usize(current)].parent;
    }
    return -1;
  }

  // The class reached by adding `atom` to `classId`, created on first use.
  function classTransition(inout this, classId: u32, atom: u32): u32 {
    const count = this.classes[usize(classId)].transitionNames.length;
    let index: usize = 0;
    while (index < count) {
      if (this.classes[usize(classId)].transitionNames[index] == atom) return this.classes[usize(classId)].transitionChildren[index];
      index = index + 1;
    }
    const propCount = this.classes[usize(classId)].propCount;
    this.classes.push(HiddenClass({
      parent: classId, transitionName: atom, transitionSlot: propCount, propCount: propCount + 1,
      transitionNames: Array<u32>(), transitionChildren: Array<u32>(),
    }));
    const child = u32(this.classes.length - 1);
    this.classes[usize(classId)].transitionNames.push(atom);
    this.classes[usize(classId)].transitionChildren.push(child);
    return child;
  }

  // Whether `child` is the class `parent` reaches by adding `atom`.
  function isTransitionOf(child: u32, parent: u32, atom: u32): boolean {
    return this.classes[usize(child)].parent == parent && this.classes[usize(child)].transitionName == atom;
  }

  // Move an object to `classId` by writing its new property, the slot
  // and class known from a previous transition.
  function transitionTo(inout this, handle: u32, classId: u32, slotIndex: u32, value: Value): void {
    if (slotIndex >= this.headers[usize(handle)].slotCount) {
      const grown: u32 = this.headers[usize(handle)].slotCount * 2;
      const needed: u32 = slotIndex + 1;
      this.growSlots(handle, grown > needed ? grown : needed);
    }
    this.headers[usize(handle)].payload = classId;
    this.setSlot(handle, slotIndex, value);
    this.setAttr(handle, slotIndex, PROP_DEFAULT);
  }

  // --- Objects ---

  // An empty object whose prototype is `proto` (0 for none), with room
  // for a few properties before its slots move.
  function allocateObject(inout this, proto: u32): u32 {
    const handle = this.allocate(TAG_OBJECT, 4);
    this.headers[usize(handle)].link = proto;
    return handle;
  }

  function isObject(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_OBJECT;
  }

  function objectClass(handle: u32): u32 {
    return this.headers[usize(handle)].payload;
  }

  function objectProto(handle: u32): u32 {
    return this.headers[usize(handle)].link;
  }

  function setObjectProto(inout this, handle: u32, proto: u32): void {
    this.headers[usize(handle)].link = proto;
  }

  // The object's own slot for `atom`, or -1: the value slot, in either
  // representation.
  function objectFindSlot(handle: u32, atom: u32): i32 {
    const payload = this.headers[usize(handle)].payload;
    if ((payload & DICT_BIT) != 0) return this.dictionaryFind(handle, payload & (DICT_BIT - 1), atom);
    return this.classFindSlot(payload, atom);
  }

  function isDictionary(handle: u32): boolean {
    return (this.headers[usize(handle)].payload & DICT_BIT) != 0;
  }

  // Write an own property, adding it (and transitioning the class) when
  // the object does not have it yet.
  function objectSet(inout this, handle: u32, atom: u32, value: Value): void {
    const existing = this.objectFindSlot(handle, atom);
    if (existing >= 0) {
      this.setSlot(handle, u32(existing), value);
      return;
    }
    const parentClass = this.headers[usize(handle)].payload;
    if ((parentClass & DICT_BIT) != 0) {
      this.dictionaryInsert(handle, parentClass & (DICT_BIT - 1), atom, value);
      return;
    }
    if (this.classes[usize(parentClass)].propCount >= this.dictThreshold) {
      const dictionary = this.toDictionary(handle);
      this.dictionaryInsert(handle, dictionary, atom, value);
      return;
    }
    const child = this.classTransition(parentClass, atom);
    const slotIndex = this.classes[usize(child)].transitionSlot;
    if (slotIndex >= this.headers[usize(handle)].slotCount) {
      const grown: u32 = this.headers[usize(handle)].slotCount * 2;
      const needed: u32 = slotIndex + 1;
      this.growSlots(handle, grown > needed ? grown : needed);
    }
    this.headers[usize(handle)].payload = child;
    this.setSlot(handle, slotIndex, value);
  }

  // Remove an own property, given its value slot. In class mode the
  // newest property is dropped by stepping back to the parent class; any
  // other removal moves the object to dictionary mode, where a pair is
  // simply retired. Either way the name is gone from lookup and a later
  // addition takes the last place in enumeration order.
  function objectDelete(inout this, handle: u32, atom: u32, slot: u32): void {
    const payload = this.headers[usize(handle)].payload;
    if ((payload & DICT_BIT) != 0) {
      this.dictionaryRemove(payload & (DICT_BIT - 1), handle, slot);
      return;
    }
    if (this.classes[usize(payload)].transitionName == atom && this.classes[usize(payload)].transitionSlot == slot) {
      this.headers[usize(handle)].payload = this.classes[usize(payload)].parent;
      this.setSlot(handle, slot, undefinedValue());
      this.setAttr(handle, slot, PROP_DEFAULT);
      return;
    }
    const dictionary = this.toDictionary(handle);
    const pairSlot = this.dictionaryFind(handle, dictionary, atom);
    if (pairSlot >= 0) this.dictionaryRemove(dictionary, handle, u32(pairSlot));
  }

  // The object's own names in insertion order, whatever its
  // representation; a class-mode slot that holds nothing yet is skipped.
  function objectNames(handle: u32): Array<u32> {
    let names = Array<u32>();
    const payload = this.headers[usize(handle)].payload;
    if ((payload & DICT_BIT) != 0) {
      const used = this.dictionaries[usize(payload & (DICT_BIT - 1))].used;
      let pair: u32 = 0;
      while (pair < used) {
        const key = this.slot(handle, pair * 2);
        if (!isDeleted(key)) names.push(asCell(key));
        pair = pair + 1;
      }
      return names;
    }
    const propCount = this.classes[usize(payload)].propCount;
    let fill: u32 = 0;
    while (fill < propCount) {
      names.push(0);
      fill = fill + 1;
    }
    let classId = payload;
    while (classId != 0) {
      names[usize(this.classes[usize(classId)].transitionSlot)] = this.classes[usize(classId)].transitionName;
      classId = this.classes[usize(classId)].parent;
    }
    return names;
  }

  // --- Dictionary mode ---

  function dictionaryHash(atom: u32, mask: u32): u32 {
    let hash = atom.wrappingMultiply(2654435761);
    hash = hash ^ (hash >> 15);
    return hash & mask;
  }

  // The value slot of `atom` in a dictionary object, or -1.
  function dictionaryFind(handle: u32, dictionary: u32, atom: u32): i32 {
    const mask = this.dictionaries[usize(dictionary)].mask;
    let probe = this.dictionaryHash(atom, mask);
    const start = this.headers[usize(handle)].slotStart;
    while (true) {
      const entry = this.dictionaries[usize(dictionary)].index[usize(probe)];
      if (entry == 0) return -1;
      const key = this.slots[usize(start + (entry - 1) * 2)];
      if (!isDeleted(key) && asCell(key) == atom) return i32((entry - 1) * 2 + 1);
      probe = (probe + 1) & mask;
    }
    return -1;
  }

  // Add a pair for a name the object does not have.
  function dictionaryInsert(inout this, handle: u32, dictionary: u32, atom: u32, value: Value): void {
    const capacity = this.headers[usize(handle)].slotCount / 2;
    if (this.dictionaries[usize(dictionary)].used >= capacity) {
      // Full: drop the retired pairs when they are the larger part,
      // otherwise double the pairs; either way rebuild the index.
      if (this.dictionaries[usize(dictionary)].live * 2 < this.dictionaries[usize(dictionary)].used) {
        this.dictionaryCompact(handle, dictionary);
      } else {
        this.growSlots(handle, capacity * 4);
      }
      this.dictionaryRehash(handle, dictionary);
    }
    const pair = this.dictionaries[usize(dictionary)].used;
    this.dictionaries[usize(dictionary)].used = pair + 1;
    this.dictionaries[usize(dictionary)].live = this.dictionaries[usize(dictionary)].live + 1;
    this.setSlot(handle, pair * 2, cellValue(atom));
    this.setSlot(handle, pair * 2 + 1, value);
    this.setAttr(handle, pair * 2 + 1, PROP_DEFAULT);
    this.dictionaryIndexPair(dictionary, atom, pair);
  }

  function dictionaryIndexPair(inout this, dictionary: u32, atom: u32, pair: u32): void {
    const mask = this.dictionaries[usize(dictionary)].mask;
    let probe = this.dictionaryHash(atom, mask);
    while (this.dictionaries[usize(dictionary)].index[usize(probe)] != 0) {
      probe = (probe + 1) & mask;
    }
    this.dictionaries[usize(dictionary)].index[usize(probe)] = pair + 1;
  }

  function dictionaryRemove(inout this, dictionary: u32, handle: u32, slot: u32): void {
    this.setSlot(handle, slot - 1, deletedValue());
    this.setSlot(handle, slot, undefinedValue());
    this.setAttr(handle, slot, PROP_DEFAULT);
    this.dictionaries[usize(dictionary)].live = this.dictionaries[usize(dictionary)].live - 1;
  }

  // Rebuild the index over the pairs in use, at twice the pair capacity.
  function dictionaryRehash(inout this, handle: u32, dictionary: u32): void {
    const capacity = this.headers[usize(handle)].slotCount / 2;
    let size: u32 = 8;
    while (size < capacity * 2) {
      size = size * 2;
    }
    let index = Array<u32>();
    let fill: u32 = 0;
    while (fill < size) {
      index.push(0);
      fill = fill + 1;
    }
    this.dictionaries[usize(dictionary)].index = move index;
    this.dictionaries[usize(dictionary)].mask = size - 1;
    const used = this.dictionaries[usize(dictionary)].used;
    let pair: u32 = 0;
    while (pair < used) {
      const key = this.slot(handle, pair * 2);
      if (!isDeleted(key)) this.dictionaryIndexPair(dictionary, asCell(key), pair);
      pair = pair + 1;
    }
  }

  // Close the gaps left by retired pairs, keeping the order.
  function dictionaryCompact(inout this, handle: u32, dictionary: u32): void {
    const used = this.dictionaries[usize(dictionary)].used;
    let write: u32 = 0;
    let read: u32 = 0;
    while (read < used) {
      const key = this.slot(handle, read * 2);
      if (!isDeleted(key)) {
        if (write != read) {
          const value = this.slot(handle, read * 2 + 1);
          const attr = this.attrOf(handle, read * 2 + 1);
          this.setSlot(handle, write * 2, key);
          this.setSlot(handle, write * 2 + 1, value);
          this.setAttr(handle, write * 2 + 1, attr);
        }
        write = write + 1;
      }
      read = read + 1;
    }
    let clear = write;
    while (clear < used) {
      this.setSlot(handle, clear * 2, undefinedValue());
      this.setSlot(handle, clear * 2 + 1, undefinedValue());
      this.setAttr(handle, clear * 2 + 1, PROP_DEFAULT);
      clear = clear + 1;
    }
    this.dictionaries[usize(dictionary)].used = write;
    this.dictionaries[usize(dictionary)].live = write;
  }

  // Move a class-mode object to dictionary mode, keeping every property,
  // its attributes, and its place in the order. Returns the dictionary.
  function toDictionary(inout this, handle: u32): u32 {
    const names = this.objectNames(handle);
    let values = Array<Value>();
    let attrs = Array<u8>();
    let kept = Array<u32>();
    let i: usize = 0;
    while (i < names.length) {
      const name = names[i];
      if (name != 0) {
        const slot = this.classFindSlot(this.headers[usize(handle)].payload, name);
        values.push(this.slot(handle, u32(slot)));
        attrs.push(this.attrOf(handle, u32(slot)));
        kept.push(name);
      }
      i = i + 1;
    }
    const count = u32(kept.length);
    let capacity: u32 = 8;
    while (capacity < count + count / 2 + 1) {
      capacity = capacity * 2;
    }
    if (this.headers[usize(handle)].slotCount < capacity * 2) this.growSlots(handle, capacity * 2);
    let dictionary: u32 = 0;
    if (this.freeDictionaryCount > 0) {
      this.freeDictionaryCount = this.freeDictionaryCount - 1;
      dictionary = this.freeDictionaries[this.freeDictionaryCount];
      this.dictionaries[usize(dictionary)] = Dictionary({ index: Array<u32>(), mask: 0, used: count, live: count });
    } else {
      this.dictionaries.push(Dictionary({ index: Array<u32>(), mask: 0, used: count, live: count }));
      dictionary = u32(this.dictionaries.length - 1);
    }
    let pair: u32 = 0;
    while (pair < count) {
      const name = kept[usize(pair)];
      const value = values[usize(pair)];
      const attr = attrs[usize(pair)];
      this.setSlot(handle, pair * 2, cellValue(name));
      this.setSlot(handle, pair * 2 + 1, value);
      this.setAttr(handle, pair * 2 + 1, attr);
      pair = pair + 1;
    }
    let clear = count * 2;
    const total = this.headers[usize(handle)].slotCount;
    while (clear < total) {
      this.setSlot(handle, clear, undefinedValue());
      this.setAttr(handle, clear, PROP_DEFAULT);
      clear = clear + 1;
    }
    this.headers[usize(handle)].payload = DICT_BIT | dictionary;
    this.dictionaryRehash(handle, dictionary);
    return dictionary;
  }

  function releaseDictionary(inout this, dictionary: u32): void {
    this.dictionaries[usize(dictionary)] = Dictionary({ index: Array<u32>(), mask: 0, used: 0, live: 0 });
    if (this.freeDictionaryCount < this.freeDictionaries.length) {
      this.freeDictionaries[this.freeDictionaryCount] = dictionary;
    } else {
      this.freeDictionaries.push(dictionary);
    }
    this.freeDictionaryCount = this.freeDictionaryCount + 1;
  }

  // Live dictionary-mode objects, for the harness.
  function dictionaryCount(): u32 {
    return u32(this.dictionaries.length - this.freeDictionaryCount);
  }

  // --- Arrays ---

  // Elements live in the slots; `payload` is the length and the slot count
  // is the capacity. A slot past the length, or holding the deleted
  // marker, is a hole.
  // ArrayCreate: `length` elements, none present. Every slot, within
  // the length and in the spare capacity past it, starts as a hole.
  function allocateArray(inout this, length: u32): u32 {
    const capacity: u32 = length < 4 ? 4 : length;
    const handle = this.allocate(TAG_ARRAY, capacity);
    this.headers[usize(handle)].payload = length;
    let hole: u32 = 0;
    while (hole < capacity) {
      this.setSlot(handle, hole, deletedValue());
      hole = hole + 1;
    }
    return handle;
  }

  function isArray(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_ARRAY;
  }

  function arrayLength(handle: u32): u32 {
    return this.headers[usize(handle)].payload;
  }

  function arrayHasIndex(handle: u32, index: u32): boolean {
    if (index >= this.headers[usize(handle)].payload) return false;
    if (index >= this.headers[usize(handle)].slotCount) return false;
    return !isDeleted(this.slot(handle, index));
  }

  function arrayGet(handle: u32, index: u32): Value {
    if (!this.arrayHasIndex(handle, index)) return undefinedValue();
    return this.slot(handle, index);
  }

  function arraySet(inout this, handle: u32, index: u32, value: Value): void {
    if (index >= this.headers[usize(handle)].slotCount) {
      let capacity = this.headers[usize(handle)].slotCount;
      while (capacity <= index) { capacity = capacity * 2; }
      const oldCount = this.headers[usize(handle)].slotCount;
      this.growSlots(handle, capacity);
      // Fresh capacity is holes, not undefined.
      let hole = oldCount;
      while (hole < capacity) {
        this.setSlot(handle, hole, deletedValue());
        hole = hole + 1;
      }
    }
    this.setSlot(handle, index, value);
    if (index >= this.headers[usize(handle)].payload) this.headers[usize(handle)].payload = index + 1;
  }

  // Shrinking drops elements; growing exposes holes.
  function setArrayLength(inout this, handle: u32, length: u32): void {
    const old = this.headers[usize(handle)].payload;
    let index = length;
    while (index < old && index < this.headers[usize(handle)].slotCount) {
      this.setSlot(handle, index, deletedValue());
      index = index + 1;
    }
    this.headers[usize(handle)].payload = length;
  }

  // --- Weak records ---
  //
  // A WeakMap or WeakSet keeps its entries in a record cell
  // (TAG_WEAK_RECORD) of five slots: the keys and values arrays, an
  // open-addressed index from key hash to entry position, the live
  // count, and the kind. Keys are cells (objects, unregistered symbols).
  //
  // The keys and values arrays have their own tag, TAG_WEAK_ARRAY, and
  // the collector never traces their elements through ordinary marking,
  // whatever reaches them: they are private to the record (nothing else
  // may hold them, and nothing does; `recordOf` hands out the record,
  // not the arrays). A key is marked only by something other than its
  // record; a value only once its key is. When a record is reached, each
  // entry whose key is already marked has its value marked at once, and
  // the rest wait in a key-indexed pending table (collection-local
  // scratch, not a root); when a waiting key is traced, its values are
  // marked in turn. So a chain of records whose keys are reached only
  // through the previous record's value costs one visit per entry
  // whatever order the records are found in. `markEphemerons` then
  // verifies with one scan (and would finish the job to a fixpoint if
  // it ever found anything). Entries whose key is unmarked are dropped
  // (`clearDeadWeakEntries`), before the atom rebuild and the sweep; the
  // value's other references, if any, keep it. Those passes allocate no
  // cells: the arrays compact and the index rebuilds in place, so a
  // long-lived record's storage follows its live count.

  function allocateWeakArray(inout this): u32 {
    const handle = this.allocate(TAG_WEAK_ARRAY, 4);
    this.headers[usize(handle)].payload = 0;
    let hole: u32 = 0;
    while (hole < 4) {
      this.setSlot(handle, hole, deletedValue());
      hole = hole + 1;
    }
    return handle;
  }

  function allocateWeakRecord(inout this, kind: i32): u32 {
    const record = this.allocate(TAG_WEAK_RECORD, 5);
    this.setSlot(record, WEAK_KEYS, cellValue(this.allocateWeakArray()));
    this.setSlot(record, WEAK_VALUES, cellValue(this.allocateWeakArray()));
    const index = this.allocateArray(8);
    let i: u32 = 0;
    while (i < 8) {
      this.setSlot(index, i, int32Value(WEAK_EMPTY));
      i = i + 1;
    }
    this.setSlot(record, WEAK_INDEX, cellValue(index));
    this.setSlot(record, WEAK_SIZE, int32Value(0));
    this.setSlot(record, WEAK_KIND, int32Value(kind));
    return record;
  }

  function isWeakRecord(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_WEAK_RECORD;
  }

  function weakKind(record: u32): i32 {
    return asInt32(this.slot(record, WEAK_KIND));
  }

  function weakSize(record: u32): u32 {
    return u32(asInt32(this.slot(record, WEAK_SIZE)));
  }

  function weakHash(key: u32, mask: u32): u32 {
    let hash = key.wrappingMultiply(2654435761);
    hash = hash ^ (hash >> 15);
    return hash & mask;
  }

  // The entry position holding `key`, or -1.
  function weakFind(record: u32, key: u32): i32 {
    const index = asCell(this.slot(record, WEAK_INDEX));
    const keys = asCell(this.slot(record, WEAK_KEYS));
    const mask = this.arrayLength(index) - 1;
    let probe = this.weakHash(key, mask);
    let probes: u32 = 0;
    while (probes <= mask) {
      const held = asInt32(this.slot(index, probe));
      if (held == WEAK_EMPTY) return -1;
      if (held >= 0) {
        const candidate = this.slot(keys, u32(held));
        if (!isDeleted(candidate) && asCell(candidate) == key) return held;
      }
      probe = (probe + 1) & mask;
      probes = probes + 1;
    }
    return -1;
  }

  function weakGet(record: u32, position: u32): Value {
    return this.slot(asCell(this.slot(record, WEAK_VALUES)), position);
  }

  function weakIndexInsert(inout this, index: u32, key: u32, position: u32): void {
    const mask = this.arrayLength(index) - 1;
    let probe = this.weakHash(key, mask);
    while (asInt32(this.slot(index, probe)) >= 0) {
      probe = (probe + 1) & mask;
    }
    this.setSlot(index, probe, int32Value(i32(position)));
  }

  // Insert or update; the key must be weakly holdable.
  function weakPut(inout this, record: u32, key: u32, value: Value): void {
    const existing = this.weakFind(record, key);
    if (existing >= 0) {
      this.setSlot(asCell(this.slot(record, WEAK_VALUES)), u32(existing), value);
      return;
    }
    const keys = asCell(this.slot(record, WEAK_KEYS));
    const values = asCell(this.slot(record, WEAK_VALUES));
    const live = this.weakSize(record);
    // Room in the index for one more position (three quarters full at
    // most): first reclaim retired entries when they are the larger
    // part, then grow.
    if ((this.arrayLength(keys) + 1) * 4 > this.arrayLength(asCell(this.slot(record, WEAK_INDEX))) * 3) {
      if (live * 2 < this.arrayLength(keys)) {
        this.weakCompact(record);
        this.weakRebuildIndex(record);
      }
      if ((this.arrayLength(keys) + 1) * 4 > this.arrayLength(asCell(this.slot(record, WEAK_INDEX))) * 3) {
        this.weakGrowIndex(record);
      }
    }
    const position = this.arrayLength(keys);
    this.arraySet(keys, position, cellValue(key));
    this.arraySet(values, position, value);
    const index = asCell(this.slot(record, WEAK_INDEX));
    this.weakIndexInsert(index, key, position);
    this.setSlot(record, WEAK_SIZE, int32Value(i32(live + 1)));
  }

  function weakDelete(inout this, record: u32, key: u32): boolean {
    const position = this.weakFind(record, key);
    if (position < 0) return false;
    this.weakRetire(record, u32(position), key);
    return true;
  }

  // Retire one entry: both slots become the deleted marker, its index
  // slot a tombstone, the count one less.
  function weakRetire(inout this, record: u32, position: u32, key: u32): void {
    const keys = asCell(this.slot(record, WEAK_KEYS));
    const values = asCell(this.slot(record, WEAK_VALUES));
    this.setSlot(keys, position, deletedValue());
    this.setSlot(values, position, deletedValue());
    const index = asCell(this.slot(record, WEAK_INDEX));
    const mask = this.arrayLength(index) - 1;
    let probe = this.weakHash(key, mask);
    while (asInt32(this.slot(index, probe)) != i32(position)) {
      probe = (probe + 1) & mask;
    }
    this.setSlot(index, probe, int32Value(WEAK_TOMBSTONE));
    const live = this.weakSize(record);
    this.setSlot(record, WEAK_SIZE, int32Value(i32(live - 1)));
  }

  // Close the gaps left by retired entries, in place.
  function weakCompact(inout this, record: u32): void {
    const keys = asCell(this.slot(record, WEAK_KEYS));
    const values = asCell(this.slot(record, WEAK_VALUES));
    const count = this.arrayLength(keys);
    let write: u32 = 0;
    let read: u32 = 0;
    while (read < count) {
      const key = this.slot(keys, read);
      if (!isDeleted(key)) {
        if (write != read) {
          const value = this.slot(values, read);
          this.setSlot(keys, write, key);
          this.setSlot(values, write, value);
        }
        write = write + 1;
      }
      read = read + 1;
    }
    this.setArrayLength(keys, write);
    this.setArrayLength(values, write);
  }

  // Rebuild the index over the live entries, in the same array.
  function weakRebuildIndex(inout this, record: u32): void {
    const index = asCell(this.slot(record, WEAK_INDEX));
    const capacity = this.arrayLength(index);
    let i: u32 = 0;
    while (i < capacity) {
      this.setSlot(index, i, int32Value(WEAK_EMPTY));
      i = i + 1;
    }
    const keys = asCell(this.slot(record, WEAK_KEYS));
    const count = this.arrayLength(keys);
    let position: u32 = 0;
    while (position < count) {
      const key = this.slot(keys, position);
      if (!isDeleted(key)) this.weakIndexInsert(index, asCell(key), position);
      position = position + 1;
    }
  }

  // A doubled index (an allocation: only ever on insertion).
  function weakGrowIndex(inout this, record: u32): void {
    const capacity = this.arrayLength(asCell(this.slot(record, WEAK_INDEX))) * 2;
    const index = this.allocateArray(capacity);
    let i: u32 = 0;
    while (i < capacity) {
      this.setSlot(index, i, int32Value(WEAK_EMPTY));
      i = i + 1;
    }
    this.setSlot(record, WEAK_INDEX, cellValue(index));
    this.weakRebuildIndex(record);
  }

  // --- Pending ephemeron work ---

  // A reached record's entries: process each whose key is already
  // marked, register the rest by key.
  function registerWeakRecord(inout this, record: u32): void {
    const keys = asCell(this.slot(record, WEAK_KEYS));
    const values = asCell(this.slot(record, WEAK_VALUES));
    const count = this.arrayLength(keys);
    let position: u32 = 0;
    while (position < count) {
      const key = this.slot(keys, position);
      if (!isDeleted(key)) {
        this.weakVisits = this.weakVisits + 1;
        const value = this.slot(values, position);
        if (isCell(value) && asCell(value) != 0 && !this.headers[usize(asCell(value))].marked) {
          if (this.headers[usize(asCell(key))].marked) {
            this.headers[usize(asCell(value))].marked = true;
            this.pushMark(asCell(value));
          } else {
            this.addPending(asCell(key), value);
          }
        }
      }
      position = position + 1;
    }
  }

  function addPending(inout this, key: u32, value: Value): void {
    if (this.pendingBuckets.length == 0) {
      let buckets = Array<u32>();
      let i: u32 = 0;
      while (i < 16) {
        buckets.push(0);
        i = i + 1;
      }
      this.pendingBuckets = move buckets;
      this.pendingMask = 15;
    }
    if ((this.pendingKeys.length + 1) * 2 > this.pendingBuckets.length) this.growPending();
    const entry = u32(this.pendingKeys.length);
    const bucket = this.weakHash(key, this.pendingMask);
    this.pendingKeys.push(key);
    this.pendingValues.push(value);
    this.pendingNext.push(this.pendingBuckets[usize(bucket)]);
    this.pendingBuckets[usize(bucket)] = entry + 1;
    this.pendingCount = this.pendingCount + 1;
  }

  // Twice the buckets, the chains rebuilt.
  function growPending(inout this): void {
    const size = u32(this.pendingBuckets.length) * 2;
    let buckets = Array<u32>.withCapacity(usize(size));
    let i: u32 = 0;
    while (i < size) {
      buckets.push(0);
      i = i + 1;
    }
    this.pendingBuckets = move buckets;
    this.pendingMask = size - 1;
    let entry: u32 = 0;
    const count = u32(this.pendingKeys.length);
    while (entry < count) {
      const key = this.pendingKeys[usize(entry)];
      if (key != 0) {
        const bucket = this.weakHash(key, this.pendingMask);
        this.pendingNext[usize(entry)] = this.pendingBuckets[usize(bucket)];
        this.pendingBuckets[usize(bucket)] = entry + 1;
      }
      entry = entry + 1;
    }
  }

  // The key `handle` was just popped from the mark stack: every value
  // waiting on it is marked (and will be traced in turn).
  function activatePending(inout this, handle: u32): void {
    const bucket = this.weakHash(handle, this.pendingMask);
    let at = this.pendingBuckets[usize(bucket)];
    while (at != 0) {
      const entry = usize(at - 1);
      if (this.pendingKeys[entry] == handle) {
        const value = this.pendingValues[entry];
        this.pendingKeys[entry] = 0;
        this.pendingCount = this.pendingCount - 1;
        if (isCell(value) && asCell(value) != 0 && !this.headers[usize(asCell(value))].marked) {
          this.headers[usize(asCell(value))].marked = true;
          this.pushMark(asCell(value));
        }
      }
      at = this.pendingNext[entry];
    }
  }

  // The scratch between collections: emptied, its capacity kept while it
  // is small, released once it has grown past the retention limit (a
  // collection that needs more allocates it again).
  function resetPending(inout this): void {
    this.pendingCount = 0;
    if (this.pendingScratchBytes() > PENDING_RETAIN_BYTES) {
      this.pendingKeys = Array<u32>();
      this.pendingValues = Array<Value>();
      this.pendingNext = Array<u32>();
      this.pendingBuckets = Array<u32>();
      this.pendingMask = 0;
      return;
    }
    this.pendingKeys.clear();
    this.pendingValues.clear();
    this.pendingNext.clear();
    let i: usize = 0;
    while (i < this.pendingBuckets.length) {
      this.pendingBuckets[i] = 0;
      i = i + 1;
    }
  }

  // Bytes the pending scratch holds between collections, for the harness.
  function pendingScratchBytes(): usize {
    return this.pendingKeys.capacity * 4 + this.pendingValues.capacity * 8 + this.pendingNext.capacity * 4 + this.pendingBuckets.capacity * 4;
  }

  // After the strong roots have drained, with the pending index having
  // activated every value whose key was marked: a verification scan over
  // the records reached. It marks nothing when the index did its job;
  // should it find something, it keeps going to a fixpoint, so the
  // collection is right either way.
  function markEphemerons(inout this): void {
    let passes: u32 = 0;
    let progressed = true;
    while (progressed) {
      progressed = false;
      passes = passes + 1;
      let r: usize = 0;
      while (r < this.weakRecords.length) {
        const record = this.weakRecords[r];
        const keys = asCell(this.slot(record, WEAK_KEYS));
        const values = asCell(this.slot(record, WEAK_VALUES));
        const count = this.arrayLength(keys);
        let position: u32 = 0;
        while (position < count) {
          const key = this.slot(keys, position);
          if (!isDeleted(key) && this.headers[usize(asCell(key))].marked) {
            this.weakVisits = this.weakVisits + 1;
            const value = this.slot(values, position);
            if (isCell(value) && asCell(value) != 0 && !this.headers[usize(asCell(value))].marked) {
              this.markHandle(asCell(value));
              progressed = true;
            }
          }
          position = position + 1;
        }
        r = r + 1;
      }
    }
    this.ephemeronPasses = passes;
  }

  // Drop every entry whose key is unmarked, then compact each touched
  // record in place. Runs before the sweep, while dead keys still have
  // headers. Ends the collection's use of the worklist.
  function clearDeadWeakEntries(inout this): void {
    let r: usize = 0;
    while (r < this.weakRecords.length) {
      const record = this.weakRecords[r];
      const keys = asCell(this.slot(record, WEAK_KEYS));
      const count = this.arrayLength(keys);
      let dropped: u32 = 0;
      let position: u32 = 0;
      while (position < count) {
        const key = this.slot(keys, position);
        if (!isDeleted(key) && !this.headers[usize(asCell(key))].marked) {
          this.weakRetire(record, position, asCell(key));
          dropped = dropped + 1;
        }
        position = position + 1;
      }
      if (dropped > 0) {
        this.weakCleared = this.weakCleared + dropped;
        this.weakCompact(record);
        this.weakRebuildIndex(record);
      }
      r = r + 1;
    }
    this.weakRecords = Array<u32>();
    this.resetPending();
  }

  // --- Closures and environments ---

  // An environment: one slot per captured binding, `link` the enclosing
  // environment (0 at the outermost).
  function allocateEnv(inout this, parent: u32, slotCount: u32): u32 {
    const handle = this.allocate(TAG_ENV, slotCount);
    this.headers[usize(handle)].link = parent;
    return handle;
  }

  function isEnv(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_ENV;
  }

  // A closure: a function index (`payload`, as for a plain function cell)
  // with the environment it was created in (`link`). Slot 0 holds the
  // `this` an arrow captured, slot 1 its `prototype` object once created,
  // slot 2 its bag of named properties once one is needed.
  function allocateClosure(inout this, functionIndex: u32, env: u32, capturedThis: Value): u32 {
    const handle = this.allocate(TAG_CLOSURE, 3);
    this.headers[usize(handle)].payload = functionIndex;
    this.headers[usize(handle)].link = env;
    this.setSlot(handle, 0, capturedThis);
    return handle;
  }

  function isClosure(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_CLOSURE;
  }

  // --- Symbols ---

  // A symbol: slot 0 its description (a string or undefined), slot 1 the
  // hidden atom that stands for it as a property key. That atom's `link`
  // points back at the symbol, so a key found on an object resolves to
  // its symbol.
  function allocateSymbol(inout this, description: Value): u32 {
    const handle = this.allocate(TAG_SYMBOL, 2);
    this.setSlot(handle, 0, description);
    return handle;
  }

  function isSymbol(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_SYMBOL;
  }

  function symbolKeyAtom(handle: u32): u32 {
    return asCell(this.slot(handle, 1));
  }

  function symbolDescription(handle: u32): Value {
    return this.slot(handle, 0);
  }

  // --- Host functions ---

  // A builtin implemented in Z; `payload` indexes the runtime's host
  // table, `link` is its `prototype` object once created. Slot 0 is
  // per-instance data, slot 1 `length`, slot 2 `name`, slot 3 the bag of
  // named properties once one is needed, slot 4 whether it is a
  // constructor.
  function allocateHostFunction(inout this, builtinId: u32): u32 {
    const handle = this.allocate(TAG_HOST_FUNCTION, 5);
    this.headers[usize(handle)].payload = builtinId;
    return handle;
  }

  function isHostFunction(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_HOST_FUNCTION;
  }

  function hostFunctionId(handle: u32): u32 {
    return this.headers[usize(handle)].payload;
  }

  // --- Strings ---
  //
  // A string cell's content is UTF-16 code units. Storage is one byte per
  // unit when every unit is at most 0xFF (Latin-1), else two bytes per
  // unit, little-endian, with FLAG_WIDE on the cell. The narrow form is
  // canonical, so equal content always has equal storage.
  function allocateStorage(inout this, bytes: Array<u8>, wide: boolean): u32 {
    let stringIndex: u32 = 0;
    if (this.freeStringCount > 0) {
      this.freeStringCount = this.freeStringCount - 1;
      stringIndex = this.freeStrings[this.freeStringCount];
      this.strings[usize(stringIndex)] = move bytes;
    } else {
      stringIndex = u32(this.strings.length);
      this.strings.push(move bytes);
    }
    const handle = this.allocate(TAG_STRING, 0);
    this.headers[usize(handle)].payload = stringIndex;
    if (wide) this.setFlags(handle, FLAG_WIDE);
    return handle;
  }

  // A string whose units are these bytes' values (ASCII or Latin-1).
  function allocateLatin1(inout this, bytes: Array<u8>): u32 {
    return this.allocateStorage(move bytes, false);
  }

  // A string of these units, stored narrow when it can be.
  function allocateUnits(inout this, units: Array<u16>): u32 {
    if (isNarrowUnits(in units)) return this.allocateStorage(unitsToLatin1(in units), false);
    let bytes = Array<u8>.withCapacity(units.length * 2);
    let i: usize = 0;
    while (i < units.length) {
      bytes.push(u8(units[i] & 0xFF));
      bytes.push(u8(units[i] >> 8));
      i = i + 1;
    }
    return this.allocateStorage(move bytes, true);
  }

  // A string decoded from UTF-8 text (the source and host boundary).
  function allocateUtf8(inout this, bytes: Array<u8>): u32 {
    if (isAsciiBytes(in bytes)) return this.allocateStorage(move bytes, false);
    return this.allocateUnits(utf8ToUnits(in bytes));
  }

  // A string cell holding a Z String's text.
  function allocateText(inout this, in text: String): u32 {
    return this.allocateUtf8(bytesOf(in text));
  }

  function isWideString(handle: u32): boolean {
    return (this.headers[usize(handle)].flags & FLAG_WIDE) != 0;
  }

  function isString(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_STRING;
  }

  // A function cell referring to compiled code by index.
  // A function value: `payload` indexes the runtime's function table,
  // `link` is its `prototype` object once created, and the slot holds its
  // bag of named properties once one is needed.
  function allocateFunction(inout this, functionIndex: u32): u32 {
    const handle = this.allocate(TAG_FUNCTION, 1);
    this.headers[usize(handle)].payload = functionIndex;
    return handle;
  }

  function isFunction(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_FUNCTION;
  }

  function functionIndex(handle: u32): u32 {
    return this.headers[usize(handle)].payload;
  }

  // The length in code units.
  function stringLength(handle: u32): usize {
    const bytes = this.strings[usize(this.headers[usize(handle)].payload)].length;
    if ((this.headers[usize(handle)].flags & FLAG_WIDE) != 0) return bytes / 2;
    return bytes;
  }

  function stringUnit(handle: u32, index: usize): u16 {
    const at = usize(this.headers[usize(handle)].payload);
    if ((this.headers[usize(handle)].flags & FLAG_WIDE) != 0) {
      return u16(this.strings[at][index * 2]) | (u16(this.strings[at][index * 2 + 1]) << 8);
    }
    return u16(this.strings[at][index]);
  }

  // units[start, end) copied; the caller keeps end in range.
  function stringUnitsSlice(handle: u32, start: usize, end: usize): Array<u16> {
    const at = usize(this.headers[usize(handle)].payload);
    let count: usize = 0;
    if (end > start) count = end - start;
    let copied = Array<u16>.withCapacity(count);
    let index = start;
    if ((this.headers[usize(handle)].flags & FLAG_WIDE) != 0) {
      while (index < end) {
        copied.push(u16(this.strings[at][index * 2]) | (u16(this.strings[at][index * 2 + 1]) << 8));
        index = index + 1;
      }
      return copied;
    }
    while (index < end) {
      copied.push(u16(this.strings[at][index]));
      index = index + 1;
    }
    return copied;
  }

  // A fresh string cell holding units[start, end) of another, copied in
  // storage form (no unit round trip).
  function allocateSubstring(inout this, handle: u32, start: usize, end: usize): u32 {
    const at = usize(this.headers[usize(handle)].payload);
    const wide = (this.headers[usize(handle)].flags & FLAG_WIDE) != 0;
    if (!wide) {
      let count: usize = 0;
      if (end > start) count = end - start;
      let bytes = Array<u8>.withCapacity(count);
      let index = start;
      while (index < end) {
        bytes.push(this.strings[at][index]);
        index = index + 1;
      }
      return this.allocateStorage(move bytes, false);
    }
    // A wide slice may fit narrow; allocateUnits decides.
    return this.allocateUnits(this.stringUnitsSlice(handle, start, end));
  }

  function stringUnits(handle: u32): Array<u16> {
    const length = this.stringLength(handle);
    return this.stringUnitsSlice(handle, 0, length);
  }

  // The raw storage: Latin-1 bytes, or two bytes per unit when wide.
  function stringStorageLength(handle: u32): usize {
    return this.strings[usize(this.headers[usize(handle)].payload)].length;
  }

  function stringStorageByte(handle: u32, index: usize): u8 {
    return this.strings[usize(this.headers[usize(handle)].payload)][index];
  }

  // A copy of the storage: the Latin-1 bytes of a narrow string (the
  // fast paths' working form), or the wide string's byte pairs.
  function stringStorageBytes(handle: u32): Array<u8> {
    const at = usize(this.headers[usize(handle)].payload);
    const length = this.strings[at].length;
    let copied = Array<u8>.withCapacity(length);
    let index: usize = 0;
    while (index < length) {
      copied.push(this.strings[at][index]);
      index = index + 1;
    }
    return copied;
  }

  // The content as UTF-8 for the host (a lone surrogate becomes U+FFFD).
  function stringUtf8(handle: u32): Array<u8> {
    const at = usize(this.headers[usize(handle)].payload);
    if ((this.headers[usize(handle)].flags & FLAG_WIDE) != 0) {
      const units = this.stringUnits(handle);
      return unitsToUtf8(in units);
    }
    const length = this.strings[at].length;
    let bytes = Array<u8>.withCapacity(length);
    let index: usize = 0;
    while (index < length) {
      const byte = this.strings[at][index];
      if (byte < 0x80) {
        bytes.push(byte);
      } else {
        bytes.push(u8(0xC0 | (byte >> 6)));
        bytes.push(u8(0x80 | (byte & 0x3F)));
      }
      index = index + 1;
    }
    return bytes;
  }

  // The content as generalized UTF-8, a lone surrogate in its three-byte
  // form: for the parser, so a string handed back as source keeps it.
  function stringWtf8(handle: u32): Array<u8> {
    if ((this.headers[usize(handle)].flags & FLAG_WIDE) == 0) return this.stringUtf8(handle);
    const units = this.stringUnits(handle);
    return unitsToWtf8(in units);
  }

  // Equal content: equal width (the narrow form is canonical) and equal
  // storage.
  function stringsEqual(a: u32, b: u32): boolean {
    if (a == b) return true;
    if (this.isWideString(a) != this.isWideString(b)) return false;
    const at = usize(this.headers[usize(a)].payload);
    const bt = usize(this.headers[usize(b)].payload);
    const length = this.strings[at].length;
    if (length != this.strings[bt].length) return false;
    let index: usize = 0;
    while (index < length) {
      if (this.strings[at][index] != this.strings[bt][index]) return false;
      index = index + 1;
    }
    return true;
  }

  // Ordering by code units, then by length: negative, zero, or positive.
  function compareStrings(a: u32, b: u32): i32 {
    const aLength = this.stringLength(a);
    const bLength = this.stringLength(b);
    const shorter = aLength < bLength ? aLength : bLength;
    let index: usize = 0;
    if (!this.isWideString(a) && !this.isWideString(b)) {
      const at = usize(this.headers[usize(a)].payload);
      const bt = usize(this.headers[usize(b)].payload);
      while (index < shorter) {
        const ab = this.strings[at][index];
        const bb = this.strings[bt][index];
        if (ab < bb) return -1;
        if (ab > bb) return 1;
        index = index + 1;
      }
      if (aLength < bLength) return -1;
      if (aLength > bLength) return 1;
      return 0;
    }
    while (index < shorter) {
      const ab = this.stringUnit(a, index);
      const bb = this.stringUnit(b, index);
      if (ab < bb) return -1;
      if (ab > bb) return 1;
      index = index + 1;
    }
    if (aLength < bLength) return -1;
    if (aLength > bLength) return 1;
    return 0;
  }

  function allocateValue(inout this, tag: u8, slotCount: u32): Value {
    return cellValue(this.allocate(tag, slotCount));
  }

  function tagOf(handle: u32): u8 {
    return this.headers[usize(handle)].tag;
  }

  function slotCountOf(handle: u32): u32 {
    return this.headers[usize(handle)].slotCount;
  }

  function slot(handle: u32, index: u32): Value {
    const header = this.headers[usize(handle)];
    return this.slots[usize(header.slotStart + index)];
  }

  function setSlot(inout this, handle: u32, index: u32, value: Value): void {
    const start = this.headers[usize(handle)].slotStart;
    this.slots[usize(start + index)] = value;
  }

  function attrOf(handle: u32, index: u32): u8 {
    return this.attrs[usize(this.headers[usize(handle)].slotStart + index)];
  }

  function setAttr(inout this, handle: u32, index: u32, attr: u8): void {
    this.attrs[usize(this.headers[usize(handle)].slotStart + index)] = attr;
  }

  function flagsOf(handle: u32): u8 {
    return this.headers[usize(handle)].flags;
  }

  function setFlags(inout this, handle: u32, flags: u8): void {
    this.headers[usize(handle)].flags = flags;
  }

  // Define an own property with attributes, adding it if absent.
  function objectDefine(inout this, handle: u32, atom: u32, value: Value, attr: u8): void {
    this.objectSet(handle, atom, value);
    const slot = this.objectFindSlot(handle, atom);
    this.setAttr(handle, u32(slot), attr);
  }

  // An accessor pair, held in a slot flagged PROP_ACCESSOR.
  function allocateAccessor(inout this, getter: Value, setter: Value): u32 {
    const handle = this.allocate(TAG_ACCESSOR, 2);
    this.setSlot(handle, 0, getter);
    this.setSlot(handle, 1, setter);
    return handle;
  }

  function isAccessor(handle: u32): boolean {
    return this.headers[usize(handle)].tag == TAG_ACCESSOR;
  }

  function marked(handle: u32): boolean {
    return this.headers[usize(handle)].marked;
  }

  function setMarked(inout this, handle: u32, value: boolean): void {
    this.headers[usize(handle)].marked = value;
  }

  // Allocated cells, excluding the reserved handle 0.
  // Whether a handle's cell has been freed: listed for reuse, or cut
  // from the table with everything above the highest survivor.
  function isReleased(handle: u32): boolean {
    if (usize(handle) >= this.headerCount) return true;
    return this.headers[usize(handle)].tag == TAG_FREE;
  }

  // One past the highest handle the table holds.
  function handleExtent(): u32 {
    return u32(this.headerCount);
  }

  function liveCells(): u32 {
    return u32(this.headerCount - 1 - this.freeHandleCount);
  }

  function slotsInUse(): u32 {
    return u32(this.slots.length);
  }

  // Cells and slots allocated since the heap was made.
  function cellsAllocated(): f64 {
    return this.cellsBeforeCycle + f64(this.allocatedSinceCollect);
  }

  function slotsAllocated(): f64 {
    let current: f64 = 0.0;
    if (this.slots.length > this.slotsAfterSweep) current = f64(this.slots.length - this.slotsAfterSweep);
    return this.slotsBeforeCycle + current;
  }

  // --- Storage figures, for reports ---
  //
  // Three different things. What was alive at the last collection: the
  // cells it traced and their slots. What is in use now: that plus
  // whatever has been allocated since, garbage included. What is held:
  // the capacity of every array behind the heap, used or not, which is
  // what the allocator sees.

  // Headers and slots of the cells the last collection traced.
  function bytesLiveAtLastCollection(): f64 {
    return f64(this.markedCells) * HEADER_BYTES + f64(this.markedSlots) * 9.0;
  }

  // The active arena and the spare one kept to compact into.
  function arenaBytesHeld(): f64 {
    return f64(this.slots.capacity) * 8.0 + f64(this.attrs.capacity);
  }

  function spareArenaBytesHeld(): f64 {
    return f64(this.spareSlots.capacity) * 8.0 + f64(this.spareAttrs.capacity);
  }

  // The handle table with its free list and the mark stack.
  function tableBytesHeld(): f64 {
    return f64(this.headers.capacity) * HEADER_BYTES + f64(this.freeHandles.capacity) * 4.0 + f64(this.markStack.capacity) * 4.0;
  }

  // The string table: an array per string plus each one's content.
  function stringBytesHeld(): f64 {
    let held: f64 = f64(this.strings.capacity) * 24.0 + f64(this.freeStrings.capacity) * 4.0;
    let index: usize = 0;
    while (index < this.strings.length) {
      held = held + f64(this.strings[index].capacity);
      index = index + 1;
    }
    return held;
  }

  // Hidden classes, dictionary indexes, and the collector's weak and
  // pending-ephemeron scratch.
  function otherBytesHeld(): f64 {
    let held: f64 = f64(this.classes.capacity) * 64.0 + f64(this.dictionaries.capacity) * 40.0 + f64(this.freeDictionaries.capacity) * 4.0;
    held = held + f64(this.weakRecords.capacity) * 4.0 + f64(this.pendingScratchBytes());
    let index: usize = 0;
    while (index < this.classes.length) {
      held = held + f64(this.classes[index].transitionNames.capacity) * 4.0 + f64(this.classes[index].transitionChildren.capacity) * 4.0;
      index = index + 1;
    }
    index = 0;
    while (index < this.dictionaries.length) {
      held = held + f64(this.dictionaries[index].index.capacity) * 4.0;
      index = index + 1;
    }
    return held;
  }

  // Bytes the engine's own storage holds in use now: a header per handle
  // within the table's extent (free ones included), a value and an
  // attribute byte per slot, and string content. Capacity beyond that is
  // in the held figures above.
  function bytesInUse(): f64 {
    let stringBytes: f64 = 0.0;
    let index: usize = 0;
    while (index < this.strings.length) {
      stringBytes = stringBytes + f64(this.strings[index].length);
      index = index + 1;
    }
    return f64(this.headerCount) * HEADER_BYTES + f64(this.slots.length) * 9.0 + stringBytes;
  }
}

export function createHeap(): Heap {
  let headers = Array<CellHeader>();
  // Handle 0 is reserved; push a sentinel so live handles start at 1.
  headers.push(CellHeader({ tag: TAG_RESERVED, marked: false, flags: 0, slotStart: 0, slotCount: 0, payload: 0, link: 0 }));
  let classes = Array<HiddenClass>();
  // Class 0 is the empty root every object starts from.
  classes.push(HiddenClass({
    parent: 0, transitionName: 0, transitionSlot: 0, propCount: 0,
    transitionNames: Array<u32>(), transitionChildren: Array<u32>(),
  }));
  return Heap({
    headers: move headers, slots: Array<Value>(), attrs: Array<u8>(), spareSlots: Array<Value>(), spareAttrs: Array<u8>(), slotsAfterSweep: 0, headerCount: 1, cellsBeforeCycle: 0.0, slotsBeforeCycle: 0.0, strings: Array<Array<u8>>(), classes: move classes,
    freeHandles: Array<u32>(), freeHandleCount: 0, freeStrings: Array<u32>(), freeStringCount: 0,
    weakRecords: Array<u32>(), pendingKeys: Array<u32>(), pendingValues: Array<Value>(), pendingNext: Array<u32>(), pendingBuckets: Array<u32>(), pendingMask: 0, pendingCount: 0,
    weakCleared: 0, ephemeronPasses: 0, weakVisits: 0, markedCells: 0, markedSlots: 0,
    dictionaries: Array<Dictionary>(), freeDictionaries: Array<u32>(), freeDictionaryCount: 0, dictThreshold: DICT_THRESHOLD,
    markStack: Array<u32>(), markCount: 0,
    allocatedSinceCollect: 0, collectThreshold: COLLECT_FLOOR, collections: 0, collectFloor: COLLECT_FLOOR, collectGrowthPercent: COLLECT_GROWTH_PERCENT,
  });
}

// The fewest allocations between collections.
// A compacted arena no larger than this many slots (about nine
// megabytes) is kept to be compacted into next time.
const SPARE_RETAIN_SLOTS: usize = 1048576;
// A handle table never made larger than this is not worth rebuilding.
const HANDLE_TABLE_SHRINK_AT: usize = 65536;
// A table shorter than this is walked whole rather than cut back.
const HANDLE_TABLE_CUT_AT: usize = 32768;
const COLLECT_FLOOR: u32 = 4096;
const COLLECT_GROWTH_PERCENT: u32 = 200;
// A cell header as laid out: three bytes of tag, mark, and flags, then
// four u32 fields.
const HEADER_BYTES: f64 = 20.0;

// Properties an object may hold in class mode before its next addition
// moves it to dictionary mode (chosen from measurement; see README).
export const DICT_THRESHOLD: u32 = 64;

// The bytes of a Z String as an owned byte array.
// An owned copy of the byte range [start, end).
export function sliceBytes(in bytes: Array<u8>, start: usize, end: usize): Array<u8> {
  let count: usize = 0;
  if (end > start) count = end - start;
  let copied = Array<u8>.withCapacity(count);
  let index = start;
  while (index < end) {
    copied.push(bytes[index]);
    index = index + 1;
  }
  return copied;
}

export function bytesOf(in text: String): Array<u8> {
  const length = text.byteLength;
  let bytes = Array<u8>.withCapacity(length);
  let index: usize = 0;
  while (index < length) {
    bytes.push(text.byteAt(index));
    index = index + 1;
  }
  return bytes;
}

// --- Tests ----------------------------------------------------------------

function int32Slot(value: i32): Value {
  return int32Value(value);
}

test "a fresh heap has no live cells and reserves handle 0" {
  const heap = createHeap();
  expect(heap.liveCells()).toEqual(0);
  expect(heap.tagOf(0)).toEqual(TAG_RESERVED);
}

test "allocation yields handles starting at one" {
  let heap = createHeap();
  const first = heap.allocate(TAG_OBJECT, 4);
  const second = heap.allocate(TAG_ARRAY, 2);
  expect(first).toEqual(1);
  expect(second).toEqual(2);
  expect(heap.liveCells()).toEqual(2);
}

test "tags and slot counts survive allocation" {
  let heap = createHeap();
  const object = heap.allocate(TAG_OBJECT, 4);
  const text = heap.allocate(TAG_STRING, 1);
  expect(heap.tagOf(object)).toEqual(TAG_OBJECT);
  expect(heap.tagOf(text)).toEqual(TAG_STRING);
  expect(heap.slotCountOf(object)).toEqual(4);
  expect(heap.slotCountOf(text)).toEqual(1);
}

test "slots initialize to undefined" {
  let heap = createHeap();
  const object = heap.allocate(TAG_OBJECT, 3);
  expect(heap.slot(object, 0).bits).toEqual(undefinedValue().bits);
  expect(heap.slot(object, 2).bits).toEqual(undefinedValue().bits);
}

test "slots round-trip and neighbouring cells stay independent" {
  let heap = createHeap();
  const first = heap.allocate(TAG_OBJECT, 2);
  const second = heap.allocate(TAG_OBJECT, 2);

  heap.setSlot(first, 0, int32Slot(11));
  heap.setSlot(first, 1, int32Slot(22));
  heap.setSlot(second, 0, int32Slot(33));

  expect(heap.slot(first, 0).bits).toEqual(int32Slot(11).bits);
  expect(heap.slot(first, 1).bits).toEqual(int32Slot(22).bits);
  expect(heap.slot(second, 0).bits).toEqual(int32Slot(33).bits);
  // Writing `second` must not have disturbed `first`.
  expect(heap.slot(first, 1).bits).toEqual(int32Slot(22).bits);
  // And `second`'s untouched slot is still undefined.
  expect(heap.slot(second, 1).bits).toEqual(undefinedValue().bits);
}

test "a boxed cell round-trips through the heap" {
  let heap = createHeap();
  const boxed = heap.allocateValue(TAG_ARRAY, 1);
  expect(isCell(boxed)).toEqual(true);
  expect(heap.tagOf(asCell(boxed))).toEqual(TAG_ARRAY);

  // A cell stored in another cell's slot survives the round trip.
  const holder = heap.allocate(TAG_OBJECT, 1);
  heap.setSlot(holder, 0, boxed);
  const recovered = heap.slot(holder, 0);
  expect(isCell(recovered)).toEqual(true);
  expect(asCell(recovered)).toEqual(asCell(boxed));
}

test "mark bits are per-cell and default clear" {
  let heap = createHeap();
  const first = heap.allocate(TAG_OBJECT, 1);
  const second = heap.allocate(TAG_OBJECT, 1);
  expect(heap.marked(first)).toEqual(false);
  heap.setMarked(first, true);
  expect(heap.marked(first)).toEqual(true);
  expect(heap.marked(second)).toEqual(false);
}

test "string cells keep their bytes and compare bytewise" {
  let heap = createHeap();
  const hello = heap.allocateText("hello");
  const help = heap.allocateText("help");
  const helloAgain = heap.allocateText("hello");
  expect(heap.isString(hello)).toEqual(true);
  const five: usize = 5;
  expect(heap.stringLength(hello)).toEqual(five);
  expect(heap.stringUnit(hello, 1)).toEqual(101);
  expect(heap.stringsEqual(hello, helloAgain)).toEqual(true);
  expect(heap.stringsEqual(hello, help)).toEqual(false);
  expect(heap.compareStrings(hello, help) < 0).toEqual(true);
  expect(heap.compareStrings(help, hello) > 0).toEqual(true);
  const prefix = heap.allocateText("hel");
  expect(heap.compareStrings(prefix, hello) < 0).toEqual(true);
  const copied = heap.stringUtf8(hello);
  expect(copied.length).toEqual(five);
  expect(copied[4]).toEqual(111);
}

test "objects add properties through shared class transitions" {
  let heap = createHeap();
  const textA: String = "a";
  const textB: String = "b";
  const nameA = heap.allocateUtf8(bytesOf(in textA));
  const nameB = heap.allocateUtf8(bytesOf(in textB));
  const first = heap.allocateObject(0);
  const second = heap.allocateObject(0);
  heap.objectSet(first, nameA, int32Value(1));
  heap.objectSet(first, nameB, int32Value(2));
  heap.objectSet(second, nameA, int32Value(10));
  heap.objectSet(second, nameB, int32Value(20));
  expect(heap.objectClass(first)).toEqual(heap.objectClass(second));
  expect(heap.objectFindSlot(first, nameA)).toEqual(0);
  expect(heap.objectFindSlot(first, nameB)).toEqual(1);
  expect(asInt32(heap.slot(second, 1))).toEqual(20);
  heap.objectSet(first, nameA, int32Value(7));
  expect(asInt32(heap.slot(first, 0))).toEqual(7);
  expect(heap.objectFindSlot(first, 12345)).toEqual(-1);
}

test "an object outgrows its initial slots" {
  let heap = createHeap();
  const object = heap.allocateObject(0);
  let i: i32 = 0;
  while (i < 10) {
    const text: String = `p${i}`;
    const name = heap.allocateUtf8(bytesOf(in text));
    heap.objectSet(object, name, int32Value(i));
    i = i + 1;
  }
  expect(heap.classPropCount(heap.objectClass(object))).toEqual(10);
  const textP9: String = "p9";
  const p9 = heap.allocateUtf8(bytesOf(in textP9));
  // Names are compared by handle; a different cell with the same bytes
  // is a different atom. The runtime interns before it asks the heap.
  expect(heap.objectFindSlot(object, p9)).toEqual(-1);
  expect(asInt32(heap.slot(object, 9))).toEqual(9);
}

test "arrays grow, keep holes, and shrink" {
  let heap = createHeap();
  const array = heap.allocateArray(0);
  expect(heap.arrayLength(array)).toEqual(0);
  heap.arraySet(array, 0, int32Value(5));
  heap.arraySet(array, 6, int32Value(6));
  expect(heap.arrayLength(array)).toEqual(7);
  expect(heap.arrayHasIndex(array, 3)).toEqual(false);
  expect(asInt32(heap.arrayGet(array, 6))).toEqual(6);
  heap.setArrayLength(array, 1);
  expect(heap.arrayHasIndex(array, 6)).toEqual(false);
  expect(asInt32(heap.arrayGet(array, 0))).toEqual(5);
}

test "a sweep frees unmarked cells, compacts slots, and reuses handles" {
  let heap = createHeap();
  const kept = heap.allocateObject(0);
  const dropped = heap.allocateObject(0);
  const textKept: String = "kept";
  const textDropped: String = "dropped";
  const keptString = heap.allocateUtf8(bytesOf(in textKept));
  const droppedString = heap.allocateUtf8(bytesOf(in textDropped));
  const child = heap.allocateArray(2);
  heap.setSlot(kept, 0, cellValue(child));
  heap.setSlot(child, 0, cellValue(keptString));
  heap.objectSet(dropped, keptString, cellValue(droppedString));
  const slotsBefore = heap.slotsInUse();
  heap.markHandle(kept);
  heap.sweep();
  expect(heap.liveCells()).toEqual(3);
  expect(heap.isReleased(dropped)).toEqual(true);
  expect(heap.isReleased(droppedString)).toEqual(true);
  expect(heap.isArray(child)).toEqual(true);
  expect(heap.stringLength(keptString)).toEqual(4);
  expect(heap.slotsInUse() < slotsBefore).toEqual(true);
  expect(asCell(heap.slot(child, 0))).toEqual(keptString);
  // The freed handle and string index come back before the arrays grow.
  const headersBefore = heap.headers.length;
  const reused = heap.allocateUtf8(bytesOf(in textDropped));
  expect(reused == dropped || reused == droppedString).toEqual(true);
  expect(heap.headers.length).toEqual(headersBefore);
  expect(heap.stringLength(reused)).toEqual(7);
}

test "marking follows links: prototypes, environments, closures" {
  let heap = createHeap();
  const unreachable = heap.allocateObject(0);
  const proto = heap.allocateObject(0);
  const object = heap.allocateObject(proto);
  const outerEnv = heap.allocateEnv(0, 1);
  const innerEnv = heap.allocateEnv(outerEnv, 1);
  const fn = heap.allocateFunction(3);
  const closure = heap.allocateClosure(3, innerEnv, cellValue(object));
  heap.setSlot(outerEnv, 0, cellValue(fn));
  heap.markHandle(closure);
  heap.sweep();
  expect(heap.tagOf(proto)).toEqual(TAG_OBJECT);
  expect(heap.tagOf(outerEnv)).toEqual(TAG_ENV);
  expect(heap.tagOf(fn)).toEqual(TAG_FUNCTION);
  expect(heap.isReleased(unreachable)).toEqual(true);
  expect(heap.liveCells()).toEqual(6);
}

test "a large table whose survivors sit low is cut back to the highest of them" {
  let heap = createHeap();
  const low = heap.allocateObject(0);
  const kept = heap.allocateObject(0);
  const middle = heap.allocateObject(0);
  const high = heap.allocateObject(0);
  let tail: u32 = 0;
  while (tail < 40000) {
    const garbage = heap.allocateObject(0);
    tail = tail + 1;
  }
  expect(heap.handleExtent()).toEqual(high + 40001);
  heap.markHandle(kept);
  heap.markHandle(high);
  heap.sweep();
  // Everything above `high` is gone from the table and from the free
  // list; `low` and `middle` are free below it and come back first.
  expect(heap.handleExtent()).toEqual(high + 1);
  expect(heap.liveCells()).toEqual(2);
  expect(heap.isReleased(middle)).toEqual(true);
  const first = heap.allocateObject(0);
  const second = heap.allocateObject(0);
  expect((first == low && second == middle) || (first == middle && second == low)).toEqual(true);
  expect(heap.allocateObject(0)).toEqual(high + 1);
  // Handles listed by an earlier sweep leave the list when a later one
  // cuts the table below them.
  tail = 0;
  while (tail < 40000) {
    const garbage = heap.allocateObject(0);
    tail = tail + 1;
  }
  heap.markHandle(kept);
  heap.sweep();
  expect(heap.handleExtent()).toEqual(kept + 1);
  expect(heap.liveCells()).toEqual(1);
  expect(heap.allocateObject(0)).toEqual(low);
  expect(heap.allocateObject(0)).toEqual(kept + 1);
}

test "a small table is walked whole and left as it is" {
  let heap = createHeap();
  const kept = heap.allocateObject(0);
  let tail: u32 = 0;
  while (tail < 100) {
    const garbage = heap.allocateObject(0);
    tail = tail + 1;
  }
  const extent = heap.handleExtent();
  heap.markHandle(kept);
  heap.sweep();
  expect(heap.handleExtent()).toEqual(extent);
  expect(heap.liveCells()).toEqual(1);
  expect(heap.isReleased(kept + 50)).toEqual(true);
}

// --- Dictionary mode ---

// Distinct string cells to serve as atoms: "n0", "n1", ...
function testNames(inout heap: Heap, count: u32): Array<u32> {
  let names = Array<u32>();
  let i: u32 = 0;
  while (i < count) {
    let bytes = Array<u8>();
    bytes.push(110);
    let rest = i;
    let digits = Array<u8>();
    if (rest == 0) digits.push(48);
    while (rest > 0) {
      digits.push(u8(48 + rest % 10));
      rest = rest / 10;
    }
    let d = digits.length;
    while (d > 0) {
      d = d - 1;
      bytes.push(digits[d]);
    }
    names.push(heap.allocateLatin1(move bytes));
    i = i + 1;
  }
  return names;
}

test "an object past the threshold becomes a dictionary keeping order, values, and attributes" {
  let heap = createHeap();
  heap.dictThreshold = 4;
  const names = testNames(inout heap, 6);
  const object = heap.allocateObject(0);
  let i: u32 = 0;
  while (i < 4) {
    heap.objectSet(object, names[usize(i)], int32Value(i32(i * 10)));
    i = i + 1;
  }
  heap.setAttr(object, u32(heap.objectFindSlot(object, names[1])), PROP_NONE);
  expect(heap.isDictionary(object)).toEqual(false);
  heap.objectSet(object, names[4], int32Value(40));
  expect(heap.isDictionary(object)).toEqual(true);
  heap.objectSet(object, names[5], int32Value(50));
  i = 0;
  while (i < 6) {
    const slot = heap.objectFindSlot(object, names[usize(i)]);
    expect(slot >= 0).toEqual(true);
    expect(asInt32(heap.slot(object, u32(slot)))).toEqual(i32(i * 10));
    i = i + 1;
  }
  expect(heap.attrOf(object, u32(heap.objectFindSlot(object, names[1])))).toEqual(PROP_NONE);
  expect(heap.attrOf(object, u32(heap.objectFindSlot(object, names[2])))).toEqual(PROP_DEFAULT);
  const order = heap.objectNames(object);
  expect(order.length).toEqual(6);
  expect(order[0]).toEqual(names[0]);
  expect(order[5]).toEqual(names[5]);
  expect(heap.objectFindSlot(object, 12345)).toEqual(-1);
  expect(heap.dictionaryCount()).toEqual(1);
}

test "deleting the newest property keeps the class; deleting another makes a dictionary; both re-add last" {
  let heap = createHeap();
  const names = testNames(inout heap, 3);
  const object = heap.allocateObject(0);
  heap.objectSet(object, names[0], int32Value(1));
  heap.objectSet(object, names[1], int32Value(2));
  heap.objectSet(object, names[2], int32Value(3));
  const full = heap.objectClass(object);
  heap.objectDelete(object, names[2], u32(heap.objectFindSlot(object, names[2])));
  expect(heap.isDictionary(object)).toEqual(false);
  expect(heap.objectFindSlot(object, names[2])).toEqual(-1);
  heap.objectSet(object, names[2], int32Value(30));
  expect(heap.objectClass(object)).toEqual(full);
  const afterReadd = heap.objectNames(object);
  expect(afterReadd[2]).toEqual(names[2]);
  heap.objectDelete(object, names[0], u32(heap.objectFindSlot(object, names[0])));
  expect(heap.isDictionary(object)).toEqual(true);
  expect(heap.objectFindSlot(object, names[0])).toEqual(-1);
  const afterDelete = heap.objectNames(object);
  expect(afterDelete.length).toEqual(2);
  heap.objectSet(object, names[0], int32Value(10));
  const order = heap.objectNames(object);
  expect(order.length).toEqual(3);
  expect(order[0]).toEqual(names[1]);
  expect(order[2]).toEqual(names[0]);
  expect(asInt32(heap.slot(object, u32(heap.objectFindSlot(object, names[0]))))).toEqual(10);
  expect(asInt32(heap.slot(object, u32(heap.objectFindSlot(object, names[2]))))).toEqual(30);
}

test "a dictionary grows, and compacts instead of growing when most pairs are retired" {
  let heap = createHeap();
  heap.dictThreshold = 0;
  const names = testNames(inout heap, 200);
  const object = heap.allocateObject(0);
  let i: u32 = 0;
  while (i < 200) {
    heap.objectSet(object, names[usize(i)], int32Value(i32(i)));
    i = i + 1;
  }
  expect(heap.isDictionary(object)).toEqual(true);
  const names1 = heap.objectNames(object);
  expect(names1.length).toEqual(200);
  i = 0;
  while (i < 190) {
    heap.objectDelete(object, names[usize(i)], u32(heap.objectFindSlot(object, names[usize(i)])));
    i = i + 1;
  }
  const names2 = heap.objectNames(object);
  expect(names2.length).toEqual(10);
  // Retire and re-add one name many times: the pairs compact rather
  // than the slots growing without bound.
  let cycle: u32 = 0;
  while (cycle < 5000) {
    heap.objectDelete(object, names[195], u32(heap.objectFindSlot(object, names[195])));
    heap.objectSet(object, names[195], int32Value(i32(cycle)));
    cycle = cycle + 1;
  }
  expect(heap.slotCountOf(object) <= 1024).toEqual(true);
  const names3 = heap.objectNames(object);
  expect(names3.length).toEqual(10);
  expect(asInt32(heap.slot(object, u32(heap.objectFindSlot(object, names[195]))))).toEqual(4999);
  expect(asInt32(heap.slot(object, u32(heap.objectFindSlot(object, names[190]))))).toEqual(190);
  const order = heap.objectNames(object);
  expect(order[0]).toEqual(names[190]);
  expect(order[9]).toEqual(names[195]);
  expect(heap.objectFindSlot(object, names[0])).toEqual(-1);
}

test "a sweep releases a dead dictionary and a live one survives the compaction" {
  let heap = createHeap();
  heap.dictThreshold = 2;
  const names = testNames(inout heap, 8);
  const dead = heap.allocateObject(0);
  const kept = heap.allocateObject(0);
  let i: u32 = 0;
  while (i < 8) {
    heap.objectSet(kept, names[usize(i)], int32Value(i32(i + 100)));
    heap.objectSet(dead, names[usize(i)], int32Value(i32(i)));
    i = i + 1;
  }
  expect(heap.dictionaryCount()).toEqual(2);
  heap.markHandle(kept);
  heap.sweep();
  expect(heap.dictionaryCount()).toEqual(1);
  expect(heap.isReleased(dead)).toEqual(true);
  // The keys were reached through the object's slots.
  expect(heap.tagOf(names[3])).toEqual(TAG_STRING);
  i = 0;
  while (i < 8) {
    const slot = heap.objectFindSlot(kept, names[usize(i)]);
    expect(asInt32(heap.slot(kept, u32(slot)))).toEqual(i32(i + 100));
    i = i + 1;
  }
  // A new dictionary reuses the released index.
  const later = heap.allocateObject(0);
  heap.objectSet(later, names[0], int32Value(1));
  heap.objectSet(later, names[1], int32Value(2));
  heap.objectSet(later, names[2], int32Value(3));
  expect(heap.isDictionary(later)).toEqual(true);
  expect(heap.dictionaryCount()).toEqual(2);
}

// --- Weak records ---

// A weak record holding `count` fresh object keys mapped to fresh object
// values; the keys and values as parallel handle arrays.
struct WeakFixture {
  record: u32;
  keys: Array<u32>;
  values: Array<u32>;
}

function weakFixture(inout heap: Heap, count: u32): WeakFixture {
  const record = heap.allocateWeakRecord(2);
  let keys = Array<u32>();
  let values = Array<u32>();
  let i: u32 = 0;
  while (i < count) {
    const key = heap.allocateObject(0);
    const value = heap.allocateObject(0);
    heap.weakPut(record, key, cellValue(value));
    keys.push(key);
    values.push(value);
    i = i + 1;
  }
  return WeakFixture({ record: record, keys: move keys, values: move values });
}

// One collection over explicit roots: the given handles are marked, the
// ephemeron pass runs, dead entries are dropped, the sweep frees the rest.
function collectWith(inout heap: Heap, in roots: Array<u32>): void {
  let i: usize = 0;
  while (i < roots.length) {
    heap.markHandle(roots[i]);
    i = i + 1;
  }
  heap.markEphemerons();
  heap.clearDeadWeakEntries();
  heap.sweep();
}

test "weak record: a rooted key keeps its entry and value; a dropped key loses both" {
  let heap = createHeap();
  const fixture = weakFixture(inout heap, 2);
  let roots = Array<u32>();
  roots.push(fixture.record);
  roots.push(fixture.keys[0]);
  collectWith(inout heap, in roots);
  expect(heap.weakSize(fixture.record)).toEqual(1);
  expect(heap.weakFind(fixture.record, fixture.keys[0]) >= 0).toEqual(true);
  expect(heap.tagOf(fixture.values[0])).toEqual(TAG_OBJECT);
  expect(heap.isReleased(fixture.keys[1])).toEqual(true);
  expect(heap.isReleased(fixture.values[1])).toEqual(true);
  expect(heap.weakCleared).toEqual(1);
  expect(heap.weakRecords.length).toEqual(0);
}

test "weak record: a value referring back to its own key is collected with it" {
  let heap = createHeap();
  const record = heap.allocateWeakRecord(2);
  const key = heap.allocateObject(0);
  const value = heap.allocateObject(0);
  heap.objectSet(value, 12345, cellValue(key));
  heap.weakPut(record, key, cellValue(value));
  let roots = Array<u32>();
  roots.push(record);
  collectWith(inout heap, in roots);
  expect(heap.weakSize(record)).toEqual(0);
  expect(heap.isReleased(key)).toEqual(true);
  expect(heap.isReleased(value)).toEqual(true);
}

test "weak record: a value rooted elsewhere survives its dead key's entry" {
  let heap = createHeap();
  const fixture = weakFixture(inout heap, 1);
  let roots = Array<u32>();
  roots.push(fixture.record);
  roots.push(fixture.values[0]);
  collectWith(inout heap, in roots);
  expect(heap.weakSize(fixture.record)).toEqual(0);
  expect(heap.isReleased(fixture.keys[0])).toEqual(true);
  expect(heap.tagOf(fixture.values[0])).toEqual(TAG_OBJECT);
}

test "weak record: keys reached only through another record's value, in both discovery orders" {
  // A: k1 -> holder{k2}; B: k2 -> v2. Only k1 is rooted. Whichever
  // record is reached first, v2 survives and the fixpoint takes the
  // passes it needs.
  let order: u32 = 0;
  while (order < 2) {
    let heap = createHeap();
    const a = heap.allocateWeakRecord(2);
    const b = heap.allocateWeakRecord(2);
    const k1 = heap.allocateObject(0);
    const k2 = heap.allocateObject(0);
    const holder = heap.allocateObject(0);
    heap.objectSet(holder, 777, cellValue(k2));
    const v2 = heap.allocateObject(0);
    heap.weakPut(a, k1, cellValue(holder));
    heap.weakPut(b, k2, cellValue(v2));
    let roots = Array<u32>();
    if (order == 0) {
      roots.push(a);
      roots.push(b);
    } else {
      roots.push(b);
      roots.push(a);
    }
    roots.push(k1);
    collectWith(inout heap, in roots);
    expect(heap.tagOf(k2)).toEqual(TAG_OBJECT);
    expect(heap.tagOf(v2)).toEqual(TAG_OBJECT);
    expect(heap.weakSize(b)).toEqual(1);
    // The pending index did the work: the verification scan found nothing.
    expect(heap.ephemeronPasses).toEqual(1);
    expect(heap.pendingCount).toEqual(0);
    order = order + 1;
  }
}

test "weak record: a record discovered through a value joins the fixpoint" {
  // Root: k1 in A; A's value holds record B (as a WeakMap would); B maps
  // k1 -> v. B is reached only by marking A's value.
  let heap = createHeap();
  const a = heap.allocateWeakRecord(2);
  const b = heap.allocateWeakRecord(2);
  const k1 = heap.allocateObject(0);
  const carrier = heap.allocateObject(0);
  heap.objectSet(carrier, 555, cellValue(b));
  const v = heap.allocateObject(0);
  heap.weakPut(a, k1, cellValue(carrier));
  heap.weakPut(b, k1, cellValue(v));
  let roots = Array<u32>();
  roots.push(a);
  roots.push(k1);
  collectWith(inout heap, in roots);
  expect(heap.tagOf(b)).toEqual(TAG_WEAK_RECORD);
  expect(heap.tagOf(v)).toEqual(TAG_OBJECT);
  expect(heap.weakSize(b)).toEqual(1);
}

test "weak record: a long chain in reverse discovery order needs no repeated scan" {
  // Record i maps key i to a holder of key i + 1; the records are rooted
  // last-first; only key 0 is rooted. Every key survives; the pending
  // index activates each link as its key is traced, so the verification
  // scan finds nothing and the work stays linear.
  let heap = createHeap();
  const links: u32 = 40;
  let records = Array<u32>();
  let keys = Array<u32>();
  let i: u32 = 0;
  while (i <= links) {
    keys.push(heap.allocateObject(0));
    i = i + 1;
  }
  i = 0;
  while (i < links) {
    const record = heap.allocateWeakRecord(2);
    const holder = heap.allocateObject(0);
    heap.objectSet(holder, 900 + i, cellValue(keys[usize(i + 1)]));
    heap.weakPut(record, keys[usize(i)], cellValue(holder));
    records.push(record);
    i = i + 1;
  }
  let roots = Array<u32>();
  i = links;
  while (i > 0) {
    i = i - 1;
    roots.push(records[usize(i)]);
  }
  roots.push(keys[0]);
  collectWith(inout heap, in roots);
  i = 0;
  while (i <= links) {
    expect(heap.tagOf(keys[usize(i)])).toEqual(TAG_OBJECT);
    i = i + 1;
  }
  expect(heap.ephemeronPasses).toEqual(1);
  // Each entry was examined once at registration and once by the scan.
  expect(heap.weakVisits <= links * 2).toEqual(true);
}

test "weak record: a shared key dropped clears it from every record; an unreachable record keeps nothing alive" {
  let heap = createHeap();
  const a = heap.allocateWeakRecord(2);
  const b = heap.allocateWeakRecord(2);
  const shared = heap.allocateObject(0);
  const va = heap.allocateObject(0);
  const vb = heap.allocateObject(0);
  heap.weakPut(a, shared, cellValue(va));
  heap.weakPut(b, shared, cellValue(vb));
  const orphan = heap.allocateWeakRecord(2);
  const orphanKey = heap.allocateObject(0);
  const orphanValue = heap.allocateObject(0);
  heap.weakPut(orphan, orphanKey, cellValue(orphanValue));
  let roots = Array<u32>();
  roots.push(a);
  roots.push(b);
  collectWith(inout heap, in roots);
  expect(heap.weakSize(a)).toEqual(0);
  expect(heap.weakSize(b)).toEqual(0);
  expect(heap.isReleased(va)).toEqual(true);
  expect(heap.isReleased(vb)).toEqual(true);
  expect(heap.isReleased(orphan)).toEqual(true);
  expect(heap.isReleased(orphanKey)).toEqual(true);
  expect(heap.isReleased(orphanValue)).toEqual(true);
}

test "weak record: one key across many records, kept or dropped, and the scratch released" {
  let heap = createHeap();
  const hot = heap.allocateObject(0);
  const cold = heap.allocateObject(0);
  let records = Array<u32>();
  let hotValues = Array<u32>();
  let i: u32 = 0;
  while (i < 20000) {
    const record = heap.allocateWeakRecord(2);
    heap.weakPut(record, cold, cellValue(heap.allocateObject(0)));
    const value = heap.allocateObject(0);
    heap.weakPut(record, hot, cellValue(value));
    records.push(record);
    hotValues.push(value);
    i = i + 1;
  }
  const holder = heap.allocateArray(0);
  i = 0;
  while (i < 20000) {
    heap.arraySet(holder, i, cellValue(records[usize(i)]));
    i = i + 1;
  }
  let roots = Array<u32>();
  roots.push(holder);
  roots.push(hot);
  collectWith(inout heap, in roots);
  i = 0;
  while (i < 20000) {
    expect(heap.weakSize(records[usize(i)])).toEqual(1);
    expect(heap.tagOf(hotValues[usize(i)])).toEqual(TAG_OBJECT);
    i = i + 1;
  }
  expect(heap.isReleased(cold)).toEqual(true);
  expect(heap.weakCleared).toEqual(20000);
  expect(heap.ephemeronPasses).toEqual(1);
  expect(heap.pendingCount).toEqual(0);
  expect(heap.pendingScratchBytes() <= 262144).toEqual(true);
}

test "weak record: a reused handle is not the old key" {
  let heap = createHeap();
  const fixture = weakFixture(inout heap, 1);
  const oldKey = fixture.keys[0];
  let roots = Array<u32>();
  roots.push(fixture.record);
  collectWith(inout heap, in roots);
  expect(heap.weakSize(fixture.record)).toEqual(0);
  // The freed handles come back on allocation; whichever order, the
  // old key's handle names a new object the record does not hold.
  const first = heap.allocateObject(0);
  const second = heap.allocateObject(0);
  expect(first == oldKey || second == oldKey).toEqual(true);
  expect(heap.weakFind(fixture.record, first)).toEqual(-1);
  expect(heap.weakFind(fixture.record, second)).toEqual(-1);
}

test "weak record: storage follows the live count across insert, drop, collect cycles" {
  let heap = createHeap();
  const record = heap.allocateWeakRecord(2);
  const kept = heap.allocateObject(0);
  heap.weakPut(record, kept, int32Value(1));
  let peakIndex: u32 = 0;
  let cycle: u32 = 0;
  while (cycle < 200) {
    let i: u32 = 0;
    while (i < 50) {
      const key = heap.allocateObject(0);
      heap.weakPut(record, key, int32Value(i32(i)));
      i = i + 1;
    }
    let roots = Array<u32>();
    roots.push(record);
    roots.push(kept);
    collectWith(inout heap, in roots);
    expect(heap.weakSize(record)).toEqual(1);
    const keys = asCell(heap.slot(record, WEAK_KEYS));
    expect(heap.arrayLength(keys)).toEqual(1);
    const index = asCell(heap.slot(record, WEAK_INDEX));
    if (heap.arrayLength(index) > peakIndex) peakIndex = heap.arrayLength(index);
    cycle = cycle + 1;
  }
  expect(peakIndex <= 128).toEqual(true);
  expect(heap.weakFind(record, kept) >= 0).toEqual(true);
  expect(heap.weakCleared).toEqual(10000);
}

test "weak record: explicit deletes and reinserts reclaim storage without a collection" {
  let heap = createHeap();
  const record = heap.allocateWeakRecord(2);
  let live = Array<u32>();
  let round: u32 = 0;
  while (round < 100) {
    let i: u32 = 0;
    while (i < 20) {
      const key = heap.allocateObject(0);
      heap.weakPut(record, key, int32Value(i32(i)));
      live.push(key);
      i = i + 1;
    }
    // Drop all but the last four.
    while (live.length > 4) {
      match (live.pop()) {
        some(key) => {
          heap.weakDelete(record, key);
        }
        none => {
        }
      }
    }
    round = round + 1;
  }
  expect(heap.weakSize(record)).toEqual(4);
  const keys = asCell(heap.slot(record, WEAK_KEYS));
  expect(heap.arrayLength(keys) <= 64).toEqual(true);
  const index = asCell(heap.slot(record, WEAK_INDEX));
  expect(heap.arrayLength(index) <= 64).toEqual(true);
  let i: usize = 0;
  while (i < live.length) {
    expect(heap.weakFind(record, live[i]) >= 0).toEqual(true);
    i = i + 1;
  }
}
