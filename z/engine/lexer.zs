// Lexer -- source bytes to a token stream.
//
// A port of src/lexer.zc in the idiomatic register: single pass, tokens
// slice into the source by offset, whitespace and comments skipped between
// tokens, EOF returned indefinitely past end of input. Regex-vs-division
// context is tracked from the previous significant token exactly as the
// reference does, so dumps from both engines diff line-for-line.
//
// The one allocation-shaped difference from the reference: the lexer owns
// its source String rather than borrowing a char*, because Z has no stored
// borrows. Keyword lookup still compares bytes in place -- no per-identifier
// allocation.
//
// Z has no byte/char literal (`'a'`), so every byte the scanner tests is a
// named constant below. Also unlike `if`, a `while` body must be braced --
// there is no single-statement form.

import { expect } from "std/test";
import { TextBuffer } from "std/text";
import { TokenKind, Token, tokenEof, tokenInvalid, expectRegexAfter } from "./token.zs";
import { bytesOf, sliceBytes } from "./heap.zs";

// --- Bytes ------------------------------------------------------------------

const B_NUL: u8 = 0;
const B_TAB: u8 = 9;
const B_LF: u8 = 10;
const B_VT: u8 = 11;
const B_FF: u8 = 12;
const B_CR: u8 = 13;
const B_SPACE: u8 = 32;
const B_BANG: u8 = 33;
const B_DQUOTE: u8 = 34;
const B_HASH: u8 = 35;
const B_DOLLAR: u8 = 36;
const B_PERCENT: u8 = 37;
const B_AMP: u8 = 38;
const B_SQUOTE: u8 = 39;
const B_LPAREN: u8 = 40;
const B_RPAREN: u8 = 41;
const B_STAR: u8 = 42;
const B_PLUS: u8 = 43;
const B_COMMA: u8 = 44;
const B_MINUS: u8 = 45;
const B_DOT: u8 = 46;
const B_SLASH: u8 = 47;
const B_0: u8 = 48;
const B_1: u8 = 49;
const B_7: u8 = 55;
const B_9: u8 = 57;
const B_COLON: u8 = 58;
const B_SEMI: u8 = 59;
const B_LT: u8 = 60;
const B_EQ: u8 = 61;
const B_GT: u8 = 62;
const B_QUESTION: u8 = 63;
const B_UPPER_A: u8 = 65;
const B_UPPER_B: u8 = 66;
const B_UPPER_E: u8 = 69;
const B_UPPER_F: u8 = 70;
const B_UPPER_O: u8 = 79;
const B_UPPER_X: u8 = 88;
const B_UPPER_Z: u8 = 90;
const B_LBRACKET: u8 = 91;
const B_BACKSLASH: u8 = 92;
const B_RBRACKET: u8 = 93;
const B_CARET: u8 = 94;
const B_UNDERSCORE: u8 = 95;
const B_BACKTICK: u8 = 96;
const B_a: u8 = 97;
const B_b: u8 = 98;
const B_e: u8 = 101;
const B_f: u8 = 102;
const B_n: u8 = 110;
const B_o: u8 = 111;
const B_u: u8 = 117;
const B_x: u8 = 120;
const B_z: u8 = 122;
const B_LBRACE: u8 = 123;
const B_PIPE: u8 = 124;
const B_RBRACE: u8 = 125;
const B_TILDE: u8 = 126;
const B_HIGH: u8 = 128;
// UTF-8 lead/continuation bytes for the non-ASCII whitespace the reference recognizes.
const B_C2: u8 = 194;
const B_A0: u8 = 160;
const B_EF: u8 = 239;
const B_BB: u8 = 187;
const B_BF: u8 = 191;
const B_E2: u8 = 226;
const B_80: u8 = 128;
const B_A8: u8 = 168;
const B_A9: u8 = 169;

// --- Character classes ------------------------------------------------------

function isDigit(c: u8): boolean {
  return c >= B_0 && c <= B_9;
}

function isHexDigit(c: u8): boolean {
  if (isDigit(c)) return true;
  if (c >= B_a && c <= B_f) return true;
  if (c >= B_UPPER_A && c <= B_UPPER_F) return true;
  return false;
}

// 0..15 for a hex digit, -1 otherwise.
function hexDigitValue(c: u8): i32 {
  if (c >= B_0 && c <= B_9) return i32(c - B_0);
  if (c >= B_a && c <= B_f) return i32(c - B_a) + 10;
  if (c >= B_UPPER_A && c <= B_UPPER_F) return i32(c - B_UPPER_A) + 10;
  return -1;
}

function isAlpha(c: u8): boolean {
  if (c >= B_a && c <= B_z) return true;
  if (c >= B_UPPER_A && c <= B_UPPER_Z) return true;
  return false;
}

// Any non-ASCII byte is accepted as identifier-start, as the reference does:
// well-formed UTF-8 only has high bytes inside multi-byte code points.
function isIdStart(c: u8): boolean {
  if (isAlpha(c)) return true;
  if (c == B_UNDERSCORE || c == B_DOLLAR) return true;
  if (c >= B_HIGH) return true;
  return false;
}

