// @ts-check
const sep = '/';
const delimiter = ':';

function assertString(p) {
  if (typeof p !== 'string') {
    throw new TypeError('Path must be a string. Received ' + typeof p);
  }
}

function isAbsolute(p) {
  assertString(p);
  return p.length > 0 && p.charCodeAt(0) === 47;
}

// Collapses runs of '/', removes '.' segments, resolves '..' segments
// against the preceding segment when possible. Preserves a leading '/'
// (absolute) and a trailing '/' when the input had one and the
// normalized form isn't '/'.
function normalizeStringPosix(path, allowAboveRoot) {
  let res = '';
  let lastSegLen = 0;
  let lastSlash = -1;
  let dots = 0;
  let code = 0;
  for (let i = 0; i <= path.length; ++i) {
    if (i < path.length) code = path.charCodeAt(i);
    else if (code === 47) break;
    else code = 47;
    if (code === 47) {
      if (lastSlash === i - 1 || dots === 1) {
        // empty segment or '.' â skip
      } else if (lastSlash !== i - 1 && dots === 2) {
        if (res.length < 2 || lastSegLen !== 2
            || res.charCodeAt(res.length - 1) !== 46
            || res.charCodeAt(res.length - 2) !== 46) {
          if (res.length > 2) {
            const lastSlashIndex = res.lastIndexOf('/');
            if (lastSlashIndex !== res.length - 1) {
              if (lastSlashIndex === -1) {
                res = '';
                lastSegLen = 0;
              } else {
                res = res.slice(0, lastSlashIndex);
                lastSegLen = res.length - 1 - res.lastIndexOf('/');
              }
              lastSlash = i;
              dots = 0;
              continue;
            }
          } else if (res.length === 2 || res.length === 1) {
            res = '';
            lastSegLen = 0;
            lastSlash = i;
            dots = 0;
            continue;
          }
        }
        if (allowAboveRoot) {
          if (res.length > 0) res += '/..'; else res = '..';
          lastSegLen = 2;
        }
      } else {
        if (res.length > 0) res += '/' + path.slice(lastSlash + 1, i);
        else res = path.slice(lastSlash + 1, i);
        lastSegLen = i - lastSlash - 1;
      }
      lastSlash = i;
      dots = 0;
    } else if (code === 46 && dots !== -1) {
      ++dots;
    } else {
      dots = -1;
    }
  }
  return res;
}

function normalize(p) {
  assertString(p);
  if (p.length === 0) return '.';
  const abs = p.charCodeAt(0) === 47;
  const trailingSep = p.charCodeAt(p.length - 1) === 47;
  p = normalizeStringPosix(p, !abs);
  if (p.length === 0 && !abs) p = '.';
  if (p.length > 0 && trailingSep) p += '/';
  return abs ? '/' + p : p;
}

function join(...args) {
  if (args.length === 0) return '.';
  let joined;
  for (let i = 0; i < args.length; ++i) {
    const arg = args[i];
    assertString(arg);
    if (arg.length > 0) {
      if (joined === undefined) joined = arg;
      else joined += '/' + arg;
    }
  }
  if (joined === undefined) return '.';
  return normalize(joined);
}

function resolve(...args) {
  let resolved = '';
  let resolvedAbs = false;
  for (let i = args.length - 1; i >= -1 && !resolvedAbs; i--) {
    let p;
    if (i >= 0) p = args[i];
    else {
      // Last resort: process.cwd() when available, else '/'.
      p = (typeof globalThis !== 'undefined'
           && globalThis.process
           && typeof globalThis.process.cwd === 'function')
        ? globalThis.process.cwd()
        : '/';
    }
    assertString(p);
    if (p.length === 0) continue;
    resolved = p + '/' + resolved;
    resolvedAbs = p.charCodeAt(0) === 47;
  }
  resolved = normalizeStringPosix(resolved, !resolvedAbs);
  if (resolvedAbs) return '/' + resolved;
  return resolved.length > 0 ? resolved : '.';
}

