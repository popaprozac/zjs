// Handle-based cell heap.
//
// The Phase 0 spike measured this against a malloc/raw-pointer heap: it costs
// roughly 5% on a dispatch-heavy microbenchmark, and buys a great deal. No raw
// pointer touches the object graph, so the GC will operate over Z-owned values
// with ownership intact; handles are position-independent, which makes the
// mmap-ready zero-copy AOT bundle nearly free; and it is trivially
// cross-platform. See spike/RESULTS.md.
//
// Layout is two parallel arrays rather than one packed slab:
//
//   headers[handle]  -> tag, mark bit, and the cell's slot range
//   slots[start..]   -> the cell's payload words, contiguous
//
// A handle indexes `headers`. Handle 0 is reserved and never allocated, so a
// live cell handle is always >= 1 and `cellValue(0)` can mean "no cell".
//
// Collection is mark-sweep with stable handles, in two generations (see
// Generations below). Marking walks from the roots the runtime supplies;
// a full collection's sweep frees dead headers onto a free list for reuse
// and compacts every live cell's slots into a fresh arena, so an object
// that outgrew its range leaves no permanent hole; a minor collection
// does the same for the cells allocated since the last collection only.
// Nothing outside the heap has to be updated: a handle never changes,
// only the slot range behind it.

import { utf8ToUnits, unitsToUtf8, unitsToWtf8, isAsciiBytes, isNarrowUnits, unitsToLatin1 } from "./text.zs";
import { expect } from "std/test";
import { replace } from "std/memory";
import { Value, undefinedValue, deletedValue, isDeleted, cellValue, asCell, isCell, int32Value, asInt32, isInt32, isNumber, asDouble } from "./value.zs";

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
// A Map's or Set's entries, kept outside the slot arena: see Tables.
export const TAG_TABLE: u8 = 18;

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

// The most slots `new Array(length)` makes before any element is written.
const ARRAY_PRESIZE: u32 = 65536;

// Per-cell flags.
export const FLAG_NON_EXTENSIBLE: u8 = 1;
export const FLAG_LENGTH_READONLY: u8 = 2;
// A symbol cell minted as a class private name: never an own key.
export const FLAG_PRIVATE_NAME: u8 = 4;
// On an array (the same bit, which only symbols otherwise use): some
// element has attributes other than the default, kept in the heap's
// element attribute tables.
export const FLAG_ELEMENT_ATTRS: u8 = 4;
// A string cell that is the runtime's atom for its bytes.
export const FLAG_INTERNED: u8 = 8;
// On an array (the same bit, which only strings otherwise use): its
// elements past its slots live in its bag under their index names,
// written there because they landed too far past the slots to fill.
export const FLAG_SPARSE: u8 = 8;
// A string cell whose units are stored two bytes each (some unit is above
// 0xFF); otherwise one byte per unit.
export const FLAG_WIDE: u8 = 16;
// A string cell used as an engine-internal key: never interned by
// content, so no program string can name it.
export const FLAG_HIDDEN: u8 = 32;
// A symbol from the global registry (Symbol.for): not weakly holdable.
export const FLAG_REGISTERED_SYMBOL: u8 = 64;
// On a function or closure cell (the same bit, which only strings
// otherwise use): its code is a leaf, which a call may run without a
// frame (the runtime's runLeaf).
export const FLAG_LEAF: u8 = 16;
// A string cell that is the canonical spelling of an array index, set
// when it is interned: the key it makes names an element.
export const FLAG_INDEX_KEY: u8 = 128;

struct CellHeader {
  tag: u8;
  // Between collections, whether the cell is old (see Generations).
  marked: boolean;
  // FLAG_* bits: extensibility, an array's read-only length.
  flags: u8;
  // An old cell's: whether it is in the remembered set. A young cell's:
  // whether growSlots has moved its slots since it was allocated.
  remembered: boolean;
  // Where the cell's slots begin in the arena. A string has no slots, and
  // its slotStart holds its length in storage bytes instead (its buffer
  // may be longer: see the string storage below), and its slotCount its
  // hash once computed (see stringHash).
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
  // The attributes of every property the class has, by slot: an
  // object's attributes are its class's, so objects of one shape share
  // them and a cache that matched the class knows them.
  slotAttrs: Array<u8>;
  // The classes reached from this one: by name and attributes.
  transitionNames: Array<u32>;
  transitionAttrs: Array<u8>;
  transitionChildren: Array<u32>;
}

export const DICT_BIT: u32 = 2147483648;

// A string buffer's reference word: the count of strings over it, and
// whether a concatenation made it (and so may append to it in place).
// A string cell's payload with this bit set is an offset into the byte
// arena; without it, an index into `strings`.
const ARENA_BIT: u32 = 0x8000_0000;
// Strings of up to this many storage bytes live in the arena.
const SMALL_STRING_BYTES: u32 = 256;
// Arena bytes beyond twice the live ones before a collection compacts it.
const SMALL_ARENA_SLACK: usize = 65536;

const BUFFER_APPENDABLE: u32 = 0x8000_0000;
const BUFFER_REFS: u32 = 0x7FFF_FFFF;

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

// A Map's or Set's entries (see Tables).
struct Table {
  keys: Array<Value>;
  values: Array<Value>;
  hashes: Array<u32>;
  index: Array<i32>;
  live: u32;
  kind: i32;
}

const TABLE_EMPTY: i32 = -1;
const TABLE_REMOVED: i32 = -2;

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
  // Each pair's attributes.
  attrs: Array<u8>;
}

// An array's element attributes, for an array whose elements do not all
// have the default ones (FLAG_ELEMENT_ATTRS on it): by index, the default
// past the end.
struct ElementAttrs {
  owner: u32;
  attrs: Array<u8>;
}

// String cells keep their bytes in a Z-owned Array<u8>, held in a side
// table indexed through the cell header's payload. The reference stores
// plain bytes with a byte length and byte-indexed access -- including
// embedded NULs, which is why the storage is bytes rather than a Z String.
export struct Heap {
  headers: Array<CellHeader>;
  slots: Array<Value>;
  // A full collection's sorting scratch (see slideSlots), kept between
  // collections.
  slideCounts: Array<u32>;
  slideOrder: Array<u32>;
  // Element attribute tables for the arrays that have any, and an
  // open-addressed index from array handle to entry (entry + 1, 0 empty).
  elementAttrs: Array<ElementAttrs>;
  elementAttrIndex: Array<u32>;
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
  // String storage buffers. A buffer can back several strings: each sees
  // the prefix its own length names. `bufferRefs` counts, per buffer, the
  // strings over it, with BUFFER_APPENDABLE set on a buffer a
  // concatenation made (see concatStorage).
  strings: Array<Array<u8>>;
  // Small strings' storage, one byte arena filled from its top (see
  // Strings).
  smallBytes: Array<u8>;
  // The live small-string bytes the last collection counted: the arena
  // is compacted only once it holds twice that and some slack, so a
  // long-lived string is copied once per doubling, not every collection.
  smallLiveBytes: usize;
  bufferRefs: Array<u32>;
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
  // Map and Set tables, one per TAG_TABLE cell, reused after a sweep.
  tables: Array<Table>;
  freeTables: Array<u32>;
  freeTableCount: usize;
  // Dictionary-mode indexes, one per such object, reused after a sweep.
  dictionaries: Array<Dictionary>;
  freeDictionaries: Array<u32>;
  freeDictionaryCount: usize;
  // The property count past which an object leaves the class tree.
  dictThreshold: u32;
  // Whether any object that is not an array has ever been given a
  // property whose key names an array index. Until then a write to an
  // absent index of an ordinary array can take the fast path: no
  // prototype an array could inherit from holds an element. Once set it
  // stays set, so a chain replaced later cannot bring in an element the
  // fast path misses: whatever object holds one set this when it was
  // given it.
  indexKeysDefined: boolean;
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

  // --- Generations ---
  //
  // Most cells die young, so most collections look only at the cells
  // allocated since the last one. A cell is young until it survives a
  // collection, then old. The mark bit says which between collections:
  // a sweep leaves its survivors marked, and a new cell starts unmarked.
  // A minor collection marks from the roots as a full one does, and
  // stops at any marked cell, so it traces only young cells; its sweep
  // walks the young cells' log instead of the whole table, frees the
  // unmarked ones, and leaves the survivors marked, old. A full
  // collection clears every mark first.
  //
  // An old cell that comes to hold a young one, which only a store can
  // bring about (setSlot, setLink, setObjectProto, a table's keys and
  // values), is listed in the remembered set, and a minor collection
  // traces the listed cells as roots. Weak entries are held strongly by
  // a minor collection: their keys wait for a full one to be let go.
  //
  // The young cells need no list of their own: allocation takes handles
  // from the free list, top down, until it is empty, then from the top
  // of the table, so the young cells are the free list's entries from
  // its length at the last collection down to its length now, then the
  // handles from the table's extent then to its extent now, in the order
  // they were allocated (see sweepYoung).
  //
  // The arenas are filled from the top, so everything allocated since
  // the last collection lies above `tailBase` in the slot arena and
  // `byteTailBase` in the byte arena, a young cell's first range in the
  // order of the cells. The ranges growSlots takes there are logged, the
  // range's start in the high word and the handle in the low one; a
  // minor sweep slides the ranges still in use down over the rest, in
  // order, and cuts the arena back, and does the same for young strings'
  // bytes.
  cycleFreeCount: usize;
  cycleExtent: usize;
  growLog: Array<u64>;
  rememberedCells: Array<u32>;
  // Slots of large cells and entries of large tables given young cells,
  // the index in the high word and the holder's handle in the low one.
  rememberedSlots: Array<u64>;
  // Young cells a minor sweep found dead, listed free once it is done;
  // dead atoms, freed once the runtime has dropped them from its table.
  deadYoung: Array<u32>;
  deadAtoms: Array<u32>;
  tailBase: usize;
  byteTailBase: usize;
  // Set while a minor collection marks.
  minorCollection: boolean;
  // Allocations between minor collections; 0 makes every collection a
  // full one.
  nurseryCells: u32;
  // Cells (and their slots) that minor collections found alive since the
  // last full one, and how many cells promoted call for the next full
  // one: the floor, or the growth multiple of what the last one kept.
  promotedCells: u32;
  promotedSlots: usize;
  majorThreshold: u32;
  // What the last full collection kept.
  majorCells: u32;
  majorSlots: usize;
  minorCollections: u32;