function isIdPart(c: u8): boolean {
  return isIdStart(c) || isDigit(c);
}

// --- Keywords ---------------------------------------------------------------
//
// Compared in place against the source bytes: no allocation per identifier.

function matchesKeyword(in source: Array<u8>, start: usize, length: usize, keyword: String): boolean {
  if (length != keyword.byteLength) return false;
  let index: usize = 0;
  while (index < length) {
    if (source[start + index] != keyword.byteAt(index)) return false;
    index = index + 1;
  }
  return true;
}

function lookupKeyword(in source: Array<u8>, start: usize, length: usize): TokenKind {
  if (matchesKeyword(in source, start, length, "var")) return TokenKind.kwVar;
  if (matchesKeyword(in source, start, length, "let")) return TokenKind.kwLet;
  if (matchesKeyword(in source, start, length, "const")) return TokenKind.kwConst;
  if (matchesKeyword(in source, start, length, "function")) return TokenKind.kwFunction;
  if (matchesKeyword(in source, start, length, "return")) return TokenKind.kwReturn;
  if (matchesKeyword(in source, start, length, "if")) return TokenKind.kwIf;
  if (matchesKeyword(in source, start, length, "else")) return TokenKind.kwElse;
  if (matchesKeyword(in source, start, length, "for")) return TokenKind.kwFor;
  if (matchesKeyword(in source, start, length, "while")) return TokenKind.kwWhile;
  if (matchesKeyword(in source, start, length, "do")) return TokenKind.kwDo;
  if (matchesKeyword(in source, start, length, "break")) return TokenKind.kwBreak;
  if (matchesKeyword(in source, start, length, "continue")) return TokenKind.kwContinue;
  if (matchesKeyword(in source, start, length, "class")) return TokenKind.kwClass;
  if (matchesKeyword(in source, start, length, "extends")) return TokenKind.kwExtends;
  if (matchesKeyword(in source, start, length, "super")) return TokenKind.kwSuper;
  if (matchesKeyword(in source, start, length, "new")) return TokenKind.kwNew;
  if (matchesKeyword(in source, start, length, "this")) return TokenKind.kwThis;
  if (matchesKeyword(in source, start, length, "true")) return TokenKind.kwTrue;
  if (matchesKeyword(in source, start, length, "false")) return TokenKind.kwFalse;
  if (matchesKeyword(in source, start, length, "null")) return TokenKind.kwNull;
  if (matchesKeyword(in source, start, length, "undefined")) return TokenKind.kwUndefined;
  if (matchesKeyword(in source, start, length, "typeof")) return TokenKind.kwTypeof;
  if (matchesKeyword(in source, start, length, "delete")) return TokenKind.kwDelete;
  if (matchesKeyword(in source, start, length, "void")) return TokenKind.kwVoid;
  if (matchesKeyword(in source, start, length, "in")) return TokenKind.kwIn;
  if (matchesKeyword(in source, start, length, "of")) return TokenKind.kwOf;
  if (matchesKeyword(in source, start, length, "instanceof")) return TokenKind.kwInstanceof;
  if (matchesKeyword(in source, start, length, "throw")) return TokenKind.kwThrow;
  if (matchesKeyword(in source, start, length, "try")) return TokenKind.kwTry;
  if (matchesKeyword(in source, start, length, "catch")) return TokenKind.kwCatch;
  if (matchesKeyword(in source, start, length, "finally")) return TokenKind.kwFinally;
  if (matchesKeyword(in source, start, length, "switch")) return TokenKind.kwSwitch;
  if (matchesKeyword(in source, start, length, "case")) return TokenKind.kwCase;
  if (matchesKeyword(in source, start, length, "default")) return TokenKind.kwDefault;
  if (matchesKeyword(in source, start, length, "with")) return TokenKind.kwWith;
  if (matchesKeyword(in source, start, length, "async")) return TokenKind.kwAsync;
  if (matchesKeyword(in source, start, length, "await")) return TokenKind.kwAwait;
  if (matchesKeyword(in source, start, length, "yield")) return TokenKind.kwYield;
  if (matchesKeyword(in source, start, length, "import")) return TokenKind.kwImport;
  if (matchesKeyword(in source, start, length, "export")) return TokenKind.kwExport;
  if (matchesKeyword(in source, start, length, "from")) return TokenKind.kwFrom;
  if (matchesKeyword(in source, start, length, "as")) return TokenKind.kwAs;
  return TokenKind.identifier;
}

// Identifier bytes, used to rebuild an escape-decoded identifier as a String
// so the same in-place keyword lookup can classify it. Z has no way to
// append a single byte to a TextBuffer or build a String from bytes, so the
// decoded bytes are looked up in this table and copied out of it.
const ID_BYTES: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$";

function idByteIndex(c: u8): i32 {
  let index: usize = 0;
  const count = ID_BYTES.byteLength;
  while (index < count) {
    if (ID_BYTES.byteAt(index) == c) return i32(index);
    index = index + 1;
  }
  return -1;
}

