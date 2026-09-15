// Parser -- token stream to AST.
//
// A port of src/parser.zc in the idiomatic register: hand-written recursive
// descent, one function per precedence level, cover-grammar reinterpretation
// for destructuring. Nodes are indices into the Ast (0 = none), so where the
// reference passes AstNode* and checks NULL, this passes u32 and checks
// NO_NODE. Error handling is the reference's: `hadError` is set and NO_NODE
// propagates up.
//
// Being ported in slices, each checked against the reference through
// tools/oracle-ast.sh. A construct not yet ported sets hadError.

import { expect } from "std/test";
import { TextBuffer } from "std/text";
import stdlib from "stdlib.h";
import { TokenKind, Token, tokenEof } from "./token.zs";
import { tokenize } from "./lexer.zs";
import { bytesOf, sliceBytes } from "./heap.zs";
import { NodeKind, AstNode, Ast, NO_NODE, createAst } from "./ast.zs";

// --- Bytes and text -------------------------------------------------------

const B_HASH: u8 = 35;
const B_DQUOTE: u8 = 34;
const B_SQUOTE: u8 = 39;
const B_DOLLAR: u8 = 36;
const B_BACKTICK: u8 = 96;
const B_LF: u8 = 10;
const B_CR: u8 = 13;
const B_0: u8 = 48;
const B_9: u8 = 57;
const B_UPPER_A: u8 = 65;
const B_UPPER_B: u8 = 66;
const B_UPPER_F: u8 = 70;
const B_UPPER_O: u8 = 79;
const B_UPPER_X: u8 = 88;
const B_BACKSLASH: u8 = 92;
const B_UNDERSCORE: u8 = 95;
const B_a: u8 = 97;
const B_b: u8 = 98;
const B_f: u8 = 102;
const B_o: u8 = 111;
const B_u: u8 = 117;
const B_x: u8 = 120;
const B_LBRACE: u8 = 123;
const B_RBRACE: u8 = 125;

function hexValue(c: u8): i32 {
  if (c >= B_0 && c <= B_9) return i32(c - B_0);
  if (c >= B_a && c <= B_f) return i32(c - B_a) + 10;
  if (c >= B_UPPER_A && c <= B_UPPER_F) return i32(c - B_UPPER_A) + 10;
  return -1;
}

// Decimal and scientific literals go through C's strtod, which is what the
// reference does too; Z has no string-to-float. A String cannot cross a raw
// native boundary, and Z has no way to view a String's bytes as a cstring,
// so the bytes are copied into a native buffer one at a time through a
// usize handle. Exact, if not elegant; a scratch buffer per parser would
// remove the per-literal allocation.
function nativeAlloc(count: usize): usize = raw c {
  return (uintptr_t)calloc(count, 1);
}

function nativeStoreByte(buffer: usize, index: usize, value: u8): void = raw c {
  ((uint8_t *)buffer)[index] = value;
}

function nativeStrtod(buffer: usize): f64 = raw c {
  return strtod((const char *)buffer, NULL);
}

function nativeFree(buffer: usize): void = raw c {
  free((void *)buffer);
}

function stringToDouble(in text: String): f64 {
  const count = text.byteLength;
  const buffer = nativeAlloc(count + 1);
  let index: usize = 0;
  while (index < count) {
    nativeStoreByte(buffer, index, text.byteAt(index));
    index = index + 1;
  }
  const value = nativeStrtod(buffer);
  nativeFree(buffer);
  return value;
}

// --- Result ---------------------------------------------------------------

// The result carries the whole Parser: Z cannot move a field out of its
// owner, and the compiler wants the source and tokens alongside the tree
// anyway (identifier and string slices resolve against the source).
export struct ParseResult {
  parser: Parser;
  root: u32;
  hadError: boolean;
}

// --- Parser ---------------------------------------------------------------

export struct Parser {
  source: Array<u8>;
  // The token stream, plus the window of it currently being parsed. A
  // template substitution is re-tokenized and appended, and the window
  // moved over it, rather than swapping the array, so the stream is
  // never copied.
  tokens: Array<Token>;
  tokenLimit: usize;
  pos: usize;
  ast: Ast;
  hadError: boolean;
  // ECMA-262 [NoIn]: parse_relational must not consume `in` as a binary
  // operator inside a for-head init slot.
  noIn: boolean;
  functionDepth: u32;
  inAsync: boolean;
  isModule: boolean;
  inGenerator: boolean;
  strictMode: boolean;
  inDerivedConstructor: boolean;
  inStaticBlock: boolean;
  staticBlockDepth: u32;

  // --- Cursor ---

  function peek(): Token {
    if (this.pos >= this.tokenLimit) return tokenEof(u32(this.source.length));
    return this.tokens[this.pos];
  }

  function peekKind(): TokenKind {
    return this.peek().kind;
  }

  function peekKind2(): TokenKind {
    if (this.pos + 1 >= this.tokenLimit) return TokenKind.eof;
    return this.tokens[this.pos + 1].kind;
  }

  function peekAt(offset: usize): Token {
    const at = this.pos + offset;
    if (at >= this.tokenLimit) return tokenEof(u32(this.source.length));
    return this.tokens[at];
  }

  function advance(inout this): Token {
    const token = this.peek();
    if (this.pos < this.tokenLimit) this.pos = this.pos + 1;
    return token;
  }

  function matchKind(inout this, kind: TokenKind): boolean {
    if (this.peekKind() != kind) return false;
    this.advance();
    return true;
  }

  function expectKind(inout this, kind: TokenKind): boolean {
    if (this.peekKind() != kind) {
      this.hadError = true;
      return false;
    }
    this.advance();
    return true;
  }

  // Lenient statement terminator: consumes `;` if present, tolerates its
  // absence before `}` / EOF, and lets anything else slip through.
  function matchTerminator(inout this): void {
    if (this.peekKind() == TokenKind.semicolon) this.advance();
  }

  function hasNewlineBetween(a: u32, b: u32): boolean {
    let index = usize(a);
    while (index < usize(b)) {
      const c = this.source[index];
      if (c == B_LF || c == B_CR) return true;
      index = index + 1;
    }
    return false;
  }

  // Exact byte comparison of a source slice against ASCII text.
  function sliceEquals(start: u32, length: u32, text: String): boolean {
    if (usize(length) != text.byteLength) return false;
    let index: usize = 0;
    while (index < usize(length)) {
      if (this.source[usize(start) + index] != text.byteAt(index)) return false;
      index = index + 1;
    }
    return true;
  }

  // Escape-aware comparison of an identifier slice against ASCII text:
  // `\uXXXX` and `\u{...}` decode on the fly, so an escaped reserved word
  // still matches.
  function identMatches(start: u32, length: u32, target: String): boolean {
    const bytes = bytesOf(in target);
    return this.identMatchesBytes(start, length, in bytes);
  }

  function identMatchesBytes(start: u32, length: u32, in target: Array<u8>): boolean {
    let i: u32 = 0;
    let ti: usize = 0;
    const targetLength = target.length;
    while (i < length && ti < targetLength) {
      const c = this.source[usize(start + i)];
      if (c == B_BACKSLASH) {
        if (i + 1 >= length) return false;
        if (this.source[usize(start + i + 1)] != B_u) return false;
        let cp: u32 = 0;
        if (i + 2 < length && this.source[usize(start + i + 2)] == B_LBRACE) {
          let j: u32 = i + 3;
          let acc: u32 = 0;
          while (j < length && this.source[usize(start + j)] != B_RBRACE) {
            const dv = hexValue(this.source[usize(start + j)]);
            if (dv < 0) return false;
            acc = acc.wrappingMultiply(16) | u32(dv);
            j = j + 1;
          }
          if (j >= length || this.source[usize(start + j)] != B_RBRACE) return false;
          cp = acc;
          i = j + 1;
        } else {
          if (i + 5 >= length) return false;
          let acc: u32 = 0;
          let k: u32 = 0;
          while (k < 4) {
            const dv = hexValue(this.source[usize(start + i + 2 + k)]);
            if (dv < 0) return false;
            acc = acc.wrappingMultiply(16) | u32(dv);
            k = k + 1;
          }
          cp = acc;
          i = i + 6;
        }
        if (cp > 127) return false;
        if (u8(cp) != target[ti]) return false;
        ti = ti + 1;
      } else {
        if (c != target[ti]) return false;
        i = i + 1;
        ti = ti + 1;
      }
    }
    return i == length && ti == targetLength;
  }

  function nameIsArgumentsOrEval(start: u32, length: u32): boolean {
    if (length == 9 && this.sliceEquals(start, length, "arguments")) return true;
    if (length == 4 && this.sliceEquals(start, length, "eval")) return true;
    return false;
  }

  // --- Identifier validity ---

  function isBindingIdent(kind: TokenKind): boolean {
    if (kind == TokenKind.identifier) return true;
    if (kind == TokenKind.kwOf) return true;
    if (kind == TokenKind.kwLet) return true;
    if (kind == TokenKind.kwYield) return true;
    if (kind == TokenKind.kwAwait) return true;
    if (kind == TokenKind.kwAsync) return true;
    if (kind == TokenKind.kwFrom) return true;
    if (kind == TokenKind.kwAs) return true;
    return false;
  }

  function isBindingIdentCtx(kind: TokenKind): boolean {
    if (kind == TokenKind.kwYield && this.inGenerator) return false;
    if (kind == TokenKind.kwAwait && this.inAsync) return false;
    if (kind == TokenKind.kwAwait && this.inStaticBlock && this.functionDepth == this.staticBlockDepth) return false;
    if (kind == TokenKind.kwYield && this.strictMode) return false;
    return this.isBindingIdent(kind);
  }

  function isBindingIdentTok(token: Token): boolean {
    if (!this.isBindingIdentCtx(token.kind)) return false;
    if (token.kind != TokenKind.identifier) return true;
    if (this.inGenerator || this.strictMode) {
      if (this.identMatches(token.start, token.length, "yield")) return false;
    }
    if (this.inAsync) {
      if (this.identMatches(token.start, token.length, "await")) return false;
    }
    if (this.strictMode) {
      if (this.identMatches(token.start, token.length, "implements")) return false;
      if (this.identMatches(token.start, token.length, "interface")) return false;
      if (this.identMatches(token.start, token.length, "package")) return false;
      if (this.identMatches(token.start, token.length, "private")) return false;
      if (this.identMatches(token.start, token.length, "protected")) return false;
      if (this.identMatches(token.start, token.length, "public")) return false;
      if (this.identMatches(token.start, token.length, "static")) return false;
    }
    return true;
  }

  function bindingNameStrictReserved(token: Token): boolean {
    if (!this.strictMode) return false;
    if (this.identMatches(token.start, token.length, "eval")) return true;
    if (this.identMatches(token.start, token.length, "arguments")) return true;
    return false;
  }

  // --- Node helpers ---

  function node(index: u32): AstNode {
    return this.ast.node(index);
  }

  function endOf(index: u32): u32 {
    return this.ast.node(index).end;
  }

  function startOf(index: u32): u32 {
    return this.ast.node(index).start;
  }

  function kindOf(index: u32): NodeKind {
    return this.ast.node(index).kind;
  }

  function isDisallowedStatementBody(index: u32): boolean {
    if (index == NO_NODE) return false;
    const n = this.node(index);
    if (n.kind == NodeKind.functionDecl) return true;
    if (n.kind == NodeKind.classDecl) return true;
    if (n.kind == NodeKind.varDecl) {
      if (n.op == TokenKind.kwLet || n.op == TokenKind.kwConst) return true;
    }
    return false;
  }

  // ======================================================================
  // Statements
  // ======================================================================

  function parseStatement(inout this): u32 {
    const k = this.peekKind();

    if (k == TokenKind.lBrace) return this.parseBlock();
    if (k == TokenKind.kwVar) return this.parseVarDecl(true);
    if (k == TokenKind.kwLet) return this.parseVarDecl(true);
    if (k == TokenKind.kwConst) return this.parseVarDecl(true);
    if (k == TokenKind.kwFunction) return this.parseFunctionDecl(false);
    // `async function f() {}`: no line terminator allowed between them.
    if (k == TokenKind.kwAsync && this.peekKind2() == TokenKind.kwFunction) {
      this.advance();
      return this.parseFunctionDecl(true);
    }
    // Modules: import / export declarations (not yet ported). `import(` and
    // `import.meta` are expressions and fall through.
    if (this.isModule && k == TokenKind.kwImport
        && this.peekKind2() != TokenKind.lParen && this.peekKind2() != TokenKind.dot) {
      return this.parseImportDecl();
    }
    if (this.isModule && k == TokenKind.kwExport) return this.parseExportDecl();
    if (k == TokenKind.kwClass) return this.parseClassDecl();
    if (k == TokenKind.kwIf) return this.parseIf();
    if (k == TokenKind.kwReturn) return this.parseReturn();
    if (k == TokenKind.kwWhile) return this.parseWhile();
    if (k == TokenKind.kwDo) return this.parseDoWhile();
    if (k == TokenKind.kwFor) return this.parseFor();
    if (k == TokenKind.kwBreak) return this.parseBreak();
    if (k == TokenKind.kwContinue) return this.parseContinue();
    if (k == TokenKind.kwThrow) return this.parseThrow();
    if (k == TokenKind.kwTry) return this.parseTry();
    if (k == TokenKind.kwSwitch) return this.parseSwitch();
    if (k == TokenKind.kwWith) return this.parseWith();
    if (k == TokenKind.semicolon) {
      const semi = this.advance();
      return this.ast.newNode(NodeKind.emptyStmt, semi.start, semi.start + semi.length);
    }
    if (k == TokenKind.eof) return NO_NODE;

    // Labeled statement: IDENT : statement.
    if (k == TokenKind.identifier && this.peekKind2() == TokenKind.colon) {
      const id = this.advance();
      this.advance();
      const body = this.parseStatement();
      if (body == NO_NODE) return NO_NODE;
      // A label must not repeat an enclosing label.
      let chain = body;
      while (chain != NO_NODE && this.kindOf(chain) == NodeKind.labeledStmt) {
        const c = this.node(chain);
        if (c.nameLength == id.length && this.labelsEqual(id.start, id.length, c.nameStart, c.nameLength)) {
          this.hadError = true;
          return NO_NODE;
        }
        chain = c.left;
      }
      if (this.isDisallowedStatementBody(body)) {
        this.hadError = true;
        return NO_NODE;
      }
      const labeled = this.ast.newNode(NodeKind.labeledStmt, id.start, this.endOf(body));
      this.ast.setName(labeled, id.start, id.length);
      this.ast.setLeft(labeled, body);
      return labeled;
    }

    const expr = this.parseExpression();
    if (expr == NO_NODE) return NO_NODE;
    this.matchTerminator();
    return expr;
  }

  // The reference compares a label against an enclosing label's source
  // slice with ident_source_matches, decoding escapes on the left only.
  function labelsEqual(aStart: u32, aLength: u32, bStart: u32, bLength: u32): boolean {
    const target = sliceBytes(in this.source, usize(bStart), usize(bStart + bLength));
    return this.identMatchesBytes(aStart, aLength, in target);
  }

  function parseBlock(inout this): u32 {
    const open = this.advance();
    let statements = Array<u32>();
    while (this.peekKind() != TokenKind.rBrace && this.peekKind() != TokenKind.eof && !this.hadError) {
      const statement = this.parseStatement();
      if (statement == NO_NODE) break;
      statements.push(statement);
    }
    const close = this.peek();
    this.expectKind(TokenKind.rBrace);
    const block = this.ast.newNode(NodeKind.blockStmt, open.start, close.start + close.length);
    this.ast.setChildren(block, in statements);
    return block;
  }

  function parseVarDecl(inout this, consumeSemi: boolean): u32 {
    const keyword = this.advance();
    let declarators = Array<u32>();
    let lastEnd: u32 = keyword.start + keyword.length;
    let constMissingInit = false;
    while (true) {
      const k = this.peekKind();
      const isPattern = k == TokenKind.lBrace || k == TokenKind.lBracket;
      const declStart = this.peek().start;
      const decl = this.ast.newNode(NodeKind.declarator, declStart, declStart);
      if (isPattern) {
        const pattern = this.parseBindingTarget();
        if (pattern == NO_NODE) break;
        // Pattern bindings use nameLength 0 as the sentinel; `third`
        // carries the pattern.
        this.ast.setName(decl, 0, 0);
        this.ast.setThird(decl, pattern);
        this.ast.setEnd(decl, this.endOf(pattern));
      } else {
        const nameToken = this.peek();
        if (!this.isBindingIdentTok(nameToken)) {
          this.hadError = true;
          break;
        }
        if (this.bindingNameStrictReserved(nameToken)) {
          this.hadError = true;
          break;
        }
        this.advance();
        this.ast.setStart(decl, nameToken.start);
        this.ast.setEnd(decl, nameToken.start + nameToken.length);
        this.ast.setName(decl, nameToken.start, nameToken.length);
      }

      if (this.matchKind(TokenKind.eq)) {
        const init = this.parseAssignment();
        if (init == NO_NODE) break;
        this.ast.setLeft(decl, init);
        this.ast.setEnd(decl, this.endOf(init));
      } else if (keyword.kind == TokenKind.kwConst) {
        constMissingInit = true;
      }

      declarators.push(decl);
      lastEnd = this.endOf(decl);
      if (!this.matchKind(TokenKind.comma)) break;
    }

    if (constMissingInit) {
      const next = this.peekKind();
      if (!(declarators.length == 1 && (next == TokenKind.kwIn || next == TokenKind.kwOf))) {
        this.hadError = true;
      }
    }

    const declaration = this.ast.newNode(NodeKind.varDecl, keyword.start, lastEnd);
    this.ast.setOp(declaration, keyword.kind);
    this.ast.setChildren(declaration, in declarators);
    if (consumeSemi) this.matchTerminator();
    return declaration;
  }