  // These are methods rather than free functions for a concrete reason.
  // Z rejects `inout` on a place expression -- `allocate(inout
  // registry.slots[i].heap, ...)` is an error, because an `inout` argument
  // must be a plain mutable binding. A method call on the same projection is
  // accepted, so the heap API has to be methods for the engine to reach a
  // per-context heap at all.
  function allocate(inout this, tag: u8, slotCount: u32): u32 {
    const start = u32(this.slots.length);
    if (this.slots.length + usize(slotCount) > this.slots.capacity) this.growArena(usize(slotCount));
    this.slots.appendRepeated(undefinedValue(), usize(slotCount));
    this.allocatedSinceCollect = this.allocatedSinceCollect + 1;
    const header = CellHeader({
      tag: tag,
      marked: false,
      flags: 0,
      remembered: false,
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
      if (this.headers.length == this.headers.capacity) this.headers.reserveCapacity(grownCapacity(this.headers.capacity, 1));
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
  // The runtime starts a collection with `beginMajor` or `beginMinor`,
  // marks its roots with `markValue`, and ends it with `sweep` or
  // `sweepYoung`.

  // Whether the next collection should be a full one: the old cells
  // have grown past the policy's bound, or there is no young generation.
  function majorDue(): boolean {
    return this.nurseryCells == 0 || this.promotedCells >= this.majorThreshold;
  }

  // A full collection starts from no marks: every cell, old or young, is
  // unmarked until reached, and the remembered set, which only a minor
  // collection reads, is emptied.
  function beginMajor(inout this): void {
    let handle: usize = 1;
    while (handle < this.headerCount) {
      this.headers[handle].marked = false;
      this.headers[handle].remembered = false;
      handle = handle + 1;
    }
    this.rememberedCells.clear();
    this.rememberedSlots.clear();
    this.minorCollection = false;
    this.markedCells = 0;
    this.markedSlots = 0;
    this.weakVisits = 0;
  }

  function beginMinor(inout this): void {
    this.minorCollection = true;
    this.markedCells = 0;
    this.markedSlots = 0;
    this.weakVisits = 0;
  }

  // The write barrier's slow half: `holder` is old and has just been
  // given a reference to `target`; when that is young and the holder not
  // yet listed, it is listed. Stores into young cells never get here.
  function remember(inout this, holder: u32, target: u32): void {
    if (this.cellHeader(holder).remembered || this.cellHeader(target).marked) return;
    this.headers[usize(holder)].remembered = true;
    this.rememberedCells.push(holder);
  }

  // The slow half for a value stored in an old cell's slot, or in an old
  // table's entry. A large cell is listed by the slot, and a large table
  // by the entry, that was given the young cell, so a minor collection
  // traces what changed and not all of it; past a bound on those, by the
  // whole cell as any other.
  function rememberStore(inout this, holder: u32, index: u32, value: Value): void {
    if (!isCell(value)) return;
    const target = asCell(value);
    if (this.cellHeader(holder).remembered || this.cellHeader(target).marked) return;
    let size = usize(this.cellHeader(holder).slotCount);
    if (this.cellHeader(holder).tag == TAG_TABLE) size = this.tables[usize(this.cellHeader(holder).payload)].keys.length;
    if (size >= LARGE_CELL_SLOTS && this.rememberedSlots.length < REMEMBERED_SLOTS_LIMIT) {
      this.rememberedSlots.push((u64(index) << 32) | u64(holder));
      return;
    }
    this.headers[usize(holder)].remembered = true;
    this.rememberedCells.push(holder);
  }

  // A minor collection's other roots: what the listed old cells, slots,
  // and table entries hold.
  function traceRemembered(inout this): void {
    let at: usize = 0;
    while (at < this.rememberedCells.length) {
      const holder = this.rememberedCells[at];
      this.traceCell(holder);
      this.drainMarks();
      at = at + 1;
    }
    at = 0;
    while (at < this.rememberedSlots.length) {
      const entry = this.rememberedSlots[at];
      const holder = u32(entry & 0xFFFF_FFFF);
      const index = u32(entry >> 32);
      if (this.cellHeader(holder).tag == TAG_TABLE) {
        const table = usize(this.cellHeader(holder).payload);
        if (usize(index) < this.tables[table].keys.length) {
          const key = this.tables[table].keys[usize(index)];
          this.markValue(key);
          const value = this.tables[table].values[usize(index)];
          this.markValue(value);
        }
      } else if (index < this.cellHeader(holder).slotCount) {
        const value = this.slot(holder, index);
        this.markValue(value);
      }
      at = at + 1;
    }
  }

  function markValue(inout this, value: Value): void {
    if (!isCell(value)) return;
    this.markHandle(asCell(value));
  }

  function markHandle(inout this, handle: u32): void {
    if (handle == 0) return;
    if (this.cellHeader(handle).marked) return;
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
      if (this.cellHeader(handle).tag != TAG_STRING) this.markedSlots = this.markedSlots + usize(this.cellHeader(handle).slotCount);
      // A key some weak record was waiting on: its values go live now.
      if (this.pendingCount > 0) this.activatePending(handle);
      this.traceCell(handle);
    }
  }

  // Mark and queue what one cell refers to.
  function traceCell(inout this, handle: u32): void {
    const tag = this.cellHeader(handle).tag;
    const link = this.cellHeader(handle).link;
    if (link != 0 && !this.cellHeader(link).marked) {
      this.headers[usize(link)].marked = true;
      this.pushMark(link);
    }
    // A table's keys and values are traced through its cell.
    if (tag == TAG_TABLE) {
      const table = usize(this.cellHeader(handle).payload);
      this.markTable(table);
    }
    // In a full collection a weak record is traced like any cell (its
    // index and counts, and the two weak arrays as cells), queued for the
    // clearing pass, and its entries registered: a marked key's value is
    // marked now, the rest wait on their keys. A weak array's elements
    // are never traced from here. A minor collection traces both like
    // any other cell.
    if (tag == TAG_WEAK_RECORD && !this.minorCollection) {
      this.weakRecords.push(handle);
      this.registerWeakRecord(handle);
    }
    // Slots hold values for every tag but strings.
    if (tag == TAG_STRING || (tag == TAG_WEAK_ARRAY && !this.minorCollection)) return;
    const start = this.cellHeader(handle).slotStart;
    const count = this.cellHeader(handle).slotCount;
    let index: u32 = 0;
    while (index < count) {
      const value = this.slots[usize(start + index)];
      if (isCell(value) && asCell(value) != 0 && !this.cellHeader(asCell(value)).marked) {
        this.headers[usize(asCell(value))].marked = true;
        this.pushMark(asCell(value));
      }
      index = index + 1;
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

  // Free every unmarked cell and compact what the survivors keep in the
  // arenas in place. When a large table's survivors all sit in its lowest
  // quarter, the dead cells above the highest of them are not listed for
  // reuse: the table's extent is cut back to that survivor, so a
  // collection after a spike costs what is alive and not what once was,
  // and a table left far larger than it needs gives its storage back.
  //
  // Compaction slides: the survivors' slot ranges, taken in arena order,
  // move down over the dead ones, and the arena is cut back after the
  // last (see slideSlots); the small strings' bytes the same way once the
  // byte arena holds twice what is live (slideBytes). Nothing is copied
  // into a second arena, which the allocator would keep resident after
  // the first was freed.
  function sweep(inout this): void {
    const count = u32(this.headerCount);
    const liveSlots = this.markedSlots;
    const survivors = this.markedCells;
    const proportional = u32(u64(survivors) * u64(this.collectGrowthPercent) / 100);
    const nextThreshold = proportional > this.collectFloor ? proportional : this.collectFloor;
    let cycleSlots: usize = 0;
    if (this.slots.length > this.slotsAfterSweep) cycleSlots = this.slots.length - this.slotsAfterSweep;
    const compactBytes = this.smallBytes.length >= this.smallLiveBytes * 2 + SMALL_ARENA_SLACK;
    let liveBytes: usize = 0;
    // The collector's sorting scratch, locals while they are used.
    let counts = replace(inout this.slideCounts, Array<u32>());
    let order = replace(inout this.slideOrder, Array<u32>());
    fillZeros(inout counts, (this.slots.length >> usize(SLIDE_SLOT_SHIFT)) + 1);
    let ranges: usize = 0;
    // The highest survivor, found by looking down from the top -- but
    // the table is cut back to it only when that is worth a pass over
    // the free list: a large table that would shrink at least fourfold.
    // A small heap's top survivor moves at every collection, and its
    // table is cheap to walk whole.
    let top: u32 = count - 1;
    if (usize(count) >= HANDLE_TABLE_CUT_AT) {
      while (top >= 1 && !this.cellHeader(top).marked) { top = top - 1; }
      if ((usize(top) + 1) * 4 >= usize(count)) top = count - 1;
    }
    const cutting = top != count - 1;
    // Handles are visited from the top down, so the cells this sweep
    // frees are listed highest first and the next allocations take the
    // lowest of them: survivors gather low in the table, which is what
    // lets a later sweep cut it back. Each survivor's slot range is
    // counted into its bucket of the arena for the slide.
    const listBelow: u32 = cutting ? top : count;
    let handle: u32 = count - 1;
    while (handle >= 1) {
      const header = this.cellHeader(handle);
      const tag = header.tag;
      if (tag == TAG_FREE) {
        handle = handle - 1;
        continue;
      }
      if (!header.marked) {
        this.releaseCell(handle, tag);
        // A cell above the highest survivor is cut off with the table,
        // not listed.
        if (handle < listBelow) this.listFree(handle);
        handle = handle - 1;
        continue;
      }
      // A survivor keeps its mark: it is old now.
      if (tag == TAG_STRING) {
        if ((header.payload & ARENA_BIT) != 0) liveBytes = liveBytes + usize(header.slotStart);
      } else if (header.slotCount > 0) {
        const bucket = usize(header.slotStart >> SLIDE_SLOT_SHIFT);
        counts[bucket] = counts[bucket] + 1;
        ranges = ranges + 1;
      }
      handle = handle - 1;
    }
    if (cutting) this.trimHandleTable(top);
    this.slideSlots(inout counts, inout order, ranges);
    this.smallLiveBytes = liveBytes;
    if (compactBytes) this.smallLiveBytes = this.slideBytes(inout counts, inout order);
    // The scratch is kept for the next collection unless a burst grew it
    // far past what the heap needs.
    if (counts.capacity <= (this.slots.length >> usize(SLIDE_SLOT_SHIFT)) * 4 + LOG_RETAIN_ENTRIES) {
      const emptyCounts = replace(inout this.slideCounts, move counts);
    }
    if (order.capacity <= usize(survivors) * 2 + LOG_RETAIN_ENTRIES) {
      const emptyOrder = replace(inout this.slideOrder, move order);
    }
    this.cellsBeforeCycle = this.cellsBeforeCycle + f64(this.allocatedSinceCollect);
    this.slotsBeforeCycle = this.slotsBeforeCycle + f64(cycleSlots);
    this.slotsAfterSweep = this.slots.length;
    this.allocatedSinceCollect = 0;
    this.majorThreshold = nextThreshold;
    this.collectThreshold = this.nurseryCells == 0 ? nextThreshold : this.nurseryCells;
    this.majorCells = survivors;
    this.majorSlots = liveSlots;
    this.promotedCells = 0;
    this.promotedSlots = 0;
    this.endCycle();
  }

  // Slide every surviving slot range down in arena order. `counts` holds,
  // per bucket of 2^SLIDE_SLOT_SHIFT arena slots, how many ranges start in
  // it; the ranges are placed bucket by bucket into `order`, a pass of
  // insertion sort puts each bucket's few in order, and each range moves
  // to the cursor (never up: everything below it is placed).
  function slideSlots(inout this, inout counts: Array<u32>, inout order: Array<u32>, ranges: usize): void {
    prefixSums(inout counts);
    order.clear();
    fillZeros(inout order, ranges);
    let handle: usize = 1;
    while (handle < this.headerCount) {
      const header = this.headers[handle];
      if (header.tag != TAG_FREE && header.tag != TAG_STRING && header.slotCount > 0) {
        const bucket = usize(header.slotStart >> SLIDE_SLOT_SHIFT);
        order[usize(counts[bucket])] = u32(handle);
        counts[bucket] = counts[bucket] + 1;
      }
      handle = handle + 1;
    }
    let i: usize = 1;
    while (i < order.length) {
      const moving = order[i];
      const key = this.cellHeader(moving).slotStart;
      let j = i;
      while (j > 0 && this.headers[usize(order[j - 1])].slotStart > key) {
        order[j] = order[j - 1];
        j = j - 1;
      }
      order[j] = moving;
      i = i + 1;
    }
    let cursor: usize = 0;
    i = 0;
    while (i < order.length) {
      const moving = order[i];
      const start = this.cellHeader(moving).slotStart;
      const slotCount = this.cellHeader(moving).slotCount;
      cursor = this.slideRange(moving, start, slotCount, cursor);
      i = i + 1;
    }
    while (this.slots.length > cursor) {
      const dropped = this.slots.pop();
    }
  }

  // Slide the surviving small strings' bytes down in arena order, as
  // slideSlots does slot ranges; the bytes kept. Strings sharing a start
  // (a run concatenation made; see sweepYoung) move together: the first
  // of a run takes the cursor and each other copies only what it adds.
  function slideBytes(inout this, inout counts: Array<u32>, inout order: Array<u32>): usize {
    counts.clear();
    fillZeros(inout counts, (this.smallBytes.length >> usize(SLIDE_BYTE_SHIFT)) + 1);
    let strings: usize = 0;
    let handle: usize = 1;
    while (handle < this.headerCount) {
      const header = this.headers[handle];
      if (header.tag == TAG_STRING && (header.payload & ARENA_BIT) != 0) {
        if (header.slotStart == 0) {
          // An empty string keeps no bytes.
          this.headers[handle].payload = ARENA_BIT;
        } else {
          const bucket = usize((header.payload & ~ARENA_BIT) >> SLIDE_BYTE_SHIFT);
          counts[bucket] = counts[bucket] + 1;
          strings = strings + 1;
        }
      }
      handle = handle + 1;
    }
    prefixSums(inout counts);
    order.clear();
    fillZeros(inout order, strings);
    handle = 1;
    while (handle < this.headerCount) {
      const header = this.headers[handle];
      if (header.tag == TAG_STRING && (header.payload & ARENA_BIT) != 0 && header.slotStart != 0) {
        const bucket = usize((header.payload & ~ARENA_BIT) >> SLIDE_BYTE_SHIFT);
        order[usize(counts[bucket])] = u32(handle);
        counts[bucket] = counts[bucket] + 1;
      }
      handle = handle + 1;
    }
    let i: usize = 1;
    while (i < order.length) {
      const moving = order[i];
      const key = this.cellHeader(moving).payload;
      let j = i;
      while (j > 0 && this.headers[usize(order[j - 1])].payload > key) {
        order[j] = order[j - 1];
        j = j - 1;
      }
      order[j] = moving;
      i = i + 1;
    }
    let cursor: usize = 0;
    let runOrigin: usize = 0;
    let runTarget: usize = 0;
    let runLength: usize = 0;
    i = 0;
    while (i < order.length) {
      const moving = order[i];
      const origin = usize(this.cellHeader(moving).payload & ~ARENA_BIT);
      const length = usize(this.cellHeader(moving).slotStart);
      let copied: usize = 0;
      if (i > 0 && origin == runOrigin) {
        copied = runLength;
      } else {
        runOrigin = origin;
        runTarget = cursor;
        runLength = 0;
      }
      let k = copied;
      while (k < length) {
        const byte = this.smallBytes[origin + k];
        this.smallBytes[runTarget + k] = byte;
        k = k + 1;
      }
      if (length > runLength) runLength = length;
      if (runTarget + runLength > cursor) cursor = runTarget + runLength;
      this.headers[usize(moving)].payload = ARENA_BIT | u32(runTarget);
      i = i + 1;
    }
    while (this.smallBytes.length > cursor) {
      const dropped = this.smallBytes.pop();
    }
    return cursor;
  }

  // What every sweep leaves: no young cells, so an empty log and
  // remembered set, and the arenas' tops as the next cycle's bases.
  function endCycle(inout this): void {
    let at: usize = 0;
    while (at < this.rememberedCells.length) {
      const holder = this.rememberedCells[at];
      this.headers[usize(holder)].remembered = false;
      at = at + 1;
    }
    // Lists a burst grew far past the usual are let go rather than kept.
    if (this.growLog.capacity > LOG_RETAIN_ENTRIES) {
      const unusedLog = replace(inout this.growLog, Array<u64>());
    } else {
      this.growLog.clear();
    }
    if (this.rememberedCells.capacity > LOG_RETAIN_ENTRIES) {
      const unusedSet = replace(inout this.rememberedCells, Array<u32>());
    } else {
      this.rememberedCells.clear();
    }
    if (this.rememberedSlots.capacity > LOG_RETAIN_ENTRIES) {
      const unusedSlots = replace(inout this.rememberedSlots, Array<u64>());
    } else {
      this.rememberedSlots.clear();
    }
    if (this.deadYoung.capacity > usize(this.nurseryCells) + LOG_RETAIN_ENTRIES) {
      const unusedDead = replace(inout this.deadYoung, Array<u32>());
    }
    this.minorCollection = false;
    this.tailBase = this.slots.length;
    this.byteTailBase = this.smallBytes.length;
    this.cycleFreeCount = this.freeHandleCount;
    this.cycleExtent = this.headerCount;
    this.collections = this.collections + 1;
  }

  // Give back what a dead cell owns outside its slots, and free its
  // header. A dead arena string's bytes are simply not copied.
  function releaseCell(inout this, handle: u32, tag: u8): void {
    if (tag == TAG_OBJECT && (this.cellHeader(handle).payload & DICT_BIT) != 0) {
      this.releaseDictionary(this.cellHeader(handle).payload & (DICT_BIT - 1));
    }
    if (tag == TAG_STRING && (this.cellHeader(handle).payload & ARENA_BIT) == 0) {
      const stringIndex = this.cellHeader(handle).payload;
      this.releaseStringBuffer(stringIndex);
    }
    if (tag == TAG_TABLE) {
      const table = this.cellHeader(handle).payload;
      this.releaseTable(table);
    }
    if (tag == TAG_ARRAY && (this.cellHeader(handle).flags & FLAG_ELEMENT_ATTRS) != 0) this.releaseElementAttrs(handle);
    this.headers[usize(handle)] = CellHeader({ tag: TAG_FREE, marked: false, flags: 0, remembered: false, slotStart: 0, slotCount: 0, payload: 0, link: 0 });
  }

  // Move a cell's slots down to `cursor` (never up: everything below it
  // is already placed); the cursor past them.
  function slideRange(inout this, handle: u32, start: u32, count: u32, cursor: usize): usize {
    if (usize(start) != cursor) {
      let k: u32 = 0;
      while (k < count) {
        const kept = this.slots[usize(start + k)];
        this.slots[cursor + usize(k)] = kept;
        k = k + 1;
      }
      this.headers[usize(handle)].slotStart = u32(cursor);
    }
    return cursor + usize(count);
  }

  // The grown range the log's entry names, slid down if it is still the
  // cell's and the cell lives.
  function slideGrown(inout this, entry: usize, cursor: usize): usize {
    const logged = this.growLog[entry];
    const handle = u32(logged & 0xFFFF_FFFF);
    const start = u32(logged >> 32);
    if (this.cellHeader(handle).tag == TAG_FREE || !this.cellHeader(handle).marked) return cursor;
    if (this.cellHeader(handle).slotStart != start) return cursor;
    const count = this.cellHeader(handle).slotCount;
    return this.slideRange(handle, start, count, cursor);
  }

  function listFree(inout this, handle: u32): void {
    if (this.freeHandleCount < this.freeHandles.length) {
      this.freeHandles[this.freeHandleCount] = handle;
    } else {
      this.freeHandles.push(handle);
    }
    this.freeHandleCount = this.freeHandleCount + 1;
  }

  // The end of a minor collection: one walk over the young cells, in
  // allocation order. A dead one is freed. A survivor keeps its mark,
  // which makes it old. The ranges above `tailBase` still in use --
  // survivors' slots, and old cells' grown ones -- slide down in order
  // over the rest, and the arena is cut back after the last; young
  // strings' bytes slide down the byte arena the same way.
  //
  // Strings can share bytes: a concatenation whose left side ended at the
  // arena's top extends it in place, so a run of strings may start at
  // the same offset, each longer than the one before (see
  // concatStorage). The first of a run that survives is moved, and later
  // survivors of the same run take its new place and copy only the bytes
  // it lacks. A run that began below `byteTailBase` stays where it is.
  function sweepYoung(inout this): void {
    let cycleSlots: usize = 0;
    if (this.slots.length > this.slotsAfterSweep) cycleSlots = this.slots.length - this.slotsAfterSweep;
    let cursor = this.tailBase;
    let byteCursor = this.byteTailBase;
    // The run of strings sharing a start: where it began, where it went,
    // and how many of its bytes are there.
    let runOrigin: usize = 0;
    let runTarget: usize = 0;
    let runLength: usize = 0;
    let survivorBytes: usize = 0;
    // The next grown range, in the log.
    let grown: usize = 0;
    this.deadYoung.clear();
    this.deadAtoms.clear();
    // The young cells, as youngHandle names them, written out.
    const fromList = this.cycleFreeCount - this.freeHandleCount;
    const young = fromList + this.headerCount - this.cycleExtent;
    let at: usize = 0;
    while (at < young) {
      let handle: u32 = 0;
      if (at < fromList) {
        handle = this.freeHandles[this.cycleFreeCount - 1 - at];
      } else {
        handle = u32(this.cycleExtent + at - fromList);
      }
      at = at + 1;
      const header = this.cellHeader(handle);
      const tag = header.tag;
      if (!header.marked) {
        // An atom stays until the runtime has taken it out of its table
        // (see finishMinor); its hash is kept in its header.
        if (tag == TAG_STRING && (header.flags & FLAG_INTERNED) != 0) {
          this.deadAtoms.push(handle);
          continue;
        }
        // Most cells own nothing outside the heap.
        if ((tag == TAG_OBJECT && (header.payload & DICT_BIT) != 0) || (tag == TAG_STRING && (header.payload & ARENA_BIT) == 0) || tag == TAG_TABLE || (tag == TAG_ARRAY && (header.flags & FLAG_ELEMENT_ATTRS) != 0)) {
          this.releaseCell(handle, tag);
        } else {
          this.headers[usize(handle)] = CellHeader({ tag: TAG_FREE, marked: false, flags: 0, remembered: false, slotStart: 0, slotCount: 0, payload: 0, link: 0 });
        }
        this.deadYoung.push(handle);
        continue;
      }
      // A survivor's slots are where it was allocated unless growSlots
      // moved them, and then the log has them.
      const moved = header.remembered;
      if (moved) this.headers[usize(handle)].remembered = false;
      if (tag == TAG_STRING) {
        const payload = header.payload;
        if ((payload & ARENA_BIT) == 0) continue;
        const origin = usize(payload & ~ARENA_BIT);
        const length = usize(header.slotStart);
        survivorBytes = survivorBytes + length;
        // An empty string has no bytes to keep, and is no part of a run.
        if (length == 0) {
          this.headers[usize(handle)].payload = ARENA_BIT | u32(byteCursor);
          continue;
        }
        if (origin < this.byteTailBase) {
          // Extends a string older than the cycle: stays in place.
          if (origin != runOrigin || runTarget != origin) runLength = 0;
          runOrigin = origin;
          runTarget = origin;
          if (length > runLength) runLength = length;
          if (origin + length > byteCursor) byteCursor = origin + length;
          continue;
        }
        let copied: usize = 0;
        if (origin == runOrigin && runLength > 0) {
          copied = runLength;
        } else {
          runOrigin = origin;
          runTarget = byteCursor;
          runLength = 0;
        }
        let k = copied;
        while (k < length) {
          const byte = this.smallBytes[origin + k];
          this.smallBytes[runTarget + k] = byte;
          k = k + 1;
        }
        if (length > runLength) runLength = length;
        if (runTarget + runLength > byteCursor) byteCursor = runTarget + runLength;
        this.headers[usize(handle)].payload = ARENA_BIT | u32(runTarget);
        continue;
      }
      const count = header.slotCount;
      if (moved || count == 0) continue;
      const start = header.slotStart;
      // Grown ranges below this one go first.
      while (grown < this.growLog.length && u32(this.growLog[grown] >> 32) < start) {
        cursor = this.slideGrown(grown, cursor);
        grown = grown + 1;
      }
      cursor = this.slideRange(handle, start, count, cursor);
    }
    while (grown < this.growLog.length) {
      cursor = this.slideGrown(grown, cursor);
      grown = grown + 1;
    }
    // The dead listed free, as listFree would, in one loop.
    at = 0;
    while (at < this.deadYoung.length) {
      const dead = this.deadYoung[at];
      if (this.freeHandleCount < this.freeHandles.length) {
        this.freeHandles[this.freeHandleCount] = dead;
      } else {
        this.freeHandles.push(dead);
      }
      this.freeHandleCount = this.freeHandleCount + 1;
      at = at + 1;
    }
    while (this.slots.length > cursor) {
      const dropped = this.slots.pop();
    }
    while (this.smallBytes.length > byteCursor) {
      const dropped = this.smallBytes.pop();
    }
    this.smallLiveBytes = this.smallLiveBytes + survivorBytes;
    this.promotedCells = this.promotedCells + this.markedCells;
    this.promotedSlots = this.promotedSlots + this.markedSlots;
    this.cellsBeforeCycle = this.cellsBeforeCycle + f64(this.allocatedSinceCollect);
    this.slotsBeforeCycle = this.slotsBeforeCycle + f64(cycleSlots);
    this.slotsAfterSweep = this.slots.length;
    this.allocatedSinceCollect = 0;
    this.collectThreshold = this.nurseryCells;
    this.minorCollections = this.minorCollections + 1;
  }

  // After the runtime has dropped the dead atoms from its table: they are
  // freed, and the next cycle begins.
  function finishMinor(inout this): void {
    let at: usize = 0;
    while (at < this.deadAtoms.length) {
      const dead = this.deadAtoms[at];
      this.releaseCell(dead, TAG_STRING);
      this.listFree(dead);
      at = at + 1;
    }
    this.endCycle();
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

  // Room for `extra` more slots. The arena and the handle table grow by
  // four times, not the doubling an array's push would do: each time a
  // large block grows it moves, and the allocator may keep the block it
  // left resident for reuse (macOS does), so the fewer moves, the less
  // memory is held for nothing. The capacity nothing has touched costs
  // address space only.
  function growArena(inout this, extra: usize): void {
    this.slots.reserveCapacity(grownCapacity(this.slots.capacity, this.slots.length + extra));
  }

  function growSlots(inout this, handle: u32, newCount: u32): void {
    this.growSlotsWith(handle, newCount, undefinedValue());
  }

  // Give a cell `newCount` slots, the new ones holding `fill`. A range at
  // the arena's top, allocated or grown since the last collection, grows
  // where it is; any other moves to a fresh range at the top, the old one
  // abandoned until the collector compacts.
  function growSlotsWith(inout this, handle: u32, newCount: u32, fill: Value): void {
    const oldStart = this.cellHeader(handle).slotStart;
    const oldCount = this.cellHeader(handle).slotCount;
    if (usize(oldStart) >= this.tailBase && usize(oldStart + oldCount) == this.slots.length) {
      if (this.slots.length + usize(newCount - oldCount) > this.slots.capacity) this.growArena(usize(newCount - oldCount));
      this.slots.appendRepeated(fill, usize(newCount - oldCount));
      this.headers[usize(handle)].slotCount = newCount;
      return;
    }
    const start = u32(this.slots.length);
    if (this.slots.length + usize(newCount) > this.slots.capacity) this.growArena(usize(newCount));
    let index: u32 = 0;
    while (index < oldCount) {
      const kept = this.slots[usize(oldStart + index)];
      this.slots.push(kept);
      index = index + 1;
    }
    if (newCount > oldCount) this.slots.appendRepeated(fill, usize(newCount - oldCount));
    this.headers[usize(handle)].slotStart = start;
    this.headers[usize(handle)].slotCount = newCount;
    this.growLog.push((u64(start) << 32) | u64(handle));
    if (!this.cellHeader(handle).marked) this.headers[usize(handle)].remembered = true;
  }

  function linkOf(handle: u32): u32 {
    return this.cellHeader(handle).link;
  }

  function setLink(inout this, handle: u32, link: u32): void {
    this.headers[usize(handle)].link = link;
    if (link != 0 && this.cellHeader(handle).marked) this.remember(handle, link);
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

  // The class reached by adding `atom` to `classId` with the default
  // attributes, created on first use.
  function classTransition(inout this, classId: u32, atom: u32): u32 {
    return this.classTransitionWith(classId, atom, PROP_DEFAULT);
  }

  // The class reached by adding `atom` with `attr` to `classId`: a
  // property's attributes are part of the shape, so the same name with
  // other attributes is another class.
  function classTransitionWith(inout this, classId: u32, atom: u32, attr: u8): u32 {
    const count = this.classes[usize(classId)].transitionNames.length;
    let index: usize = 0;
    while (index < count) {
      if (this.classes[usize(classId)].transitionNames[index] == atom && this.classes[usize(classId)].transitionAttrs[index] == attr) return this.classes[usize(classId)].transitionChildren[index];
      index = index + 1;
    }
    const propCount = this.classes[usize(classId)].propCount;
    let slotAttrs = Array<u8>.withCapacity(usize(propCount) + 1);
    let k: usize = 0;
    while (k < usize(propCount)) {
      slotAttrs.push(this.classes[usize(classId)].slotAttrs[k]);
      k = k + 1;
    }
    slotAttrs.push(attr);
    this.classes.push(HiddenClass({
      parent: classId, transitionName: atom, transitionSlot: propCount, propCount: propCount + 1, slotAttrs: move slotAttrs,
      transitionNames: Array<u32>(), transitionAttrs: Array<u8>(), transitionChildren: Array<u32>(),
    }));
    const child = u32(this.classes.length - 1);
    this.classes[usize(classId)].transitionNames.push(atom);
    this.classes[usize(classId)].transitionAttrs.push(attr);
    this.classes[usize(classId)].transitionChildren.push(child);
    return child;
  }

  // The class an object of `classId` moves to when the property in
  // `slot` takes `attr`: the chain replayed from the root with that one
  // property's attributes changed, so the slots stay where they are and
  // every object reconfigured the same way shares the result.
  function classWithAttr(inout this, classId: u32, slot: u32, attr: u8): u32 {
    let chain = Array<u32>();
    let current = classId;
    while (current != 0) {
      chain.push(current);
      current = this.classes[usize(current)].parent;
    }
    let result: u32 = 0;
    let k = chain.length;
    while (k > 0) {
      k = k - 1;
      const step = chain[k];
      const stepSlot = this.classes[usize(step)].transitionSlot;
      const stepAttr = stepSlot == slot ? attr : this.classes[usize(step)].slotAttrs[usize(stepSlot)];
      const stepName = this.classes[usize(step)].transitionName;
      result = this.classTransitionWith(result, stepName, stepAttr);
    }
    return result;
  }

  // Whether `child` is the class `parent` reaches by adding `atom`.
  // The slot the property a class adds lives in.
  function classSlot(classId: u32): u32 {
    return this.classes[usize(classId)].transitionSlot;
  }

  function isTransitionOf(child: u32, parent: u32, atom: u32): boolean {
    return this.classes[usize(child)].parent == parent && this.classes[usize(child)].transitionName == atom;
  }

  // Move an object to `classId` by writing its new property, the slot
  // and class known from a previous transition.
  function transitionTo(inout this, handle: u32, classId: u32, slotIndex: u32, value: Value): void {
    if (slotIndex >= this.cellHeader(handle).slotCount) {
      const grown: u32 = this.cellHeader(handle).slotCount * 2;
      const needed: u32 = slotIndex + 1;
      this.growSlots(handle, grown > needed ? grown : needed);
    }
    this.headers[usize(handle)].payload = classId;
    this.setSlot(handle, slotIndex, value);
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
    return this.cellHeader(handle).tag == TAG_OBJECT;
  }

  function objectClass(handle: u32): u32 {
    return this.cellHeader(handle).payload;
  }

  function objectProto(handle: u32): u32 {
    return this.cellHeader(handle).link;
  }

  function setObjectProto(inout this, handle: u32, proto: u32): void {
    this.headers[usize(handle)].link = proto;
    if (proto != 0 && this.cellHeader(handle).marked) this.remember(handle, proto);
  }

  // The object's own slot for `atom`, or -1: the value slot, in either
  // representation.
  function objectFindSlot(handle: u32, atom: u32): i32 {
    const payload = this.cellHeader(handle).payload;
    if ((payload & DICT_BIT) != 0) return this.dictionaryFind(handle, payload & (DICT_BIT - 1), atom);
    return this.classFindSlot(payload, atom);
  }

  function isDictionary(handle: u32): boolean {
    return (this.cellHeader(handle).payload & DICT_BIT) != 0;
  }

  // Write an own property, adding it (and transitioning the class) when
  // the object does not have it yet.
  function objectSet(inout this, handle: u32, atom: u32, value: Value): void {
    const existing = this.objectFindSlot(handle, atom);
    if (existing >= 0) {
      this.setSlot(handle, u32(existing), value);
      return;
    }
    this.objectAdd(handle, atom, value);
  }

  // Add a property the object does not have yet, with the default
  // attributes: what filling a fresh object needs, without looking the
  // name up first.
  function objectAdd(inout this, handle: u32, atom: u32, value: Value): void {
    this.objectAddWith(handle, atom, value, PROP_DEFAULT);
  }

  // Add a property the object does not have yet, with `attr`.
  function objectAddWith(inout this, handle: u32, atom: u32, value: Value, attr: u8): void {
    if ((this.cellHeader(atom).flags & FLAG_INDEX_KEY) != 0) this.indexKeysDefined = true;
    const parentClass = this.cellHeader(handle).payload;
    if ((parentClass & DICT_BIT) != 0) {
      this.dictionaryInsert(handle, parentClass & (DICT_BIT - 1), atom, value, attr);
      return;
    }
    if (this.classes[usize(parentClass)].propCount >= this.dictThreshold) {
      const dictionary = this.toDictionary(handle);
      this.dictionaryInsert(handle, dictionary, atom, value, attr);
      return;
    }
    const child = this.classTransitionWith(parentClass, atom, attr);
    const slotIndex = this.classes[usize(child)].transitionSlot;
    if (slotIndex >= this.cellHeader(handle).slotCount) {
      const grown: u32 = this.cellHeader(handle).slotCount * 2;
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
    const payload = this.cellHeader(handle).payload;
    if ((payload & DICT_BIT) != 0) {
      this.dictionaryRemove(payload & (DICT_BIT - 1), handle, slot);
      return;
    }
    if (this.classes[usize(payload)].transitionName == atom && this.classes[usize(payload)].transitionSlot == slot) {
      this.headers[usize(handle)].payload = this.classes[usize(payload)].parent;
      this.setSlot(handle, slot, undefinedValue());
      return;
    }
    const dictionary = this.toDictionary(handle);
    const pairSlot = this.dictionaryFind(handle, dictionary, atom);
    if (pairSlot >= 0) this.dictionaryRemove(dictionary, handle, u32(pairSlot));
  }

  // The object's own names in insertion order, whatever its
  // representation; a class-mode slot that holds nothing yet is skipped.
  // An object's own properties as (name, value slot) pairs in insertion
  // order, deleted ones left out: what enumerating its keys needs without
  // finding each name's slot again.
  function objectNamedSlots(handle: u32, inout names: Array<u32>, inout slots: Array<u32>): void {
    const payload = this.cellHeader(handle).payload;
    if ((payload & DICT_BIT) != 0) {
      const used = this.dictionaries[usize(payload & (DICT_BIT - 1))].used;
      let pair: u32 = 0;
      while (pair < used) {
        const key = this.slot(handle, pair * 2);
        if (!isDeleted(key) && !isDeleted(this.slot(handle, pair * 2 + 1))) {
          names.push(asCell(key));
          slots.push(pair * 2 + 1);
        }
        pair = pair + 1;
      }
      return;
    }
    const byClass = this.objectNames(handle);
    let slot: u32 = 0;
    while (usize(slot) < byClass.length) {
      const name = byClass[usize(slot)];
      if (name != 0 && !isDeleted(this.slot(handle, slot))) {
        names.push(name);
        slots.push(slot);
      }
      slot = slot + 1;
    }
  }

  // An object's own property names and value slots in insertion order,
  // appended to the caller's arrays, with nothing allocated here: a
  // class-mode object's come from its class chain, newest first, and are
  // turned around in place.
  function appendOwnNamedSlots(handle: u32, inout names: Array<u32>, inout slots: Array<u32>): void {
    const payload = this.cellHeader(handle).payload;
    if ((payload & DICT_BIT) != 0) {
      this.objectNamedSlots(handle, inout names, inout slots);
      return;
    }
    const start = names.length;
    let classId = payload;
    while (classId != 0) {
      const slot = this.classes[usize(classId)].transitionSlot;
      if (!isDeleted(this.slot(handle, slot))) {
        names.push(this.classes[usize(classId)].transitionName);
        slots.push(slot);
      }
      classId = this.classes[usize(classId)].parent;
    }
    let low = start;
    let high = names.length;
    while (high > low + 1) {
      high = high - 1;
      const name = names[low];
      names[low] = names[high];
      names[high] = name;
      const slot = slots[low];
      slots[low] = slots[high];
      slots[high] = slot;
      low = low + 1;
    }
  }

  function objectNames(handle: u32): Array<u32> {
    let names = Array<u32>();
    const payload = this.cellHeader(handle).payload;
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
    names.appendRepeated(0, usize(propCount));
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
    const start = this.cellHeader(handle).slotStart;
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
  function dictionaryInsert(inout this, handle: u32, dictionary: u32, atom: u32, value: Value, attr: u8): void {
    const capacity = this.cellHeader(handle).slotCount / 2;
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
    this.setPairAttr(dictionary, pair, attr);
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
    this.setPairAttr(dictionary, (slot - 1) / 2, PROP_DEFAULT);
    this.dictionaries[usize(dictionary)].live = this.dictionaries[usize(dictionary)].live - 1;
  }

  // Rebuild the index over the pairs in use, at twice the pair capacity.
  function dictionaryRehash(inout this, handle: u32, dictionary: u32): void {
    const capacity = this.cellHeader(handle).slotCount / 2;
    let size: u32 = 8;
    while (size < capacity * 2) {
      size = size * 2;
    }
    let index = Array<u32>.withCapacity(usize(size));
    index.appendRepeated(0, usize(size));
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
          const attr = this.pairAttr(dictionary, read);
          this.setSlot(handle, write * 2, key);
          this.setSlot(handle, write * 2 + 1, value);
          this.setPairAttr(dictionary, write, attr);
        }
        write = write + 1;
      }
      read = read + 1;
    }
    let clear = write;
    while (clear < used) {
      this.setSlot(handle, clear * 2, undefinedValue());
      this.setSlot(handle, clear * 2 + 1, undefinedValue());
      this.setPairAttr(dictionary, clear, PROP_DEFAULT);
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
        const slot = this.classFindSlot(this.cellHeader(handle).payload, name);
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
    if (this.cellHeader(handle).slotCount < capacity * 2) this.growSlots(handle, capacity * 2);
    let dictionary: u32 = 0;
    if (this.freeDictionaryCount > 0) {
      this.freeDictionaryCount = this.freeDictionaryCount - 1;
      dictionary = this.freeDictionaries[this.freeDictionaryCount];
      this.dictionaries[usize(dictionary)] = Dictionary({ index: Array<u32>(), mask: 0, used: count, live: count, attrs: Array<u8>() });
    } else {
      this.dictionaries.push(Dictionary({ index: Array<u32>(), mask: 0, used: count, live: count, attrs: Array<u8>() }));
      dictionary = u32(this.dictionaries.length - 1);
    }
    let pair: u32 = 0;
    while (pair < count) {
      const name = kept[usize(pair)];
      const value = values[usize(pair)];
      const attr = attrs[usize(pair)];
      this.setSlot(handle, pair * 2, cellValue(name));
      this.setSlot(handle, pair * 2 + 1, value);
      this.setPairAttr(dictionary, pair, attr);
      pair = pair + 1;
    }
    let clear = count * 2;
    const total = this.cellHeader(handle).slotCount;
    while (clear < total) {
      this.setSlot(handle, clear, undefinedValue());
      clear = clear + 1;
    }
    this.headers[usize(handle)].payload = DICT_BIT | dictionary;
    this.dictionaryRehash(handle, dictionary);
    return dictionary;
  }

  function pairAttr(dictionary: u32, pair: u32): u8 {
    if (usize(pair) >= this.dictionaries[usize(dictionary)].attrs.length) return PROP_DEFAULT;
    return this.dictionaries[usize(dictionary)].attrs[usize(pair)];
  }

  function setPairAttr(inout this, dictionary: u32, pair: u32, attr: u8): void {
    const held = this.dictionaries[usize(dictionary)].attrs.length;
    if (held <= usize(pair)) this.dictionaries[usize(dictionary)].attrs.appendRepeated(PROP_DEFAULT, usize(pair) + 1 - held);
    this.dictionaries[usize(dictionary)].attrs[usize(pair)] = attr;
  }

  function releaseDictionary(inout this, dictionary: u32): void {
    this.dictionaries[usize(dictionary)] = Dictionary({ index: Array<u32>(), mask: 0, used: 0, live: 0, attrs: Array<u8>() });
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

  // --- Tables ---
  //
  // A Map's or Set's entries live outside the slot arena, in a table that
  // a TAG_TABLE cell owns (its payload is the table's number): keys and
  // values in insertion order, a removed entry leaving the deleted marker
  // in both; each entry's hash beside it, given by the caller; an
  // open-addressed index from hash to position (TABLE_EMPTY, or
  // TABLE_REMOVED where an entry was); the live count; and a kind the
  // caller defines. Positions never move while the table lives, so an
  // iterator walks them in order, seeing entries added during the walk
  // and skipping removed ones. The collector traces the keys and values
  // through the cell and takes the table back with it.
  function allocateTable(inout this, kind: i32): u32 {
    let index = Array<i32>.withCapacity(8);
    index.appendRepeated(TABLE_EMPTY, 8);
    const fresh = Table({ keys: Array<Value>(), values: Array<Value>(), hashes: Array<u32>(), index: move index, live: 0, kind: kind });
    let table: u32 = 0;
    if (this.freeTableCount > 0) {
      this.freeTableCount = this.freeTableCount - 1;
      table = this.freeTables[this.freeTableCount];
      this.tables[usize(table)] = move fresh;
    } else {
      table = u32(this.tables.length);
      this.tables.push(move fresh);
    }
    const handle = this.allocate(TAG_TABLE, 0);
    this.headers[usize(handle)].payload = table;
    return handle;
  }

  function isTable(handle: u32): boolean {
    return this.cellHeader(handle).tag == TAG_TABLE;
  }

  function tableKind(handle: u32): i32 {
    return this.tables[usize(this.cellHeader(handle).payload)].kind;
  }

  // Entries present.
  function tableLive(handle: u32): u32 {
    return this.tables[usize(this.cellHeader(handle).payload)].live;
  }

  // Positions taken, removed entries included: an iteration's bound.
  function tableExtent(handle: u32): u32 {
    return u32(this.tables[usize(this.cellHeader(handle).payload)].keys.length);
  }

  // The key at a position, the deleted marker once removed.
  function tableKey(handle: u32, position: u32): Value {
    return this.tables[usize(this.cellHeader(handle).payload)].keys[usize(position)];
  }

  function tableValue(handle: u32, position: u32): Value {
    return this.tables[usize(this.cellHeader(handle).payload)].values[usize(position)];
  }

  function setTableValue(inout this, handle: u32, position: u32, value: Value): void {
    this.tables[usize(this.cellHeader(handle).payload)].values[usize(position)] = value;
    if (this.cellHeader(handle).marked) this.rememberStore(handle, position, value);
  }

  // The position of `key`, whose hash is `hash`, or -1.
  function tableFind(handle: u32, key: Value, hash: u32): i32 {
    const table = usize(this.cellHeader(handle).payload);
    return probeTable(in this, this.tables[table].index, this.tables[table].hashes, this.tables[table].keys, key, hash);
  }

  // Append an entry the table does not hold.
  function tableAdd(inout this, handle: u32, key: Value, value: Value, hash: u32): void {
    const table = usize(this.cellHeader(handle).payload);
    const position = this.tables[table].keys.length;
    // The index counts every position taken, removed ones included, and
    // stays at most three quarters full.
    if ((position + 1) * 4 > this.tables[table].index.length * 3) this.growTableIndex(table);
    this.tables[table].keys.push(key);
    this.tables[table].values.push(value);
    this.tables[table].hashes.push(hash);
    const mask = u32(this.tables[table].index.length) - 1;
    let slot = hash & mask;
    while (this.tables[table].index[usize(slot)] >= 0) { slot = (slot + 1) & mask; }
    this.tables[table].index[usize(slot)] = i32(position);
    this.tables[table].live = this.tables[table].live + 1;
    if (this.cellHeader(handle).marked) {
      this.rememberStore(handle, u32(position), key);
      this.rememberStore(handle, u32(position), value);
    }
  }

  // Remove the entry at a position.
  function tableRemove(inout this, handle: u32, position: u32): void {
    const table = usize(this.cellHeader(handle).payload);
    const mask = u32(this.tables[table].index.length) - 1;
    let slot = this.tables[table].hashes[usize(position)] & mask;
    while (this.tables[table].index[usize(slot)] != i32(position)) { slot = (slot + 1) & mask; }
    this.tables[table].index[usize(slot)] = TABLE_REMOVED;
    this.tables[table].keys[usize(position)] = deletedValue();
    this.tables[table].values[usize(position)] = deletedValue();
    this.tables[table].live = this.tables[table].live - 1;
  }

  // Remove every entry; positions stay taken, so an iterator walking the
  // table finds nothing live and then whatever is added after.
  function tableClear(inout this, handle: u32): void {
    const table = usize(this.cellHeader(handle).payload);
    let k: usize = 0;
    while (k < this.tables[table].keys.length) {
      this.tables[table].keys[k] = deletedValue();
      this.tables[table].values[k] = deletedValue();
      k = k + 1;
    }
    k = 0;
    while (k < this.tables[table].index.length) {
      this.tables[table].index[k] = TABLE_EMPTY;
      k = k + 1;
    }
    this.tables[table].live = 0;
  }

  // Twice the index, rebuilt from the kept hashes over the live entries.
  function growTableIndex(inout this, table: usize): void {
    const capacity = this.tables[table].index.length * 2;
    let index = Array<i32>.withCapacity(capacity);
    index.appendRepeated(TABLE_EMPTY, capacity);
    const mask = u32(capacity) - 1;
    let position: usize = 0;
    while (position < this.tables[table].keys.length) {
      if (!isDeleted(this.tables[table].keys[position])) {
        let slot = this.tables[table].hashes[position] & mask;
        while (index[usize(slot)] != TABLE_EMPTY) { slot = (slot + 1) & mask; }
        index[usize(slot)] = i32(position);
      }
      position = position + 1;
    }
    this.tables[table].index = move index;
  }

  function markTable(inout this, table: usize): void {
    let k: usize = 0;
    while (k < this.tables[table].keys.length) {
      const key = this.tables[table].keys[k];
      if (isCell(key) && asCell(key) != 0 && !this.cellHeader(asCell(key)).marked) {
        this.headers[usize(asCell(key))].marked = true;
        this.pushMark(asCell(key));
      }
      const value = this.tables[table].values[k];
      if (isCell(value) && asCell(value) != 0 && !this.cellHeader(asCell(value)).marked) {
        this.headers[usize(asCell(value))].marked = true;
        this.pushMark(asCell(value));
      }
      k = k + 1;
    }
  }

  function releaseTable(inout this, table: u32): void {
    this.tables[usize(table)] = Table({ keys: Array<Value>(), values: Array<Value>(), hashes: Array<u32>(), index: Array<i32>(), live: 0, kind: 0 });
    if (this.freeTableCount < this.freeTables.length) {
      this.freeTables[this.freeTableCount] = table;
    } else {
      this.freeTables.push(table);
    }
    this.freeTableCount = this.freeTableCount + 1;
  }

  // SameValueZero between keys: numbers by value (NaN equal to itself,
  // the two zeros alike), strings by content, anything else by identity.
  function sameKey(a: Value, b: Value): boolean {
    if (a.bits == b.bits) return true;
    if (isNumber(a) && isNumber(b)) {
      const x = isInt32(a) ? f64(asInt32(a)) : asDouble(a);
      const y = isInt32(b) ? f64(asInt32(b)) : asDouble(b);
      return x == y || (x != x && y != y);
    }
    if (isCell(a) && isCell(b) && asCell(a) != 0 && asCell(b) != 0 && this.cellHeader(asCell(a)).tag == TAG_STRING && this.cellHeader(asCell(b)).tag == TAG_STRING) {
      return this.stringsEqual(asCell(a), asCell(b));
    }
    return false;
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

  // An array of `length` holes, as a program's `new Array(length)` makes
  // it: slots for at most ARRAY_PRESIZE of them up front, the rest added
  // as elements are written.
  function allocateArrayOfLength(inout this, length: u32): u32 {
    const handle = this.allocateArray(length < ARRAY_PRESIZE ? length : ARRAY_PRESIZE);
    this.headers[usize(handle)].payload = length;
    return handle;
  }

  function isArray(handle: u32): boolean {
    return this.cellHeader(handle).tag == TAG_ARRAY;
  }

  function arrayLength(handle: u32): u32 {
    return this.cellHeader(handle).payload;
  }

  function arrayHasIndex(handle: u32, index: u32): boolean {
    if (index >= this.cellHeader(handle).payload) return false;
    if (index >= this.cellHeader(handle).slotCount) return false;
    return !isDeleted(this.slot(handle, index));
  }

  // An array's element as a plain read sees it: the value of a present
  // data element, or the deleted marker for a hole, an accessor, or an
  // index past the length -- one pass over the header, for the paths that
  // read elements in place.
  function dataElement(handle: u32, index: u32): Value {
    const header = this.cellHeader(handle);
    if (index >= header.payload || index >= header.slotCount) return deletedValue();
    const value = unsafe { select this.slots.uncheckedAt(usize(header.slotStart.wrappingAdd(index))); };
    if ((header.flags & FLAG_ELEMENT_ATTRS) != 0 && !isDeleted(value) && (this.elementAttrOf(handle, index) & PROP_ACCESSOR) != 0) return deletedValue();
    return value;
  }

  // Whether an array's element is present, writable data: a write in
  // place is what assignment would do.
  function writableElement(handle: u32, index: u32): boolean {
    const header = this.cellHeader(handle);
    if (index >= header.payload || index >= header.slotCount) return false;
    const value = unsafe { select this.slots.uncheckedAt(usize(header.slotStart.wrappingAdd(index))); };
    if (isDeleted(value)) return false;
    if ((header.flags & FLAG_ELEMENT_ATTRS) == 0) return true;
    const attr = this.elementAttrOf(handle, index);
    return (attr & PROP_ACCESSOR) == 0 && (attr & PROP_WRITABLE) != 0;
  }

  function arrayGet(handle: u32, index: u32): Value {
    if (!this.arrayHasIndex(handle, index)) return undefinedValue();
    return this.slot(handle, index);
  }

  function arraySet(inout this, handle: u32, index: u32, value: Value): void {
    if (index >= this.cellHeader(handle).slotCount) {
      let capacity = this.cellHeader(handle).slotCount;
      while (capacity <= index) { capacity = capacity * 2; }
      // Fresh capacity is holes, not undefined.
      this.growSlotsWith(handle, capacity, deletedValue());
    }
    this.setSlot(handle, index, value);
    if (index >= this.cellHeader(handle).payload) this.headers[usize(handle)].payload = index + 1;
  }

  // Shrinking drops elements, and their attributes with them; growing
  // exposes holes.
  function setArrayLength(inout this, handle: u32, length: u32): void {
    const old = this.cellHeader(handle).payload;
    let index = length;
    while (index < old && index < this.cellHeader(handle).slotCount) {
      this.setSlot(handle, index, deletedValue());
      index = index + 1;
    }
    this.headers[usize(handle)].payload = length;
    const entry = this.elementAttrEntry(handle);
    if (entry >= 0) {
      while (this.elementAttrs[usize(entry)].attrs.length > usize(length)) {
        const dropped = this.elementAttrs[usize(entry)].attrs.pop();
      }
    }
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
    return this.cellHeader(handle).tag == TAG_WEAK_RECORD;
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
        if (isCell(value) && asCell(value) != 0 && !this.cellHeader(asCell(value)).marked) {
          if (this.cellHeader(asCell(key)).marked) {
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
      let buckets = Array<u32>.withCapacity(16);
      buckets.appendRepeated(0, 16);
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
    buckets.appendRepeated(0, usize(size));
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
        if (isCell(value) && asCell(value) != 0 && !this.cellHeader(asCell(value)).marked) {
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
          if (!isDeleted(key) && this.cellHeader(asCell(key)).marked) {
            this.weakVisits = this.weakVisits + 1;
            const value = this.slot(values, position);
            if (isCell(value) && asCell(value) != 0 && !this.cellHeader(asCell(value)).marked) {
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
        if (!isDeleted(key) && !this.cellHeader(asCell(key)).marked) {
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
    return this.cellHeader(handle).tag == TAG_ENV;
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
    return this.cellHeader(handle).tag == TAG_CLOSURE;
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
    return this.cellHeader(handle).tag == TAG_SYMBOL;
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
    return this.cellHeader(handle).tag == TAG_HOST_FUNCTION;
  }

  function hostFunctionId(handle: u32): u32 {
    return this.cellHeader(handle).payload;
  }

  // --- Strings ---
  //
  // A string cell's content is UTF-16 code units. Storage is one byte per
  // unit when every unit is at most 0xFF (Latin-1), else two bytes per
  // unit, little-endian, with FLAG_WIDE on the cell. The narrow form is
  // canonical, so equal content always has equal storage. The cell's
  // slotStart is its storage length in bytes.
  //
  // Where the bytes are: a string of up to SMALL_STRING_BYTES lives in
  // the byte arena, its payload the offset with ARENA_BIT set; the arena
  // is filled from its top and compacted by the collector, which copies
  // the live strings and drops the rest, so a small string costs no
  // allocation of its own and nothing to free. A larger string has a
  // buffer of its own in `strings`, its payload the buffer's index,
  // shared by the strings a concatenation chain makes over it.
  function allocateStorage(inout this, bytes: Array<u8>, wide: boolean): u32 {
    const byteCount = u32(bytes.length);
    if (byteCount <= SMALL_STRING_BYTES) {
      const offset = u32(this.smallBytes.length);
      this.smallBytes.append(bytes);
      return this.allocateArenaString(offset, byteCount, wide);
    }
    // A buffer holding far more than its bytes (one sized for a larger
    // text) is not kept at that size for the string's life.
    if (bytes.capacity > bytes.length * 2 + 64) {
      let fitted = Array<u8>.withCapacity(bytes.length);
      fitted.append(bytes);
      const stringIndex = this.adoptBuffer(move fitted);
      return this.allocateStringOver(stringIndex, byteCount, wide);
    }
    const stringIndex = this.adoptBuffer(move bytes);
    return this.allocateStringOver(stringIndex, byteCount, wide);
  }

  // A buffer slot for `bytes`, with one string over it to come.
  function adoptBuffer(inout this, bytes: Array<u8>): u32 {
    if (this.freeStringCount > 0) {
      this.freeStringCount = this.freeStringCount - 1;
      const reused = this.freeStrings[this.freeStringCount];
      this.strings[usize(reused)] = move bytes;
      this.bufferRefs[usize(reused)] = 1;
      return reused;
    }
    const stringIndex = u32(this.strings.length);
    this.strings.push(move bytes);
    this.bufferRefs.push(1);
    return stringIndex;
  }

  // A string cell over the first `byteCount` bytes of buffer
  // `stringIndex`, whose count already includes it.
  function allocateStringOver(inout this, stringIndex: u32, byteCount: u32, wide: boolean): u32 {
    const handle = this.allocate(TAG_STRING, 0);
    this.headers[usize(handle)].payload = stringIndex;
    this.headers[usize(handle)].slotStart = byteCount;
    if (wide) this.setFlags(handle, FLAG_WIDE);
    return handle;
  }

  // A string cell over `byteCount` arena bytes from `offset`.
  function allocateArenaString(inout this, offset: u32, byteCount: u32, wide: boolean): u32 {
    const handle = this.allocate(TAG_STRING, 0);
    this.headers[usize(handle)].payload = ARENA_BIT | offset;
    this.headers[usize(handle)].slotStart = byteCount;
    if (wide) this.setFlags(handle, FLAG_WIDE);
    return handle;
  }

  function isArenaString(handle: u32): boolean {
    return (this.cellHeader(handle).payload & ARENA_BIT) != 0;
  }

  // Where a string's bytes start: its arena offset, or 0 in its buffer.
  function stringStorageStart(handle: u32): usize {
    const payload = this.cellHeader(handle).payload;
    if ((payload & ARENA_BIT) != 0) return usize(payload & ~ARENA_BIT);
    return 0;
  }

  // One string over a buffer has died: the buffer goes back to the free
  // list with the last one.
  function releaseStringBuffer(inout this, stringIndex: u32): void {
    const at = usize(stringIndex);
    const remaining = (this.bufferRefs[at] & BUFFER_REFS) - 1;
    if (remaining > 0) {
      this.bufferRefs[at] = (this.bufferRefs[at] & BUFFER_APPENDABLE) | remaining;
      return;
    }
    this.strings[at] = Array<u8>();
    this.bufferRefs[at] = 0;
    if (this.freeStringCount < this.freeStrings.length) {
      this.freeStrings[this.freeStringCount] = stringIndex;
    } else {
      this.freeStrings.push(stringIndex);
    }
    this.freeStringCount = this.freeStringCount + 1;
  }

  // A string's storage byte, wherever it lives.
  // A narrow string's bytes appended to `bytes`, read where they are.
  function appendNarrowTo(handle: u32, bytes: Array<u8>): Array<u8> {
    const payload = this.cellHeader(handle).payload;
    const length = usize(this.cellHeader(handle).slotStart);
    if ((payload & ARENA_BIT) != 0) {
      const origin = usize(payload & ~ARENA_BIT);
      return appendRange(this.smallBytes, origin, origin + length, move bytes);
    }
    return appendRange(this.strings[usize(payload)], 0, length, move bytes);
  }

  function storageByte(handle: u32, index: usize): u8 {
    const payload = this.cellHeader(handle).payload;
    if ((payload & ARENA_BIT) != 0) return this.smallBytes[usize(payload & ~ARENA_BIT) + index];
    return this.strings[usize(payload)][index];
  }

  // A string's storage bytes appended to the arena's top.
  function copyToArena(inout this, handle: u32): void {
    const payload = this.cellHeader(handle).payload;
    const length = usize(this.cellHeader(handle).slotStart);
    let k: usize = 0;
    if ((payload & ARENA_BIT) != 0) {
      const origin = usize(payload & ~ARENA_BIT);
      while (k < length) {
        const byte = this.smallBytes[origin + k];
        this.smallBytes.push(byte);
        k = k + 1;
      }
      return;
    }
    this.smallBytes.append(this.strings[usize(payload)].slice(0, length));
  }

  // A string's storage bytes appended to `target`.
  function copyStorage(handle: u32, inout target: Array<u8>): void {
    const payload = this.cellHeader(handle).payload;
    const length = usize(this.cellHeader(handle).slotStart);
    if ((payload & ARENA_BIT) != 0) {
      const origin = usize(payload & ~ARENA_BIT);
      target.append(this.smallBytes.slice(origin, origin + length));
      return;
    }
    target.append(this.strings[usize(payload)].slice(0, length));
  }

  // Whether a string's bytes end at the arena's top, so what follows can
  // be appended there and shared.
  function endsArena(handle: u32): boolean {
    const payload = this.cellHeader(handle).payload;
    if ((payload & ARENA_BIT) == 0) return false;
    return usize(payload & ~ARENA_BIT) + usize(this.cellHeader(handle).slotStart) == this.smallBytes.length;
  }

  // `left` followed by `right`, two strings of the same width. A small
  // result goes to the arena, after `left` in place when `left` ends at
  // its top. A larger one extends `left`'s buffer in place when `left`
  // is the newest string over a buffer a concatenation made -- every
  // earlier string over it keeps seeing its own prefix, and a loop that
  // grows a string by `+=` copies each byte once instead of once per
  // iteration -- or else copies both into a fresh buffer that later
  // concatenations may extend the same way.
  function concatStorage(inout this, left: u32, right: u32): u32 {
    const leftPayload = this.cellHeader(left).payload;
    const leftBytes = this.cellHeader(left).slotStart;
    const rightPayload = this.cellHeader(right).payload;
    const rightBytes = this.cellHeader(right).slotStart;
    const wide = (this.cellHeader(left).flags & FLAG_WIDE) != 0;
    const joinedBytes = leftBytes + rightBytes;
    if (joinedBytes <= SMALL_STRING_BYTES) {
      let offset = u32(this.smallBytes.length);
      if (this.endsArena(left)) {
        offset = leftPayload & ~ARENA_BIT;
      } else {
        this.copyToArena(left);
      }
      this.copyToArena(right);
      return this.allocateArenaString(offset, joinedBytes, wide);
    }
    if ((leftPayload & ARENA_BIT) == 0) {
      const leftBuffer = usize(leftPayload);
      const appendable = (this.bufferRefs[leftBuffer] & BUFFER_APPENDABLE) != 0;
      if (appendable && rightPayload != leftPayload && u32(this.strings[leftBuffer].length) == leftBytes) {
        let index: usize = 0;
        if ((rightPayload & ARENA_BIT) != 0) {
          // A small right side, the usual piece appended: its arena bytes
          // copied in one step.
          const origin = usize(rightPayload & ~ARENA_BIT);
          this.strings[leftBuffer].append(this.smallBytes.slice(origin, origin + usize(rightBytes)));
        } else {
          while (index < usize(rightBytes)) {
            const byte = this.storageByte(right, index);
            this.strings[leftBuffer].push(byte);
            index = index + 1;
          }
        }
        this.bufferRefs[leftBuffer] = this.bufferRefs[leftBuffer] + 1;
        return this.allocateStringOver(u32(leftBuffer), joinedBytes, wide);
      }
    }
    let joined = Array<u8>.withCapacity(usize(joinedBytes));
    this.copyStorage(left, inout joined);
    this.copyStorage(right, inout joined);
    const stringIndex = this.adoptBuffer(move joined);
    this.bufferRefs[usize(stringIndex)] = BUFFER_APPENDABLE | 1;
    return this.allocateStringOver(stringIndex, joinedBytes, wide);
  }

  // A string and `count` ASCII bytes joined, the bytes after the string
  // or, with `before`, ahead of it: what adding a string and a number
  // makes, with no string made for the number. The result goes where
  // concatStorage would put it, extending in place where it could.
  function concatAscii(inout this, handle: u32, bytes: Slice<u8>, count: usize, before: boolean): u32 {
    const payload = this.cellHeader(handle).payload;
    const length = this.cellHeader(handle).slotStart;
    const wide = (this.cellHeader(handle).flags & FLAG_WIDE) != 0;
    const width: usize = wide ? 2 : 1;
    const joinedBytes = length + u32(count * width);
    if (joinedBytes <= SMALL_STRING_BYTES) {
      let offset = u32(this.smallBytes.length);
      if (before) {
        appendAsciiUnits(inout this.smallBytes, bytes, count, wide);
        this.copyToArena(handle);
        return this.allocateArenaString(offset, joinedBytes, wide);
      }
      if (this.endsArena(handle)) {
        offset = payload & ~ARENA_BIT;
      } else {
        this.copyToArena(handle);
      }
      appendAsciiUnits(inout this.smallBytes, bytes, count, wide);
      return this.allocateArenaString(offset, joinedBytes, wide);
    }
    if (!before && (payload & ARENA_BIT) == 0) {
      const buffer = usize(payload);
      const appendable = (this.bufferRefs[buffer] & BUFFER_APPENDABLE) != 0;
      if (appendable && u32(this.strings[buffer].length) == length) {
        if (!wide) {
          this.strings[buffer].append(bytes.slice(0, count));
        } else {
          let k: usize = 0;
          while (k < count) {
            this.strings[buffer].push(bytes[k]);
            this.strings[buffer].push(0);
            k = k + 1;
          }
        }
        this.bufferRefs[buffer] = this.bufferRefs[buffer] + 1;
        return this.allocateStringOver(u32(buffer), joinedBytes, wide);
      }
    }
    let joined = Array<u8>.withCapacity(usize(joinedBytes));
    if (before) appendAsciiUnits(inout joined, bytes, count, wide);
    this.copyStorage(handle, inout joined);
    if (!before) appendAsciiUnits(inout joined, bytes, count, wide);
    const stringIndex = this.adoptBuffer(move joined);
    this.bufferRefs[usize(stringIndex)] = BUFFER_APPENDABLE | 1;
    return this.allocateStringOver(stringIndex, joinedBytes, wide);
  }

  // A string whose units are these bytes' values, written straight from
  // the caller's bytes: a small one into the arena with no array of its
  // own.
  function allocateLatin1Slice(inout this, bytes: Slice<u8>): u32 {
    const count = bytes.length;
    if (count <= usize(SMALL_STRING_BYTES)) {
      const offset = u32(this.smallBytes.length);
      this.smallBytes.append(bytes);
      return this.allocateArenaString(offset, u32(count), false);
    }
    let copied = Array<u8>.withCapacity(count);
    copied.append(bytes);
    return this.allocateStorage(move copied, false);
  }

  // A string whose units are these bytes' values (ASCII or Latin-1).
  function allocateLatin1(inout this, bytes: Array<u8>): u32 {
    return this.allocateStorage(move bytes, false);
  }

  // A string of these units, stored narrow when it can be; a small one
  // is written straight into the arena.
  function allocateUnits(inout this, units: Array<u16>): u32 {
    const narrow = isNarrowUnits(in units);
    const byteCount = narrow ? units.length : units.length * 2;
    if (byteCount <= usize(SMALL_STRING_BYTES)) {
      const offset = u32(this.smallBytes.length);
      let i: usize = 0;
      while (i < units.length) {
        this.smallBytes.push(u8(units[i] & 0xFF));
        if (!narrow) this.smallBytes.push(u8(units[i] >> 8));
        i = i + 1;
      }
      return this.allocateArenaString(offset, u32(byteCount), !narrow);
    }
    if (narrow) return this.allocateStorage(unitsToLatin1(in units), false);
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
    return (this.cellHeader(handle).flags & FLAG_WIDE) != 0;
  }

  function isString(handle: u32): boolean {
    return this.cellHeader(handle).tag == TAG_STRING;
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
    return this.cellHeader(handle).tag == TAG_FUNCTION;
  }

  function functionIndex(handle: u32): u32 {
    return this.cellHeader(handle).payload;
  }

  // The length in code units.
  function stringLength(handle: u32): usize {
    const bytes = usize(this.cellHeader(handle).slotStart);
    if ((this.cellHeader(handle).flags & FLAG_WIDE) != 0) return bytes / 2;
    return bytes;
  }

  function stringUnit(handle: u32, index: usize): u16 {
    if ((this.cellHeader(handle).flags & FLAG_WIDE) != 0) {
      return u16(this.storageByte(handle, index * 2)) | (u16(this.storageByte(handle, index * 2 + 1)) << 8);
    }
    // A narrow string's byte, read where it is.
    const payload = this.cellHeader(handle).payload;
    if ((payload & ARENA_BIT) != 0) return u16(this.smallBytes[usize(payload & ~ARENA_BIT) + index]);
    return u16(this.strings[usize(payload)][index]);
  }

  // units[start, end) copied; the caller keeps end in range.
  function stringUnitsSlice(handle: u32, start: usize, end: usize): Array<u16> {
    let count: usize = 0;
    if (end > start) count = end - start;
    let copied = Array<u16>.withCapacity(count);
    const payload = this.cellHeader(handle).payload;
    const wide = (this.cellHeader(handle).flags & FLAG_WIDE) != 0;
    let index = start;
    if ((payload & ARENA_BIT) != 0) {
      const origin = usize(payload & ~ARENA_BIT);
      if (wide) {
        while (index < end) {
          copied.push(u16(this.smallBytes[origin + index * 2]) | (u16(this.smallBytes[origin + index * 2 + 1]) << 8));
          index = index + 1;
        }
        return copied;
      }
      while (index < end) {
        copied.push(u16(this.smallBytes[origin + index]));
        index = index + 1;
      }
      return copied;
    }
    const at = usize(payload);
    if (wide) {
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
  // storage form (no unit round trip); a small one straight into the
  // arena.
  function allocateSubstring(inout this, handle: u32, start: usize, end: usize): u32 {
    const wide = (this.cellHeader(handle).flags & FLAG_WIDE) != 0;
    if (wide) {
      // A wide slice may fit narrow; allocateUnits decides.
      return this.allocateUnits(this.stringUnitsSlice(handle, start, end));
    }
    let count: usize = 0;
    if (end > start) count = end - start;
    const payload = this.cellHeader(handle).payload;
    if (count <= usize(SMALL_STRING_BYTES)) {
      const offset = u32(this.smallBytes.length);
      let index = start;
      if ((payload & ARENA_BIT) != 0) {
        const origin = usize(payload & ~ARENA_BIT);
        while (index < end) {
          const byte = this.smallBytes[origin + index];
          this.smallBytes.push(byte);
          index = index + 1;
        }
      } else {
        const buffer = usize(payload);
        while (index < end) {
          const byte = this.strings[buffer][index];
          this.smallBytes.push(byte);
          index = index + 1;
        }
      }
      return this.allocateArenaString(offset, u32(count), false);
    }
    let bytes = Array<u8>.withCapacity(count);
    let index = start;
    while (index < end) {
      bytes.push(this.storageByte(handle, index));
      index = index + 1;
    }
    return this.allocateStorage(move bytes, false);
  }

  function stringUnits(handle: u32): Array<u16> {
    const length = this.stringLength(handle);
    return this.stringUnitsSlice(handle, 0, length);
  }

  // A string's hash: FNV-1a over its unit values, so a narrow string and
  // the units it stands for hash alike, with the top bit set. Computed
  // once: a string has no slots, so its header's slot count keeps it,
  // zero until then.
  function stringHash(inout this, handle: u32): u32 {
    const known = this.cellHeader(handle).slotCount;
    if (known != 0) return known;
    const payload = this.cellHeader(handle).payload;
    const length = usize(this.cellHeader(handle).slotStart);
    const wide = (this.cellHeader(handle).flags & FLAG_WIDE) != 0;
    let hash: u32 = 2166136261;
    let index: usize = 0;
    if ((payload & ARENA_BIT) != 0) {
      const origin = usize(payload & ~ARENA_BIT);
      if (!wide) {
        while (index < length) {
          hash = (hash ^ u32(this.smallBytes[origin + index])).wrappingMultiply(16777619);
          index = index + 1;
        }
      } else {
        while (index < length) {
          const unit = u32(this.smallBytes[origin + index]) | (u32(this.smallBytes[origin + index + 1]) << 8);
          hash = (hash ^ unit).wrappingMultiply(16777619);
          index = index + 2;
        }
      }
    } else {
      const at = usize(payload);
      if (!wide) {
        while (index < length) {
          hash = (hash ^ u32(this.strings[at][index])).wrappingMultiply(16777619);
          index = index + 1;
        }
      } else {
        while (index < length) {
          const unit = u32(this.strings[at][index]) | (u32(this.strings[at][index + 1]) << 8);
          hash = (hash ^ unit).wrappingMultiply(16777619);
          index = index + 2;
        }
      }
    }
    hash = hash | 0x8000_0000;
    this.headers[usize(handle)].slotCount = hash;
    return hash;
  }

  // Keep a string's hash, computed elsewhere from the same content.
  function cacheStringHash(inout this, handle: u32, hash: u32): void {
    this.headers[usize(handle)].slotCount = hash;
  }

  // Every place narrow string `needle` (not empty) occurs in narrow
  // string `hay`, left to right and not overlapping, appended to `cuts`:
  // one pass over the bytes where they are.
  function findAllNarrow(hay: u32, needle: u32, inout cuts: Array<usize>): void {
    const hayLength = usize(this.cellHeader(hay).slotStart);
    const needleLength = usize(this.cellHeader(needle).slotStart);
    if (needleLength == 0 || needleLength > hayLength) return;
    const hayPayload = this.cellHeader(hay).payload;
    const needlePayload = this.cellHeader(needle).payload;
    const hayStart = usize(hayPayload & ~ARENA_BIT);
    const needleStart = usize(needlePayload & ~ARENA_BIT);
    const hayArena = (hayPayload & ARENA_BIT) != 0;
    const needleArena = (needlePayload & ARENA_BIT) != 0;
    if (hayArena && needleArena) {
      findAllIn(this.smallBytes, hayStart, hayLength, this.smallBytes, needleStart, needleLength, inout cuts);
    } else if (hayArena) {
      findAllIn(this.smallBytes, hayStart, hayLength, this.strings[usize(needlePayload)], 0, needleLength, inout cuts);
    } else if (needleArena) {
      findAllIn(this.strings[usize(hayPayload)], 0, hayLength, this.smallBytes, needleStart, needleLength, inout cuts);
    } else {
      findAllIn(this.strings[usize(hayPayload)], 0, hayLength, this.strings[usize(needlePayload)], 0, needleLength, inout cuts);
    }
  }

  // Where the bytes of narrow string `needle` first occur in those of
  // narrow string `hay` at or after `startAt`, or -1: both read where they
  // are, nothing copied.
  function findNarrow(hay: u32, needle: u32, startAt: usize): i32 {
    const hayLength = usize(this.cellHeader(hay).slotStart);
    const needleLength = usize(this.cellHeader(needle).slotStart);
    if (needleLength == 0) return i32(startAt <= hayLength ? startAt : hayLength);
    if (needleLength > hayLength || startAt > hayLength - needleLength) return -1;
    const hayPayload = this.cellHeader(hay).payload;
    const needlePayload = this.cellHeader(needle).payload;
    const hayStart = usize(hayPayload & ~ARENA_BIT);
    const needleStart = usize(needlePayload & ~ARENA_BIT);
    const hayArena = (hayPayload & ARENA_BIT) != 0;
    const needleArena = (needlePayload & ARENA_BIT) != 0;
    if (hayArena && needleArena) return findIn(this.smallBytes, hayStart, hayLength, this.smallBytes, needleStart, needleLength, startAt);
    if (hayArena) return findIn(this.smallBytes, hayStart, hayLength, this.strings[usize(needlePayload)], 0, needleLength, startAt);
    if (needleArena) return findIn(this.strings[usize(hayPayload)], 0, hayLength, this.smallBytes, needleStart, needleLength, startAt);
    return findIn(this.strings[usize(hayPayload)], 0, hayLength, this.strings[usize(needlePayload)], 0, needleLength, startAt);
  }

  // The buffer in `strings` a string's storage is in, for a string that
  // is not in the arena.
  function stringBuffer(handle: u32): u32 {
    return this.cellHeader(handle).payload;
  }

  // The raw storage: Latin-1 bytes, or two bytes per unit when wide.
  function stringStorageLength(handle: u32): usize {
    return usize(this.cellHeader(handle).slotStart);
  }

  function stringStorageByte(handle: u32, index: usize): u8 {
    return this.storageByte(handle, index);
  }

  // A copy of the storage: the Latin-1 bytes of a narrow string (the
  // fast paths' working form), or the wide string's byte pairs.
  function stringStorageBytes(handle: u32): Array<u8> {
    let copied = Array<u8>.withCapacity(usize(this.cellHeader(handle).slotStart));
    this.copyStorage(handle, inout copied);
    return copied;
  }

  // The content as UTF-8 for the host (a lone surrogate becomes U+FFFD).
  function stringUtf8(handle: u32): Array<u8> {
    if ((this.cellHeader(handle).flags & FLAG_WIDE) != 0) {
      const units = this.stringUnits(handle);
      return unitsToUtf8(in units);
    }
    const length = usize(this.cellHeader(handle).slotStart);
    let bytes = Array<u8>.withCapacity(length);
    let index: usize = 0;
    while (index < length) {
      const byte = this.storageByte(handle, index);
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
    if ((this.cellHeader(handle).flags & FLAG_WIDE) == 0) return this.stringUtf8(handle);
    const units = this.stringUnits(handle);
    return unitsToWtf8(in units);
  }

  // Equal content: equal width (the narrow form is canonical) and equal
  // storage.
  function stringsEqual(a: u32, b: u32): boolean {
    if (a == b) return true;
    if (this.isWideString(a) != this.isWideString(b)) return false;
    const aPayload = this.cellHeader(a).payload;
    const bPayload = this.cellHeader(b).payload;
    const length = usize(this.cellHeader(a).slotStart);
    if (length != usize(this.cellHeader(b).slotStart)) return false;
    // Two hashes already known and different: different content.
    const aHash = this.cellHeader(a).slotCount;
    const bHash = this.cellHeader(b).slotCount;
    if (aHash != 0 && bHash != 0 && aHash != bHash) return false;
    // Two strings over the same bytes with one length are one content.
    if (aPayload == bPayload) return true;
    const aArena = (aPayload & ARENA_BIT) != 0;
    const bArena = (bPayload & ARENA_BIT) != 0;
    let aStart: usize = 0;
    if (aArena) aStart = usize(aPayload & ~ARENA_BIT);
    let bStart: usize = 0;
    if (bArena) bStart = usize(bPayload & ~ARENA_BIT);
    if (aArena && bArena) return sameStorage(this.smallBytes, aStart, this.smallBytes, bStart, length);
    if (aArena) return sameStorage(this.smallBytes, aStart, this.strings[usize(bPayload)], 0, length);
    if (bArena) return sameStorage(this.strings[usize(aPayload)], 0, this.smallBytes, bStart, length);
    return sameStorage(this.strings[usize(aPayload)], 0, this.strings[usize(bPayload)], 0, length);
  }

  // Ordering by code units, then by length: negative, zero, or positive.
  function compareStrings(a: u32, b: u32): i32 {
    const aLength = this.stringLength(a);
    const bLength = this.stringLength(b);
    const shorter = aLength < bLength ? aLength : bLength;
    let index: usize = 0;
    if (!this.isWideString(a) && !this.isWideString(b)) {
      while (index < shorter) {
        const ab = this.storageByte(a, index);
        const bb = this.storageByte(b, index);
        if (ab < bb) return -1;
        if (ab > bb) return 1;
        index = index + 1;
      }
    } else {
      while (index < shorter) {
        const ab = this.stringUnit(a, index);
        const bb = this.stringUnit(b, index);
        if (ab < bb) return -1;
        if (ab > bb) return 1;
        index = index + 1;
      }
    }
    if (aLength < bLength) return -1;
    if (aLength > bLength) return 1;
    return 0;
  }

  function allocateValue(inout this, tag: u8, slotCount: u32): Value {
    return cellValue(this.allocate(tag, slotCount));
  }

  // A cell's header. The engine reads the header only of a cell it can
  // reach, which is live, and every live handle indexes the table: a full
  // collection's trim cuts the table only above the highest survivor. No
  // value crosses the embedding ABI into a heap; an entry point that took
  // one would have to check it first. Checked in a debug build.
  function cellHeader(handle: u32): CellHeader {
    return unsafe { select this.headers.uncheckedAt(usize(handle)); };
  }

  function tagOf(handle: u32): u8 {
    return this.cellHeader(handle).tag;
  }

  function slotCountOf(handle: u32): u32 {
    return this.cellHeader(handle).slotCount;
  }

  // A slot of a live cell, which lies inside the slot arena; callers pass
  // an index below the cell's slot count. Checked in a debug build.
  function slot(handle: u32, index: u32): Value {
    const header = this.cellHeader(handle);
    return unsafe { select this.slots.uncheckedAt(usize(header.slotStart.wrappingAdd(index))); };
  }

  // Every store of a value into a cell's slots comes through here, and
  // so through the write barrier (see Generations).
  function setSlot(inout this, handle: u32, index: u32, value: Value): void {
    const header = this.cellHeader(handle);
    unsafe {
      this.slots.uncheckedSet(usize(header.slotStart.wrappingAdd(index)), value);
    }
    if (header.marked) this.rememberStore(handle, index, value);
  }

  // A property's attributes, by the slot its value is in: an object's
  // from its class or its dictionary, an array element's from its
  // array's table when it has one; the default for anything else.
  // Kept small, so it inlines where array elements are read: an array
  // without element attributes answers at once.
  function attrOf(handle: u32, index: u32): u8 {
    const tag = this.cellHeader(handle).tag;
    if (tag == TAG_ARRAY) {
      if ((this.cellHeader(handle).flags & FLAG_ELEMENT_ATTRS) == 0) return PROP_DEFAULT;
      return this.elementAttrOf(handle, index);
    }
    if (tag == TAG_OBJECT) return this.objectAttrOf(handle, index);
    return PROP_DEFAULT;
  }

  function objectAttrOf(handle: u32, index: u32): u8 {
    const payload = this.cellHeader(handle).payload;
    if ((payload & DICT_BIT) != 0) return this.pairAttr(payload & (DICT_BIT - 1), (index - 1) / 2);
    if (usize(index) >= this.classes[usize(payload)].slotAttrs.length) return PROP_DEFAULT;
    return this.classes[usize(payload)].slotAttrs[usize(index)];
  }

  function elementAttrOf(handle: u32, index: u32): u8 {
    const entry = this.elementAttrEntry(handle);
    if (entry < 0 || usize(index) >= this.elementAttrs[usize(entry)].attrs.length) return PROP_DEFAULT;
    return this.elementAttrs[usize(entry)].attrs[usize(index)];
  }

  // Give the property in a slot `attr`. A class-mode object moves to the
  // class with that property's attributes changed (see classWithAttr).
  function setAttr(inout this, handle: u32, index: u32, attr: u8): void {
    const tag = this.cellHeader(handle).tag;
    if (tag == TAG_OBJECT) {
      const payload = this.cellHeader(handle).payload;
      if ((payload & DICT_BIT) != 0) {
        this.setPairAttr(payload & (DICT_BIT - 1), (index - 1) / 2, attr);
        return;
      }
      if (usize(index) >= this.classes[usize(payload)].slotAttrs.length) return;
      if (this.classes[usize(payload)].slotAttrs[usize(index)] == attr) return;
      this.headers[usize(handle)].payload = this.classWithAttr(payload, index, attr);
      return;
    }
    if (tag == TAG_ARRAY) {
      let entry = this.elementAttrEntry(handle);
      if (entry < 0) {
        if (attr == PROP_DEFAULT) return;
        entry = this.addElementAttrs(handle);
      }
      const held = this.elementAttrs[usize(entry)].attrs.length;
      if (held <= usize(index)) this.elementAttrs[usize(entry)].attrs.appendRepeated(PROP_DEFAULT, usize(index) + 1 - held);
      this.elementAttrs[usize(entry)].attrs[usize(index)] = attr;
    }
  }

  // --- Element attributes ---

  function elementAttrHash(handle: u32, mask: usize): usize {
    return usize(handle.wrappingMultiply(2654435761) >> 7) & mask;
  }

  // The entry holding an array's element attributes, or -1.
  function elementAttrEntry(handle: u32): i32 {
    if ((this.cellHeader(handle).flags & FLAG_ELEMENT_ATTRS) == 0) return -1;
    const size = this.elementAttrIndex.length;
    if (size == 0) return -1;
    let probe = this.elementAttrHash(handle, size - 1);
    while (true) {
      const held = this.elementAttrIndex[probe];
      if (held == 0) return -1;
      if (this.elementAttrs[usize(held - 1)].owner == handle) return i32(held - 1);
      probe = (probe + 1) & (size - 1);
    }
    return -1;
  }

  function addElementAttrs(inout this, handle: u32): i32 {
    let entry: usize = 0;
    let found = false;
    while (entry < this.elementAttrs.length) {
      if (this.elementAttrs[entry].owner == 0) {
        found = true;
        break;
      }
      entry = entry + 1;
    }
    if (found) {
      this.elementAttrs[entry] = ElementAttrs({ owner: handle, attrs: Array<u8>() });
    } else {
      this.elementAttrs.push(ElementAttrs({ owner: handle, attrs: Array<u8>() }));
      entry = this.elementAttrs.length - 1;
    }
    this.headers[usize(handle)].flags = this.cellHeader(handle).flags | FLAG_ELEMENT_ATTRS;
    this.rebuildElementAttrIndex();
    return i32(entry);
  }

  function releaseElementAttrs(inout this, handle: u32): void {
    const entry = this.elementAttrEntry(handle);
    if (entry < 0) return;
    this.elementAttrs[usize(entry)] = ElementAttrs({ owner: 0, attrs: Array<u8>() });
    this.rebuildElementAttrIndex();
  }

  // The index at least twice the entries, rebuilt over the live ones.
  function rebuildElementAttrIndex(inout this): void {
    let size: usize = 8;
    while (size < this.elementAttrs.length * 2) {
      size = size * 2;
    }
    let index = Array<u32>.withCapacity(size);
    index.appendRepeated(0, size);
    let entry: usize = 0;
    while (entry < this.elementAttrs.length) {
      const owner = this.elementAttrs[entry].owner;
      if (owner != 0) {
        let probe = this.elementAttrHash(owner, size - 1);
        while (index[probe] != 0) { probe = (probe + 1) & (size - 1); }
        index[probe] = u32(entry + 1);
      }
      entry = entry + 1;
    }
    this.elementAttrIndex = move index;
  }

  function flagsOf(handle: u32): u8 {
    return this.cellHeader(handle).flags;
  }

  function setFlags(inout this, handle: u32, flags: u8): void {
    this.headers[usize(handle)].flags = flags;
  }

  // Define an own property with attributes, adding it if absent: a new
  // one takes its attributes in the transition that adds it.
  function objectDefine(inout this, handle: u32, atom: u32, value: Value, attr: u8): void {
    const existing = this.objectFindSlot(handle, atom);
    if (existing >= 0) {
      this.setSlot(handle, u32(existing), value);
      this.setAttr(handle, u32(existing), attr);
      return;
    }
    this.objectAddWith(handle, atom, value, attr);
  }

  // An accessor pair, held in a slot flagged PROP_ACCESSOR.
  function allocateAccessor(inout this, getter: Value, setter: Value): u32 {
    const handle = this.allocate(TAG_ACCESSOR, 2);
    this.setSlot(handle, 0, getter);
    this.setSlot(handle, 1, setter);
    return handle;
  }

  function isAccessor(handle: u32): boolean {
    return this.cellHeader(handle).tag == TAG_ACCESSOR;
  }

  function marked(handle: u32): boolean {
    return this.cellHeader(handle).marked;
  }

  function setMarked(inout this, handle: u32, value: boolean): void {
    this.headers[usize(handle)].marked = value;
  }

  // Allocated cells, excluding the reserved handle 0.
  // Whether a handle's cell has been freed: listed for reuse, or cut
  // from the table with everything above the highest survivor.
  function isReleased(handle: u32): boolean {
    if (usize(handle) >= this.headerCount) return true;
    return this.cellHeader(handle).tag == TAG_FREE;
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

  // Headers and slots of the cells the last collection found alive:
  // what the last full one kept and the minor ones promoted since.
  function bytesLiveAtLastCollection(): f64 {
    return f64(this.majorCells + this.promotedCells) * HEADER_BYTES + f64(this.majorSlots + this.promotedSlots) * 8.0;
  }

  // The slot arena, and the full collection's sorting scratch.
  function arenaBytesHeld(): f64 {
    return f64(this.slots.capacity) * 8.0 + f64(this.slideCounts.capacity + this.slideOrder.capacity) * 4.0;
  }

  // The handle table with its free list, the mark stack, and the
  // collector's lists.
  function tableBytesHeld(): f64 {
    return f64(this.headers.capacity) * HEADER_BYTES + f64(this.freeHandles.capacity) * 4.0 + f64(this.markStack.capacity) * 4.0 + f64(this.growLog.capacity) * 8.0 + f64(this.rememberedCells.capacity) * 4.0 + f64(this.rememberedSlots.capacity) * 8.0 + f64(this.deadYoung.capacity + this.deadAtoms.capacity) * 4.0;
  }

  // The string table: an array per string plus each one's content.
  function stringBytesHeld(): f64 {
    let held: f64 = f64(this.strings.capacity) * 24.0 + f64(this.freeStrings.capacity) * 4.0;
    held = held + f64(this.smallBytes.capacity);
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
    let held: f64 = f64(this.classes.capacity) * 112.0 + f64(this.dictionaries.capacity) * 64.0 + f64(this.freeDictionaries.capacity) * 4.0;
    held = held + f64(this.weakRecords.capacity) * 4.0 + f64(this.pendingScratchBytes());
    let index: usize = 0;
    while (index < this.classes.length) {
      held = held + f64(this.classes[index].transitionNames.capacity) * 4.0 + f64(this.classes[index].transitionChildren.capacity) * 4.0;
      held = held + f64(this.classes[index].transitionAttrs.capacity) + f64(this.classes[index].slotAttrs.capacity);
      index = index + 1;
    }
    index = 0;
    while (index < this.dictionaries.length) {
      held = held + f64(this.dictionaries[index].index.capacity) * 4.0 + f64(this.dictionaries[index].attrs.capacity);
      index = index + 1;
    }
    held = held + f64(this.elementAttrs.capacity) * 32.0 + f64(this.elementAttrIndex.capacity) * 4.0;
    index = 0;
    while (index < this.elementAttrs.length) {
      held = held + f64(this.elementAttrs[index].attrs.capacity);
      index = index + 1;
    }
    held = held + f64(this.tables.capacity) * 104.0 + f64(this.freeTables.capacity) * 4.0;
    index = 0;
    while (index < this.tables.length) {
      held = held + f64(this.tables[index].keys.capacity + this.tables[index].values.capacity) * 8.0;
      held = held + f64(this.tables[index].hashes.capacity + this.tables[index].index.capacity) * 4.0;
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
    return f64(this.headerCount) * HEADER_BYTES + f64(this.slots.length) * 8.0 + stringBytes + f64(this.smallBytes.length);
  }
}

// A large array's next capacity: four times the current, at least
// `needed`.
function grownCapacity(capacity: usize, needed: usize): usize {
  let next = capacity * 4;
  if (next < 1024) next = 1024;
  if (next < needed) next = needed;
  return next;
}

// `count` zeros, whatever `values` held.
function fillZeros(inout values: Array<u32>, count: usize): void {
  values.clear();
  values.appendRepeated(0, count);
}

// Each count replaced by the sum of those before it.
function prefixSums(inout values: Array<u32>): void {
  let running: u32 = 0;
  let i: usize = 0;
  while (i < values.length) {
    const counted = values[i];
    values[i] = running;
    running = running + counted;
    i = i + 1;
  }
}

// The first offset at or after `startAt` where the `needleLength` bytes at
// `needleStart` of `needle` occur among the `hayLength` at `hayStart` of
// `hay`, or -1 (the needle is not empty and fits).
function findIn(hay: Slice<u8>, hayStart: usize, hayLength: usize, needle: Slice<u8>, needleStart: usize, needleLength: usize, startAt: usize): i32 {
  // A start is tried only when the needle's first and last bytes both
  // match there, which rules out most starts that share a prefix.
  const first = needle[needleStart];
  const lastOffset = needleLength - 1;
  const lastByte = needle[needleStart + lastOffset];
  const last = hayLength - needleLength;
  let start = startAt;
  while (start <= last) {
    if (hay[hayStart + start] == first && hay[hayStart + start + lastOffset] == lastByte) {
      let k: usize = 1;
      while (k < needleLength && hay[hayStart + start + k] == needle[needleStart + k]) { k = k + 1; }
      if (k == needleLength) return i32(start);
    }
    start = start + 1;
  }
  return -1;
}

// Every occurrence of `needle` in `hay`, as findAllNarrow: a byte at a
// time for a one-byte needle, the common separator.
function findAllIn(hay: Slice<u8>, hayStart: usize, hayLength: usize, needle: Slice<u8>, needleStart: usize, needleLength: usize, inout cuts: Array<usize>): void {
  const first = needle[needleStart];
  if (needleLength == 1) {
    let index: usize = 0;
    while (index < hayLength) {
      if (hay[hayStart + index] == first) cuts.push(index);
      index = index + 1;
    }
    return;
  }
  const last = hayLength - needleLength;
  let start: usize = 0;
  while (start <= last) {
    if (hay[hayStart + start] == first) {
      let k: usize = 1;
      while (k < needleLength && hay[hayStart + start + k] == needle[needleStart + k]) { k = k + 1; }
      if (k == needleLength) {
        cuts.push(start);
        start = start + needleLength;
      } else {
        start = start + 1;
      }
    } else {
      start = start + 1;
    }
  }
}

// `count` ASCII bytes appended to `target` as string units: in one copy
// for a narrow string, each followed by a zero byte for a wide one.
function appendAsciiUnits(inout target: Array<u8>, bytes: Slice<u8>, count: usize, wide: boolean): void {
  if (!wide) {
    target.append(bytes.slice(0, count));
    return;
  }
  let k: usize = 0;
  while (k < count) {
    target.push(bytes[k]);
    target.push(0);
    k = k + 1;
  }
}

// `storage`[first, last) appended to `bytes` in one copy.
export function appendRange(storage: Slice<u8>, first: usize, last: usize, bytes: Array<u8>): Array<u8> {
  let appended = move bytes;
  appended.append(storage.slice(first, last));
  return appended;
}

// The position of `key` among a table's entries, or -1: its index,
// hashes, and keys passed as slices, so the probe keeps their bounds in
// registers.
function probeTable(in heap: Heap, index: Slice<i32>, hashes: Slice<u32>, keys: Slice<Value>, key: Value, hash: u32): i32 {
  const mask = u32(index.length) - 1;
  let slot = hash & mask;
  while (true) {
    const held = index[usize(slot)];
    if (held == TABLE_EMPTY) return -1;
    if (held >= 0 && hashes[usize(held)] == hash) {
      const candidate = keys[usize(held)];
      if (candidate.bits == key.bits || heap.sameKey(candidate, key)) return held;
    }
    slot = (slot + 1) & mask;
  }
  return -1;
}

function sameStorage(a: Slice<u8>, aStart: usize, b: Slice<u8>, bStart: usize, length: usize): boolean {
  let index: usize = 0;
  while (index < length) {
    if (a[aStart + index] != b[bStart + index]) return false;
    index = index + 1;
  }
  return true;
}

export function createHeap(): Heap {
  let headers = Array<CellHeader>();
  // Handle 0 is reserved; push a sentinel so live handles start at 1.
  headers.push(CellHeader({ tag: TAG_RESERVED, marked: false, flags: 0, remembered: false, slotStart: 0, slotCount: 0, payload: 0, link: 0 }));
  let classes = Array<HiddenClass>();
  // Class 0 is the empty root every object starts from.
  classes.push(HiddenClass({
    parent: 0, transitionName: 0, transitionSlot: 0, propCount: 0, slotAttrs: Array<u8>(),
    transitionNames: Array<u32>(), transitionAttrs: Array<u8>(), transitionChildren: Array<u32>(),
  }));
  return Heap({
    headers: move headers, slots: Array<Value>(), slideCounts: Array<u32>(), slideOrder: Array<u32>(), elementAttrs: Array<ElementAttrs>(), elementAttrIndex: Array<u32>(), slotsAfterSweep: 0, headerCount: 1, cellsBeforeCycle: 0.0, slotsBeforeCycle: 0.0, strings: Array<Array<u8>>(), smallBytes: Array<u8>(), smallLiveBytes: 0, bufferRefs: Array<u32>(), classes: move classes,
    freeHandles: Array<u32>(), freeHandleCount: 0, freeStrings: Array<u32>(), freeStringCount: 0,
    weakRecords: Array<u32>(), pendingKeys: Array<u32>(), pendingValues: Array<Value>(), pendingNext: Array<u32>(), pendingBuckets: Array<u32>(), pendingMask: 0, pendingCount: 0,
    weakCleared: 0, ephemeronPasses: 0, weakVisits: 0, markedCells: 0, markedSlots: 0,
    tables: Array<Table>(), freeTables: Array<u32>(), freeTableCount: 0,
    dictionaries: Array<Dictionary>(), freeDictionaries: Array<u32>(), freeDictionaryCount: 0, dictThreshold: DICT_THRESHOLD, indexKeysDefined: false,
    markStack: Array<u32>(), markCount: 0,
    allocatedSinceCollect: 0, collectThreshold: NURSERY_CELLS, collections: 0, collectFloor: COLLECT_FLOOR, collectGrowthPercent: COLLECT_GROWTH_PERCENT,
    cycleFreeCount: 0, cycleExtent: 1, growLog: Array<u64>(), rememberedCells: Array<u32>(), rememberedSlots: Array<u64>(), deadYoung: Array<u32>(), deadAtoms: Array<u32>(), tailBase: 0, byteTailBase: 0, minorCollection: false, nurseryCells: NURSERY_CELLS,
    promotedCells: 0, promotedSlots: 0, majorThreshold: COLLECT_FLOOR, majorCells: 0, majorSlots: 0, minorCollections: 0,
  });
}

// A full collection sorts the survivors' slot ranges by buckets of 8
// arena slots, and small strings by buckets of 16 bytes: a bucket holds
// few enough that one pass of insertion sort orders them.
const SLIDE_SLOT_SHIFT: u32 = 3;
const SLIDE_BYTE_SHIFT: u32 = 4;
// A handle table never made larger than this is not worth rebuilding.
const HANDLE_TABLE_SHRINK_AT: usize = 65536;
// A table shorter than this is walked whole rather than cut back.
const HANDLE_TABLE_CUT_AT: usize = 32768;
// The fewest cells promoted between full collections, and the multiple
// of what the last one kept (in percent) that replaces it once larger.
const COLLECT_FLOOR: u32 = 4096;
const COLLECT_GROWTH_PERCENT: u32 = 200;
// Allocations between minor collections.
const NURSERY_CELLS: u32 = 16384;
// Entries the collector's lists keep room for between collections.
const LOG_RETAIN_ENTRIES: usize = 65536;
// A cell with this many slots, or a table with this many entries, is
// remembered by the slot or entry; up to this many such are listed
// between collections.
const LARGE_CELL_SLOTS: usize = 256;
const REMEMBERED_SLOTS_LIMIT: usize = 262144;
// A cell header as laid out: four bytes of tag, mark, flags, and the
// remembered bit, then four u32 fields.
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
  if (count > 0) copied.append(bytes.slice(start, end));
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
  heap.beginMajor();
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
  heap.beginMajor();
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
  const back = testNames(inout heap, 1);
  heap.objectSet(value, back[0], cellValue(key));
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
    const link = testNames(inout heap, 1);
    heap.objectSet(holder, link[0], cellValue(k2));
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
  const via = testNames(inout heap, 1);
  heap.objectSet(carrier, via[0], cellValue(b));
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
  const chainNames = testNames(inout heap, links);
  i = 0;
  while (i < links) {
    const record = heap.allocateWeakRecord(2);
    const holder = heap.allocateObject(0);
    heap.objectSet(holder, chainNames[usize(i)], cellValue(keys[usize(i + 1)]));
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

// --- Generations ---

// A full collection keeping `roots`, after which they are old.
function collectFull(inout heap: Heap, in roots: Array<u32>): void {
  heap.beginMajor();
  let i: usize = 0;
  while (i < roots.length) {
    heap.markHandle(roots[i]);
    i = i + 1;
  }
  heap.sweep();
}

// A minor collection over explicit roots.
function collectMinor(inout heap: Heap, in roots: Array<u32>): void {
  heap.beginMinor();
  let i: usize = 0;
  while (i < roots.length) {
    heap.markHandle(roots[i]);
    i = i + 1;
  }
  heap.traceRemembered();
  heap.sweepYoung();
  heap.finishMinor();
}

test "a minor collection frees unreached young cells and keeps old ones it does not trace" {
  let heap = createHeap();
  let roots = Array<u32>();
  const old = heap.allocateObject(0);
  roots.push(old);
  collectFull(inout heap, in roots);
  const kept = heap.allocateObject(0);
  const dropped = heap.allocateObject(0);
  let young = Array<u32>();
  young.push(kept);
  collectMinor(inout heap, in young);
  expect(heap.isReleased(dropped)).toEqual(true);
  expect(heap.isObject(old)).toEqual(true);
  expect(heap.isObject(kept)).toEqual(true);
  // A survivor is old: the next minor collection keeps it unreached.
  const empty = Array<u32>();
  collectMinor(inout heap, in empty);
  expect(heap.isObject(kept)).toEqual(true);
  // A full collection lets go of what nothing reaches.
  collectFull(inout heap, in empty);
  expect(heap.isReleased(kept)).toEqual(true);
  expect(heap.isReleased(old)).toEqual(true);
}

test "an old cell given a young one keeps it through a minor collection" {
  let heap = createHeap();
  let roots = Array<u32>();
  const holder = heap.allocateObject(0);
  const large = heap.allocateArray(300);
  const table = heap.allocateTable(0);
  const child = heap.allocateObject(0);
  roots.push(holder);
  roots.push(large);
  roots.push(table);
  roots.push(child);
  collectFull(inout heap, in roots);
  const bySlot = heap.allocateObject(0);
  const byLargeSlot = heap.allocateObject(0);
  const byLink = heap.allocateObject(0);
  const byKey = heap.allocateObject(0);
  const byValue = heap.allocateObject(0);
  const unreached = heap.allocateObject(0);
  heap.setSlot(holder, 0, cellValue(bySlot));
  heap.arraySet(large, 299, cellValue(byLargeSlot));
  heap.setObjectProto(child, byLink);
  heap.tableAdd(table, cellValue(byKey), cellValue(byValue), 7);
  const empty = Array<u32>();
  collectMinor(inout heap, in empty);
  expect(heap.isObject(bySlot)).toEqual(true);
  expect(heap.isObject(byLargeSlot)).toEqual(true);
  expect(heap.isObject(byLink)).toEqual(true);
  expect(heap.isObject(byKey)).toEqual(true);
  expect(heap.isObject(byValue)).toEqual(true);
  expect(heap.isReleased(unreached)).toEqual(true);
  expect(asCell(heap.arrayGet(large, 299))).toEqual(byLargeSlot);
}

test "a minor collection slides the young ranges still in use down and cuts the arena back" {
  let heap = createHeap();
  let roots = Array<u32>();
  const grown = heap.allocateArray(2);
  heap.arraySet(grown, 0, int32Value(5));
  roots.push(grown);
  collectFull(inout heap, in roots);
  const base = heap.slotsInUse();
  const deadFirst = heap.allocateObject(0);
  const kept = heap.allocateObject(0);
  heap.setSlot(kept, 3, int32Value(7));
  const deadArray = heap.allocateArray(3);
  // An old array outgrows its slots: the new range is above the base.
  heap.arraySet(grown, 5, int32Value(9));
  const alsoKept = heap.allocateArray(2);
  heap.arraySet(alsoKept, 1, int32Value(11));
  let young = Array<u32>();
  young.push(kept);
  young.push(alsoKept);
  collectMinor(inout heap, in young);
  expect(heap.isReleased(deadFirst)).toEqual(true);
  expect(heap.isReleased(deadArray)).toEqual(true);
  const expected = base + heap.slotCountOf(kept) + heap.slotCountOf(grown) + heap.slotCountOf(alsoKept);
  expect(heap.slotsInUse()).toEqual(expected);
  expect(asInt32(heap.slot(kept, 3))).toEqual(7);
  expect(asInt32(heap.arrayGet(grown, 0))).toEqual(5);
  expect(asInt32(heap.arrayGet(grown, 5))).toEqual(9);
  expect(asInt32(heap.arrayGet(alsoKept, 1))).toEqual(11);
}

test "young strings sharing bytes keep their text through a minor collection" {
  let heap = createHeap();
  let roots = Array<u32>();
  const old = heap.allocateText("old");
  roots.push(old);
  collectFull(inout heap, in roots);
  // Extends the old string in place: stays where it is.
  const er: String = "er";
  const erBytes = bytesOf(in er);
  const older = heap.concatAscii(old, erBytes, 2, false);
  const deadFirst = heap.allocateText("zz");
  const abc = heap.allocateText("abc");
  const def: String = "def";
  const defBytes = bytesOf(in def);
  const abcdef = heap.concatAscii(abc, defBytes, 3, false);
  const gh: String = "gh";
  const ghBytes = bytesOf(in gh);
  const abcdefgh = heap.concatAscii(abcdef, ghBytes, 2, false);
  const tail = heap.allocateText("tail");
  let young = Array<u32>();
  young.push(older);
  young.push(abcdef);
  young.push(abcdefgh);
  young.push(tail);
  collectMinor(inout heap, in young);
  expect(heap.isReleased(deadFirst)).toEqual(true);
  expect(heap.isReleased(abc)).toEqual(true);
  expect(heap.stringsEqual(old, heap.allocateText("old"))).toEqual(true);
  expect(heap.stringsEqual(older, heap.allocateText("older"))).toEqual(true);
  expect(heap.stringsEqual(abcdef, heap.allocateText("abcdef"))).toEqual(true);
  expect(heap.stringsEqual(abcdefgh, heap.allocateText("abcdefgh"))).toEqual(true);
  expect(heap.stringsEqual(tail, heap.allocateText("tail"))).toEqual(true);
}

test "a full collection slides the survivors' slots and string bytes down in place" {
  let heap = createHeap();
  let roots = Array<u32>();
  const first = heap.allocateObject(0);
  const dead = heap.allocateArray(3);
  const grown = heap.allocateArray(2);
  const last = heap.allocateObject(0);
  heap.setSlot(first, 1, int32Value(1));
  heap.arraySet(grown, 0, int32Value(2));
  heap.setSlot(last, 3, int32Value(4));
  // Its slots move above `last`'s: arena order is no longer handle order.
  heap.arraySet(grown, 9, int32Value(3));
  // Enough dead small strings that the byte arena is compacted too, and a
  // run of strings sharing bytes whose first member dies.
  let filler: u32 = 0;
  while (filler < 1200) {
    const junk = heap.allocateText("0123456789012345678901234567890123456789012345678901234567890123");
    filler = filler + 1;
  }
  const abc = heap.allocateText("abc");
  const def: String = "def";
  const defBytes = bytesOf(in def);
  const abcdef = heap.concatAscii(abc, defBytes, 3, false);
  const gh: String = "gh";
  const ghBytes = bytesOf(in gh);
  const abcdefgh = heap.concatAscii(abcdef, ghBytes, 2, false);
  roots.push(first);
  roots.push(grown);
  roots.push(last);
  roots.push(abcdefgh);
  roots.push(abcdef);
  collectFull(inout heap, in roots);
  expect(heap.isReleased(dead)).toEqual(true);
  expect(heap.isReleased(abc)).toEqual(true);
  const expected = heap.slotCountOf(first) + heap.slotCountOf(grown) + heap.slotCountOf(last);
  expect(heap.slotsInUse()).toEqual(expected);
  expect(asInt32(heap.slot(first, 1))).toEqual(1);
  expect(asInt32(heap.arrayGet(grown, 0))).toEqual(2);
  expect(asInt32(heap.arrayGet(grown, 9))).toEqual(3);
  expect(asInt32(heap.slot(last, 3))).toEqual(4);
  // The run keeps one copy of its bytes.
  const eight: usize = 8;
  expect(heap.smallBytes.length).toEqual(eight);
  expect(heap.stringsEqual(abcdef, heap.allocateText("abcdef"))).toEqual(true);
  expect(heap.stringsEqual(abcdefgh, heap.allocateText("abcdefgh"))).toEqual(true);
}