// --- Lexer ------------------------------------------------------------------

export struct Lexer {
  source: Array<u8>;
  pos: usize;
  length: usize;
  line: u32;
  // ECMA-262 12.2.1 -- whether the next `/` starts a regex literal. Set
  // after each token from the kind just emitted.
  expectRegex: boolean;
  // Kind of the most recent token, for the `} /re/` newline refinement.
  prevKind: TokenKind;
  crossedNewline: boolean;

  function atEnd(): boolean {
    return this.pos >= this.length;
  }

  function peek(): u8 {
    if (this.pos >= this.length) return B_NUL;
    return this.source[this.pos];
  }

  function peekAt(offset: usize): u8 {
    const at = this.pos + offset;
    if (at >= this.length) return B_NUL;
    return this.source[at];
  }

  function advance(inout this): u8 {
    const c = this.peek();
    this.pos = this.pos + 1;
    if (c == B_LF) this.line = this.line + 1;
    return c;
  }

  function matchByte(inout this, expected: u8): boolean {
    if (this.peek() != expected) return false;
    this.advance();
    return true;
  }

  // The bytes of one token.
  function text(token: Token): Array<u8> {
    return sliceBytes(in this.source, usize(token.start), usize(token.start + token.length));
  }

  // --- Whitespace and comments ---

  function skipTrivia(inout this): void {
    this.crossedNewline = false;
    while (!this.atEnd()) {
      const c = this.peek();
      if (c == B_SPACE || c == B_TAB || c == B_CR || c == B_LF || c == B_VT || c == B_FF) {
        if (c == B_LF || c == B_CR) this.crossedNewline = true;
        this.advance();
      } else if (c == B_C2 && this.peekAt(1) == B_A0) {
        // U+00A0 NO-BREAK SPACE
        this.advance();
        this.advance();
      } else if (c == B_EF && this.peekAt(1) == B_BB && this.peekAt(2) == B_BF) {
        // U+FEFF BOM
        this.advance();
        this.advance();
        this.advance();
      } else if (c == B_E2 && this.peekAt(1) == B_80 && (this.peekAt(2) == B_A8 || this.peekAt(2) == B_A9)) {
        // U+2028 / U+2029 line terminators
        this.crossedNewline = true;
        this.advance();
        this.advance();
        this.advance();
      } else if (c == B_SLASH && this.peekAt(1) == B_SLASH) {
        this.advance();
        this.advance();
        while (!this.atEnd() && this.peek() != B_LF && this.peek() != B_CR) {
          this.advance();
        }
      } else if (c == B_SLASH && this.peekAt(1) == B_STAR) {
        this.advance();
        this.advance();
        while (!this.atEnd()) {
          if (this.peek() == B_STAR && this.peekAt(1) == B_SLASH) {
            this.advance();
            this.advance();
            break;
          }
          this.advance();
        }
      } else {
        return;
      }
    }
  }

  // --- Entry ---

  function nextToken(inout this): Token {
    const token = this.nextTokenInner();
    this.expectRegex = expectRegexAfter(token.kind);
    this.prevKind = token.kind;
    return token;
  }

  function nextTokenInner(inout this): Token {
    this.skipTrivia();
    if (this.atEnd()) return tokenEof(u32(this.pos));

    const start = u32(this.pos);
    const c = this.peek();

    if (isIdStart(c)) return this.scanIdentifierOrKeyword(start);
    if (c == B_BACKSLASH && this.peekAt(1) == B_u) return this.scanIdentifierOrKeyword(start);
    if (isDigit(c)) return this.scanNumber(start);
    if (c == B_DQUOTE || c == B_SQUOTE) return this.scanString(start, c);
    if (c == B_BACKTICK) return this.scanTemplate(start);
    if (c == B_DOT) {
      if (isDigit(this.peekAt(1))) return this.scanNumber(start);
      if (this.peekAt(1) == B_DOT && this.peekAt(2) == B_DOT) {
        this.advance();
        this.advance();
        this.advance();
        return Token({ kind: TokenKind.ellipsis, start: start, length: 3 });
      }
      this.advance();
      return Token({ kind: TokenKind.dot, start: start, length: 1 });
    }
    return this.scanPunctuator(start);
  }

  // --- Identifiers and keywords ---

  function scanIdentifierOrKeyword(inout this, start: u32): Token {
    let hasEscape = false;
    if (this.peek() == B_BACKSLASH) {
      if (!this.consumeUnicodeEscape()) return tokenInvalid(start);
      hasEscape = true;
    } else {
      this.advance();
    }
    while (!this.atEnd()) {
      const c = this.peek();
      if (isIdPart(c)) {
        this.advance();
      } else if (c == B_BACKSLASH && this.peekAt(1) == B_u) {
        if (!this.consumeUnicodeEscape()) return tokenInvalid(start);
        hasEscape = true;
      } else {
        break;
      }
    }
    const length = u32(this.pos) - start;
    if (hasEscape) {
      const kind = this.lookupKeywordAfterEscape(start, length);
      return Token({ kind: kind, start: start, length: length });
    }
    const kind = lookupKeyword(in this.source, usize(start), usize(length));
    return Token({ kind: kind, start: start, length: length });
  }