  function parseIf(inout this): u32 {
    const keyword = this.advance();
    if (!this.expectKind(TokenKind.lParen)) return NO_NODE;
    const condition = this.parseExpression();
    if (condition == NO_NODE) return NO_NODE;
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    const thenStatement = this.parseStatement();
    if (thenStatement == NO_NODE) return NO_NODE;
    if (this.isDisallowedStatementBody(thenStatement)) {
      this.hadError = true;
      return NO_NODE;
    }
    let end = this.endOf(thenStatement);
    let elseStatement: u32 = NO_NODE;
    if (this.matchKind(TokenKind.kwElse)) {
      elseStatement = this.parseStatement();
      if (elseStatement == NO_NODE) return NO_NODE;
      if (this.isDisallowedStatementBody(elseStatement)) {
        this.hadError = true;
        return NO_NODE;
      }
      end = this.endOf(elseStatement);
    }
    const statement = this.ast.newNode(NodeKind.ifStmt, keyword.start, end);
    this.ast.setLeft(statement, condition);
    this.ast.setRight(statement, thenStatement);
    this.ast.setThird(statement, elseStatement);
    return statement;
  }

  function parseReturn(inout this): u32 {
    if (this.functionDepth == 0) {
      this.hadError = true;
      return NO_NODE;
    }
    if (this.inStaticBlock && this.functionDepth == this.staticBlockDepth) {
      this.hadError = true;
      return NO_NODE;
    }
    const keyword = this.advance();
    let end: u32 = keyword.start + keyword.length;
    let argument: u32 = NO_NODE;
    const k = this.peekKind();
    if (k != TokenKind.semicolon && k != TokenKind.rBrace && k != TokenKind.eof) {
      argument = this.parseExpression();
      if (argument == NO_NODE) return NO_NODE;
      end = this.endOf(argument);
    }
    const statement = this.ast.newNode(NodeKind.returnStmt, keyword.start, end);
    this.ast.setLeft(statement, argument);
    this.matchTerminator();
    return statement;
  }

  function parseWhile(inout this): u32 {
    const keyword = this.advance();
    if (!this.expectKind(TokenKind.lParen)) return NO_NODE;
    const condition = this.parseExpression();
    if (condition == NO_NODE) return NO_NODE;
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    const body = this.parseStatement();
    if (body == NO_NODE) return NO_NODE;
    if (this.isDisallowedStatementBody(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    const statement = this.ast.newNode(NodeKind.whileStmt, keyword.start, this.endOf(body));
    this.ast.setLeft(statement, condition);
    this.ast.setRight(statement, body);
    return statement;
  }

  function parseWith(inout this): u32 {
    const keyword = this.advance();
    if (this.strictMode || this.isModule) {
      this.hadError = true;
      return NO_NODE;
    }
    if (!this.expectKind(TokenKind.lParen)) return NO_NODE;
    const object = this.parseExpression();
    if (object == NO_NODE) return NO_NODE;
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    const body = this.parseStatement();
    if (body == NO_NODE) return NO_NODE;
    if (this.isDisallowedStatementBody(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    const statement = this.ast.newNode(NodeKind.withStmt, keyword.start, this.endOf(body));
    this.ast.setLeft(statement, object);
    this.ast.setRight(statement, body);
    return statement;
  }

  function parseDoWhile(inout this): u32 {
    const keyword = this.advance();
    const body = this.parseStatement();
    if (body == NO_NODE) return NO_NODE;
    if (this.isDisallowedStatementBody(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (!this.expectKind(TokenKind.kwWhile)) return NO_NODE;
    if (!this.expectKind(TokenKind.lParen)) return NO_NODE;
    const condition = this.parseExpression();
    if (condition == NO_NODE) return NO_NODE;
    const close = this.peek();
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    const statement = this.ast.newNode(NodeKind.doWhileStmt, keyword.start, close.start + close.length);
    this.ast.setLeft(statement, body);
    this.ast.setRight(statement, condition);
    this.matchTerminator();
    return statement;
  }

  // ======================================================================
  // Expressions
  // ======================================================================

  function parseExpression(inout this): u32 {
    const first = this.parseAssignment();
    if (first == NO_NODE) return NO_NODE;
    if (this.peekKind() != TokenKind.comma) return first;
    let items = Array<u32>();
    items.push(first);
    let lastEnd = this.endOf(first);
    while (this.matchKind(TokenKind.comma)) {
      const next = this.parseAssignment();
      if (next == NO_NODE) break;
      items.push(next);
      lastEnd = this.endOf(next);
    }
    const sequence = this.ast.newNode(NodeKind.sequence, this.startOf(first), lastEnd);
    this.ast.setChildren(sequence, in items);
    return sequence;
  }

  function parseExpressionIn(inout this): u32 {
    const savedNoIn = this.noIn;
    this.noIn = false;
    const expression = this.parseExpression();
    this.noIn = savedNoIn;
    return expression;
  }

  function isAssignmentOp(kind: TokenKind): boolean {
    if (kind == TokenKind.eq) return true;
    if (kind == TokenKind.plusEq) return true;
    if (kind == TokenKind.minusEq) return true;
    if (kind == TokenKind.starEq) return true;
    if (kind == TokenKind.starStarEq) return true;
    if (kind == TokenKind.slashEq) return true;
    if (kind == TokenKind.percentEq) return true;
    if (kind == TokenKind.ltLtEq) return true;
    if (kind == TokenKind.gtGtEq) return true;
    if (kind == TokenKind.gtGtGtEq) return true;
    if (kind == TokenKind.ampEq) return true;
    if (kind == TokenKind.pipeEq) return true;
    if (kind == TokenKind.caretEq) return true;
    if (kind == TokenKind.ampAmpEq) return true;
    if (kind == TokenKind.pipePipeEq) return true;
    if (kind == TokenKind.questionQuestionEq) return true;
    return false;
  }

  function parseAssignment(inout this): u32 {
    // YieldExpression sits at AssignmentExpression precedence.
    if (this.peekKind() == TokenKind.kwYield && this.inGenerator) {
      const keyword = this.advance();
      const keywordEnd = keyword.start + keyword.length;
      // `yield [no LineTerminator here] *`: a newline before `*` means a
      // bare yield, and the stray `*` fails later as a statement.
      let isDelegate = false;
      const star = this.peek();
      if (star.kind == TokenKind.star && !this.hasNewlineBetween(keywordEnd, star.start)) {
        this.advance();
        isDelegate = true;
      }
      const yielded = this.ast.newNode(NodeKind.yieldExpr, keyword.start, keywordEnd);
      this.ast.setBool(yielded, isDelegate);
      const nextToken = this.peek();
      const next = nextToken.kind;
      const operandAllowed = isDelegate || !this.hasNewlineBetween(keywordEnd, nextToken.start);
      if (operandAllowed
          && next != TokenKind.comma && next != TokenKind.semicolon
          && next != TokenKind.rParen && next != TokenKind.rBracket
          && next != TokenKind.rBrace && next != TokenKind.colon
          && next != TokenKind.star && next != TokenKind.eof) {
        const argument = this.parseAssignment();
        if (argument != NO_NODE) {
          this.ast.setLeft(yielded, argument);
          this.ast.setEnd(yielded, this.endOf(argument));
        }
      }
      return yielded;
    }
    // Arrow detection comes before the expression path so `x => body` and
    // `(a, b) => body` are not consumed as an identifier / parenthesized
    // expression first.
    if (this.peekKind() == TokenKind.identifier && this.peekAt(1).kind == TokenKind.arrow) {
      return this.parseArrowSingle(false);
    }
    if (this.peekKind() == TokenKind.lParen && this.lookaheadArrowParen()) {
      return this.parseArrowParen(false);
    }
    if (this.peekKind() == TokenKind.kwAsync) {
      const next = this.peekAt(1);
      if (next.kind == TokenKind.identifier && this.peekAt(2).kind == TokenKind.arrow) {
        this.advance();
        return this.parseArrowSingle(true);
      }
      if (next.kind == TokenKind.lParen) {
        const savedPos = this.pos;
        this.advance();
        if (this.lookaheadArrowParen()) return this.parseArrowParen(true);
        this.pos = savedPos;
      }
    }

    const left = this.parseConditional();
    if (left == NO_NODE) return NO_NODE;
    const k = this.peekKind();
    if (this.isAssignmentOp(k)) {
      const opToken = this.advance();
      const leftNode = this.node(left);
      if (this.strictMode && leftNode.kind == NodeKind.identExpr
          && this.nameIsArgumentsOrEval(leftNode.start, leftNode.end - leftNode.start)) {
        this.hadError = true;
        return NO_NODE;
      }
      // Cover grammar: a plain `=` reinterprets an Array / Object literal
      // on the left as the matching assignment pattern.
      let target = left;
      if (opToken.kind == TokenKind.eq && (leftNode.kind == NodeKind.array || leftNode.kind == NodeKind.object)) {
        target = this.reinterpretAsPattern(left);
        if (target == NO_NODE) return NO_NODE;
      }
      const right = this.parseAssignment();
      if (right == NO_NODE) return NO_NODE;
      const assignment = this.ast.newNode(NodeKind.assignment, this.startOf(target), this.endOf(right));
      this.ast.setOp(assignment, opToken.kind);
      this.ast.setLeft(assignment, target);
      this.ast.setRight(assignment, right);
      return assignment;
    }
    return left;
  }

  function parseConditional(inout this): u32 {
    const condition = this.parseNullish();
    if (condition == NO_NODE) return NO_NODE;
    if (!this.matchKind(TokenKind.question)) return condition;
    const savedNoIn = this.noIn;
    this.noIn = false;
    const consequent = this.parseAssignment();
    this.noIn = savedNoIn;
    if (consequent == NO_NODE) return NO_NODE;
    if (!this.expectKind(TokenKind.colon)) return NO_NODE;
    const alternate = this.parseAssignment();
    if (alternate == NO_NODE) return NO_NODE;
    const conditional = this.ast.newNode(NodeKind.conditional, this.startOf(condition), this.endOf(alternate));
    this.ast.setLeft(conditional, condition);
    this.ast.setRight(conditional, consequent);
    this.ast.setThird(conditional, alternate);
    return conditional;
  }

  // Left-associative binary level: `kind` for the node, one operator.
  function binaryNode(inout this, kind: NodeKind, left: u32, op: TokenKind, right: u32): u32 {
    const created = this.ast.newNode(kind, this.startOf(left), this.endOf(right));
    this.ast.setOp(created, op);
    this.ast.setLeft(created, left);
    this.ast.setRight(created, right);
    return created;
  }

  function parseNullish(inout this): u32 {
    let left = this.parseLogicalOr();
    if (left == NO_NODE) return NO_NODE;
    while (this.peekKind() == TokenKind.questionQuestion) {
      const opToken = this.advance();
      const right = this.parseLogicalOr();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.logical, left, opToken.kind, right);
    }
    return left;
  }

  function parseLogicalOr(inout this): u32 {
    let left = this.parseLogicalAnd();
    if (left == NO_NODE) return NO_NODE;
    while (this.peekKind() == TokenKind.pipePipe) {
      const opToken = this.advance();
      const right = this.parseLogicalAnd();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.logical, left, opToken.kind, right);
    }
    return left;
  }

  function parseLogicalAnd(inout this): u32 {
    let left = this.parseBitOr();
    if (left == NO_NODE) return NO_NODE;
    while (this.peekKind() == TokenKind.ampAmp) {
      const opToken = this.advance();
      const right = this.parseBitOr();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.logical, left, opToken.kind, right);
    }
    return left;
  }

  function parseBitOr(inout this): u32 {
    let left = this.parseBitXor();
    if (left == NO_NODE) return NO_NODE;
    while (this.peekKind() == TokenKind.pipe) {
      const opToken = this.advance();
      const right = this.parseBitXor();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.binary, left, opToken.kind, right);
    }
    return left;
  }

  function parseBitXor(inout this): u32 {
    let left = this.parseBitAnd();
    if (left == NO_NODE) return NO_NODE;
    while (this.peekKind() == TokenKind.caret) {
      const opToken = this.advance();
      const right = this.parseBitAnd();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.binary, left, opToken.kind, right);
    }
    return left;
  }

  function parseBitAnd(inout this): u32 {
    let left = this.parseEquality();
    if (left == NO_NODE) return NO_NODE;
    while (this.peekKind() == TokenKind.amp) {
      const opToken = this.advance();
      const right = this.parseEquality();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.binary, left, opToken.kind, right);
    }
    return left;
  }