function relative(from, to) {
  assertString(from);
  assertString(to);
  if (from === to) return '';
  from = resolve(from);
  to = resolve(to);
  if (from === to) return '';
  // Trim leading '/' before comparing segments.
  const fromStart = 1;
  const fromEnd = from.length;
  const fromLen = fromEnd - fromStart;
  const toStart = 1;
  const toLen = to.length - toStart;
  const length = fromLen < toLen ? fromLen : toLen;
  let lastCommonSep = -1;
  let i = 0;
  for (; i < length; i++) {
    const fc = from.charCodeAt(fromStart + i);
    if (fc !== to.charCodeAt(toStart + i)) break;
    if (fc === 47) lastCommonSep = i;
  }
  if (i === length) {
    if (toLen > length) {
      if (to.charCodeAt(toStart + i) === 47) return to.slice(toStart + i + 1);
      if (i === 0) return to.slice(toStart + i);
    } else if (fromLen > length) {
      if (from.charCodeAt(fromStart + i) === 47) lastCommonSep = i;
      else if (i === 0) lastCommonSep = 0;
    }
  }
  let out = '';
  for (i = fromStart + lastCommonSep + 1; i <= fromEnd; ++i) {
    if (i === fromEnd || from.charCodeAt(i) === 47) {
      out += out.length === 0 ? '..' : '/..';
    }
  }
  if (out.length > 0) return out + to.slice(toStart + lastCommonSep);
  let toAdj = toStart + lastCommonSep;
  if (to.charCodeAt(toAdj) === 47) toAdj++;
  return to.slice(toAdj);
}

function dirname(p) {
  assertString(p);
  if (p.length === 0) return '.';
  const hasRoot = p.charCodeAt(0) === 47;
  let end = -1;
  let matchedSlash = true;
  for (let i = p.length - 1; i >= 1; --i) {
    if (p.charCodeAt(i) === 47) {
      if (!matchedSlash) { end = i; break; }
    } else {
      matchedSlash = false;
    }
  }
  if (end === -1) return hasRoot ? '/' : '.';
  if (hasRoot && end === 1) return '//';
  return p.slice(0, end);
}

function basename(p, ext) {
  assertString(p);
  if (ext !== undefined) assertString(ext);
  let start = 0;
  let end = -1;
  let matchedSlash = true;
  if (ext !== undefined && ext.length > 0 && ext.length <= p.length) {
    if (ext.length === p.length && ext === p) return '';
    let extIdx = ext.length - 1;
    let firstNonSlashEnd = -1;
    for (let i = p.length - 1; i >= 0; --i) {
      const code = p.charCodeAt(i);
      if (code === 47) {
        if (!matchedSlash) { start = i + 1; break; }
      } else {
        if (firstNonSlashEnd === -1) {
          matchedSlash = false;
          firstNonSlashEnd = i + 1;
        }
        if (extIdx >= 0) {
          if (code === ext.charCodeAt(extIdx)) {
            if (--extIdx === -1) end = i;
          } else {
            extIdx = -1;
            end = firstNonSlashEnd;
          }
        }
      }
    }
    if (start === end) end = firstNonSlashEnd;
    else if (end === -1) end = p.length;
    return p.slice(start, end);
  }
  for (let i = p.length - 1; i >= 0; --i) {
    if (p.charCodeAt(i) === 47) {
      if (!matchedSlash) { start = i + 1; break; }
    } else if (end === -1) {
      matchedSlash = false;
      end = i + 1;
    }
  }
  if (end === -1) return '';
  return p.slice(start, end);
}

function extname(p) {
  assertString(p);
  let startDot = -1;
  let startPart = 0;
  let end = -1;
  let matchedSlash = true;
  let preDotState = 0;
  for (let i = p.length - 1; i >= 0; --i) {
    const code = p.charCodeAt(i);
    if (code === 47) {
      if (!matchedSlash) { startPart = i + 1; break; }
      continue;
    }
    if (end === -1) { matchedSlash = false; end = i + 1; }
    if (code === 46) {
      if (startDot === -1) startDot = i;
      else if (preDotState !== 1) preDotState = 1;
    } else if (startDot !== -1) {
      preDotState = -1;
    }
  }
  if (startDot === -1 || end === -1 || preDotState === 0
      || (preDotState === 1 && startDot === end - 1 && startDot === startPart + 1)) {
    return '';
  }
  return p.slice(startDot, end);
}

function parse(p) {
  assertString(p);
  const ret = { root: '', dir: '', base: '', ext: '', name: '' };
  if (p.length === 0) return ret;
  const isAbs = p.charCodeAt(0) === 47;
  if (isAbs) ret.root = '/';
  ret.dir = dirname(p);
  ret.base = basename(p);
  ret.ext = extname(p);
  ret.name = ret.base.slice(0, ret.base.length - ret.ext.length);
  return ret;
}

function format(pathObject) {
  if (pathObject === null || typeof pathObject !== 'object') {
    throw new TypeError('pathObject must be a non-null object');
  }
  const dir = pathObject.dir || pathObject.root || '';
  const base = pathObject.base
            || ((pathObject.name || '') + (pathObject.ext || ''));
  if (!dir) return base;
  if (dir === pathObject.root) return dir + base;
  return dir + '/' + base;
}

export {
  sep, delimiter,
  isAbsolute, normalize, join, resolve, relative,
  dirname, basename, extname, parse, format,
};
export default {
  sep, delimiter,
  isAbsolute, normalize, join, resolve, relative,
  dirname, basename, extname, parse, format,
};