  // Decode `\uXXXX` / `\u{...}` in the span and classify the result. An
  // escape-decoded identifier that spells a reserved word is the keyword
  // (ECMA-262 11.6.2.1); anything non-ASCII or oversize is an identifier.
  function lookupKeywordAfterEscape(start: u32, length: u32): TokenKind {
    let decoded = Array<u8>();
    let j: u32 = 0;
    while (j < length) {
      if (decoded.length >= 16) return TokenKind.identifier;
      const c = this.source[usize(start + j)];
      if (c == B_BACKSLASH && j + 1 < length && this.source[usize(start + j + 1)] == B_u) {
        j = j + 2;
        let cp: u32 = 0;
        if (j < length && this.source[usize(start + j)] == B_LBRACE) {
          j = j + 1;
          while (j < length && this.source[usize(start + j)] != B_RBRACE) {
            const d = hexDigitValue(this.source[usize(start + j)]);
            if (d < 0) return TokenKind.identifier;
            cp = cp.wrappingMultiply(16) | u32(d);
            j = j + 1;
          }
          if (j < length) j = j + 1;
        } else {
          let n: u32 = 0;
          while (n < 4 && j < length) {
            const d = hexDigitValue(this.source[usize(start + j)]);
            if (d < 0) return TokenKind.identifier;
            cp = cp.wrappingMultiply(16) | u32(d);
            j = j + 1;
            n = n + 1;
          }
        }
        if (cp > 127) return TokenKind.identifier;
        decoded.push(u8(cp));
      } else {
        decoded.push(c);
        j = j + 1;
      }
    }
    // Rebuild as a String through the identifier-byte table so the in-place
    // keyword lookup can be reused unchanged.
    let rebuilt = TextBuffer();
    let index: usize = 0;
    while (index < decoded.length) {
      const at = idByteIndex(decoded[index]);
      if (at < 0) return TokenKind.identifier;
      rebuilt.appendBytes(ID_BYTES, usize(at), usize(at) + 1);
      index = index + 1;
    }
    const text = rebuilt.finish();
    // Z rejects an `in` borrow of `text` alongside a read of `text.byteLength`
    // in the same call ("overlapping in and value uses"), so bind the length.
    const textLength = text.byteLength;
    const textBytes = bytesOf(in text);
    const byteCount = textBytes.length;
    return lookupKeyword(in textBytes, 0, byteCount);
  }

  // Consume `\uXXXX` or `\u{...}` after checking the code point is a valid
  // identifier part. ASCII is checked; non-ASCII is accepted without ID
  // tables, matching the reference.
  function consumeUnicodeEscape(inout this): boolean {
    if (this.peek() != B_BACKSLASH || this.peekAt(1) != B_u) return false;
    this.advance();
    this.advance();
    let cp: u32 = 0;
    if (this.peek() == B_LBRACE) {
      this.advance();
      let n: u32 = 0;
      while (!this.atEnd() && this.peek() != B_RBRACE) {
        const d = hexDigitValue(this.peek());
        if (d < 0) return false;
        cp = cp.wrappingMultiply(16) | u32(d);
        n = n + 1;
        if (n > 6 || cp > 0x10FFFF) return false;
        this.advance();
      }
      if (this.peek() != B_RBRACE) return false;
      this.advance();
    } else {
      let i: u32 = 0;
      while (i < 4) {
        const d = hexDigitValue(this.peek());
        if (d < 0) return false;
        cp = cp.wrappingMultiply(16) | u32(d);
        this.advance();
        i = i + 1;
      }
    }
    if (cp <= 127) {
      if (!isIdPart(u8(cp))) return false;
    }
    return true;
  }

  // --- Numbers ---