  function parseEquality(inout this): u32 {
    let left = this.parseRelational();
    if (left == NO_NODE) return NO_NODE;
    while (true) {
      const k = this.peekKind();
      if (k != TokenKind.eqEq && k != TokenKind.bangEq && k != TokenKind.eqEqEq && k != TokenKind.bangEqEq) {
        return left;
      }
      const opToken = this.advance();
      const right = this.parseRelational();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.binary, left, opToken.kind, right);
    }
    return left;
  }

  function parseRelational(inout this): u32 {
    let left: u32 = NO_NODE;
    if (this.peekKind() == TokenKind.privateName && this.peekKind2() == TokenKind.kwIn && !this.noIn) {
      // Brand check `#x in obj`: a Member with no object, then a Binary.
      const nameToken = this.advance();
      const inToken = this.advance();
      const rhs = this.parseShift();
      if (rhs == NO_NODE) return NO_NODE;
      const member = this.ast.newNode(NodeKind.member, nameToken.start, nameToken.start + nameToken.length);
      this.ast.setName(member, nameToken.start, nameToken.length);
      left = this.binaryNode(NodeKind.binary, member, inToken.kind, rhs);
      this.ast.setStart(left, nameToken.start);
    } else {
      left = this.parseShift();
      if (left == NO_NODE) return NO_NODE;
    }
    while (true) {
      const k = this.peekKind();
      const isIn = k == TokenKind.kwIn;
      if (k != TokenKind.lt && k != TokenKind.gt && k != TokenKind.ltEq && k != TokenKind.gtEq
          && (!isIn || this.noIn) && k != TokenKind.kwInstanceof) {
        return left;
      }
      const opToken = this.advance();
      const right = this.parseShift();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.binary, left, opToken.kind, right);
    }
    return left;
  }

  function parseShift(inout this): u32 {
    let left = this.parseAdditive();
    if (left == NO_NODE) return NO_NODE;
    while (true) {
      const k = this.peekKind();
      if (k != TokenKind.ltLt && k != TokenKind.gtGt && k != TokenKind.gtGtGt) return left;
      const opToken = this.advance();
      const right = this.parseAdditive();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.binary, left, opToken.kind, right);
    }
    return left;
  }

  function parseAdditive(inout this): u32 {
    let left = this.parseMultiplicative();
    if (left == NO_NODE) return NO_NODE;
    while (true) {
      const k = this.peekKind();
      if (k != TokenKind.plus && k != TokenKind.minus) return left;
      const opToken = this.advance();
      const right = this.parseMultiplicative();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.binary, left, opToken.kind, right);
    }
    return left;
  }

  function parseMultiplicative(inout this): u32 {
    let left = this.parseExponent();
    if (left == NO_NODE) return NO_NODE;
    while (true) {
      const k = this.peekKind();
      if (k != TokenKind.star && k != TokenKind.slash && k != TokenKind.percent) return left;
      const opToken = this.advance();
      const right = this.parseExponent();
      if (right == NO_NODE) return NO_NODE;
      left = this.binaryNode(NodeKind.binary, left, opToken.kind, right);
    }
    return left;
  }

  function parseExponent(inout this): u32 {
    const left = this.parseUnary();
    if (left == NO_NODE) return NO_NODE;
    if (this.peekKind() != TokenKind.starStar) return left;
    const opToken = this.advance();
    const right = this.parseExponent();
    if (right == NO_NODE) return NO_NODE;
    return this.binaryNode(NodeKind.binary, left, opToken.kind, right);
  }

  function parseUnary(inout this): u32 {
    const k = this.peekKind();
    if (k == TokenKind.bang || k == TokenKind.tilde || k == TokenKind.plus || k == TokenKind.minus
        || k == TokenKind.plusPlus || k == TokenKind.minusMinus
        || k == TokenKind.kwTypeof || k == TokenKind.kwVoid || k == TokenKind.kwDelete) {
      const opToken = this.advance();
      const operand = this.parseUnary();
      if (operand == NO_NODE) return NO_NODE;
      const unary = this.ast.newNode(NodeKind.unary, opToken.start, this.endOf(operand));
      this.ast.setOp(unary, opToken.kind);
      this.ast.setLeft(unary, operand);
      return unary;
    }
    return this.parsePostfix();
  }

  function parsePostfix(inout this): u32 {
    const operand = this.parseCallMember();
    if (operand == NO_NODE) return NO_NODE;
    const k = this.peekKind();
    if (k == TokenKind.plusPlus || k == TokenKind.minusMinus) {
      const opToken = this.advance();
      const postfix = this.ast.newNode(NodeKind.postfix, this.startOf(operand), opToken.start + opToken.length);
      this.ast.setOp(postfix, opToken.kind);
      this.ast.setLeft(postfix, operand);
      return postfix;
    }
    return operand;
  }

  // Member access after `.`: name slice from the identifier token.
  function memberNode(inout this, kind: NodeKind, object: u32, start: u32, idToken: Token): u32 {
    const member = this.ast.newNode(kind, start, idToken.start + idToken.length);
    this.ast.setLeft(member, object);
    this.ast.setName(member, idToken.start, idToken.length);
    return member;
  }

  function parseCallMember(inout this): u32 {
    let expr: u32 = NO_NODE;

    if (this.peekKind() == TokenKind.kwNew) {
      const newToken = this.advance();
      let isNewTarget = false;
      if (this.peekKind() == TokenKind.dot) {
        const targetToken = this.peekAt(1);
        if (targetToken.kind == TokenKind.identifier && targetToken.length == 6
            && this.sliceEquals(targetToken.start, 6, "target")) {
          isNewTarget = true;
        }
      }
      if (isNewTarget) {
        this.advance();
        const targetToken = this.advance();
        const meta = this.ast.newNode(NodeKind.thisExpr, newToken.start, targetToken.start + 6);
        this.ast.setBool(meta, true);
        expr = meta;
      } else {
        let callee = this.parsePrimary();
        if (callee == NO_NODE) return NO_NODE;
        while (true) {
          const kk = this.peekKind();
          if (kk == TokenKind.dot) {
            this.advance();
            const idToken = this.advance();
            callee = this.memberNode(NodeKind.member, callee, this.startOf(callee), idToken);
          } else if (kk == TokenKind.lBracket) {
            this.advance();
            const property = this.parseExpressionIn();
            if (property == NO_NODE) return NO_NODE;
            const close = this.peek();
            if (!this.expectKind(TokenKind.rBracket)) return NO_NODE;
            const computed = this.ast.newNode(NodeKind.computed, this.startOf(callee), close.start + close.length);
            this.ast.setLeft(computed, callee);
            this.ast.setRight(computed, property);
            callee = computed;
          } else {
            break;
          }
        }
        const created = this.ast.newNode(NodeKind.newExpr, newToken.start, this.endOf(callee));
        this.ast.setLeft(created, callee);
        if (this.peekKind() == TokenKind.lParen) {
          const end = this.parseArguments(created);
          this.ast.setEnd(created, end);
        }
        expr = created;
      }
    } else {
      expr = this.parsePrimary();
      if (expr == NO_NODE) return NO_NODE;
    }

    while (true) {
      const k = this.peekKind();
      if (k == TokenKind.dot) {
        this.advance();
        const idToken = this.advance();
        if (this.kindOf(expr) == NodeKind.superExpr && idToken.kind == TokenKind.privateName) {
          this.hadError = true;
          return NO_NODE;
        }
        expr = this.memberNode(NodeKind.member, expr, this.startOf(expr), idToken);
      } else if (k == TokenKind.lBracket) {
        this.advance();
        const property = this.parseExpressionIn();
        if (property == NO_NODE) return NO_NODE;
        const close = this.peek();
        if (!this.expectKind(TokenKind.rBracket)) return NO_NODE;
        const computed = this.ast.newNode(NodeKind.computed, this.startOf(expr), close.start + close.length);
        this.ast.setLeft(computed, expr);
        this.ast.setRight(computed, property);
        expr = computed;
      } else if (k == TokenKind.lParen) {
        if (this.kindOf(expr) == NodeKind.superExpr && !this.inDerivedConstructor) {
          this.hadError = true;
          return NO_NODE;
        }
        const call = this.ast.newNode(NodeKind.call, this.startOf(expr), 0);
        this.ast.setLeft(call, expr);
        const end = this.parseArguments(call);
        this.ast.setEnd(call, end);
        expr = call;
      } else if (k == TokenKind.templateLit) {
        const template = this.parseTemplateLit();
        if (template == NO_NODE) return NO_NODE;
        const tagged = this.ast.newNode(NodeKind.taggedTemplate, this.startOf(expr), this.endOf(template));
        this.ast.setLeft(tagged, expr);
        this.ast.setRight(tagged, template);
        expr = tagged;
      } else if (k == TokenKind.questionDot) {
        this.advance();
        const after = this.peekKind();
        if (after == TokenKind.lParen) {
          const call = this.ast.newNode(NodeKind.optionalCall, this.startOf(expr), 0);
          this.ast.setLeft(call, expr);
          const end = this.parseArguments(call);
          this.ast.setEnd(call, end);
          expr = call;
        } else if (after == TokenKind.lBracket) {
          this.advance();
          const property = this.parseExpressionIn();
          if (property == NO_NODE) return NO_NODE;
          const close = this.peek();
          if (!this.expectKind(TokenKind.rBracket)) return NO_NODE;
          const computed = this.ast.newNode(NodeKind.optionalComputed, this.startOf(expr), close.start + close.length);
          this.ast.setLeft(computed, expr);
          this.ast.setRight(computed, property);
          expr = computed;
        } else {
          const idToken = this.advance();
          expr = this.memberNode(NodeKind.optionalMember, expr, this.startOf(expr), idToken);
        }
      } else {
        return expr;
      }
    }
    return expr;
  }

  // Parses `( args )` into `call`'s children; returns the end offset.
  function parseArguments(inout this, call: u32): u32 {
    this.advance();
    const savedNoIn = this.noIn;
    this.noIn = false;
    let arguments = Array<u32>();
    if (this.peekKind() != TokenKind.rParen) {
      while (true) {
        let argument: u32 = NO_NODE;
        if (this.peekKind() == TokenKind.ellipsis) {
          const dots = this.advance();
          const inner = this.parseAssignment();
          if (inner == NO_NODE) break;
          const spread = this.ast.newNode(NodeKind.spread, dots.start, this.endOf(inner));
          this.ast.setLeft(spread, inner);
          argument = spread;
        } else {
          argument = this.parseAssignment();
          if (argument == NO_NODE) break;
        }
        arguments.push(argument);
        if (!this.matchKind(TokenKind.comma)) break;
        if (this.peekKind() == TokenKind.rParen) break;
      }
    }
    this.noIn = savedNoIn;
    const close = this.peek();
    this.expectKind(TokenKind.rParen);
    this.ast.setChildren(call, in arguments);
    return close.start + close.length;
  }

  function parsePrimary(inout this): u32 {
    const t = this.peek();
    const k = t.kind;

    if (k == TokenKind.kwFunction) return this.parseFunctionExpr(false);
    if (k == TokenKind.kwAsync && this.peekKind2() == TokenKind.kwFunction) {
      this.advance();
      return this.parseFunctionExpr(true);
    }
    // `await expr` only inside an async body; elsewhere `await` is an
    // identifier reference.
    if (k == TokenKind.kwAwait && this.inAsync) {
      const keyword = this.advance();
      const inner = this.parseUnary();
      if (inner == NO_NODE) return NO_NODE;
      const awaited = this.ast.newNode(NodeKind.awaitExpr, keyword.start, this.endOf(inner));
      this.ast.setLeft(awaited, inner);
      return awaited;
    }
    if (k == TokenKind.kwAwait && this.inStaticBlock && this.functionDepth == this.staticBlockDepth) {
      this.hadError = true;
      return NO_NODE;
    }
    if (k == TokenKind.kwClass) return this.parseClassExpr();
    // Dynamic `import(specifier [, options])` and `import.meta`.
    if (k == TokenKind.kwImport) {
      const keyword = this.advance();
      if (this.peekKind() == TokenKind.dot) {
        this.advance();
        const property = this.peek();
        const isMeta = property.length == 4 && this.sliceEquals(property.start, 4, "meta");
        if (!isMeta) {
          this.hadError = true;
          return NO_NODE;
        }
        this.advance();
        return this.ast.newNode(NodeKind.importMetaExpr, keyword.start, property.start + property.length);
      }
      if (!this.expectKind(TokenKind.lParen)) return NO_NODE;
      const specifier = this.parseAssignment();
      if (specifier == NO_NODE) return NO_NODE;
      // Import attributes are parsed and discarded.
      if (this.peekKind() == TokenKind.comma) {
        this.advance();
        if (this.peekKind() != TokenKind.rParen) {
          const options = this.parseAssignment();
          if (options == NO_NODE) return NO_NODE;
          if (this.peekKind() == TokenKind.comma) this.advance();
        }
      }
      const close = this.peek();
      if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
      const call = this.ast.newNode(NodeKind.importCall, keyword.start, close.start + close.length);
      this.ast.setLeft(call, specifier);
      return call;
    }

    if (k == TokenKind.numberLit) {
      this.advance();
      const number = this.ast.newNode(NodeKind.numberExpr, t.start, t.start + t.length);
      this.ast.setNum(number, this.parseNumberLiteral(t.start, t.length));
      return number;
    }
    if (k == TokenKind.bigIntLit) {
      this.advance();
      return this.ast.newNode(NodeKind.bigIntExpr, t.start, t.start + t.length);
    }
    if (k == TokenKind.stringLit) {
      this.advance();
      return this.ast.newNode(NodeKind.stringExpr, t.start, t.start + t.length);
    }
    if (k == TokenKind.templateLit) return this.parseTemplateLit();
    if (k == TokenKind.regexLit) {
      this.advance();
      return this.ast.newNode(NodeKind.regexExpr, t.start, t.start + t.length);
    }
    if (k == TokenKind.kwTrue) {
      this.advance();
      const literal = this.ast.newNode(NodeKind.boolExpr, t.start, t.start + t.length);
      this.ast.setBool(literal, true);
      return literal;
    }
    if (k == TokenKind.kwFalse) {
      this.advance();
      return this.ast.newNode(NodeKind.boolExpr, t.start, t.start + t.length);
    }
    if (k == TokenKind.kwNull) {
      this.advance();
      return this.ast.newNode(NodeKind.nullExpr, t.start, t.start + t.length);
    }
    if (k == TokenKind.kwUndefined) {
      this.advance();
      return this.ast.newNode(NodeKind.undefinedExpr, t.start, t.start + t.length);
    }
    if (k == TokenKind.kwThis) {
      this.advance();
      return this.ast.newNode(NodeKind.thisExpr, t.start, t.start + t.length);
    }
    if (k == TokenKind.kwSuper) {
      this.advance();
      return this.ast.newNode(NodeKind.superExpr, t.start, t.start + t.length);
    }
    if (this.isBindingIdentCtx(k)) {
      this.advance();
      if (!this.isBindingIdentTok(t)) {
        this.hadError = true;
        return NO_NODE;
      }
      const ident = this.ast.newNode(NodeKind.identExpr, t.start, t.start + t.length);
      this.ast.setName(ident, t.start, t.length);
      return ident;
    }
    if (k == TokenKind.lParen) {
      this.advance();
      const savedNoIn = this.noIn;
      this.noIn = false;
      const inner = this.parseExpression();
      this.noIn = savedNoIn;
      if (inner == NO_NODE) return NO_NODE;
      const close = this.peek();
      if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
      const paren = this.ast.newNode(NodeKind.paren, t.start, close.start + close.length);
      this.ast.setLeft(paren, inner);
      return paren;
    }
    if (k == TokenKind.lBracket) return this.parseArray();
    if (k == TokenKind.lBrace) return this.parseObject();

    this.hadError = true;
    this.advance();
    return NO_NODE;
  }

  function parseArray(inout this): u32 {
    const open = this.advance();
    const savedNoIn = this.noIn;
    this.noIn = false;
    let elements = Array<u32>();
    while (this.peekKind() != TokenKind.rBracket && this.peekKind() != TokenKind.eof) {
      let element: u32 = NO_NODE;
      if (this.peekKind() == TokenKind.comma) {
        const at = this.peek().start;
        element = this.ast.newNode(NodeKind.holeExpr, at, at);
      } else if (this.peekKind() == TokenKind.ellipsis) {
        const dots = this.advance();
        const inner = this.parseAssignment();
        if (inner == NO_NODE) break;
        const spread = this.ast.newNode(NodeKind.spread, dots.start, this.endOf(inner));
        this.ast.setLeft(spread, inner);
        element = spread;
      } else {
        element = this.parseAssignment();
        if (element == NO_NODE) break;
      }
      elements.push(element);
      if (!this.matchKind(TokenKind.comma)) break;
      // A comma after a spread only matters if this literal becomes a
      // pattern; flag it and let reinterpretation decide.
      if (this.kindOf(element) == NodeKind.spread) this.ast.setBool(element, true);
    }
    this.noIn = savedNoIn;
    const close = this.peek();
    this.expectKind(TokenKind.rBracket);
    const array = this.ast.newNode(NodeKind.array, open.start, close.start + close.length);
    this.ast.setChildren(array, in elements);
    return array;
  }


  // ======================================================================
  // Identifier names, property names
  // ======================================================================

  function isKeywordToken(kind: TokenKind): boolean {
    if (kind == TokenKind.kwVar || kind == TokenKind.kwLet || kind == TokenKind.kwConst) return true;
    if (kind == TokenKind.kwFunction || kind == TokenKind.kwReturn) return true;
    if (kind == TokenKind.kwIf || kind == TokenKind.kwElse) return true;
    if (kind == TokenKind.kwFor || kind == TokenKind.kwWhile || kind == TokenKind.kwDo) return true;
    if (kind == TokenKind.kwBreak || kind == TokenKind.kwContinue) return true;
    if (kind == TokenKind.kwClass || kind == TokenKind.kwExtends || kind == TokenKind.kwSuper) return true;
    if (kind == TokenKind.kwNew || kind == TokenKind.kwThis) return true;
    if (kind == TokenKind.kwTrue || kind == TokenKind.kwFalse || kind == TokenKind.kwNull || kind == TokenKind.kwUndefined) return true;
    if (kind == TokenKind.kwTypeof || kind == TokenKind.kwDelete || kind == TokenKind.kwVoid) return true;
    if (kind == TokenKind.kwIn || kind == TokenKind.kwOf || kind == TokenKind.kwInstanceof) return true;
    if (kind == TokenKind.kwThrow || kind == TokenKind.kwTry || kind == TokenKind.kwCatch || kind == TokenKind.kwFinally) return true;
    if (kind == TokenKind.kwSwitch || kind == TokenKind.kwCase || kind == TokenKind.kwDefault) return true;
    if (kind == TokenKind.kwWith) return true;
    if (kind == TokenKind.kwAsync || kind == TokenKind.kwAwait || kind == TokenKind.kwYield) return true;
    if (kind == TokenKind.kwImport || kind == TokenKind.kwExport || kind == TokenKind.kwFrom || kind == TokenKind.kwAs) return true;
    return false;
  }

  function isPropertyNameStart(kind: TokenKind): boolean {
    if (kind == TokenKind.identifier) return true;
    if (kind == TokenKind.stringLit) return true;
    if (kind == TokenKind.numberLit) return true;
    return this.isKeywordToken(kind);
  }

  // Exact byte comparison of two source slices.
  function slicesEqual(aStart: u32, aLength: u32, bStart: u32, bLength: u32): boolean {
    if (aLength != bLength) return false;
    let index: u32 = 0;
    while (index < aLength) {
      if (this.source[usize(aStart + index)] != this.source[usize(bStart + index)]) return false;
      index = index + 1;
    }
    return true;
  }

  // A bare identifier that is illegal as an assignment / binding target in
  // the current context: always-reserved words plus the strict-mode set.
  function identTargetReserved(expr: u32): boolean {
    const n = this.node(expr);
    const s = n.start;
    const length = n.end - n.start;
    if (this.identMatches(s, length, "enum")) return true;
    if (this.identMatches(s, length, "with")) return true;
    if (this.identMatches(s, length, "debugger")) return true;
    if (this.inGenerator || this.strictMode) {
      if (this.identMatches(s, length, "yield")) return true;
    }
    if (this.inAsync) {
      if (this.identMatches(s, length, "await")) return true;
    }
    if (this.strictMode) {
      if (this.identMatches(s, length, "implements")) return true;
      if (this.identMatches(s, length, "interface")) return true;
      if (this.identMatches(s, length, "package")) return true;
      if (this.identMatches(s, length, "private")) return true;
      if (this.identMatches(s, length, "protected")) return true;
      if (this.identMatches(s, length, "public")) return true;
      if (this.identMatches(s, length, "static")) return true;
      if (this.identMatches(s, length, "let")) return true;
      if (this.identMatches(s, length, "eval")) return true;
      if (this.identMatches(s, length, "arguments")) return true;
    }
    return false;
  }

  // ======================================================================
  // Binding patterns
  // ======================================================================

  function identNode(inout this, token: Token): u32 {
    const ident = this.ast.newNode(NodeKind.identExpr, token.start, token.start + token.length);
    this.ast.setName(ident, token.start, token.length);
    return ident;
  }

  function parseBindingTarget(inout this): u32 {
    const k = this.peekKind();
    if (k == TokenKind.lBrace) return this.parseObjectPattern();
    if (k == TokenKind.lBracket) return this.parseArrayPattern();
    const t = this.peek();
    if (!this.isBindingIdentTok(t)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (this.bindingNameStrictReserved(t)) {
      this.hadError = true;
      return NO_NODE;
    }
    this.advance();
    return this.identNode(t);
  }

  // `{ a, b: rename, c = default, ...rest }`
  function parseObjectPattern(inout this): u32 {
    const open = this.advance();
    let entries = Array<u32>();
    let seenRest = false;
    while (this.peekKind() != TokenKind.rBrace && this.peekKind() != TokenKind.eof) {
      if (seenRest) {
        this.hadError = true;
        break;
      }
      const entryStart = this.peek().start;
      if (this.peekKind() == TokenKind.ellipsis) {
        this.advance();
        const id = this.peek();
        if (!this.isBindingIdentTok(id)) {
          this.hadError = true;
          break;
        }
        if (this.bindingNameStrictReserved(id)) {
          this.hadError = true;
          break;
        }
        this.advance();
        const ident = this.identNode(id);
        const rest = this.ast.newNode(NodeKind.patternEntry, entryStart, id.start + id.length);
        this.ast.setLeft(rest, ident);
        this.ast.setBool(rest, true);
        entries.push(rest);
        seenRest = true;
        break;
      }
      let computedKey: u32 = NO_NODE;
      let keyStart: u32 = 0;
      let keyLength: u32 = 0;
      let savedKey = tokenEof(0);
      if (this.peekKind() == TokenKind.lBracket) {
        this.advance();
        computedKey = this.parseAssignment();
        if (computedKey == NO_NODE) break;
        if (!this.expectKind(TokenKind.rBracket)) break;
      } else {
        const keyToken = this.peek();
        if (!this.isPropertyNameStart(keyToken.kind)) {
          this.hadError = true;
          break;
        }
        this.advance();
        keyStart = keyToken.start;
        keyLength = keyToken.length;
        savedKey = keyToken;
      }
      let target: u32 = NO_NODE;
      if (this.matchKind(TokenKind.colon)) {
        target = this.parseBindingTarget();
        if (target == NO_NODE) break;
      } else if (computedKey != NO_NODE) {
        this.hadError = true;
        break;
      } else {
        // Shorthand: the key doubles as the binding, so it must be a valid
        // binding identifier, not a reserved word.
        if (!this.isBindingIdentTok(savedKey)) {
          this.hadError = true;
          break;
        }
        if (this.bindingNameStrictReserved(savedKey)) {
          this.hadError = true;
          break;
        }
        target = this.ast.newNode(NodeKind.identExpr, keyStart, keyStart + keyLength);
        this.ast.setName(target, keyStart, keyLength);
      }
      let defaultExpr: u32 = NO_NODE;
      if (this.matchKind(TokenKind.eq)) {
        defaultExpr = this.parseAssignment();
        if (defaultExpr == NO_NODE) break;
      }
      const entryEnd = defaultExpr != NO_NODE ? this.endOf(defaultExpr) : this.endOf(target);
      const entry = this.ast.newNode(NodeKind.patternEntry, entryStart, entryEnd);
      this.ast.setName(entry, keyStart, keyLength);
      this.ast.setThird(entry, computedKey);
      this.ast.setLeft(entry, target);
      this.ast.setRight(entry, defaultExpr);
      entries.push(entry);
      if (!this.matchKind(TokenKind.comma)) break;
    }
    const close = this.peek();
    if (!this.expectKind(TokenKind.rBrace)) return NO_NODE;
    const pattern = this.ast.newNode(NodeKind.objectPattern, open.start, close.start + close.length);
    this.ast.setChildren(pattern, in entries);
    return pattern;
  }

  // `[a, , b = default, ...tail]`
  function parseArrayPattern(inout this): u32 {
    const open = this.advance();
    let entries = Array<u32>();
    let seenRest = false;
    while (this.peekKind() != TokenKind.rBracket && this.peekKind() != TokenKind.eof) {
      if (seenRest) {
        this.hadError = true;
        break;
      }
      const entryStart = this.peek().start;
      if (this.peekKind() == TokenKind.comma) {
        const hole = this.ast.newNode(NodeKind.patternEntry, entryStart, entryStart);
        entries.push(hole);
        this.advance();
        continue;
      }
      let isRest = false;
      if (this.peekKind() == TokenKind.ellipsis) {
        this.advance();
        isRest = true;
      }
      const target = this.parseBindingTarget();
      if (target == NO_NODE) break;
      let defaultExpr: u32 = NO_NODE;
      if (!isRest && this.matchKind(TokenKind.eq)) {
        defaultExpr = this.parseAssignment();
        if (defaultExpr == NO_NODE) break;
      }
      const entryEnd = defaultExpr != NO_NODE ? this.endOf(defaultExpr) : this.endOf(target);
      const entry = this.ast.newNode(NodeKind.patternEntry, entryStart, entryEnd);
      this.ast.setLeft(entry, target);
      this.ast.setRight(entry, defaultExpr);
      this.ast.setBool(entry, isRest);
      entries.push(entry);
      if (isRest) {
        seenRest = true;
        break;
      }
      if (!this.matchKind(TokenKind.comma)) break;
    }
    const close = this.peek();
    if (!this.expectKind(TokenKind.rBracket)) return NO_NODE;
    const pattern = this.ast.newNode(NodeKind.arrayPattern, open.start, close.start + close.length);
    this.ast.setChildren(pattern, in entries);
    return pattern;
  }

  // Cover grammar: an Array / Object literal that turns out to be an
  // assignment target becomes the matching pattern.
  function reinterpretAsPattern(inout this, expr: u32): u32 {
    if (expr == NO_NODE) return NO_NODE;
    const e = this.node(expr);
    if (e.kind == NodeKind.array) {
      const pattern = this.ast.newNode(NodeKind.arrayPattern, e.start, e.end);
      let entries = Array<u32>();
      let i: u32 = 0;
      while (i < e.childrenCount) {
        const element = this.ast.child(expr, i);
        const elementStart = element != NO_NODE ? this.startOf(element) : e.start;
        const elementEnd = element != NO_NODE ? this.endOf(element) : e.start;
        const entry = this.ast.newNode(NodeKind.patternEntry, elementStart, elementEnd);
        if (element == NO_NODE || this.kindOf(element) == NodeKind.holeExpr) {
          // Elision: no target, no default.
        } else if (this.kindOf(element) == NodeKind.spread) {
          const spread = this.node(element);
          if (i + 1 != e.childrenCount || spread.boolValue) {
            this.hadError = true;
            return NO_NODE;
          }
          this.ast.setBool(entry, true);
          const target = this.reinterpretAssignTarget(spread.left);
          if (target == NO_NODE) return NO_NODE;
          this.ast.setLeft(entry, target);
        } else if (this.kindOf(element) == NodeKind.assignment && this.node(element).op == TokenKind.eq) {
          const assignment = this.node(element);
          const target = this.reinterpretAssignTarget(assignment.left);
          if (target == NO_NODE) return NO_NODE;
          this.ast.setLeft(entry, target);
          this.ast.setRight(entry, assignment.right);
        } else {
          const target = this.reinterpretAssignTarget(element);
          if (target == NO_NODE) return NO_NODE;
          this.ast.setLeft(entry, target);
        }
        entries.push(entry);
        i = i + 1;
      }
      this.ast.setChildren(pattern, in entries);
      return pattern;
    }
    if (e.kind == NodeKind.object) {
      const pattern = this.ast.newNode(NodeKind.objectPattern, e.start, e.end);
      let entries = Array<u32>();
      let i: u32 = 0;
      while (i < e.childrenCount) {
        const property = this.ast.child(expr, i);
        if (property == NO_NODE) {
          this.hadError = true;
          return NO_NODE;
        }
        const prop = this.node(property);
        const entry = this.ast.newNode(NodeKind.patternEntry, prop.start, prop.end);
        if (prop.kind == NodeKind.spread) {
          if (i + 1 != e.childrenCount || prop.boolValue) {
            this.hadError = true;
            return NO_NODE;
          }
          this.ast.setBool(entry, true);
          const target = this.reinterpretAssignTarget(prop.left);
          if (target == NO_NODE) return NO_NODE;
          this.ast.setLeft(entry, target);
          entries.push(entry);
          i = i + 1;
          continue;
        }
        if (prop.kind != NodeKind.objectProp) {
          this.hadError = true;
          return NO_NODE;
        }
        this.ast.setName(entry, prop.nameStart, prop.nameLength);
        if (prop.third != NO_NODE) this.ast.setThird(entry, prop.third);
        const value = prop.left;
        if (value != NO_NODE && this.kindOf(value) == NodeKind.assignment && this.node(value).op == TokenKind.eq) {
          const assignment = this.node(value);
          const target = this.reinterpretAssignTarget(assignment.left);
          if (target == NO_NODE) return NO_NODE;
          this.ast.setLeft(entry, target);
          this.ast.setRight(entry, assignment.right);
        } else {
          const target = this.reinterpretAssignTarget(value);
          if (target == NO_NODE) return NO_NODE;
          this.ast.setLeft(entry, target);
        }
        entries.push(entry);
        i = i + 1;
      }
      this.ast.setChildren(pattern, in entries);
      return pattern;
    }
    if (e.kind == NodeKind.paren) return this.reinterpretAsPattern(e.left);
    if (e.kind == NodeKind.arrayPattern || e.kind == NodeKind.objectPattern) return expr;
    this.hadError = true;
    return NO_NODE;
  }

  function reinterpretAssignTarget(inout this, expr: u32): u32 {
    if (expr == NO_NODE) return NO_NODE;
    const k = this.kindOf(expr);
    if (k == NodeKind.array || k == NodeKind.object) return this.reinterpretAsPattern(expr);
    if (k == NodeKind.paren) return this.reinterpretAssignTarget(this.node(expr).left);
    if (k == NodeKind.identExpr) {
      if (this.identTargetReserved(expr)) {
        this.hadError = true;
        return NO_NODE;
      }
      return expr;
    }
    if (k == NodeKind.member || k == NodeKind.computed || k == NodeKind.arrayPattern || k == NodeKind.objectPattern) {
      return expr;
    }
    this.hadError = true;
    return NO_NODE;
  }

  // ======================================================================
  // Functions, parameters, arrows
  // ======================================================================

  // Comma-separated bindings up to (not including) `)`: plain, defaulted,
  // pattern (wrapped in a placeholder IdentExpr with the pattern on
  // `third`), and a trailing `...rest`.
  function parseParamList(inout this): Array<u32> {
    let params = Array<u32>();
    let seenRest = false;
    while (this.peekKind() != TokenKind.rParen && this.peekKind() != TokenKind.eof) {
      if (seenRest) {
        this.hadError = true;
        break;
      }
      let isRest = false;
      if (this.peekKind() == TokenKind.ellipsis) {
        this.advance();
        isRest = true;
      }
      const pk = this.peekKind();
      const isPattern = pk == TokenKind.lBrace || pk == TokenKind.lBracket;
      let ident: u32 = NO_NODE;
      let identStart: u32 = 0;
      let identEnd: u32 = 0;
      if (isPattern) {
        if (isRest) {
          this.hadError = true;
          break;
        }
        const pattern = this.parseBindingTarget();
        if (pattern == NO_NODE) break;
        identStart = this.startOf(pattern);
        identEnd = this.endOf(pattern);
        ident = this.ast.newNode(NodeKind.identExpr, identStart, identEnd);
        this.ast.setThird(ident, pattern);
      } else {
        const nameToken = this.peek();
        if (!this.isBindingIdentTok(nameToken)) {
          this.hadError = true;
          break;
        }
        if (this.strictMode && this.nameIsArgumentsOrEval(nameToken.start, nameToken.length)) {
          this.hadError = true;
          break;
        }
        this.advance();
        identStart = nameToken.start;
        identEnd = nameToken.start + nameToken.length;
        ident = this.identNode(nameToken);
      }
      let param = ident;
      if (isRest) {
        const rest = this.ast.newNode(NodeKind.restParam, identStart, identEnd);
        this.ast.setLeft(rest, ident);
        param = rest;
        seenRest = true;
      } else if (this.peekKind() == TokenKind.eq) {
        this.advance();
        const init = this.parseAssignment();
        if (init == NO_NODE) break;
        this.ast.setRight(param, init);
      }
      params.push(param);
      if (!this.matchKind(TokenKind.comma)) break;
      if (seenRest) {
        this.hadError = true;
        break;
      }
      if (this.peekKind() == TokenKind.rParen) break;
    }
    // Strict-mode duplicate parameter names (simple identifiers only here).
    if (this.strictMode && params.length >= 2) {
      let pi: usize = 0;
      while (pi < params.length) {
        const a = this.paramIdent(params[pi]);
        if (a != NO_NODE && this.node(a).nameLength > 0) {
          const an = this.node(a);
          let pj: usize = pi + 1;
          while (pj < params.length) {
            const b = this.paramIdent(params[pj]);
            if (b != NO_NODE) {
              const bn = this.node(b);
              if (bn.nameLength == an.nameLength && this.slicesEqual(an.nameStart, an.nameLength, bn.nameStart, bn.nameLength)) {
                this.hadError = true;
              }
            }
            pj = pj + 1;
          }
        }
        pi = pi + 1;
      }
    }
    return params;
  }

  // The IdentExpr a parameter entry binds (through a RestParam wrapper).
  function paramIdent(param: u32): u32 {
    if (param == NO_NODE) return NO_NODE;
    const n = this.node(param);
    if (n.kind == NodeKind.restParam) return n.left;
    if (n.kind == NodeKind.identExpr) return param;
    return NO_NODE;
  }

  function paramsAreSimple(in params: Array<u32>): boolean {
    let i: usize = 0;
    while (i < params.length) {
      const param = params[i];
      if (param == NO_NODE) return false;
      const n = this.node(param);
      if (n.kind == NodeKind.restParam) return false;
      if (n.kind != NodeKind.identExpr) return false;
      if (n.nameLength == 0) return false;
      if (n.right != NO_NODE) return false;
      i = i + 1;
    }
    return true;
  }

  function collectParamBoundNames(node: u32, inout starts: Array<u32>, inout lengths: Array<u32>): void {
    if (node == NO_NODE) return;
    const n = this.node(node);
    if (n.kind == NodeKind.identExpr) {
      if (n.nameLength > 0) {
        starts.push(n.nameStart);
        lengths.push(n.nameLength);
        return;
      }
      if (n.third != NO_NODE) this.collectParamBoundNames(n.third, inout starts, inout lengths);
      return;
    }
    if (n.kind == NodeKind.restParam) {
      this.collectParamBoundNames(n.left, inout starts, inout lengths);
      return;
    }
    if (n.kind == NodeKind.patternEntry) {
      if (n.left != NO_NODE) this.collectParamBoundNames(n.left, inout starts, inout lengths);
      return;
    }
    if (n.kind == NodeKind.arrayPattern || n.kind == NodeKind.objectPattern) {
      let i: u32 = 0;
      while (i < n.childrenCount) {
        this.collectParamBoundNames(this.ast.child(node, i), inout starts, inout lengths);
        i = i + 1;
      }
    }
  }

  // Duplicate BoundNames through patterns, rest, and defaults.
  function paramsHaveDuplicateBinding(in params: Array<u32>): boolean {
    let starts = Array<u32>();
    let lengths = Array<u32>();
    let i: usize = 0;
    while (i < params.length) {
      this.collectParamBoundNames(params[i], inout starts, inout lengths);
      i = i + 1;
    }
    let a: usize = 0;
    while (a < starts.length) {
      let b: usize = a + 1;
      while (b < starts.length) {
        if (lengths[a] == lengths[b] && this.slicesEqual(starts[a], lengths[a], starts[b], lengths[b])) return true;
        b = b + 1;
      }
      a = a + 1;
    }
    return false;
  }

  // A 12-byte string token spelling "use strict" in either quote.
  function isUseStrictSlice(start: u32, length: u32): boolean {
    if (length != 12) return false;
    const quote = this.source[usize(start)];
    if (quote != B_DQUOTE && quote != B_SQUOTE) return false;
    if (this.source[usize(start + 11)] != quote) return false;
    return this.sliceEquals(start + 1, 10, "use strict");
  }

  // Directive prologue of a parsed body: leading string-literal statements.
  function bodyHasUseStrictDirective(body: u32): boolean {
    if (body == NO_NODE) return false;
    const b = this.node(body);
    if (b.kind != NodeKind.blockStmt && b.kind != NodeKind.program) return false;
    let i: u32 = 0;
    while (i < b.childrenCount) {
      const statement = this.ast.child(body, i);
      if (statement == NO_NODE) return false;
      const st = this.node(statement);
      if (st.kind != NodeKind.stringExpr) return false;
      if (this.isUseStrictSlice(st.start, st.end - st.start)) return true;
      i = i + 1;
    }
    return false;
  }

  // Token-level prologue detection, before the body is parsed, so strict
  // early errors apply while parsing it.
  function tokensHaveUseStrictPrologue(startIndex: usize): boolean {
    let j = startIndex;
    while (j < this.tokenLimit) {
      const t = this.tokens[j];
      if (t.kind != TokenKind.stringLit) return false;
      if (this.isUseStrictSlice(t.start, t.length)) return true;
      const next = this.peekAtIndex(j + 1);
      if (next.kind == TokenKind.semicolon) {
        j = j + 2;
        continue;
      }
      if (next.kind == TokenKind.stringLit) {
        j = j + 1;
        continue;
      }
      return false;
    }
    return false;
  }

  function peekAtIndex(index: usize): Token {
    if (index >= this.tokenLimit) return tokenEof(u32(this.source.length));
    return this.tokens[index];
  }

  // Parses `{ body }` with the function context flags set; returns the block.
  function parseFunctionBody(inout this, isAsync: boolean, isGenerator: boolean): u32 {
    const savedAsync = this.inAsync;
    const savedGenerator = this.inGenerator;
    this.inAsync = isAsync;
    this.inGenerator = isGenerator;
    this.functionDepth = this.functionDepth + 1;
    const body = this.parseBlock();
    this.functionDepth = this.functionDepth - 1;
    this.inAsync = savedAsync;
    this.inGenerator = savedGenerator;
    return body;
  }

  function parseFunctionDecl(inout this, isAsync: boolean): u32 {
    const keyword = this.advance();
    let isGenerator = false;
    if (this.peekKind() == TokenKind.star) {
      this.advance();
      isGenerator = true;
    }
    const nameToken = this.peek();
    if (!this.isBindingIdentTok(nameToken)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (this.bindingNameStrictReserved(nameToken)) {
      this.hadError = true;
      return NO_NODE;
    }
    this.advance();
    if (!this.expectKind(TokenKind.lParen)) return NO_NODE;
    const params = this.parseParamList();
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    if (this.peekKind() != TokenKind.lBrace) {
      this.hadError = true;
      return NO_NODE;
    }
    const body = this.parseFunctionBody(isAsync, isGenerator);
    if (body == NO_NODE) return NO_NODE;
    if (!this.paramsAreSimple(in params) && this.bodyHasUseStrictDirective(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (!this.paramsAreSimple(in params) && this.paramsHaveDuplicateBinding(in params)) {
      this.hadError = true;
      return NO_NODE;
    }
    const declaration = this.ast.newNode(NodeKind.functionDecl, keyword.start, this.endOf(body));
    this.ast.setName(declaration, nameToken.start, nameToken.length);
    this.ast.setLeft(declaration, body);
    this.ast.setChildren(declaration, in params);
    this.ast.setBool(declaration, isAsync);
    if (isGenerator) this.ast.setNum(declaration, 3.0);
    return declaration;
  }

  function parseFunctionExpr(inout this, isAsync: boolean): u32 {
    const keyword = this.advance();
    let isGenerator = false;
    if (this.peekKind() == TokenKind.star) {
      this.advance();
      isGenerator = true;
    }
    let nameStart: u32 = 0;
    let nameLength: u32 = 0;
    const nameToken = this.peek();
    if (nameToken.kind != TokenKind.lParen && this.isBindingIdentTok(nameToken)) {
      if (this.bindingNameStrictReserved(nameToken)) {
        this.hadError = true;
        return NO_NODE;
      }
      this.advance();
      nameStart = nameToken.start;
      nameLength = nameToken.length;
    }
    if (!this.expectKind(TokenKind.lParen)) return NO_NODE;
    const params = this.parseParamList();
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    if (this.peekKind() != TokenKind.lBrace) {
      this.hadError = true;
      return NO_NODE;
    }
    const body = this.parseFunctionBody(isAsync, isGenerator);
    if (body == NO_NODE) return NO_NODE;
    if (!this.paramsAreSimple(in params) && this.bodyHasUseStrictDirective(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (!this.paramsAreSimple(in params) && this.paramsHaveDuplicateBinding(in params)) {
      this.hadError = true;
      return NO_NODE;
    }
    const expression = this.ast.newNode(NodeKind.functionExpr, keyword.start, this.endOf(body));
    this.ast.setName(expression, nameStart, nameLength);
    this.ast.setLeft(expression, body);
    this.ast.setChildren(expression, in params);
    this.ast.setBool(expression, isAsync);
    if (isGenerator) this.ast.setNum(expression, 3.0);
    return expression;
  }

  // Block body or a concise AssignmentExpression body; both count as a
  // function for `return`.
  function parseArrowBody(inout this, isAsync: boolean): u32 {
    const savedAsync = this.inAsync;
    this.inAsync = isAsync;
    this.functionDepth = this.functionDepth + 1;
    let body: u32 = NO_NODE;
    if (this.peekKind() == TokenKind.lBrace) {
      body = this.parseBlock();
    } else {
      body = this.parseAssignment();
    }
    this.functionDepth = this.functionDepth - 1;
    this.inAsync = savedAsync;
    return body;
  }

  function parseArrowSingle(inout this, isAsync: boolean): u32 {
    const startPos = this.peek().start;
    const nameToken = this.advance();
    this.advance();
    const param = this.identNode(nameToken);
    if (this.identTargetReserved(param)) {
      this.hadError = true;
      return NO_NODE;
    }
    let params = Array<u32>();
    params.push(param);
    const body = this.parseArrowBody(isAsync);
    if (body == NO_NODE) return NO_NODE;
    const arrow = this.ast.newNode(NodeKind.arrowFunc, startPos, this.endOf(body));
    this.ast.setLeft(arrow, body);
    this.ast.setChildren(arrow, in params);
    this.ast.setBool(arrow, isAsync);
    return arrow;
  }

  function parseArrowParen(inout this, isAsync: boolean): u32 {
    const startPos = this.peek().start;
    this.advance();
    const params = this.parseParamList();
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    if (!this.expectKind(TokenKind.arrow)) return NO_NODE;
    const body = this.parseArrowBody(isAsync);
    if (body == NO_NODE) return NO_NODE;
    if (!this.paramsAreSimple(in params) && this.bodyHasUseStrictDirective(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (this.paramsHaveDuplicateBinding(in params)) {
      this.hadError = true;
      return NO_NODE;
    }
    const arrow = this.ast.newNode(NodeKind.arrowFunc, startPos, this.endOf(body));
    this.ast.setLeft(arrow, body);
    this.ast.setChildren(arrow, in params);
    this.ast.setBool(arrow, isAsync);
    return arrow;
  }

  // From a `(`, find its matching `)` and report whether `=>` follows.
  function lookaheadArrowParen(): boolean {
    let depth: i32 = 0;
    let i = this.pos;
    while (i < this.tokenLimit) {
      const k = this.tokens[i].kind;
      if (k == TokenKind.lParen) {
        depth = depth + 1;
      } else if (k == TokenKind.rParen) {
        depth = depth - 1;
        if (depth == 0) {
          const next = i + 1;
          if (next >= this.tokenLimit) return false;
          return this.tokens[next].kind == TokenKind.arrow;
        }
      } else if (k == TokenKind.eof) {
        return false;
      }
      i = i + 1;
    }
    return false;
  }

  // ======================================================================
  // Object literals
  // ======================================================================

  // Method shorthand body shared by the computed and named forms.
  function parseMethodFunction(inout this, start: u32, isAsync: boolean, isGenerator: boolean, inout params: Array<u32>): u32 {
    const body = this.parseFunctionBody(isAsync, isGenerator);
    if (body == NO_NODE) return NO_NODE;
    const method = this.ast.newNode(NodeKind.functionExpr, start, this.endOf(body));
    this.ast.setLeft(method, body);
    this.ast.setChildren(method, in params);
    if (isAsync) this.ast.setBool(method, true);
    if (isGenerator) this.ast.setNum(method, 3.0);
    return method;
  }

  function parseObject(inout this): u32 {
    const open = this.advance();
    const savedNoIn = this.noIn;
    this.noIn = false;
    let properties = Array<u32>();

    while (this.peekKind() != TokenKind.rBrace && this.peekKind() != TokenKind.eof) {
      if (this.peekKind() == TokenKind.ellipsis) {
        const dots = this.advance();
        const inner = this.parseAssignment();
        if (inner == NO_NODE) break;
        const spread = this.ast.newNode(NodeKind.spread, dots.start, this.endOf(inner));
        this.ast.setLeft(spread, inner);
        properties.push(spread);
        if (!this.matchKind(TokenKind.comma)) break;
        this.ast.setBool(spread, true);
        continue;
      }
      // `async m(){}`, `*m(){}`, `async *m(){}`. `async` is a prefix only
      // when a property name, `[`, or `*` follows.
      let isAsync = false;
      let isGenerator = false;
      if (this.peekKind() == TokenKind.kwAsync
          && (this.isPropertyNameStart(this.peekKind2()) || this.peekKind2() == TokenKind.lBracket || this.peekKind2() == TokenKind.star)) {
        this.advance();
        isAsync = true;
      }
      if (this.peekKind() == TokenKind.star) {
        this.advance();
        isGenerator = true;
      }

      // Computed key: `[expr]: value` or `[expr](args) { body }`.
      if (this.peekKind() == TokenKind.lBracket) {
        const bracket = this.advance();
        const keyExpr = this.parseAssignment();
        if (keyExpr == NO_NODE) break;
        if (!this.expectKind(TokenKind.rBracket)) break;
        let value: u32 = NO_NODE;
        if (this.matchKind(TokenKind.colon)) {
          if (isAsync || isGenerator) {
            this.hadError = true;
            break;
          }
          value = this.parseAssignment();
          if (value == NO_NODE) break;
        } else if (this.peekKind() == TokenKind.lParen) {
          this.advance();
          const savedAsync = this.inAsync;
          const savedGenerator = this.inGenerator;
          this.inAsync = isAsync;
          this.inGenerator = isGenerator;
          let params = this.parseParamList();
          if (!this.expectKind(TokenKind.rParen)) {
            this.inAsync = savedAsync;
            this.inGenerator = savedGenerator;
            break;
          }
          if (this.peekKind() != TokenKind.lBrace) {
            this.inAsync = savedAsync;
            this.inGenerator = savedGenerator;
            this.hadError = true;
            break;
          }
          this.inAsync = savedAsync;
          this.inGenerator = savedGenerator;
          value = this.parseMethodFunction(bracket.start, isAsync, isGenerator, inout params);
          if (value == NO_NODE) break;
        } else {
          this.hadError = true;
          break;
        }
        const property = this.ast.newNode(NodeKind.objectProp, bracket.start, this.endOf(value));
        this.ast.setLeft(property, value);
        this.ast.setThird(property, keyExpr);
        properties.push(property);
        if (!this.matchKind(TokenKind.comma)) break;
        continue;
      }

      const keyToken = this.peek();
      if (!this.isPropertyNameStart(keyToken.kind)) {
        this.hadError = true;
        break;
      }

      // Accessor shorthand: `get name() {}` / `set name(v) {}`, when the
      // next token is a property name (reserved words included) or `[`.
      let isAccessor = false;
      let isSetter = false;
      if (keyToken.kind == TokenKind.identifier && keyToken.length == 3) {
        const isGet = this.sliceEquals(keyToken.start, 3, "get");
        const isSet = this.sliceEquals(keyToken.start, 3, "set");
        if (isGet || isSet) {
          const after = this.peekKind2();
          if (after == TokenKind.identifier || after == TokenKind.stringLit || after == TokenKind.numberLit
              || after == TokenKind.lBracket || this.isKeywordToken(after)) {
            isAccessor = true;
            isSetter = isSet;
          }
        }
      }

      this.advance();
      const propStart = keyToken.start;
      let propEnd = keyToken.start + keyToken.length;

      if (isAccessor) {
        const realName = this.peek();
        let computedKey: u32 = NO_NODE;
        if (realName.kind == TokenKind.lBracket) {
          this.advance();
          computedKey = this.parseAssignment();
          if (computedKey == NO_NODE) break;
          if (!this.expectKind(TokenKind.rBracket)) break;
        } else {
          this.advance();
        }
        if (!this.expectKind(TokenKind.lParen)) break;
        const params = this.parseParamList();
        if (!this.expectKind(TokenKind.rParen)) break;
        if (this.peekKind() != TokenKind.lBrace) {
          this.hadError = true;
          break;
        }
        this.functionDepth = this.functionDepth + 1;
        const body = this.parseBlock();
        this.functionDepth = this.functionDepth - 1;
        if (body == NO_NODE) break;
        const accessor = this.ast.newNode(NodeKind.functionExpr, realName.start, this.endOf(body));
        if (computedKey == NO_NODE) this.ast.setName(accessor, realName.start, realName.length);
        this.ast.setLeft(accessor, body);
        this.ast.setChildren(accessor, in params);
        const property = this.ast.newNode(NodeKind.objectProp, keyToken.start, this.endOf(body));
        if (computedKey != NO_NODE) {
          this.ast.setThird(property, computedKey);
        } else {
          this.ast.setName(property, realName.start, realName.length);
        }
        this.ast.setLeft(property, accessor);
        this.ast.setOp(property, isSetter ? TokenKind.kwSet : TokenKind.kwGet);
        properties.push(property);
        if (!this.matchKind(TokenKind.comma)) break;
        continue;
      }

      let value: u32 = NO_NODE;
      let isColonForm = false;
      if (this.matchKind(TokenKind.colon)) {
        if (isAsync || isGenerator) {
          this.hadError = true;
          break;
        }
        isColonForm = true;
        value = this.parseAssignment();
        if (value == NO_NODE) break;
        propEnd = this.endOf(value);
      } else if (this.peekKind() == TokenKind.lParen) {
        // Method shorthand: anonymous function value, the key is only the
        // property name.
        if (!this.expectKind(TokenKind.lParen)) break;
        const savedAsync = this.inAsync;
        const savedGenerator = this.inGenerator;
        this.inAsync = isAsync;
        this.inGenerator = isGenerator;
        let params = this.parseParamList();
        if (!this.expectKind(TokenKind.rParen)) {
          this.inAsync = savedAsync;
          this.inGenerator = savedGenerator;
          break;
        }
        if (this.peekKind() != TokenKind.lBrace) {
          this.inAsync = savedAsync;
          this.inGenerator = savedGenerator;
          this.hadError = true;
          break;
        }
        this.inAsync = savedAsync;
        this.inGenerator = savedGenerator;
        const body = this.parseFunctionBody(isAsync, isGenerator);
        if (body == NO_NODE) break;
        if (!this.paramsAreSimple(in params) && this.bodyHasUseStrictDirective(body)) {
          this.hadError = true;
          break;
        }
        if (this.paramsHaveDuplicateBinding(in params)) {
          this.hadError = true;
          break;
        }
        const method = this.ast.newNode(NodeKind.functionExpr, keyToken.start, this.endOf(body));
        this.ast.setName(method, keyToken.start, 0);
        this.ast.setLeft(method, body);
        this.ast.setChildren(method, in params);
        if (isAsync) this.ast.setBool(method, true);
        if (isGenerator) this.ast.setNum(method, 3.0);
        value = method;
        propEnd = this.endOf(body);
      } else {
        // Shorthand `{ x }`, and the cover-grammar default `{ x = init }`.
        if (keyToken.kind != TokenKind.identifier) {
          this.hadError = true;
          break;
        }
        const ident = this.identNode(keyToken);
        if (this.peekKind() == TokenKind.eq) {
          this.advance();
          const defaultExpr = this.parseAssignment();
          if (defaultExpr == NO_NODE) break;
          const assignment = this.ast.newNode(NodeKind.assignment, this.startOf(ident), this.endOf(defaultExpr));
          this.ast.setOp(assignment, TokenKind.eq);
          this.ast.setLeft(assignment, ident);
          this.ast.setRight(assignment, defaultExpr);
          value = assignment;
          propEnd = this.endOf(defaultExpr);
        } else {
          value = ident;
        }
      }

      const property = this.ast.newNode(NodeKind.objectProp, propStart, propEnd);
      this.ast.setName(property, keyToken.start, keyToken.length);
      this.ast.setLeft(property, value);
      this.ast.setBool(property, isColonForm);
      properties.push(property);
      if (!this.matchKind(TokenKind.comma)) break;
    }

    const close = this.peek();
    this.expectKind(TokenKind.rBrace);
    this.noIn = savedNoIn;
    const object = this.ast.newNode(NodeKind.object, open.start, close.start + close.length);
    this.ast.setChildren(object, in properties);
    return object;
  }

  // ======================================================================
  // Loops, jumps, exceptions, switch
  // ======================================================================

  function parseFor(inout this): u32 {
    const keyword = this.advance();
    let isAwait = false;
    if (this.peekKind() == TokenKind.kwAwait) {
      if (!this.inAsync) {
        this.hadError = true;
        return NO_NODE;
      }
      this.advance();
      isAwait = true;
    }
    if (!this.expectKind(TokenKind.lParen)) return NO_NODE;

    const savedNoIn = this.noIn;
    this.noIn = true;
    let init: u32 = NO_NODE;
    const kk = this.peekKind();
    if (kk == TokenKind.semicolon) {
      this.advance();
      this.noIn = savedNoIn;
    } else if (kk == TokenKind.kwVar || kk == TokenKind.kwLet || kk == TokenKind.kwConst) {
      init = this.parseVarDecl(false);
      this.noIn = savedNoIn;
      if (init == NO_NODE) return NO_NODE;
      const after = this.peekKind();
      if (after == TokenKind.kwIn || after == TokenKind.kwOf) return this.finishForInOrOf(keyword, init, after, isAwait);
      if (isAwait) {
        this.hadError = true;
        return NO_NODE;
      }
      if (!this.expectKind(TokenKind.semicolon)) return NO_NODE;
    } else {
      init = this.parseExpression();
      this.noIn = savedNoIn;
      if (init == NO_NODE) return NO_NODE;
      const after = this.peekKind();
      if (after == TokenKind.kwIn || after == TokenKind.kwOf) return this.finishForInOrOf(keyword, init, after, isAwait);
      if (isAwait) {
        this.hadError = true;
        return NO_NODE;
      }
      if (!this.expectKind(TokenKind.semicolon)) return NO_NODE;
    }

    let test: u32 = NO_NODE;
    if (this.peekKind() != TokenKind.semicolon) {
      test = this.parseExpression();
      if (test == NO_NODE) return NO_NODE;
    }
    if (!this.expectKind(TokenKind.semicolon)) return NO_NODE;
    let update: u32 = NO_NODE;
    if (this.peekKind() != TokenKind.rParen) {
      update = this.parseExpression();
      if (update == NO_NODE) return NO_NODE;
    }
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    const body = this.parseStatement();
    if (body == NO_NODE) return NO_NODE;
    if (this.isDisallowedStatementBody(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    const loop = this.ast.newNode(NodeKind.forStmt, keyword.start, this.endOf(body));
    this.ast.setLeft(loop, init);
    this.ast.setRight(loop, test);
    this.ast.setThird(loop, update);
    let bodyList = Array<u32>();
    bodyList.push(body);
    this.ast.setChildren(loop, in bodyList);
    return loop;
  }

  function finishForInOrOf(inout this, keyword: Token, bindingIn: u32, opKind: TokenKind, isAwait: boolean): u32 {
    let binding = bindingIn;
    if (binding != NO_NODE && (this.kindOf(binding) == NodeKind.array || this.kindOf(binding) == NodeKind.object)) {
      binding = this.reinterpretAsPattern(binding);
      if (binding == NO_NODE) return NO_NODE;
    }
    if (binding != NO_NODE && this.kindOf(binding) == NodeKind.varDecl) {
      const declaration = this.node(binding);
      if (declaration.childrenCount != 1) {
        this.hadError = true;
        return NO_NODE;
      }
      const first = this.ast.child(binding, 0);
      if (first != NO_NODE && this.node(first).left != NO_NODE) {
        this.hadError = true;
        return NO_NODE;
      }
      // `for (let let of ...)` / const: a lexical ForDeclaration may not
      // bind the identifier `let`.
      if (first != NO_NODE && this.node(first).nameLength == 3
          && (declaration.op == TokenKind.kwLet || declaration.op == TokenKind.kwConst)
          && this.sliceEquals(this.node(first).nameStart, 3, "let")) {
        this.hadError = true;
        return NO_NODE;
      }
    }
    // A for-of head may not begin with the identifier `async`.
    if (opKind == TokenKind.kwOf && binding != NO_NODE && this.kindOf(binding) == NodeKind.identExpr) {
      const b = this.node(binding);
      if (b.end - b.start == 5 && this.sliceEquals(b.start, 5, "async")) {
        this.hadError = true;
        return NO_NODE;
      }
    }
    this.advance();
    let iterated: u32 = NO_NODE;
    if (opKind == TokenKind.kwOf) {
      iterated = this.parseAssignment();
    } else {
      iterated = this.parseExpression();
    }
    if (iterated == NO_NODE) return NO_NODE;
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    const body = this.parseStatement();
    if (body == NO_NODE) return NO_NODE;
    if (this.isDisallowedStatementBody(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (isAwait && opKind == TokenKind.kwIn) {
      this.hadError = true;
      return NO_NODE;
    }
    const kind = opKind == TokenKind.kwIn ? NodeKind.forInStmt : NodeKind.forOfStmt;
    const loop = this.ast.newNode(kind, keyword.start, this.endOf(body));
    this.ast.setLeft(loop, binding);
    this.ast.setRight(loop, iterated);
    if (isAwait) this.ast.setBool(loop, true);
    let bodyList = Array<u32>();
    bodyList.push(body);
    this.ast.setChildren(loop, in bodyList);
    return loop;
  }

  // `break` / `continue` with an optional same-line label.
  function parseJump(inout this, kind: NodeKind): u32 {
    const keyword = this.advance();
    let end = keyword.start + keyword.length;
    let labelStart: u32 = 0;
    let labelLength: u32 = 0;
    if (this.peekKind() == TokenKind.identifier) {
      const next = this.peek();
      if (!this.hasNewlineBetween(keyword.start + keyword.length, next.start)) {
        const id = this.advance();
        labelStart = id.start;
        labelLength = id.length;
        end = id.start + id.length;
      }
    }
    const jump = this.ast.newNode(kind, keyword.start, end);
    this.ast.setName(jump, labelStart, labelLength);
    this.matchTerminator();
    return jump;
  }

  function parseBreak(inout this): u32 {
    return this.parseJump(NodeKind.breakStmt);
  }

  function parseContinue(inout this): u32 {
    return this.parseJump(NodeKind.continueStmt);
  }

  function parseThrow(inout this): u32 {
    const keyword = this.advance();
    const argument = this.parseExpression();
    if (argument == NO_NODE) return NO_NODE;
    const statement = this.ast.newNode(NodeKind.throwStmt, keyword.start, this.endOf(argument));
    this.ast.setLeft(statement, argument);
    this.matchTerminator();
    return statement;
  }

  function parseSwitch(inout this): u32 {
    const keyword = this.advance();
    if (!this.expectKind(TokenKind.lParen)) return NO_NODE;
    const discriminant = this.parseExpression();
    if (discriminant == NO_NODE) return NO_NODE;
    if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
    if (!this.expectKind(TokenKind.lBrace)) return NO_NODE;
    let cases = Array<u32>();
    while (this.peekKind() != TokenKind.rBrace && this.peekKind() != TokenKind.eof) {
      const head = this.peek();
      let isDefault = false;
      let test: u32 = NO_NODE;
      if (head.kind == TokenKind.kwDefault) {
        this.advance();
        isDefault = true;
      } else if (head.kind == TokenKind.kwCase) {
        this.advance();
        test = this.parseExpression();
        if (test == NO_NODE) break;
      } else {
        this.hadError = true;
        break;
      }
      if (!this.expectKind(TokenKind.colon)) break;
      let body = Array<u32>();
      let lastEnd: u32 = head.start + head.length;
      while (this.peekKind() != TokenKind.kwCase && this.peekKind() != TokenKind.kwDefault
             && this.peekKind() != TokenKind.rBrace && this.peekKind() != TokenKind.eof) {
        const statement = this.parseStatement();
        if (statement == NO_NODE) break;
        body.push(statement);
        lastEnd = this.endOf(statement);
      }
      const clause = this.ast.newNode(NodeKind.switchCase, head.start, lastEnd);
      this.ast.setLeft(clause, test);
      this.ast.setChildren(clause, in body);
      this.ast.setBool(clause, isDefault);
      cases.push(clause);
    }
    const close = this.peek();
    if (!this.expectKind(TokenKind.rBrace)) return NO_NODE;
    const statement = this.ast.newNode(NodeKind.switchStmt, keyword.start, close.start + close.length);
    this.ast.setLeft(statement, discriminant);
    this.ast.setChildren(statement, in cases);
    return statement;
  }

  function parseTry(inout this): u32 {
    const keyword = this.advance();
    if (this.peekKind() != TokenKind.lBrace) {
      this.hadError = true;
      return NO_NODE;
    }
    const tryBlock = this.parseBlock();
    if (tryBlock == NO_NODE) return NO_NODE;
    let catchBlock: u32 = NO_NODE;
    let catchNameStart: u32 = 0;
    let catchNameLength: u32 = 0;
    let catchPattern: u32 = NO_NODE;
    if (this.matchKind(TokenKind.kwCatch)) {
      if (this.matchKind(TokenKind.lParen)) {
        const target = this.parseBindingTarget();
        if (target == NO_NODE) return NO_NODE;
        if (this.kindOf(target) == NodeKind.identExpr) {
          const t = this.node(target);
          catchNameStart = t.start;
          catchNameLength = t.end - t.start;
        } else {
          catchPattern = target;
        }
        if (!this.expectKind(TokenKind.rParen)) return NO_NODE;
      }
      if (this.peekKind() != TokenKind.lBrace) {
        this.hadError = true;
        return NO_NODE;
      }
      catchBlock = this.parseBlock();
      if (catchBlock == NO_NODE) return NO_NODE;
    }
    let finallyBlock: u32 = NO_NODE;
    if (this.matchKind(TokenKind.kwFinally)) {
      if (this.peekKind() != TokenKind.lBrace) {
        this.hadError = true;
        return NO_NODE;
      }
      finallyBlock = this.parseBlock();
      if (finallyBlock == NO_NODE) return NO_NODE;
    }
    if (catchBlock == NO_NODE && finallyBlock == NO_NODE) {
      this.hadError = true;
      return NO_NODE;
    }
    let end = this.endOf(tryBlock);
    if (finallyBlock != NO_NODE) {
      end = this.endOf(finallyBlock);
    } else if (catchBlock != NO_NODE) {
      end = this.endOf(catchBlock);
    }
    const statement = this.ast.newNode(NodeKind.tryStmt, keyword.start, end);
    this.ast.setLeft(statement, tryBlock);
    this.ast.setRight(statement, catchBlock);
    this.ast.setThird(statement, finallyBlock);
    this.ast.setName(statement, catchNameStart, catchNameLength);
    if (catchPattern != NO_NODE) {
      let kids = Array<u32>();
      kids.push(catchPattern);
      this.ast.setChildren(statement, in kids);
    }
    return statement;
  }

  // ======================================================================
  // Template literals
  // ======================================================================
  //
  // The lexer emits one TemplateLit token for the whole literal. Split it
  // here into alternating literal parts and expressions; each `${...}` is
  // re-tokenized and parsed on its own with offsets shifted to absolute.

  function parseTemplateLit(inout this): u32 {
    const t = this.advance();
    const bodyStart: u32 = t.start + 1;
    const bodyEnd: u32 = t.length >= 2 ? t.start + t.length - 1 : t.start + 1;
    const template = this.ast.newNode(NodeKind.templateExpr, t.start, t.start + t.length);
    let children = Array<u32>();
    let cur: u32 = bodyStart;
    let segStart: u32 = cur;
    while (cur < bodyEnd) {
      const c = this.source[usize(cur)];
      if (c == B_BACKSLASH) {
        cur = cur + 1;
        if (cur < bodyEnd) cur = cur + 1;
        continue;
      }
      if (c == B_DOLLAR && cur + 1 < bodyEnd && this.source[usize(cur + 1)] == B_LBRACE) {
        children.push(this.ast.newNode(NodeKind.templatePartExpr, segStart, cur));
        cur = cur + 2;
        const exprStart: u32 = cur;
        let depth: u32 = 1;
        while (cur < bodyEnd) {
          const ec = this.source[usize(cur)];
          if (ec == B_BACKSLASH) {
            cur = cur + 1;
            if (cur < bodyEnd) cur = cur + 1;
            continue;
          }
          if (ec == B_LBRACE) {
            depth = depth + 1;
            cur = cur + 1;
            continue;
          }
          if (ec == B_RBRACE) {
            depth = depth - 1;
            if (depth == 0) break;
            cur = cur + 1;
            continue;
          }
          if (ec == B_DQUOTE || ec == B_SQUOTE) {
            const quote = ec;
            cur = cur + 1;
            while (cur < bodyEnd && this.source[usize(cur)] != quote) {
              if (this.source[usize(cur)] == B_BACKSLASH) {
                cur = cur + 1;
                if (cur < bodyEnd) cur = cur + 1;
              } else {
                cur = cur + 1;
              }
            }
            if (cur < bodyEnd) cur = cur + 1;
            continue;
          }
          if (ec == B_BACKTICK) {
            cur = cur + 1;
            while (cur < bodyEnd && this.source[usize(cur)] != B_BACKTICK) {
              const tc = this.source[usize(cur)];
              if (tc == B_BACKSLASH) {
                cur = cur + 1;
                if (cur < bodyEnd) cur = cur + 1;
                continue;
              }
              if (tc == B_DOLLAR && cur + 1 < bodyEnd && this.source[usize(cur + 1)] == B_LBRACE) {
                cur = cur + 2;
                let nested: u32 = 1;
                while (cur < bodyEnd && nested > 0) {
                  const nc = this.source[usize(cur)];
                  if (nc == B_BACKSLASH) {
                    cur = cur + 1;
                    if (cur < bodyEnd) cur = cur + 1;
                    continue;
                  }
                  if (nc == B_LBRACE) nested = nested + 1;
                  if (nc == B_RBRACE) {
                    nested = nested - 1;
                    if (nested == 0) {
                      cur = cur + 1;
                      break;
                    }
                  }
                  cur = cur + 1;
                }
                continue;
              }
              cur = cur + 1;
            }
            if (cur < bodyEnd) cur = cur + 1;
            continue;
          }
          cur = cur + 1;
        }
        const exprEnd: u32 = cur;
        if (cur < bodyEnd) cur = cur + 1;
        const expr = this.parseTemplateExprSlice(exprStart, exprEnd);
        if (expr == NO_NODE) {
          this.hadError = true;
          this.ast.setChildren(template, in children);
          return template;
        }
        children.push(expr);
        segStart = cur;
        continue;
      }
      cur = cur + 1;
    }
    children.push(this.ast.newNode(NodeKind.templatePartExpr, segStart, bodyEnd));
    this.ast.setChildren(template, in children);
    return template;
  }

  // Re-tokenize [start, end) and parse it as an assignment expression with
  // absolute offsets, swapping the token stream in and back out.
  function parseTemplateExprSlice(inout this, start: u32, end: u32): u32 {
    const sliceTokens = tokenize(sliceBytes(in this.source, usize(start), usize(end)));
    const savedPos = this.pos;
    const savedLimit = this.tokenLimit;
    const savedNoIn = this.noIn;
    // Append the slice's tokens, shifted to absolute offsets, and parse
    // within that window. The appended tokens stay behind harmlessly.
    const base = this.tokens.length;
    let i: usize = 0;
    while (i < sliceTokens.length) {
      const token = sliceTokens[i];
      this.tokens.push(Token({ kind: token.kind, start: token.start + start, length: token.length }));
      i = i + 1;
    }
    this.tokenLimit = this.tokens.length;
    this.pos = base;
    this.noIn = false;
    const expr = this.parseAssignment();
    this.pos = savedPos;
    this.tokenLimit = savedLimit;
    this.noIn = savedNoIn;
    return expr;
  }

  // ======================================================================
  // Private names: every `#x` access must resolve to an enclosing class.
  // ======================================================================

  function pnIsPrivateName(nameStart: u32, nameLength: u32): boolean {
    if (nameLength == 0) return false;
    return this.source[usize(nameStart)] == B_HASH;
  }

  function pnSliceHasEscape(start: u32, length: u32): boolean {
    let i: u32 = 0;
    while (i < length) {
      if (this.source[usize(start + i)] == B_BACKSLASH) return true;
      i = i + 1;
    }
    return false;
  }

  function pnResolvesInChain(in chain: Array<u32>, depth: usize, nameStart: u32, nameLength: u32): boolean {
    let d = depth;
    while (d > 0) {
      d = d - 1;
      const cls = chain[d];
      if (cls == NO_NODE) continue;
      const count = this.node(cls).childrenCount;
      let i: u32 = 0;
      while (i < count) {
        const element = this.ast.child(cls, i);
        if (element != NO_NODE) {
          const el = this.node(element);
          if (this.pnIsPrivateName(el.nameStart, el.nameLength)) {
            if (this.pnSliceHasEscape(el.nameStart, el.nameLength)) return true;
            if (this.slicesEqual(el.nameStart, el.nameLength, nameStart, nameLength)) return true;
          }
        }
        i = i + 1;
      }
    }
    return false;
  }

  function validatePrivateNames(inout this, index: u32, inout chain: Array<u32>, depth: usize): void {
    if (index == NO_NODE || this.hadError) return;
    const n = this.node(index);
    if (n.kind == NodeKind.classDecl || n.kind == NodeKind.classExpr) {
      if (n.right != NO_NODE) this.validatePrivateNames(n.right, inout chain, depth);
      if (depth < 16) {
        while (chain.length <= depth) { chain.push(NO_NODE); }
        chain[depth] = index;
        let j: u32 = 0;
        while (j < n.childrenCount) {
          this.validatePrivateNames(this.ast.child(index, j), inout chain, depth + 1);
          j = j + 1;
        }
      }
      return;
    }
    if ((n.kind == NodeKind.member || n.kind == NodeKind.optionalMember)
        && this.pnIsPrivateName(n.nameStart, n.nameLength)
        && !this.pnSliceHasEscape(n.nameStart, n.nameLength)) {
      if (!this.pnResolvesInChain(in chain, depth, n.nameStart, n.nameLength)) {
        this.hadError = true;
        return;
      }
    }
    if (n.left != NO_NODE) this.validatePrivateNames(n.left, inout chain, depth);
    if (n.right != NO_NODE) this.validatePrivateNames(n.right, inout chain, depth);
    if (n.third != NO_NODE) this.validatePrivateNames(n.third, inout chain, depth);
    let k: u32 = 0;
    while (k < n.childrenCount) {
      this.validatePrivateNames(this.ast.child(index, k), inout chain, depth);
      k = k + 1;
    }
  }


  // ======================================================================
  // Classes
  // ======================================================================

  // Strict-mode reserved identifiers that may not name a class or function.
  function isStrictReservedName(start: u32, length: u32): boolean {
    if (length == 3) return this.sliceEquals(start, 3, "let");
    if (length == 5) return this.sliceEquals(start, 5, "yield");
    if (length == 6) return this.sliceEquals(start, 6, "static") || this.sliceEquals(start, 6, "public");
    if (length == 7) return this.sliceEquals(start, 7, "package") || this.sliceEquals(start, 7, "private");
    if (length == 9) return this.sliceEquals(start, 9, "interface") || this.sliceEquals(start, 9, "protected");
    if (length == 10) return this.sliceEquals(start, 10, "implements");
    return false;
  }

  // ContainsArguments for a class field initializer: recurses through
  // arrows, stops at functions and methods (which have their own).
  function exprContainsArguments(index: u32): boolean {
    if (index == NO_NODE) return false;
    const n = this.node(index);
    if (n.kind == NodeKind.functionDecl || n.kind == NodeKind.functionExpr || n.kind == NodeKind.methodDef) return false;
    if (n.kind == NodeKind.identExpr) {
      return n.end - n.start == 9 && this.sliceEquals(n.start, 9, "arguments");
    }
    if (n.left != NO_NODE && this.exprContainsArguments(n.left)) return true;
    if (n.right != NO_NODE && this.exprContainsArguments(n.right)) return true;
    if (n.third != NO_NODE && this.exprContainsArguments(n.third)) return true;
    let i: u32 = 0;
    while (i < n.childrenCount) {
      if (this.exprContainsArguments(this.ast.child(index, i))) return true;
      i = i + 1;
    }
    return false;
  }

  // ContainsArguments for a static block body: escape-aware, and only the
  // computed keys of nested members are in the block's scope.
  function staticBlockUsesArguments(index: u32): boolean {
    if (index == NO_NODE) return false;
    const n = this.node(index);
    if (n.kind == NodeKind.functionDecl || n.kind == NodeKind.functionExpr) return false;
    if (n.kind == NodeKind.identExpr) return this.identMatches(n.start, n.end - n.start, "arguments");
    if (n.kind == NodeKind.methodDef) {
      if (n.third != NO_NODE && this.staticBlockUsesArguments(n.third)) return true;
      return false;
    }
    if (n.left != NO_NODE && this.staticBlockUsesArguments(n.left)) return true;
    if (n.right != NO_NODE && this.staticBlockUsesArguments(n.right)) return true;
    if (n.third != NO_NODE && this.staticBlockUsesArguments(n.third)) return true;
    let i: u32 = 0;
    while (i < n.childrenCount) {
      if (this.staticBlockUsesArguments(this.ast.child(index, i))) return true;
      i = i + 1;
    }
    return false;
  }

  // Duplicate lexical declarations, or a lexical/var clash, among a static
  // block's direct statements.
  function staticBlockDupBinding(body: u32): boolean {
    if (body == NO_NODE) return false;
    const b = this.node(body);
    if (b.childrenCount == 0) return false;
    let starts = Array<u32>();
    let lengths = Array<u32>();
    let lexical = Array<boolean>();
    let ci: u32 = 0;
    while (ci < b.childrenCount && starts.length < 128) {
      const statement = this.ast.child(body, ci);
      const st = this.node(statement);
      if (st.kind == NodeKind.varDecl) {
        const isLexical = st.op != TokenKind.kwVar;
        let di: u32 = 0;
        while (di < st.childrenCount && starts.length < 128) {
          const decl = this.node(this.ast.child(statement, di));
          if (decl.nameLength > 0) {
            starts.push(decl.nameStart);
            lengths.push(decl.nameLength);
            lexical.push(isLexical);
          }
          di = di + 1;
        }
      } else if (st.kind == NodeKind.classDecl) {
        if (st.nameLength > 0) {
          starts.push(st.nameStart);
          lengths.push(st.nameLength);
          lexical.push(true);
        }
      }
      ci = ci + 1;
    }
    let i: usize = 0;
    while (i < starts.length) {
      let j: usize = i + 1;
      while (j < starts.length) {
        if (lengths[i] == lengths[j] && (lexical[i] || lexical[j])
            && this.slicesEqual(starts[i], lengths[i], starts[j], lengths[j])) return true;
        j = j + 1;
      }
      i = i + 1;
    }
    return false;
  }

  // Pure lookahead: is the upcoming element a plain, non-static
  // `constructor(...)`? Gates `super(...)` for exactly that body.
  function nextMethodIsConstructor(): boolean {
    let i = this.pos;
    let sawStatic = false;
    let sawAsync = false;
    let sawGenerator = false;
    let sawAccessor = false;
    while (i < this.tokenLimit) {
      const t = this.tokens[i];
      if (t.kind == TokenKind.identifier && t.length == 6 && this.sliceEquals(t.start, 6, "static")) {
        sawStatic = true;
        i = i + 1;
        continue;
      }
      if (t.kind == TokenKind.kwAsync) {
        sawAsync = true;
        i = i + 1;
        continue;
      }
      if (t.kind == TokenKind.star) {
        sawGenerator = true;
        i = i + 1;
        continue;
      }
      if (t.kind == TokenKind.identifier && t.length == 3
          && (this.sliceEquals(t.start, 3, "get") || this.sliceEquals(t.start, 3, "set"))) {
        sawAccessor = true;
        i = i + 1;
        continue;
      }
      if (sawStatic || sawAsync || sawGenerator || sawAccessor) return false;
      if (t.kind == TokenKind.identifier && t.length == 11 && this.sliceEquals(t.start, 11, "constructor")) {
        return this.peekAtIndex(i + 1).kind == TokenKind.lParen;
      }
      return false;
    }
    return false;
  }

  // The unquoted span of a class element name token: string literals drop
  // their quotes for the "constructor" / "prototype" checks.
  function elementNameSpan(token: Token): u32 {
    if (token.kind == TokenKind.stringLit && token.length >= 2) return token.length - 2;
    return token.length;
  }

  function elementNameStart(token: Token): u32 {
    if (token.kind == TokenKind.stringLit && token.length >= 2) return token.start + 1;
    return token.start;
  }

  // One class element: static block, field, method, or accessor.
  function parseClassElement(inout this): u32 {
    const elementStart = this.peek().start;
    let isStatic = false;
    const first = this.peek();
    if (first.kind == TokenKind.identifier && first.length == 6 && this.sliceEquals(first.start, 6, "static")) {
      // `static { ... }` -- a static initialization block.
      if (this.peekKind2() == TokenKind.lBrace) {
        this.advance();
        const savedAsync = this.inAsync;
        const savedGenerator = this.inGenerator;
        const savedInBlock = this.inStaticBlock;
        const savedDepth = this.staticBlockDepth;
        this.inAsync = false;
        this.inGenerator = false;
        this.functionDepth = this.functionDepth + 1;
        this.inStaticBlock = true;
        this.staticBlockDepth = this.functionDepth;
        const body = this.parseBlock();
        this.functionDepth = this.functionDepth - 1;
        this.inAsync = savedAsync;
        this.inGenerator = savedGenerator;
        this.inStaticBlock = savedInBlock;
        this.staticBlockDepth = savedDepth;
        if (body == NO_NODE) return NO_NODE;
        if (this.staticBlockUsesArguments(body)) {
          this.hadError = true;
          return NO_NODE;
        }
        if (this.staticBlockDupBinding(body)) {
          this.hadError = true;
          return NO_NODE;
        }
        const block = this.ast.newNode(NodeKind.staticBlock, elementStart, this.endOf(body));
        this.ast.setLeft(block, body);
        this.ast.setBool(block, true);
        return block;
      }
      const after = this.peekKind2();
      if (this.isPropertyNameStart(after) || after == TokenKind.lBracket || after == TokenKind.star || after == TokenKind.privateName) {
        this.advance();
        isStatic = true;
      }
    }
    let isAsyncMethod = false;
    if (this.peekKind() == TokenKind.kwAsync) {
      const after = this.peekKind2();
      if (this.isPropertyNameStart(after) || after == TokenKind.lBracket || after == TokenKind.privateName || after == TokenKind.star) {
        this.advance();
        isAsyncMethod = true;
      }
    }
    let isGeneratorMethod = false;
    if (this.peekKind() == TokenKind.star) {
      this.advance();
      isGeneratorMethod = true;
    }
    // `Eq` is the sentinel for a regular method; accessors carry get/set.
    let accessorKind = TokenKind.eq;
    if (!isAsyncMethod) {
      const id = this.peek();
      if (id.kind == TokenKind.identifier && id.length == 3) {
        const isGet = this.sliceEquals(id.start, 3, "get");
        const isSet = this.sliceEquals(id.start, 3, "set");
        const after = this.peekKind2();
        if ((isGet || isSet) && (this.isPropertyNameStart(after) || after == TokenKind.lBracket || after == TokenKind.privateName)) {
          this.advance();
          accessorKind = isGet ? TokenKind.kwGet : TokenKind.kwSet;
        }
      }
    }
    let computedKey: u32 = NO_NODE;
    const nameToken = this.peek();
    if (nameToken.kind == TokenKind.lBracket) {
      this.advance();
      computedKey = this.parseAssignment();
      if (computedKey == NO_NODE) return NO_NODE;
      if (!this.expectKind(TokenKind.rBracket)) return NO_NODE;
    } else {
      if (!this.isPropertyNameStart(nameToken.kind) && nameToken.kind != TokenKind.privateName) {
        this.hadError = true;
        return NO_NODE;
      }
      if (nameToken.kind == TokenKind.privateName && nameToken.length == 12
          && this.sliceEquals(nameToken.start, 12, "#constructor")) {
        this.hadError = true;
        return NO_NODE;
      }
      this.advance();
    }

    // Field: no `(` and no method prefixes.
    if (this.peekKind() != TokenKind.lParen && accessorKind == TokenKind.eq && !isAsyncMethod && !isGeneratorMethod) {
      if (computedKey == NO_NODE && nameToken.length > 0) {
        const nameStart = this.elementNameStart(nameToken);
        const nameSpan = this.elementNameSpan(nameToken);
        if (nameSpan == 11 && this.sliceEquals(nameStart, 11, "constructor")) {
          this.hadError = true;
          return NO_NODE;
        }
        if (isStatic && nameSpan == 9 && this.sliceEquals(nameStart, 9, "prototype")) {
          this.hadError = true;
          return NO_NODE;
        }
      }
      let init: u32 = NO_NODE;
      if (this.peekKind() == TokenKind.eq) {
        this.advance();
        init = this.parseAssignment();
        if (init == NO_NODE) return NO_NODE;
        if (this.exprContainsArguments(init)) {
          this.hadError = true;
          return NO_NODE;
        }
      }
      let fieldEnd: u32 = nameToken.start + nameToken.length;
      if (init != NO_NODE) {
        fieldEnd = this.endOf(init);
      } else if (computedKey != NO_NODE) {
        fieldEnd = this.endOf(computedKey);
      }
      // Terminator: `;`, or ASI before `}` / EOF / a newline.
      if (!this.matchKind(TokenKind.semicolon)) {
        const next = this.peek();
        if (next.kind != TokenKind.rBrace && next.kind != TokenKind.eof && !this.hasNewlineBetween(fieldEnd, next.start)) {
          this.hadError = true;
          return NO_NODE;
        }
      }
      const field = this.ast.newNode(NodeKind.classField, elementStart, fieldEnd);
      if (computedKey != NO_NODE) {
        this.ast.setThird(field, computedKey);
      } else if (nameToken.kind == TokenKind.stringLit && nameToken.length >= 2) {
        // A string-literal field name is stored unquoted.
        this.ast.setName(field, nameToken.start + 1, nameToken.length - 2);
      } else {
        this.ast.setName(field, nameToken.start, nameToken.length);
      }
      this.ast.setBool(field, isStatic);
      this.ast.setLeft(field, init);
      return field;
    }

    // Method early errors: a non-static special method may not be named
    // "constructor"; a static method may not be named "prototype".
    if (computedKey == NO_NODE && nameToken.length > 0) {
      const nameStart = this.elementNameStart(nameToken);
      const nameSpan = this.elementNameSpan(nameToken);
      if (nameSpan == 11 && this.sliceEquals(nameStart, 11, "constructor")) {
        const isSpecial = isAsyncMethod || isGeneratorMethod || accessorKind == TokenKind.kwGet || accessorKind == TokenKind.kwSet;
        if (!isStatic && isSpecial) {
          this.hadError = true;
          return NO_NODE;
        }
      }
      if (isStatic && nameSpan == 9 && this.sliceEquals(nameStart, 9, "prototype")) {
        this.hadError = true;
        return NO_NODE;
      }
    }

    // Parameters of async / generator methods are parsed in [+Await] /
    // [+Yield]; toggle before the list, restore after the body.
    const savedAsync = this.inAsync;
    const savedGenerator = this.inGenerator;
    this.inAsync = isAsyncMethod;
    this.inGenerator = isGeneratorMethod;
    if (!this.expectKind(TokenKind.lParen)) {
      this.inAsync = savedAsync;
      this.inGenerator = savedGenerator;
      return NO_NODE;
    }
    const params = this.parseParamList();
    if (!this.expectKind(TokenKind.rParen)) {
      this.inAsync = savedAsync;
      this.inGenerator = savedGenerator;
      return NO_NODE;
    }
    if (this.peekKind() != TokenKind.lBrace) {
      this.inAsync = savedAsync;
      this.inGenerator = savedGenerator;
      this.hadError = true;
      return NO_NODE;
    }
    this.functionDepth = this.functionDepth + 1;
    const body = this.parseBlock();
    this.functionDepth = this.functionDepth - 1;
    this.inAsync = savedAsync;
    this.inGenerator = savedGenerator;
    if (body == NO_NODE) return NO_NODE;
    if (!this.paramsAreSimple(in params) && this.bodyHasUseStrictDirective(body)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (!this.paramsAreSimple(in params) && this.paramsHaveDuplicateBinding(in params)) {
      this.hadError = true;
      return NO_NODE;
    }
    const method = this.ast.newNode(NodeKind.methodDef, elementStart, this.endOf(body));
    if (computedKey != NO_NODE) {
      this.ast.setThird(method, computedKey);
    } else {
      this.ast.setName(method, nameToken.start, nameToken.length);
    }
    this.ast.setBool(method, isStatic);
    this.ast.setOp(method, accessorKind);
    this.ast.setLeft(method, body);
    this.ast.setChildren(method, in params);
    // `num` carries the function kind: 1 async, 4 generator, 5 both.
    if (isAsyncMethod && isGeneratorMethod) {
      this.ast.setNum(method, 5.0);
    } else if (isAsyncMethod) {
      this.ast.setNum(method, 1.0);
    } else if (isGeneratorMethod) {
      this.ast.setNum(method, 4.0);
    }
    return method;
  }

  // Is this element the class's own (non-static) constructor method?
  function isConstructorMethod(element: u32): boolean {
    const m = this.node(element);
    return m.kind == NodeKind.methodDef && m.nameLength == 11 && !m.boolValue
      && this.sliceEquals(m.nameStart, 11, "constructor");
  }

  function isInstanceField(element: u32): boolean {
    const f = this.node(element);
    return f.kind == NodeKind.classField && !f.boolValue;
  }

  // Class body: elements, then instance-field initializers desugared into
  // the constructor (synthesizing one if needed).
  function parseClassBody(inout this, isDerived: boolean): Array<u32> {
    let elements = Array<u32>();
    if (!this.expectKind(TokenKind.lBrace)) return elements;
    // Class bodies are strict code.
    const savedStrict = this.strictMode;
    this.strictMode = true;
    const savedDerived = this.inDerivedConstructor;

    while (this.peekKind() != TokenKind.rBrace && this.peekKind() != TokenKind.eof) {
      if (this.peekKind() == TokenKind.semicolon) {
        this.advance();
        continue;
      }
      this.inDerivedConstructor = isDerived && this.nextMethodIsConstructor();
      const element = this.parseClassElement();
      if (element == NO_NODE) {
        this.hadError = true;
        break;
      }
      elements.push(element);
    }
    this.expectKind(TokenKind.rBrace);

    let constructorIndex: i32 = -1;
    let anyInstanceField = false;
    let scan: usize = 0;
    while (scan < elements.length) {
      if (this.isInstanceField(elements[scan])) anyInstanceField = true;
      if (this.isConstructorMethod(elements[scan])) {
        // At most one non-static "constructor".
        if (constructorIndex < 0) {
          constructorIndex = i32(scan);
        } else {
          this.hadError = true;
        }
      }
      scan = scan + 1;
    }
    // Fields but no constructor: synthesize an empty one (calling super()
    // when derived), recognized by the compiler through num = 2.
    if (anyInstanceField && constructorIndex < 0) {
      const zero: u32 = 0;
      const anchor: u32 = elements.length > 0 ? this.startOf(elements[0]) : zero;
      const block = this.ast.newNode(NodeKind.blockStmt, anchor, anchor);
      if (isDerived) {
        const superExpr = this.ast.newNode(NodeKind.superExpr, anchor, anchor);
        const superCall = this.ast.newNode(NodeKind.call, anchor, anchor);
        this.ast.setLeft(superCall, superExpr);
        let statements = Array<u32>();
        statements.push(superCall);
        this.ast.setChildren(block, in statements);
      }
      const synthesized = this.ast.newNode(NodeKind.methodDef, anchor, anchor);
      this.ast.setName(synthesized, anchor, 0);
      this.ast.setOp(synthesized, TokenKind.eq);
      this.ast.setNum(synthesized, 2.0);
      this.ast.setLeft(synthesized, block);
      elements.push(synthesized);
      constructorIndex = i32(elements.length - 1);
    }
    if (anyInstanceField && constructorIndex >= 0) {
      const constructorElement = elements[usize(constructorIndex)];
      const block = this.node(constructorElement).left;
      if (block != NO_NODE && this.kindOf(block) == NodeKind.blockStmt) {
        // `this.<name> = <init>` (or `this[<key>] = <init>`) for each
        // instance field, prepended to the constructor body.
        let statements = Array<u32>();
        let s3: usize = 0;
        while (s3 < elements.length) {
          const element = elements[s3];
          if (this.isInstanceField(element)) {
            const f = this.node(element);
            const thisExpr = this.ast.newNode(NodeKind.thisExpr, f.start, f.start);
            let target: u32 = NO_NODE;
            if (f.nameLength == 0 && f.third != NO_NODE) {
              target = this.ast.newNode(NodeKind.computed, f.start, f.end);
              this.ast.setLeft(target, thisExpr);
              this.ast.setRight(target, f.third);
            } else {
              target = this.ast.newNode(NodeKind.member, f.start, f.end);
              this.ast.setLeft(target, thisExpr);
              this.ast.setName(target, f.nameStart, f.nameLength);
              // A private-field DEFINE skips the presence check a SET does.
              this.ast.setNum(target, 1.0);
            }
            let init = f.left;
            if (init == NO_NODE) init = this.ast.newNode(NodeKind.undefinedExpr, f.start, f.start);
            const assignment = this.ast.newNode(NodeKind.assignment, f.start, this.endOf(init));
            this.ast.setOp(assignment, TokenKind.eq);
            this.ast.setLeft(assignment, target);
            this.ast.setRight(assignment, init);
            statements.push(assignment);
          }
          s3 = s3 + 1;
        }
        const existing = this.node(block).childrenCount;
        let bi: u32 = 0;
        while (bi < existing) {
          statements.push(this.ast.child(block, bi));
          bi = bi + 1;
        }
        this.ast.setChildren(block, in statements);
      }
    }

    this.strictMode = savedStrict;
    this.inDerivedConstructor = savedDerived;
    return elements;
  }

  function parseClassDecl(inout this): u32 {
    const keyword = this.advance();
    const nameToken = this.peek();
    if (!this.isBindingIdentTok(nameToken)) {
      this.hadError = true;
      return NO_NODE;
    }
    if (this.isStrictReservedName(nameToken.start, nameToken.length)) {
      this.hadError = true;
      return NO_NODE;
    }
    // A class definition is always strict code: never eval / arguments.
    if (this.nameIsArgumentsOrEval(nameToken.start, nameToken.length)) {
      this.hadError = true;
      return NO_NODE;
    }
    this.advance();
    let parent: u32 = NO_NODE;
    if (this.peekKind() == TokenKind.kwExtends) {
      this.advance();
      parent = this.parseCallMember();
      if (parent == NO_NODE) return NO_NODE;
    }
    const elements = this.parseClassBody(parent != NO_NODE);
    const end: u32 = elements.length > 0 ? this.endOf(elements[elements.length - 1]) : this.peek().start;
    const declaration = this.ast.newNode(NodeKind.classDecl, keyword.start, end);
    this.ast.setName(declaration, nameToken.start, nameToken.length);
    this.ast.setRight(declaration, parent);
    this.ast.setChildren(declaration, in elements);
    return declaration;
  }

  function parseClassExpr(inout this): u32 {
    const keyword = this.advance();
    let nameStart: u32 = 0;
    let nameLength: u32 = 0;
    if (this.peekKind() == TokenKind.identifier) {
      const nameToken = this.advance();
      nameStart = nameToken.start;
      nameLength = nameToken.length;
    }
    let parent: u32 = NO_NODE;
    if (this.peekKind() == TokenKind.kwExtends) {
      this.advance();
      parent = this.parseCallMember();
      if (parent == NO_NODE) return NO_NODE;
    }
    const elements = this.parseClassBody(parent != NO_NODE);
    const end: u32 = elements.length > 0 ? this.endOf(elements[elements.length - 1]) : this.peek().start;
    const expression = this.ast.newNode(NodeKind.classExpr, keyword.start, end);
    this.ast.setName(expression, nameStart, nameLength);
    this.ast.setRight(expression, parent);
    this.ast.setChildren(expression, in elements);
    return expression;
  }

  // ======================================================================
  // Modules
  // ======================================================================

  function parseImportDecl(inout this): u32 {
    const keyword = this.advance();
    let clauses = Array<u32>();
    // `import 'mod'` -- side effect only.
    if (this.peekKind() == TokenKind.stringLit) {
      const specifier = this.advance();
      this.matchKind(TokenKind.semicolon);
      const declaration = this.ast.newNode(NodeKind.importDecl, keyword.start, specifier.start + specifier.length);
      this.ast.setName(declaration, specifier.start, specifier.length);
      return declaration;
    }
    // Default binding.
    if (this.peekKind() == TokenKind.identifier) {
      const nameToken = this.advance();
      const clause = this.ast.newNode(NodeKind.importClause, nameToken.start, nameToken.start + nameToken.length);
      this.ast.setOp(clause, TokenKind.kwDefault);
      this.ast.setName(clause, nameToken.start, nameToken.length);
      clauses.push(clause);
      if (this.peekKind() == TokenKind.comma) this.advance();
    }
    if (this.peekKind() == TokenKind.star) {
      // `* as ns`
      const star = this.advance();
      if (this.peekKind() != TokenKind.kwAs) {
        this.hadError = true;
        return NO_NODE;
      }
      this.advance();
      const nameToken = this.peek();
      if (!this.isBindingIdentTok(nameToken)) {
        this.hadError = true;
        return NO_NODE;
      }
      this.advance();
      const clause = this.ast.newNode(NodeKind.importClause, star.start, nameToken.start + nameToken.length);
      this.ast.setOp(clause, TokenKind.star);
      this.ast.setName(clause, nameToken.start, nameToken.length);
      clauses.push(clause);
    } else if (this.peekKind() == TokenKind.lBrace) {
      // `{ a, b as c }`
      this.advance();
      while (this.peekKind() != TokenKind.rBrace && this.peekKind() != TokenKind.eof) {
        const sourceToken = this.peek();
        if (!this.isBindingIdentTok(sourceToken) && !this.isKeywordToken(sourceToken.kind)) {
          this.hadError = true;
          return NO_NODE;
        }
        this.advance();
        let localStart = sourceToken.start;
        let localLength = sourceToken.length;
        if (this.peekKind() == TokenKind.kwAs) {
          this.advance();
          const localToken = this.peek();
          if (!this.isBindingIdentTok(localToken)) {
            this.hadError = true;
            return NO_NODE;
          }
          this.advance();
          localStart = localToken.start;
          localLength = localToken.length;
        }
        const clause = this.ast.newNode(NodeKind.importClause, sourceToken.start, localStart + localLength);
        this.ast.setOp(clause, TokenKind.eq);
        this.ast.setName(clause, localStart, localLength);
        // The source export name rides on a synthetic IdentExpr in `third`.
        const sourceName = this.identNode(sourceToken);
        this.ast.setThird(clause, sourceName);
        clauses.push(clause);
        if (!this.matchKind(TokenKind.comma)) break;
      }
      if (!this.expectKind(TokenKind.rBrace)) return NO_NODE;
    }
    if (this.peekKind() != TokenKind.kwFrom) {
      this.hadError = true;
      return NO_NODE;
    }
    this.advance();
    const specifier = this.peek();
    if (specifier.kind != TokenKind.stringLit) {
      this.hadError = true;
      return NO_NODE;
    }
    this.advance();
    this.matchKind(TokenKind.semicolon);
    const declaration = this.ast.newNode(NodeKind.importDecl, keyword.start, specifier.start + specifier.length);
    this.ast.setName(declaration, specifier.start, specifier.length);
    this.ast.setChildren(declaration, in clauses);
    return declaration;
  }

  function parseExportDecl(inout this): u32 {
    const keyword = this.advance();
    if (this.peekKind() == TokenKind.kwDefault) {
      this.advance();
      let value: u32 = NO_NODE;
      const k = this.peekKind();
      if (k == TokenKind.kwFunction) {
        value = this.parseFunctionExpr(false);
      } else if (k == TokenKind.kwAsync && this.peekKind2() == TokenKind.kwFunction) {
        this.advance();
        value = this.parseFunctionExpr(true);
      } else if (k == TokenKind.kwClass) {
        value = this.parseClassExpr();
      } else {
        value = this.parseAssignment();
        this.matchKind(TokenKind.semicolon);
      }
      if (value == NO_NODE) return NO_NODE;
      const declaration = this.ast.newNode(NodeKind.exportDecl, keyword.start, this.endOf(value));
      this.ast.setBool(declaration, true);
      this.ast.setLeft(declaration, value);
      return declaration;
    }
    if (this.peekKind() == TokenKind.lBrace) {
      this.advance();
      let clauses = Array<u32>();
      while (this.peekKind() != TokenKind.rBrace && this.peekKind() != TokenKind.eof) {
        const localToken = this.peek();
        if (!this.isBindingIdentTok(localToken) && !this.isKeywordToken(localToken.kind)) {
          this.hadError = true;
          break;
        }
        this.advance();
        let exportStart = localToken.start;
        let exportLength = localToken.length;
        if (this.peekKind() == TokenKind.kwAs) {
          this.advance();
          const exportToken = this.peek();
          if (!this.isBindingIdentTok(exportToken) && !this.isKeywordToken(exportToken.kind)) {
            this.hadError = true;
            break;
          }
          this.advance();
          exportStart = exportToken.start;
          exportLength = exportToken.length;
        }
        const clause = this.ast.newNode(NodeKind.exportClause, localToken.start, exportStart + exportLength);
        this.ast.setName(clause, localToken.start, localToken.length);
        const exportedName = this.ast.newNode(NodeKind.identExpr, exportStart, exportStart + exportLength);
        this.ast.setName(exportedName, exportStart, exportLength);
        this.ast.setThird(clause, exportedName);
        clauses.push(clause);
        if (!this.matchKind(TokenKind.comma)) break;
      }
      if (!this.expectKind(TokenKind.rBrace)) return NO_NODE;
      let fromStart: u32 = 0;
      let fromLength: u32 = 0;
      if (this.peekKind() == TokenKind.kwFrom) {
        this.advance();
        const specifier = this.peek();
        if (specifier.kind != TokenKind.stringLit) {
          this.hadError = true;
          return NO_NODE;
        }
        this.advance();
        fromStart = specifier.start;
        fromLength = specifier.length;
      }
      this.matchKind(TokenKind.semicolon);
      const declaration = this.ast.newNode(NodeKind.exportDecl, keyword.start, this.peek().start);
      this.ast.setChildren(declaration, in clauses);
      this.ast.setName(declaration, fromStart, fromLength);
      return declaration;
    }
    // `export <declaration>`
    let declared: u32 = NO_NODE;
    const k = this.peekKind();
    if (k == TokenKind.kwVar || k == TokenKind.kwLet || k == TokenKind.kwConst) {
      declared = this.parseVarDecl(true);
    } else if (k == TokenKind.kwFunction) {
      declared = this.parseFunctionDecl(false);
    } else if (k == TokenKind.kwClass) {
      declared = this.parseClassDecl();
    } else if (k == TokenKind.kwAsync && this.peekKind2() == TokenKind.kwFunction) {
      this.advance();
      declared = this.parseFunctionDecl(true);
    } else {
      this.hadError = true;
      return NO_NODE;
    }
    if (declared == NO_NODE) return NO_NODE;
    const declaration = this.ast.newNode(NodeKind.exportDecl, keyword.start, this.endOf(declared));
    this.ast.setLeft(declaration, declared);
    return declaration;
  }

  // --- Number literals ---

  function parseNumberLiteral(start: u32, length: u32): f64 {
    // Copy the slice without numeric separators.
    let stripped = TextBuffer();
    let index: u32 = 0;
    while (index < length) {
      const at = usize(start + index);
      if (this.source[at] != B_UNDERSCORE) stripped.appendAscii(this.source[at]);
      index = index + 1;
    }
    const text = stripped.finish();
    const count = text.byteLength;
    if (length >= 2 && text.byteAt(0) == B_0) {
      const c1 = text.byteAt(1);
      if (c1 == B_x || c1 == B_UPPER_X) return parseIntPrefix(in text, 2, count, 16);
      if (c1 == B_b || c1 == B_UPPER_B) return parseIntPrefix(in text, 2, count, 2);
      if (c1 == B_o || c1 == B_UPPER_O) return parseIntPrefix(in text, 2, count, 8);
    }
    return stringToDouble(in text);
  }
}

function parseIntPrefix(in text: String, begin: usize, limit: usize, base: u32): f64 {
  let acc: f64 = 0.0;
  let index = begin;
  while (index < limit) {
    const c = text.byteAt(index);
    let d: u32 = 0;
    if (c >= B_0 && c <= B_9) {
      d = u32(c - B_0);
    } else if (c >= B_a && c <= B_f) {
      d = u32(c - B_a) + 10;
    } else if (c >= B_UPPER_A && c <= B_UPPER_F) {
      d = u32(c - B_UPPER_A) + 10;
    } else {
      return acc;
    }
    acc = acc * f64(base) + f64(d);
    index = index + 1;
  }
  return acc;
}

// --- Entry ----------------------------------------------------------------

// Source given as text, for tests and tools that hold a String.
export function parseText(source: String, isModule: boolean): ParseResult {
  return parseProgram(bytesOf(in source), isModule);
}

export function parseProgram(source: Array<u8>, isModule: boolean): ParseResult {
  const sourceLength = u32(source.length);
  const byteCount = source.length;
  const tokens = tokenize(sliceBytes(in source, 0, byteCount));
  const tokenCount = tokens.length;
  let parser = Parser({
    source: move source,
    tokens: move tokens,
    tokenLimit: tokenCount,
    pos: 0,
    ast: createAst(),
    hadError: false,
    noIn: false,
    functionDepth: 0,
    inAsync: false,
    isModule: isModule,
    inGenerator: false,
    strictMode: false,
    inDerivedConstructor: false,
    inStaticBlock: false,
    staticBlockDepth: 0,
  });

  // A top-level "use strict" prologue makes the whole script strict.
  if (parser.tokensHaveUseStrictPrologue(0)) parser.strictMode = true;

  const program = parser.ast.newNode(NodeKind.program, 0, sourceLength);
  parser.ast.setBool(program, isModule);
  let statements = Array<u32>();
  while (parser.peekKind() != TokenKind.eof && !parser.hadError) {
    const statement = parser.parseStatement();
    if (statement == NO_NODE) break;
    statements.push(statement);
  }
  parser.ast.setChildren(program, in statements);

  // AllPrivateNamesValid: checked after parsing because a class body may use
  // a private name before its declaration.
  if (!parser.hadError) {
    let chain = Array<u32>();
    parser.validatePrivateNames(program, inout chain, 0);
  }

  const hadError = parser.hadError;
  return ParseResult({ parser: move parser, root: program, hadError: hadError });
}

// --- Tests ----------------------------------------------------------------

test "precedence builds the expected tree" {
  const result = parseText("1 + 2 * 3;", false);
  expect(result.hadError).toEqual(false);
  const program = result.parser.ast.node(result.root);
  const one: u32 = 1;
  expect(program.childrenCount).toEqual(one);
  const sum = result.parser.ast.node(result.parser.ast.child(result.root, 0));
  expect(sum.kind == NodeKind.binary).toEqual(true);
  expect(sum.op == TokenKind.plus).toEqual(true);
  const product = result.parser.ast.node(sum.right);
  expect(product.kind == NodeKind.binary).toEqual(true);
  expect(product.op == TokenKind.star).toEqual(true);
}

test "number literals decode radix and separators" {
  const result = parseText("0xFF; 0b1_0; 0o17; 1_000.5e1;", false);
  expect(result.hadError).toEqual(false);
  expect(result.parser.ast.node(result.parser.ast.child(result.root, 0)).num).toEqual(255.0);
  expect(result.parser.ast.node(result.parser.ast.child(result.root, 1)).num).toEqual(2.0);
  expect(result.parser.ast.node(result.parser.ast.child(result.root, 2)).num).toEqual(15.0);
  expect(result.parser.ast.node(result.parser.ast.child(result.root, 3)).num).toEqual(10005.0);
}

test "a class with fields gains a synthesized constructor" {
  const result = parseText("class C { x = 1; static y = 2; m() {} }", false);
  expect(result.hadError).toEqual(false);
  const classNode = result.parser.ast.node(result.parser.ast.child(result.root, 0));
  expect(classNode.kind == NodeKind.classDecl).toEqual(true);
  // x, y, m, plus the synthesized constructor.
  const four: u32 = 4;
  expect(classNode.childrenCount).toEqual(four);
  const synthesized = result.parser.ast.node(result.parser.ast.child(result.parser.ast.child(result.root, 0), 3));
  expect(synthesized.kind == NodeKind.methodDef).toEqual(true);
  expect(synthesized.num).toEqual(2.0);
}

test "a private name outside any class is rejected" {
  const result = parseText("#x in obj;", false);
  expect(result.hadError).toEqual(true);
}
