// @ts-check
// node:path — POSIX + Windows personalities, adapted from Node's
// lib/path.js. The default export is the personality matching the host
// (process.platform === 'win32' → win32, else posix); both are always
// reachable as path.posix / path.win32.

const CHAR_UPPERCASE_A = 65;
const CHAR_LOWERCASE_A = 97;
const CHAR_UPPERCASE_Z = 90;
const CHAR_LOWERCASE_Z = 122;
const CHAR_DOT = 46;
const CHAR_FORWARD_SLASH = 47;
const CHAR_BACKWARD_SLASH = 92;
const CHAR_COLON = 58;
const CHAR_QUESTION_MARK = 63;

function assertString(p) {
  if (typeof p !== 'string') {
    throw new TypeError('Path must be a string. Received ' + typeof p);
  }
}

function isPosixPathSeparator(code) {
  return code === CHAR_FORWARD_SLASH;
}

function isWindowsPathSeparator(code) {
  return code === CHAR_FORWARD_SLASH || code === CHAR_BACKWARD_SLASH;
}

function isWindowsDeviceRoot(code) {
  return (code >= CHAR_UPPERCASE_A && code <= CHAR_UPPERCASE_Z)
      || (code >= CHAR_LOWERCASE_A && code <= CHAR_LOWERCASE_Z);
}

// Resolves . and .. elements in a path with directory names. `separator`
// is the literal output separator; `isPathSeparator` classifies input
// separators (Windows accepts both / and \).
function normalizeString(path, allowAboveRoot, separator, isPathSeparator) {
  let res = '';
  let lastSegmentLength = 0;
  let lastSlash = -1;
  let dots = 0;
  let code = 0;
  for (let i = 0; i <= path.length; ++i) {
    if (i < path.length) code = path.charCodeAt(i);
    else if (isPathSeparator(code)) break;
    else code = CHAR_FORWARD_SLASH;

    if (isPathSeparator(code)) {
      if (lastSlash === i - 1 || dots === 1) {
        // empty segment or '.' — skip
      } else if (dots === 2) {
        if (res.length < 2 || lastSegmentLength !== 2
            || res.charCodeAt(res.length - 1) !== CHAR_DOT
            || res.charCodeAt(res.length - 2) !== CHAR_DOT) {
          if (res.length > 2) {
            const lastSlashIndex = res.lastIndexOf(separator);
            if (lastSlashIndex === -1) {
              res = '';
              lastSegmentLength = 0;
            } else {
              res = res.slice(0, lastSlashIndex);
              lastSegmentLength = res.length - 1 - res.lastIndexOf(separator);
            }
            lastSlash = i;
            dots = 0;
            continue;
          } else if (res.length !== 0) {
            res = '';
            lastSegmentLength = 0;
            lastSlash = i;
            dots = 0;
            continue;
          }
        }
        if (allowAboveRoot) {
          res += res.length > 0 ? separator + '..' : '..';
          lastSegmentLength = 2;
        }
      } else {
        if (res.length > 0) res += separator + path.slice(lastSlash + 1, i);
        else res = path.slice(lastSlash + 1, i);
        lastSegmentLength = i - lastSlash - 1;
      }
      lastSlash = i;
      dots = 0;
    } else if (code === CHAR_DOT && dots !== -1) {
      ++dots;
    } else {
      dots = -1;
    }
  }
  return res;
}

// ---------------------------------------------------------------------
// POSIX
// ---------------------------------------------------------------------

function posixCwd() {
  if (typeof globalThis !== 'undefined' && globalThis.process
      && typeof globalThis.process.cwd === 'function') {
    return globalThis.process.cwd();
  }
  return '/';
}