  function scanNumber(inout this, start: u32): Token {
    const c0 = this.peek();
    const c1 = this.peekAt(1);

    if (c0 == B_0 && (c1 == B_x || c1 == B_UPPER_X)) {
      this.advance();
      this.advance();
      while (!this.atEnd() && (isHexDigit(this.peek()) || this.peek() == B_UNDERSCORE)) { this.advance(); }
      if (this.peek() == B_n) {
        this.advance();
        return this.tokN(TokenKind.bigIntLit, start);
      }
      return this.tokN(TokenKind.numberLit, start);
    }
    if (c0 == B_0 && (c1 == B_b || c1 == B_UPPER_B)) {
      this.advance();
      this.advance();
      while (!this.atEnd() && (this.peek() == B_0 || this.peek() == B_1 || this.peek() == B_UNDERSCORE)) { this.advance(); }
      if (this.peek() == B_n) {
        this.advance();
        return this.tokN(TokenKind.bigIntLit, start);
      }
      return this.tokN(TokenKind.numberLit, start);
    }
    if (c0 == B_0 && (c1 == B_o || c1 == B_UPPER_O)) {
      this.advance();
      this.advance();
      while (!this.atEnd() && ((this.peek() >= B_0 && this.peek() <= B_7) || this.peek() == B_UNDERSCORE)) { this.advance(); }
      if (this.peek() == B_n) {
        this.advance();
        return this.tokN(TokenKind.bigIntLit, start);
      }
      return this.tokN(TokenKind.numberLit, start);
    }

    let sawIntDigit = false;
    if (isDigit(c0)) sawIntDigit = true;
    while (!this.atEnd() && (isDigit(this.peek()) || this.peek() == B_UNDERSCORE)) { this.advance(); }
    if (sawIntDigit && this.peek() == B_n) {
      this.advance();
      return this.tokN(TokenKind.bigIntLit, start);
    }

    if (this.peek() == B_DOT) {
      this.advance();
      while (!this.atEnd() && (isDigit(this.peek()) || this.peek() == B_UNDERSCORE)) { this.advance(); }
    }

    if (this.peek() == B_e || this.peek() == B_UPPER_E) {
      this.advance();
      if (this.peek() == B_PLUS || this.peek() == B_MINUS) this.advance();
      while (!this.atEnd() && (isDigit(this.peek()) || this.peek() == B_UNDERSCORE)) { this.advance(); }
    }

    // `n` after a fraction or exponent is a SyntaxError (only integer
    // literals take the BigInt suffix); consume it and flag Invalid.
    if (this.peek() == B_n) {
      this.advance();
      return this.tokN(TokenKind.invalid, start);
    }

    return this.tokN(TokenKind.numberLit, start);
  }

  // --- Strings ---

  function scanString(inout this, start: u32, quote: u8): Token {
    this.advance();
    while (!this.atEnd()) {
      const c = this.peek();
      if (c == quote) {
        this.advance();
        return this.tokN(TokenKind.stringLit, start);
      }
      if (c == B_LF || c == B_CR) return this.tokN(TokenKind.invalid, start);
      if (c == B_BACKSLASH) {
        this.advance();
        if (!this.atEnd()) {
          // LineContinuation: \<CR><LF> is one terminator sequence.
          if (this.peek() == B_CR) {
            this.advance();
            if (!this.atEnd() && this.peek() == B_LF) this.advance();
          } else {
            this.advance();
          }
        }
      } else {
        this.advance();
      }
    }
    return this.tokN(TokenKind.invalid, start);
  }

  // --- Template literals ---
  //
  // One TemplateLit token covers the whole backtick literal including every
  // ${...}; the parser splits it. Substitutions are skipped by balancing
  // braces and stepping over nested strings, templates, comments, and
  // regexes just well enough to find the matching `}`.

  function scanTemplate(inout this, start: u32): Token {
    this.advance();
    while (!this.atEnd()) {
      const c = this.peek();
      if (c == B_BACKTICK) {
        this.advance();
        return this.tokN(TokenKind.templateLit, start);
      }
      if (c == B_BACKSLASH) {
        this.advance();
        if (!this.atEnd()) this.advance();
        continue;
      }
      if (c == B_DOLLAR && this.peekAt(1) == B_LBRACE) {
        this.advance();
        this.advance();
        if (!this.scanTemplateSubstitution()) return this.tokN(TokenKind.invalid, start);
        continue;
      }
      this.advance();
    }
    return this.tokN(TokenKind.invalid, start);
  }

