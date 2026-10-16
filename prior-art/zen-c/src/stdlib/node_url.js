// node:url — WHATWG URL/URLSearchParams re-export plus the legacy
// url.parse/format/resolve API and the file-URL helpers.
//
// URL and URLSearchParams are engine globals; this module references
// them via globalThis (a builtin module source can't `import` another
// builtin module). The legacy Url shape is built from a WHATWG URL parse
// where possible, with a regex fallback for relative / non-special URLs.

const G = globalThis;
const URL = G.URL;
const URLSearchParams = G.URLSearchParams;

function Url() {
  this.protocol = null; this.slashes = null; this.auth = null;
  this.host = null; this.port = null; this.hostname = null;
  this.hash = null; this.search = null; this.query = null;
  this.pathname = null; this.path = null; this.href = null;
}

function parse(urlStr, parseQueryString, slashesDenoteHost) {
  const u = new Url();
  urlStr = String(urlStr);
  let parsed = null;
  try { parsed = new URL(urlStr); } catch (e) { parsed = null; }
  if (parsed) {
    u.protocol = parsed.protocol;
    u.slashes = urlStr.slice(parsed.protocol.length, parsed.protocol.length + 2) === "//";
    u.auth = parsed.username ? (parsed.username + (parsed.password ? ":" + parsed.password : "")) : null;
    u.host = parsed.host || null;
    u.port = parsed.port || null;
    u.hostname = parsed.hostname || null;
    u.hash = parsed.hash || null;
    u.search = parsed.search || null;
    u.query = parseQueryString
      ? querystringParse(parsed.search ? parsed.search.slice(1) : "")
      : (parsed.search ? parsed.search.slice(1) : null);
    u.pathname = parsed.pathname || null;
    u.path = (parsed.pathname || "") + (parsed.search || "") || null;
    u.href = parsed.href;
    return u;
  }
  // Relative / unparseable: a minimal regex split.
  const m = /^(?:([^:/?#]+:))?(?:\/\/([^/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(urlStr);
  if (m) {
    u.protocol = m[1] || null;
    u.slashes = urlStr.indexOf("//") === (m[1] ? m[1].length : 0) && !!m[2];
    if (m[2] !== undefined && (m[2] !== "" || u.slashes)) {
      u.host = m[2]; const at = m[2].indexOf("@");
      let hostpart = m[2];
      if (at >= 0) { u.auth = m[2].slice(0, at); hostpart = m[2].slice(at + 1); }
      const colon = hostpart.lastIndexOf(":");
      if (colon >= 0) { u.hostname = hostpart.slice(0, colon); u.port = hostpart.slice(colon + 1); }
      else u.hostname = hostpart;
    }
    u.pathname = m[3] || null;
    u.search = m[4] || null;
    u.query = parseQueryString ? querystringParse(m[4] ? m[4].slice(1) : "") : (m[4] ? m[4].slice(1) : null);
    u.hash = m[5] || null;
    u.path = (m[3] || "") + (m[4] || "") || null;
    u.href = urlStr;
  }
  return u;
}

function format(urlObj) {
  if (typeof urlObj === "string") return urlObj;
  if (urlObj instanceof URL) return urlObj.href;
  let out = "";
  const protocol = urlObj.protocol || "";
  if (protocol) out += protocol + (protocol.endsWith(":") ? "" : ":");
  if (urlObj.slashes || urlObj.host || (protocol && protocol !== "mailto:")) out += "//";
  if (urlObj.auth) out += urlObj.auth + "@";
  if (urlObj.host) out += urlObj.host;
  else if (urlObj.hostname) out += urlObj.hostname + (urlObj.port ? ":" + urlObj.port : "");
  if (urlObj.pathname) out += urlObj.pathname;
  let search = urlObj.search;
  if (!search && urlObj.query) {
    search = typeof urlObj.query === "string" ? "?" + urlObj.query : "?" + querystringStringify(urlObj.query);
  }
  if (search) out += (search.startsWith("?") ? search : "?" + search);
  if (urlObj.hash) out += (urlObj.hash.startsWith("#") ? urlObj.hash : "#" + urlObj.hash);
  return out;
}

function resolve(from, to) {
  try { return new URL(to, new URL(from)).href; }
  catch (e) { try { return new URL(to).href; } catch (e2) { return to; } }
}

// Minimal querystring parse/stringify (node:querystring-lite, enough for
// url.parse(..., true) and url.format).
function querystringParse(str) {
  const out = Object.create(null);
  if (!str) return out;
  for (const pair of String(str).split("&")) {
    if (!pair) continue;
    const eq = pair.indexOf("=");
    const k = decodeURIComponent(eq < 0 ? pair : pair.slice(0, eq));
    const v = eq < 0 ? "" : decodeURIComponent(pair.slice(eq + 1));
    if (k in out) { if (Array.isArray(out[k])) out[k].push(v); else out[k] = [out[k], v]; }
    else out[k] = v;
  }
  return out;
}
function querystringStringify(obj) {
  const parts = [];
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    if (Array.isArray(v)) { for (const item of v) parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(item)); }
    else parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(v));
  }
  return parts.join("&");
}

function fileURLToPath(url) {
  const u = typeof url === "string" ? new URL(url) : url;
  if (u.protocol !== "file:") throw new TypeError("The URL must be of scheme file");
  return decodeURIComponent(u.pathname);
}
function pathToFileURL(path) {
  let p = String(path);
  if (p[0] !== "/") p = "/" + p;
  return new URL("file://" + encodeURI(p));
}
function domainToASCII(d) { try { return new URL("http://" + d).hostname; } catch (e) { return ""; } }
function domainToUnicode(d) { return domainToASCII(d); }

export { URL, URLSearchParams, parse, format, resolve, fileURLToPath, pathToFileURL, domainToASCII, domainToUnicode };
export default { URL, URLSearchParams, parse, format, resolve, fileURLToPath, pathToFileURL, domainToASCII, domainToUnicode, Url };
