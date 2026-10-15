#!/usr/bin/env python3
"""The dispatch loop threaded, in a copy of the generated C: an experiment.

Rewrites Runtime.runFrames in zjsz.c, to measure what Z would gain from a
way to write the loop as separate instruction handlers:

  tail  every instruction's arm becomes a function of its own, which ends
        by fetching the next instruction and tail-calling its handler
        through a table (clang's musttail). The loop's state (ip, base,
        codeStart, frameIndex, fi) travels in arguments, and the handlers
        use preserve_none, so it stays in registers across calls into
        helpers. An arm that breaks out of the loop or returns leaves
        through a record the loop reads back. The switch keeps only its
        default arm.
  goto  the arms stay in the one function; each ends by fetching the next
        instruction and jumping to its arm (computed goto).

Usage, from the repository root:
    ./z/bench/speed/thread-dispatch.py tail z/tools/zjsz/.z-cache/build/zjsz.c OUT.c
    ./z/bench/speed/placements.py build OUT.c PREFIX

The patterns match the C generated for ZJS 506cf27 by z-lang d48e790b;
other versions may need them adjusted. tail needs clang 17 or later.
"""
import re
import sys

SIG = ("Z_UNUSED_FUNCTION static Z___z_module_2_RunResult Z___z_module_2_Runtime_runFrames("
       "Z___z_module_2_Runtime *self, uint32_t entryDepth) {")
ARM = r'\n          case Z_module_6_Op_(\w+): \{'

TAIL_PRELUDE = '''
typedef struct ZT_Cold {
  Z___z_module_1_Value result; Z___z_module_1_Value thrown; bool throwing; bool returned;
  uint32_t entryDepth; int exit; Z___z_module_6_Inst inst;
  uintptr_t ip; uint32_t base; uintptr_t codeStart; uintptr_t frameIndex; uint32_t fi;
} ZT_Cold;
#define ZT_ARGS Z___z_module_2_Runtime *self, Z___z_module_6_Inst inst, uintptr_t ip, uint32_t base, uintptr_t codeStart, uintptr_t frameIndex, uint32_t fi, ZT_Cold *zt_cold
typedef __attribute__((preserve_none)) void (*ZT_Handler)(ZT_ARGS);
static ZT_Handler zt_table[256];
#define ZT_SAVE do { zt_cold->ip = ip; zt_cold->base = base; zt_cold->codeStart = codeStart; zt_cold->frameIndex = frameIndex; zt_cold->fi = fi; } while (0)
#define ZT_NEXT do { const Z___z_module_6_Inst zt_next = (self->codeSegment).data[codeStart + ip]; __attribute__((musttail)) return zt_table[(zt_next).op.tag](self, zt_next, ip + 1, base, codeStart, frameIndex, fi, zt_cold); } while (0)
#define ZT_BREAK do { ZT_SAVE; zt_cold->exit = 1; zt_cold->result = result; zt_cold->thrown = thrown; zt_cold->throwing = throwing; zt_cold->returned = returned; return; } while (0)
#define ZT_AFTER do { if (self->pendingThrow) { thrown = Z___z_module_2_Runtime_takePending(self); throwing = true; ZT_BREAK; } ZT_NEXT; } while (0)
__attribute__((preserve_none)) static void zt_fallback(ZT_ARGS) { ZT_SAVE; zt_cold->exit = 2; zt_cold->inst = inst; }
'''

TAIL_HANDLER = '''__attribute__((preserve_none)) static void zt_%s(ZT_ARGS) {
  const uint32_t entryDepth = zt_cold->entryDepth; (void)entryDepth;
  Z___z_module_1_Value result = _z_function___z_module_1_undefinedValue(); (void)result;
  Z___z_module_1_Value thrown = _z_function___z_module_1_undefinedValue(); (void)thrown;
  bool throwing = false; (void)throwing;
  bool returned = false; (void)returned;
  %s
  ZT_AFTER;
}
'''

# The loop's fetch becomes a threaded run; an instruction without a
# handler comes back and goes through the switch's default arm.
TAIL_FETCH = '''
    while (true) {
      {
        ZT_Cold zt_cold; zt_cold.entryDepth = entryDepth;
        { const Z___z_module_6_Inst zt_first = (self->codeSegment).data[codeStart + ip];
          zt_table[(zt_first).op.tag](self, zt_first, ip + 1, base, codeStart, frameIndex, fi, &zt_cold); }
        ip = zt_cold.ip; base = zt_cold.base; codeStart = zt_cold.codeStart; frameIndex = zt_cold.frameIndex; fi = zt_cold.fi;
        if (zt_cold.exit == 1) { result = zt_cold.result; thrown = zt_cold.thrown; throwing = zt_cold.throwing; returned = zt_cold.returned; goto _z_loop_break_2; }
        const Z___z_module_6_Inst inst = zt_cold.inst;
        (void)inst;
'''