const posix = {
  sep: '/',
  delimiter: ':',

  isAbsolute(p) {
    assertString(p);
    return p.length > 0 && p.charCodeAt(0) === CHAR_FORWARD_SLASH;
  },

  normalize(p) {
    assertString(p);
    if (p.length === 0) return '.';
    const isAbsolute = p.charCodeAt(0) === CHAR_FORWARD_SLASH;
    const trailingSeparator =
      p.charCodeAt(p.length - 1) === CHAR_FORWARD_SLASH;
    p = normalizeString(p, !isAbsolute, '/', isPosixPathSeparator);
    if (p.length === 0) {
      if (isAbsolute) return '/';
      return trailingSeparator ? './' : '.';
    }
    if (trailingSeparator) p += '/';
    return isAbsolute ? '/' + p : p;
  },

  join(...args) {
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
    return posix.normalize(joined);
  },

  resolve(...args) {
    let resolvedPath = '';
    let resolvedAbsolute = false;
    for (let i = args.length - 1; i >= -1 && !resolvedAbsolute; i--) {
      const path = i >= 0 ? args[i] : posixCwd();
      assertString(path);
      if (path.length === 0) continue;
      resolvedPath = path + '/' + resolvedPath;
      resolvedAbsolute = path.charCodeAt(0) === CHAR_FORWARD_SLASH;
    }
    resolvedPath = normalizeString(resolvedPath, !resolvedAbsolute, '/',
                                   isPosixPathSeparator);
    if (resolvedAbsolute) return '/' + resolvedPath;
    return resolvedPath.length > 0 ? resolvedPath : '.';
  },

  relative(from, to) {
    assertString(from);
    assertString(to);
    if (from === to) return '';
    from = posix.resolve(from);
    to = posix.resolve(to);
    if (from === to) return '';

    const fromStart = 1;
    const fromEnd = from.length;
    const fromLen = fromEnd - fromStart;
    const toStart = 1;
    const toLen = to.length - toStart;
    const length = fromLen < toLen ? fromLen : toLen;
    let lastCommonSep = -1;
    let i = 0;
    for (; i < length; i++) {
      const fromCode = from.charCodeAt(fromStart + i);
      if (fromCode !== to.charCodeAt(toStart + i)) break;
      if (fromCode === CHAR_FORWARD_SLASH) lastCommonSep = i;
    }
    if (i === length) {
      if (toLen > length) {
        if (to.charCodeAt(toStart + i) === CHAR_FORWARD_SLASH) {
          return to.slice(toStart + i + 1);
        }
        if (i === 0) return to.slice(toStart + i);
      } else if (fromLen > length) {
        if (from.charCodeAt(fromStart + i) === CHAR_FORWARD_SLASH) {
          lastCommonSep = i;
        } else if (i === 0) {
          lastCommonSep = 0;
        }
      }
    }
    let out = '';
    for (i = fromStart + lastCommonSep + 1; i <= fromEnd; ++i) {
      if (i === fromEnd || from.charCodeAt(i) === CHAR_FORWARD_SLASH) {
        out += out.length === 0 ? '..' : '/..';
      }
    }
    return out + to.slice(toStart + lastCommonSep);
  },

  dirname(p) {
    assertString(p);
    if (p.length === 0) return '.';
    const hasRoot = p.charCodeAt(0) === CHAR_FORWARD_SLASH;
    let end = -1;
    let matchedSlash = true;
    for (let i = p.length - 1; i >= 1; --i) {
      if (p.charCodeAt(i) === CHAR_FORWARD_SLASH) {
        if (!matchedSlash) { end = i; break; }
      } else {
        matchedSlash = false;
      }
    }
    if (end === -1) return hasRoot ? '/' : '.';
    if (hasRoot && end === 1) return '//';
    return p.slice(0, end);
  },

  basename(p, ext) {
    if (ext !== undefined) assertString(ext);
    assertString(p);
    let start = 0;
    let end = -1;
    let matchedSlash = true;
    if (ext !== undefined && ext.length > 0 && ext.length <= p.length) {
      if (ext === p) return '';
      let extIdx = ext.length - 1;
      let firstNonSlashEnd = -1;
      for (let i = p.length - 1; i >= 0; --i) {
        const code = p.charCodeAt(i);
        if (code === CHAR_FORWARD_SLASH) {
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
      if (p.charCodeAt(i) === CHAR_FORWARD_SLASH) {
        if (!matchedSlash) { start = i + 1; break; }
      } else if (end === -1) {
        matchedSlash = false;
        end = i + 1;
      }
    }
    if (end === -1) return '';
    return p.slice(start, end);
  },

  extname(p) {
    assertString(p);
    let startDot = -1;
    let startPart = 0;
    let end = -1;
    let matchedSlash = true;
    let preDotState = 0;
    for (let i = p.length - 1; i >= 0; --i) {
      const code = p.charCodeAt(i);
      if (code === CHAR_FORWARD_SLASH) {
        if (!matchedSlash) { startPart = i + 1; break; }
        continue;
      }
      if (end === -1) { matchedSlash = false; end = i + 1; }
      if (code === CHAR_DOT) {
        if (startDot === -1) startDot = i;
        else if (preDotState !== 1) preDotState = 1;
      } else if (startDot !== -1) {
        preDotState = -1;
      }
    }
    if (startDot === -1 || end === -1 || preDotState === 0
        || (preDotState === 1 && startDot === end - 1
            && startDot === startPart + 1)) {
      return '';
    }
    return p.slice(startDot, end);
  },

  format(pathObject) {
    return _format('/', pathObject);
  },

  parse(p) {
    assertString(p);
    const ret = { root: '', dir: '', base: '', ext: '', name: '' };
    if (p.length === 0) return ret;
    const isAbsolute = p.charCodeAt(0) === CHAR_FORWARD_SLASH;
    let start;
    if (isAbsolute) { ret.root = '/'; start = 1; } else { start = 0; }
    let startDot = -1;
    let startPart = 0;
    let end = -1;
    let matchedSlash = true;
    let i = p.length - 1;
    let preDotState = 0;
    for (; i >= start; --i) {
      const code = p.charCodeAt(i);
      if (code === CHAR_FORWARD_SLASH) {
        if (!matchedSlash) { startPart = i + 1; break; }
        continue;
      }
      if (end === -1) { matchedSlash = false; end = i + 1; }
      if (code === CHAR_DOT) {
        if (startDot === -1) startDot = i;
        else if (preDotState !== 1) preDotState = 1;
      } else if (startDot !== -1) {
        preDotState = -1;
      }
    }
    if (end !== -1) {
      const dirStart = startPart === 0 && isAbsolute ? 1 : startPart;
      if (startDot === -1 || preDotState === 0
          || (preDotState === 1 && startDot === end - 1
              && startDot === startPart + 1)) {
        ret.base = ret.name = p.slice(startPart, end);
      } else {
        ret.name = p.slice(startPart, startDot);
        ret.base = p.slice(startPart, end);
        ret.ext = p.slice(startDot, end);
      }
      if (dirStart > 0) ret.dir = p.slice(0, dirStart - 1);
      else if (isAbsolute) ret.dir = '/';
    } else if (isAbsolute) {
      ret.dir = '/';
    }
    return ret;
  },
};

// ---------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------

const win32 = {
  sep: '\\',
  delimiter: ';',

  isAbsolute(p) {
    assertString(p);
    const len = p.length;
    if (len === 0) return false;
    const code = p.charCodeAt(0);
    if (isWindowsPathSeparator(code)) return true;
    // Possible device root: "C:\" or "C:/".
    if (isWindowsDeviceRoot(code) && len > 2 && p.charCodeAt(1) === CHAR_COLON) {
      return isWindowsPathSeparator(p.charCodeAt(2));
    }
    return false;
  },

  normalize(p) {
    assertString(p);
    const len = p.length;
    if (len === 0) return '.';
    let rootEnd = 0;
    let device;
    let isAbsolute = false;
    const code = p.charCodeAt(0);

    if (len === 1) {
      return isPosixPathSeparator(code) ? '\\' : p;
    }
    if (isWindowsPathSeparator(code)) {
      isAbsolute = true;
      if (isWindowsPathSeparator(p.charCodeAt(1))) {
        // UNC: \\server\share
        let j = 2;
        let last = j;
        while (j < len && !isWindowsPathSeparator(p.charCodeAt(j))) j++;
        if (j < len && j !== last) {
          const firstPart = p.slice(last, j);
          last = j;
          while (j < len && isWindowsPathSeparator(p.charCodeAt(j))) j++;
          if (j < len && j !== last) {
            last = j;
            while (j < len && !isWindowsPathSeparator(p.charCodeAt(j))) j++;
            if (j === len) {
              return '\\\\' + firstPart + '\\' + p.slice(last) + '\\';
            }
            if (j !== last) {
              device = '\\\\' + firstPart + '\\' + p.slice(last, j);
              rootEnd = j;
            }
          }
        }
      } else {
        rootEnd = 1;
      }
    } else if (isWindowsDeviceRoot(code) && p.charCodeAt(1) === CHAR_COLON) {
      device = p.slice(0, 2);
      rootEnd = 2;
      if (len > 2 && isWindowsPathSeparator(p.charCodeAt(2))) {
        isAbsolute = true;
        rootEnd = 3;
      }
    }

    let tail = rootEnd < len
      ? normalizeString(p.slice(rootEnd), !isAbsolute, '\\',
                        isWindowsPathSeparator)
      : '';
    if (tail.length === 0 && !isAbsolute) tail = '.';
    if (tail.length > 0 && isWindowsPathSeparator(p.charCodeAt(len - 1))) {
      tail += '\\';
    }
    if (device === undefined) {
      return isAbsolute ? '\\' + tail : tail;
    }
    return isAbsolute ? device + '\\' + tail : device + tail;
  },

  join(...args) {
    if (args.length === 0) return '.';
    let joined;
    let firstPart;
    for (let i = 0; i < args.length; ++i) {
      const arg = args[i];
      assertString(arg);
      if (arg.length > 0) {
        if (joined === undefined) joined = firstPart = arg;
        else joined += '\\' + arg;
      }
    }
    if (joined === undefined) return '.';
    // Collapse a run of separators at the join of the first two parts
    // into one — except a UNC root needs exactly two leading separators.
    let needsReplace = true;
    let slashCount = 0;
    if (isWindowsPathSeparator(firstPart.charCodeAt(0))) {
      ++slashCount;
      const firstLen = firstPart.length;
      if (firstLen > 1 && isWindowsPathSeparator(firstPart.charCodeAt(1))) {
        ++slashCount;
        if (firstLen > 2) {
          if (isWindowsPathSeparator(firstPart.charCodeAt(2))) ++slashCount;
          else needsReplace = false;
        }
      }
    }
    if (needsReplace) {
      while (slashCount < joined.length
             && isWindowsPathSeparator(joined.charCodeAt(slashCount))) {
        slashCount++;
      }
      if (slashCount >= 2) joined = '\\' + joined.slice(slashCount);
    }
    return win32.normalize(joined);
  },

  resolve(...args) {
    let resolvedDevice = '';
    let resolvedTail = '';
    let resolvedAbsolute = false;
    for (let i = args.length - 1; i >= -1; i--) {
      let path;
      if (i >= 0) {
        path = args[i];
        assertString(path);
        if (path.length === 0) continue;
      } else if (resolvedDevice.length === 0) {
        path = posixCwd();
      } else {
        // Per-drive cwd isn't tracked; fall back to "<device>\".
        path = resolvedDevice + '\\';
      }

      const len = path.length;
      let rootEnd = 0;
      let device = '';
      let isAbsolute = false;
      const code = path.charCodeAt(0);

      if (len === 1) {
        if (isWindowsPathSeparator(code)) { rootEnd = 1; isAbsolute = true; }
      } else if (isWindowsPathSeparator(code)) {
        isAbsolute = true;
        if (isWindowsPathSeparator(path.charCodeAt(1))) {
          let j = 2;
          let last = j;
          while (j < len && !isWindowsPathSeparator(path.charCodeAt(j))) j++;
          if (j < len && j !== last) {
            const firstPart = path.slice(last, j);
            last = j;
            while (j < len && isWindowsPathSeparator(path.charCodeAt(j))) j++;
            if (j < len && j !== last) {
              last = j;
              while (j < len && !isWindowsPathSeparator(path.charCodeAt(j))) j++;
              if (j === len) {
                device = '\\\\' + firstPart + '\\' + path.slice(last);
                rootEnd = j;
              } else if (j !== last) {
                device = '\\\\' + firstPart + '\\' + path.slice(last, j);
                rootEnd = j;
              }
            }
          }
        } else {
          rootEnd = 1;
        }
      } else if (isWindowsDeviceRoot(code) && path.charCodeAt(1) === CHAR_COLON) {
        device = path.slice(0, 2);
        rootEnd = 2;
        if (len > 2 && isWindowsPathSeparator(path.charCodeAt(2))) {
          isAbsolute = true;
          rootEnd = 3;
        }
      }

      if (device.length > 0) {
        if (resolvedDevice.length > 0) {
          if (device.toLowerCase() !== resolvedDevice.toLowerCase()) continue;
        } else {
          resolvedDevice = device;
        }
      }

      if (resolvedAbsolute) {
        if (resolvedDevice.length > 0) break;
      } else {
        resolvedTail = path.slice(rootEnd) + '\\' + resolvedTail;
        resolvedAbsolute = isAbsolute;
        if (isAbsolute && resolvedDevice.length > 0) break;
      }
    }

    resolvedTail = normalizeString(resolvedTail, !resolvedAbsolute, '\\',
                                   isWindowsPathSeparator);
    if (resolvedAbsolute) return resolvedDevice + '\\' + resolvedTail;
    if ((resolvedDevice + resolvedTail).length > 0) {
      return resolvedDevice + resolvedTail;
    }
    return '.';
  },

  relative(from, to) {
    assertString(from);
    assertString(to);
    if (from === to) return '';
    const fromOrig = win32.resolve(from);
    const toOrig = win32.resolve(to);
    if (fromOrig === toOrig) return '';
    from = fromOrig.toLowerCase();
    to = toOrig.toLowerCase();
    if (from === to) return '';

    let fromStart = 0;
    while (fromStart < from.length
           && from.charCodeAt(fromStart) === CHAR_BACKWARD_SLASH) fromStart++;
    let fromEnd = from.length;
    while (fromEnd - 1 > fromStart
           && from.charCodeAt(fromEnd - 1) === CHAR_BACKWARD_SLASH) fromEnd--;
    const fromLen = fromEnd - fromStart;

    let toStart = 0;
    while (toStart < to.length
           && to.charCodeAt(toStart) === CHAR_BACKWARD_SLASH) toStart++;
    let toEnd = to.length;
    while (toEnd - 1 > toStart
           && to.charCodeAt(toEnd - 1) === CHAR_BACKWARD_SLASH) toEnd--;
    const toLen = toEnd - toStart;

    const length = fromLen < toLen ? fromLen : toLen;
    let lastCommonSep = -1;
    let i = 0;
    for (; i < length; i++) {
      const fromCode = from.charCodeAt(fromStart + i);
      if (fromCode !== to.charCodeAt(toStart + i)) break;
      if (fromCode === CHAR_BACKWARD_SLASH) lastCommonSep = i;
    }
    if (i !== length) {
      if (lastCommonSep === -1) return toOrig;
    } else {
      if (toLen > length) {
        if (to.charCodeAt(toStart + i) === CHAR_BACKWARD_SLASH) {
          return toOrig.slice(toStart + i + 1);
        }
        if (i === 2) return toOrig.slice(toStart + i);
      }
      if (fromLen > length) {
        if (from.charCodeAt(fromStart + i) === CHAR_BACKWARD_SLASH) {
          lastCommonSep = i;
        } else if (i === 2) {
          lastCommonSep = 3;
        }
      }
      if (lastCommonSep === -1) lastCommonSep = 0;
    }
    let out = '';
    for (i = fromStart + lastCommonSep + 1; i <= fromEnd; ++i) {
      if (i === fromEnd || from.charCodeAt(i) === CHAR_BACKWARD_SLASH) {
        out += out.length === 0 ? '..' : '\\..';
      }
    }
    toStart += lastCommonSep;
    if (out.length > 0) return out + toOrig.slice(toStart, toEnd);
    if (toOrig.charCodeAt(toStart) === CHAR_BACKWARD_SLASH) ++toStart;
    return toOrig.slice(toStart, toEnd);
  },

  dirname(p) {
    assertString(p);
    const len = p.length;
    if (len === 0) return '.';
    let rootEnd = -1;
    let offset = 0;
    const code = p.charCodeAt(0);

    if (len === 1) return isWindowsPathSeparator(code) ? p : '.';

    if (isWindowsPathSeparator(code)) {
      rootEnd = offset = 1;
      if (isWindowsPathSeparator(p.charCodeAt(1))) {
        let j = 2;
        let last = j;
        while (j < len && !isWindowsPathSeparator(p.charCodeAt(j))) j++;
        if (j < len && j !== last) {
          last = j;
          while (j < len && isWindowsPathSeparator(p.charCodeAt(j))) j++;
          if (j < len && j !== last) {
            last = j;
            while (j < len && !isWindowsPathSeparator(p.charCodeAt(j))) j++;
            if (j === len) return p;
            if (j !== last) rootEnd = offset = j + 1;
          }
        }
      }
    } else if (isWindowsDeviceRoot(code) && p.charCodeAt(1) === CHAR_COLON) {
      rootEnd = len > 2 && isWindowsPathSeparator(p.charCodeAt(2)) ? 3 : 2;
      offset = rootEnd;
    }

    let end = -1;
    let matchedSlash = true;
    for (let i = len - 1; i >= offset; --i) {
      if (isWindowsPathSeparator(p.charCodeAt(i))) {
        if (!matchedSlash) { end = i; break; }
      } else {
        matchedSlash = false;
      }
    }
    if (end === -1) {
      if (rootEnd === -1) return '.';
      end = rootEnd;
    }
    return p.slice(0, end);
  },

  basename(p, ext) {
    if (ext !== undefined) assertString(ext);
    assertString(p);
    let start = 0;
    let end = -1;
    let matchedSlash = true;
    // A drive-letter prefix can't be a basename component.
    if (p.length >= 2 && isWindowsDeviceRoot(p.charCodeAt(0))
        && p.charCodeAt(1) === CHAR_COLON) {
      start = 2;
    }
    if (ext !== undefined && ext.length > 0 && ext.length <= p.length) {
      if (ext === p) return '';
      let extIdx = ext.length - 1;
      let firstNonSlashEnd = -1;
      for (let i = p.length - 1; i >= start; --i) {
        const code = p.charCodeAt(i);
        if (isWindowsPathSeparator(code)) {
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
    for (let i = p.length - 1; i >= start; --i) {
      if (isWindowsPathSeparator(p.charCodeAt(i))) {
        if (!matchedSlash) { start = i + 1; break; }
      } else if (end === -1) {
        matchedSlash = false;
        end = i + 1;
      }
    }
    if (end === -1) return '';
    return p.slice(start, end);
  },

  extname(p) {
    assertString(p);
    let start = 0;
    let startDot = -1;
    let startPart = 0;
    let end = -1;
    let matchedSlash = true;
    let preDotState = 0;
    if (p.length >= 2 && p.charCodeAt(1) === CHAR_COLON
        && isWindowsDeviceRoot(p.charCodeAt(0))) {
      start = startPart = 2;
    }
    for (let i = p.length - 1; i >= start; --i) {
      const code = p.charCodeAt(i);
      if (isWindowsPathSeparator(code)) {
        if (!matchedSlash) { startPart = i + 1; break; }
        continue;
      }
      if (end === -1) { matchedSlash = false; end = i + 1; }
      if (code === CHAR_DOT) {
        if (startDot === -1) startDot = i;
        else if (preDotState !== 1) preDotState = 1;
      } else if (startDot !== -1) {
        preDotState = -1;
      }
    }
    if (startDot === -1 || end === -1 || preDotState === 0
        || (preDotState === 1 && startDot === end - 1
            && startDot === startPart + 1)) {
      return '';
    }
    return p.slice(startDot, end);
  },

  format(pathObject) {
    return _format('\\', pathObject);
  },

  parse(p) {
    assertString(p);
    const ret = { root: '', dir: '', base: '', ext: '', name: '' };
    const len = p.length;
    if (len === 0) return ret;
    let rootEnd = 0;
    let code = p.charCodeAt(0);

    if (len === 1) {
      if (isWindowsPathSeparator(code)) {
        ret.root = ret.dir = p;
        return ret;
      }
      ret.base = ret.name = p;
      return ret;
    }

    if (isWindowsPathSeparator(code)) {
      rootEnd = 1;
      if (isWindowsPathSeparator(p.charCodeAt(1))) {
        let j = 2;
        let last = j;
        while (j < len && !isWindowsPathSeparator(p.charCodeAt(j))) j++;
        if (j < len && j !== last) {
          last = j;
          while (j < len && isWindowsPathSeparator(p.charCodeAt(j))) j++;
          if (j < len && j !== last) {
            last = j;
            while (j < len && !isWindowsPathSeparator(p.charCodeAt(j))) j++;
            if (j === len) rootEnd = j;
            else if (j !== last) rootEnd = j + 1;
          }
        }
      }
    } else if (isWindowsDeviceRoot(code) && p.charCodeAt(1) === CHAR_COLON) {
      if (len <= 2) {
        ret.root = ret.dir = p;
        return ret;
      }
      rootEnd = 2;
      if (isWindowsPathSeparator(p.charCodeAt(2))) {
        if (len === 3) {
          ret.root = ret.dir = p;
          return ret;
        }
        rootEnd = 3;
      }
    }
    if (rootEnd > 0) ret.root = p.slice(0, rootEnd);

    let startDot = -1;
    let startPart = rootEnd;
    let end = -1;
    let matchedSlash = true;
    let i = len - 1;
    let preDotState = 0;
    for (; i >= rootEnd; --i) {
      code = p.charCodeAt(i);
      if (isWindowsPathSeparator(code)) {
        if (!matchedSlash) { startPart = i + 1; break; }
        continue;
      }
      if (end === -1) { matchedSlash = false; end = i + 1; }
      if (code === CHAR_DOT) {
        if (startDot === -1) startDot = i;
        else if (preDotState !== 1) preDotState = 1;
      } else if (startDot !== -1) {
        preDotState = -1;
      }
    }
    if (end !== -1) {
      if (startDot === -1 || preDotState === 0
          || (preDotState === 1 && startDot === end - 1
              && startDot === startPart + 1)) {
        ret.base = ret.name = p.slice(startPart, end);
      } else {
        ret.name = p.slice(startPart, startDot);
        ret.base = p.slice(startPart, end);
        ret.ext = p.slice(startDot, end);
      }
    }
    if (startPart > 0 && startPart !== rootEnd) {
      ret.dir = p.slice(0, startPart - 1);
    } else {
      ret.dir = ret.root;
    }
    return ret;
  },
};

// Shared path.format for both personalities.
function _format(sep, pathObject) {
  if (pathObject === null || typeof pathObject !== 'object') {
    throw new TypeError('The "pathObject" argument must be of type object. Received '
                        + (pathObject === null ? 'null' : typeof pathObject));
  }
  const dir = pathObject.dir || pathObject.root;
  const base = pathObject.base
            || ((pathObject.name || '') + (pathObject.ext || ''));
  if (!dir) return base;
  return dir === pathObject.root ? dir + base : dir + sep + base;
}

posix.posix = posix;
posix.win32 = win32;
win32.posix = posix;
win32.win32 = win32;

const isWin = (typeof globalThis !== 'undefined' && globalThis.process
               && globalThis.process.platform === 'win32');
const active = isWin ? win32 : posix;

export const sep = active.sep;
export const delimiter = active.delimiter;
export const isAbsolute = active.isAbsolute;
export const normalize = active.normalize;
export const join = active.join;
export const resolve = active.resolve;
export const relative = active.relative;
export const dirname = active.dirname;
export const basename = active.basename;
export const extname = active.extname;
export const parse = active.parse;
export const format = active.format;
export { posix, win32 };
export default active;