  function scanTemplateSubstitution(inout this): boolean {
    let depth: u32 = 1;
    // Last significant byte consumed: decides whether `/` opens a regex
    // (expression position) or is division (value position).
    let prevSig: u8 = B_LBRACE;
    while (depth > 0 && !this.atEnd()) {
      const c = this.peek();
      if (c == B_LBRACE) { this.advance(); depth = depth + 1; prevSig = c; continue; }
      if (c == B_RBRACE) { this.advance(); depth = depth - 1; prevSig = c; continue; }
      if (c == B_BACKSLASH) {
        this.advance();
        if (!this.atEnd()) this.advance();
        prevSig = c;
        continue;
      }
      if (c == B_SLASH) {
        const next = this.peekAt(1);
        if (next == B_SLASH) {
          while (!this.atEnd() && this.peek() != B_LF) { this.advance(); }
          continue;
        }
        if (next == B_STAR) {
          this.advance();
          this.advance();
          while (!this.atEnd()) {
            if (this.peek() == B_STAR && this.peekAt(1) == B_SLASH) {
              this.advance();
              this.advance();
              break;
            }
            this.advance();
          }
          continue;
        }
        const isValueEnd =
          (prevSig >= B_a && prevSig <= B_z)
          || (prevSig >= B_UPPER_A && prevSig <= B_UPPER_Z)
          || (prevSig >= B_0 && prevSig <= B_9)
          || prevSig == B_UNDERSCORE || prevSig == B_DOLLAR
          || prevSig == B_RPAREN || prevSig == B_RBRACKET
          || prevSig == B_SQUOTE || prevSig == B_DQUOTE
          || prevSig == B_BACKTICK || prevSig == B_RBRACE
          || prevSig == B_DOT;
        if (!isValueEnd) {
          this.advance();
          let inClass = false;
          while (!this.atEnd()) {
            const rc = this.peek();
            if (rc == B_BACKSLASH) {
              this.advance();
              if (!this.atEnd()) this.advance();
              continue;
            }
            if (rc == B_LF) return false;
            if (rc == B_LBRACKET) { inClass = true; this.advance(); continue; }
            if (rc == B_RBRACKET) { inClass = false; this.advance(); continue; }
            if (rc == B_SLASH && !inClass) { this.advance(); break; }
            this.advance();
          }
          while (!this.atEnd()) {
            const fc = this.peek();
            const isFlag = (fc >= B_a && fc <= B_z) || (fc >= B_UPPER_A && fc <= B_UPPER_Z);
            if (!isFlag) break;
            this.advance();
          }
          prevSig = B_RPAREN;
          continue;
        }
        this.advance();
        prevSig = c;
        continue;
      }
      if (c == B_BACKTICK) {
        this.advance();
        while (!this.atEnd() && this.peek() != B_BACKTICK) {
          const ic = this.peek();
          if (ic == B_BACKSLASH) {
            this.advance();
            if (!this.atEnd()) this.advance();
            continue;
          }
          if (ic == B_DOLLAR && this.peekAt(1) == B_LBRACE) {
            this.advance();
            this.advance();
            if (!this.scanTemplateSubstitution()) return false;
            continue;
          }
          this.advance();
        }
        if (!this.atEnd()) this.advance();
        prevSig = B_BACKTICK;
        continue;
      }
      if (c == B_DQUOTE || c == B_SQUOTE) {
        const quote = c;
        this.advance();
        while (!this.atEnd() && this.peek() != quote) {
          if (this.peek() == B_BACKSLASH) {
            this.advance();
            if (!this.atEnd()) this.advance();
          } else if (this.peek() == B_LF) {
            return false;
          } else {
            this.advance();
          }
        }
        if (!this.atEnd()) this.advance();
        prevSig = quote;
        continue;
      }
      if (c != B_SPACE && c != B_TAB && c != B_LF && c != B_CR) prevSig = c;
      this.advance();
    }
    return depth == 0;
  }

  // --- Punctuators ---