GOTO_MACROS = '''
#define ZG_NEXT do { inst = (self->codeSegment).data[codeStart + ip]; ip = ip + 1; op = (inst).op; _z_match_0 = op; goto *zg_table[(op).tag]; } while (0)
#define ZG_AFTER do { if (self->pendingThrow) { thrown = Z___z_module_2_Runtime_takePending(self); throwing = true; goto _z_loop_break_2; } ZG_NEXT; } while (0)
'''


def tail(fn):
    starts = {m.group(1): m.start() for m in re.finditer(ARM, fn)}
    bounds = sorted(m.start() for m in re.finditer(r'\n          (?:case Z_module_6_Op_\w+|default): \{', fn))
    names = sorted(starts, key=starts.get)
    spans, handlers = [], []
    for name in names:
        at = starts[name]
        end = min(b for b in bounds if b > at)
        spans.append((at, end))
        head = 'case Z_module_6_Op_%s: {' % name
        body = fn[at:end]
        body = body[body.index(head) + len(head):]
        body = body[:body.rstrip().rfind('}')]  # the case block's closing brace
        body = body.replace('goto _z_loop_continue_2;', 'ZT_NEXT;').replace('goto _z_loop_break_2;', 'ZT_BREAK;')
        # The arm's own break, to the check after the switch.
        body = re.sub(r'\n            break;\s*$', '\n            ZT_AFTER;\n', body)
        handlers.append(TAIL_HANDLER % (name, body))
    for at, end in sorted(spans, reverse=True):
        fn = fn[:at] + fn[end:]
    fetch = re.search(r'\n    while \(true\) \{\n      \{\n        const Z___z_module_6_Inst inst = '
                      r'\(\(self->codeSegment\)\.data\[[^\n]*\n        \(void\)inst;\n'
                      r'        ip = z_wrapping_add_usize\(ip, 1ULL\);\n', fn)
    assert fetch, 'the loop fetch was not found'
    fn = fn[:fetch.start()] + TAIL_FETCH + fn[fetch.end():]
    table = ('static ZT_Handler zt_table[256] = { [0 ... 255] = zt_fallback, %s };\n'
             % ', '.join('[Z_module_6_Op_%s] = zt_%s' % (n, n) for n in names))
    return TAIL_PRELUDE + '\n'.join(handlers) + table + fn, len(names)


def goto(fn):
    for old, new in [
        ('        const Z___z_module_6_Inst inst = ((self->codeSegment)', '        Z___z_module_6_Inst inst = ((self->codeSegment)'),
        ('        const Z_module_6_Op op = (inst).op;', '        Z_module_6_Op op = (inst).op;'),
        ('        const Z_module_6_Op _z_match_0 = op;', '        Z_module_6_Op _z_match_0 = op;'),
    ]:
        assert fn.count(old) == 1, old
        fn = fn.replace(old, new)
    at = fn.index('        switch (_z_match_0.tag) {')
    end = fn.index('\n        if (self->pendingThrow) {', at)
    switch = fn[at:end]
    names = re.findall(ARM, switch)
    switch = re.sub(ARM, r'\n          case Z_module_6_Op_\1: zg_\1: {', switch)
    assert switch.count('\n          default: {') == 1
    switch = switch.replace('\n          default: {', '\n          default: zg_default: {')
    switch = switch.replace('goto _z_loop_continue_2;', 'ZG_NEXT;')
    switch = re.sub(r'\n            break;\n          \}', '\n            ZG_AFTER;\n          }', switch)
    fn = fn[:at] + switch + fn[end:]
    table = ('\n  static void *const zg_table[256] = { [0 ... 255] = &&zg_default, %s };\n'
             % ', '.join('[Z_module_6_Op_%s] = &&zg_%s' % (n, n) for n in names))
    return GOTO_MACROS + fn.replace(SIG, SIG + table, 1), len(names)


def main(args):
    if len(args) != 3 or args[0] not in ('tail', 'goto'):
        sys.exit(__doc__.strip().split('\n\n')[-2])
    mode, source, out = args
    text = open(source).read()
    start = text.index(SIG)
    end = text.index('\n}\n', start) + 3
    fn, count = (tail if mode == 'tail' else goto)(text[start:end])
    open(out, 'w').write(text[:start] + fn + text[end:])
    print('%s: %d instructions threaded' % (mode, count))


if __name__ == '__main__':
    main(sys.argv[1:])
