// Native error constructors, AggregateError, and the URI functions.
var log = [];
log.push(typeof EvalError, typeof URIError, typeof AggregateError);
log.push(new EvalError("e").name, new URIError("u").message, EvalError.prototype instanceof Error);
log.push(Object.getPrototypeOf(EvalError) === Error, Object.getPrototypeOf(URIError.prototype) === Error.prototype, String(new EvalError("x")));
var a = new AggregateError([1, 2], "agg");
log.push(a.name, a.message, a.errors.length, a.errors[1], Object.prototype.hasOwnProperty.call(a, "errors"), a instanceof Error, a instanceof AggregateError);
try { new AggregateError(5); } catch (x) { log.push(x instanceof TypeError); }
log.push(encodeURIComponent("a b&c/d?é"), encodeURI("http://x.y/a b?q=1&r=é#f"), decodeURIComponent("a%20b%26c%2Fd%C3%A9"));
log.push(encodeURIComponent("\u{1F600}"), decodeURIComponent("%F0%9F%98%80") === "\u{1F600}");
log.push(decodeURI.name, encodeURIComponent("-_.!~*'()"), encodeURI(";/?:@&=+$,#"), encodeURIComponent(";/?:@&=+$,#"));
log.push(decodeURIComponent("%3B%2F%3F%3A%40%26%3D%2B%24%2C%23"), decodeURI("%41%61%2d"), encodeURIComponent(""), decodeURI(""));
log.join("|");