  function scanPunctuator(inout this, start: u32): Token {
    const c = this.advance();

    if (c == B_LPAREN) return this.tok1(TokenKind.lParen, start);
    if (c == B_RPAREN) return this.tok1(TokenKind.rParen, start);
    if (c == B_LBRACKET) return this.tok1(TokenKind.lBracket, start);
    if (c == B_RBRACKET) return this.tok1(TokenKind.rBracket, start);
    if (c == B_LBRACE) return this.tok1(TokenKind.lBrace, start);
    if (c == B_RBRACE) return this.tok1(TokenKind.rBrace, start);
    if (c == B_COMMA) return this.tok1(TokenKind.comma, start);
    if (c == B_SEMI) return this.tok1(TokenKind.semicolon, start);
    if (c == B_COLON) return this.tok1(TokenKind.colon, start);
    if (c == B_TILDE) return this.tok1(TokenKind.tilde, start);

    if (c == B_QUESTION) {
      if (this.matchByte(B_QUESTION)) {
        if (this.matchByte(B_EQ)) return this.tokN(TokenKind.questionQuestionEq, start);
        return this.tokN(TokenKind.questionQuestion, start);
      }
      if (this.matchByte(B_DOT)) return this.tokN(TokenKind.questionDot, start);
      return this.tok1(TokenKind.question, start);
    }
    if (c == B_BANG) {
      if (this.matchByte(B_EQ)) {
        if (this.matchByte(B_EQ)) return this.tokN(TokenKind.bangEqEq, start);
        return this.tokN(TokenKind.bangEq, start);
      }
      return this.tok1(TokenKind.bang, start);
    }
    if (c == B_EQ) {
      if (this.matchByte(B_EQ)) {
        if (this.matchByte(B_EQ)) return this.tokN(TokenKind.eqEqEq, start);
        return this.tokN(TokenKind.eqEq, start);
      }
      if (this.matchByte(B_GT)) return this.tokN(TokenKind.arrow, start);
      return this.tok1(TokenKind.eq, start);
    }
    if (c == B_LT) {
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.ltEq, start);
      if (this.matchByte(B_LT)) {
        if (this.matchByte(B_EQ)) return this.tokN(TokenKind.ltLtEq, start);
        return this.tokN(TokenKind.ltLt, start);
      }
      return this.tok1(TokenKind.lt, start);
    }
    if (c == B_GT) {
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.gtEq, start);
      if (this.matchByte(B_GT)) {
        if (this.matchByte(B_GT)) {
          if (this.matchByte(B_EQ)) return this.tokN(TokenKind.gtGtGtEq, start);
          return this.tokN(TokenKind.gtGtGt, start);
        }
        if (this.matchByte(B_EQ)) return this.tokN(TokenKind.gtGtEq, start);
        return this.tokN(TokenKind.gtGt, start);
      }
      return this.tok1(TokenKind.gt, start);
    }
    if (c == B_PLUS) {
      if (this.matchByte(B_PLUS)) return this.tokN(TokenKind.plusPlus, start);
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.plusEq, start);
      return this.tok1(TokenKind.plus, start);
    }
    if (c == B_MINUS) {
      if (this.matchByte(B_MINUS)) return this.tokN(TokenKind.minusMinus, start);
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.minusEq, start);
      return this.tok1(TokenKind.minus, start);
    }
    if (c == B_STAR) {
      if (this.matchByte(B_STAR)) {
        if (this.matchByte(B_EQ)) return this.tokN(TokenKind.starStarEq, start);
        return this.tokN(TokenKind.starStar, start);
      }
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.starEq, start);
      return this.tok1(TokenKind.star, start);
    }
    if (c == B_SLASH) {
      // Regex vs division. A `}` followed by a newline then `/` is the
      // ASI "end of block, new statement starting with a regex" shape.
      const forceRegex = this.expectRegex || (this.prevKind == TokenKind.rBrace && this.crossedNewline);
      if (forceRegex) return this.scanRegexBody(start);
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.slashEq, start);
      return this.tok1(TokenKind.slash, start);
    }
    if (c == B_PERCENT) {
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.percentEq, start);
      return this.tok1(TokenKind.percent, start);
    }
    if (c == B_AMP) {
      if (this.matchByte(B_AMP)) {
        if (this.matchByte(B_EQ)) return this.tokN(TokenKind.ampAmpEq, start);
        return this.tokN(TokenKind.ampAmp, start);
      }
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.ampEq, start);
      return this.tok1(TokenKind.amp, start);
    }
    if (c == B_PIPE) {
      if (this.matchByte(B_PIPE)) {
        if (this.matchByte(B_EQ)) return this.tokN(TokenKind.pipePipeEq, start);
        return this.tokN(TokenKind.pipePipe, start);
      }
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.pipeEq, start);
      return this.tok1(TokenKind.pipe, start);
    }
    if (c == B_CARET) {
      if (this.matchByte(B_EQ)) return this.tokN(TokenKind.caretEq, start);
      return this.tok1(TokenKind.caret, start);
    }
    if (c == B_HASH) {
      // PrivateName `#identifier`, lexically adjacent.
      if (this.atEnd()) return tokenInvalid(start);
      if (this.peek() == B_BACKSLASH && this.peekAt(1) == B_u) {
        if (!this.consumeUnicodeEscape()) return tokenInvalid(start);
      } else if (isIdStart(this.peek())) {
        this.advance();
      } else {
        return tokenInvalid(start);
      }
      while (!this.atEnd()) {
        const ch = this.peek();
        if (isIdPart(ch)) {
          this.advance();
        } else if (ch == B_BACKSLASH && this.peekAt(1) == B_u) {
          if (!this.consumeUnicodeEscape()) return tokenInvalid(start);
        } else {
          break;
        }
      }
      return this.tokN(TokenKind.privateName, start);
    }

    return tokenInvalid(start);
  }

  // --- Regex literal ---
  //
  // After the opening `/` has been eaten: body until an unescaped `/` outside
  // a character class, then a greedy run of flag letters. A raw line
  // terminator in the body is invalid.
  function scanRegexBody(inout this, start: u32): Token {
    let inClass = false;
    while (!this.atEnd()) {
      const c = this.peek();
      if (c == B_LF || c == B_CR) return tokenInvalid(start);
      if (c == B_BACKSLASH) {
        this.advance();
        if (!this.atEnd()) {
          const nc = this.peek();
          if (nc == B_LF || nc == B_CR) return tokenInvalid(start);
          this.advance();
        }
        continue;
      }
      if (c == B_LBRACKET) { inClass = true; this.advance(); continue; }
      if (c == B_RBRACKET) { inClass = false; this.advance(); continue; }
      if (c == B_SLASH && !inClass) {
        this.advance();
        while (!this.atEnd() && isIdPart(this.peek())) { this.advance(); }
        return this.tokN(TokenKind.regexLit, start);
      }
      this.advance();
    }
    return tokenInvalid(start);
  }

  // --- Token constructors, after the cursor has advanced ---

  function tok1(kind: TokenKind, start: u32): Token {
    return Token({ kind: kind, start: start, length: 1 });
  }

  function tokN(kind: TokenKind, start: u32): Token {
    return Token({ kind: kind, start: start, length: u32(this.pos) - start });
  }
}

export function createLexer(source: Array<u8>): Lexer {
  const length = source.length;
  return Lexer({
    source: move source,
    pos: 0,
    length: length,
    line: 1,
    // Source start is expression position: a leading `/re/` is a regex.
    expectRegex: true,
    prevKind: TokenKind.eof,
    crossedNewline: false,
  });
}

// Eager form: every token including the trailing Eof.
export function tokenize(source: Array<u8>): Array<Token> {
  let lexer = createLexer(move source);
  let tokens = Array<Token>();
  while (true) {
    const token = lexer.nextToken();
    tokens.push(token);
    if (token.kind == TokenKind.eof) return tokens;
  }
  // `while (true)` with only `return` exits is not seen as diverging.
  return tokens;
}

// Source given as text, for tests and tools that hold a String.
export function tokenizeText(source: String): Array<Token> {
  return tokenize(bytesOf(in source));
}

// --- Tests ----------------------------------------------------------------

function kinds(source: String): Array<TokenKind> {
  const tokens = tokenizeText(move source);
  let result = Array<TokenKind>();
  let index: usize = 0;
  while (index < tokens.length) {
    result.push(tokens[index].kind);
    index = index + 1;
  }
  return result;
}

test "keywords, identifiers, numbers, and punctuators" {
  const found = kinds("var x = 1 + 2.5;");
  const eight: usize = 8;
  expect(found.length).toEqual(eight);
  expect(found[0] == TokenKind.kwVar).toEqual(true);
  expect(found[1] == TokenKind.identifier).toEqual(true);
  expect(found[2] == TokenKind.eq).toEqual(true);
  expect(found[3] == TokenKind.numberLit).toEqual(true);
  expect(found[4] == TokenKind.plus).toEqual(true);
  expect(found[5] == TokenKind.numberLit).toEqual(true);
  expect(found[6] == TokenKind.semicolon).toEqual(true);
  expect(found[7] == TokenKind.eof).toEqual(true);
}

test "token spans slice the source" {
  const sample: String = "let  answer = 42";
  let lexer = createLexer(bytesOf(in sample));
  const first = lexer.nextToken();
  const second = lexer.nextToken();
  const firstText = lexer.text(first);
  const secondText = lexer.text(second);
  expect(firstText.length).toEqual(3);
  expect(firstText[0]).toEqual(0x6C);
  expect(secondText.length).toEqual(6);
  expect(secondText[5]).toEqual(0x72);
  const five: u32 = 5;
  expect(second.start).toEqual(five);
}

test "regex after an operator, division after a value" {
  const regex = kinds("x = /ab+c/gi;");
  expect(regex[2] == TokenKind.regexLit).toEqual(true);
  const division = kinds("a / b / c");
  expect(division[1] == TokenKind.slash).toEqual(true);
  expect(division[3] == TokenKind.slash).toEqual(true);
}

test "closing brace then newline then slash starts a regex" {
  const found = kinds("}\n/re/.test(s)");
  expect(found[0] == TokenKind.rBrace).toEqual(true);
  expect(found[1] == TokenKind.regexLit).toEqual(true);
}

test "template literal with substitution is one token" {
  const found = kinds("`a${b + \"}\"}c`;");
  expect(found[0] == TokenKind.templateLit).toEqual(true);
  expect(found[1] == TokenKind.semicolon).toEqual(true);
}

test "radix and bigint literals" {
  const found = kinds("0xFF 0b1_0 0o17 123n 0xFFn 1.5n");
  expect(found[0] == TokenKind.numberLit).toEqual(true);
  expect(found[1] == TokenKind.numberLit).toEqual(true);
  expect(found[2] == TokenKind.numberLit).toEqual(true);
  expect(found[3] == TokenKind.bigIntLit).toEqual(true);
  expect(found[4] == TokenKind.bigIntLit).toEqual(true);
  expect(found[5] == TokenKind.invalid).toEqual(true);
}

test "escape-decoded reserved word is the keyword" {
  const found = kinds("\\u0069f x");
  expect(found[0] == TokenKind.kwIf).toEqual(true);
  expect(found[1] == TokenKind.identifier).toEqual(true);
}

test "private names and multi-byte punctuators" {
  const found = kinds("#x >>>= ??= ?. ... =>");
  expect(found[0] == TokenKind.privateName).toEqual(true);
  expect(found[1] == TokenKind.gtGtGtEq).toEqual(true);
  expect(found[2] == TokenKind.questionQuestionEq).toEqual(true);
  expect(found[3] == TokenKind.questionDot).toEqual(true);
  expect(found[4] == TokenKind.ellipsis).toEqual(true);
  expect(found[5] == TokenKind.arrow).toEqual(true);
}

test "comments and unusual whitespace are trivia" {
  // Literal U+00A0 bytes below: Z strings have no \u escape. Between tokens
  // NBSP is trivia. Inside an identifier it is glued in, because any byte
  // >= 0x80 is identifier-part -- the reference does the same (verified
  // with tokdump-ref: `b<NBSP>c` is one identifier of length 4).
  const between = kinds("a // c\n/* b */ ; c");
  expect(between[0] == TokenKind.identifier).toEqual(true);
  expect(between[1] == TokenKind.semicolon).toEqual(true);
  expect(between[2] == TokenKind.identifier).toEqual(true);
  expect(between[3] == TokenKind.eof).toEqual(true);

  const glued = tokenizeText("b c");
  const four: u32 = 4;
  expect(glued[0].kind == TokenKind.identifier).toEqual(true);
  expect(glued[0].length).toEqual(four);
  expect(glued[1].kind == TokenKind.eof).toEqual(true);
}

test "unterminated string is invalid" {
  const found = kinds("'abc\nx");
  expect(found[0] == TokenKind.invalid).toEqual(true);
}
