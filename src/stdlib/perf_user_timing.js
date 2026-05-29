(function(){
  var marks = new Map();
  var measures = [];
  var entries = [];
  function makeMark(name, opts) {
    var o = opts || {};
    return {
      name: String(name),
      entryType: 'mark',
      startTime: o.startTime !== undefined ? +o.startTime : performance.now(),
      duration: 0,
      detail: o.detail !== undefined ? o.detail : null,
    };
  }
  function makeMeasure(name, startTime, duration, detail) {
    return { name: String(name), entryType: 'measure', startTime: startTime, duration: duration, detail: detail !== undefined ? detail : null };
  }
  function resolveTime(t) {
    if (typeof t === 'number') return t;
    if (typeof t === 'string') {
      var list = marks.get(t);
      if (!list || list.length === 0) {
        var Err = (typeof DOMException !== 'undefined') ? DOMException : SyntaxError;
        throw new Err("Mark '" + t + "' does not exist", 'SyntaxError');
      }
      return list[list.length - 1].startTime;
    }
    return undefined;
  }
  performance.mark = function(name, opts) {
    var m = makeMark(name, opts);
    if (!marks.has(m.name)) marks.set(m.name, []);
    marks.get(m.name).push(m);
    entries.push(m);
    return m;
  };
  performance.measure = function(name, startOrOpts, endMark) {
    var startTime, endTime, detail = null;
    if (startOrOpts !== null && typeof startOrOpts === 'object' && endMark === undefined) {
      var opts = startOrOpts;
      if (opts.start !== undefined) startTime = resolveTime(opts.start);
      if (opts.end   !== undefined) endTime   = resolveTime(opts.end);
      if (opts.duration !== undefined) {
        if (startTime === undefined && endTime !== undefined) startTime = endTime - opts.duration;
        else if (endTime === undefined && startTime !== undefined) endTime = startTime + opts.duration;
      }
      if (opts.detail !== undefined) detail = opts.detail;
    } else {
      startTime = (startOrOpts !== undefined) ? resolveTime(startOrOpts) : 0;
      endTime   = (endMark   !== undefined) ? resolveTime(endMark)   : performance.now();
    }
    if (startTime === undefined) startTime = 0;
    if (endTime   === undefined) endTime   = performance.now();
    var meas = makeMeasure(name, startTime, endTime - startTime, detail);
    measures.push(meas);
    entries.push(meas);
    return meas;
  };
  performance.clearMarks = function(name) {
    if (name === undefined) {
      marks.clear();
      entries = entries.filter(function(e){return e.entryType !== 'mark';});
    } else {
      var key = String(name);
      marks.delete(key);
      entries = entries.filter(function(e){return !(e.entryType === 'mark' && e.name === key);});
    }
  };
  performance.clearMeasures = function(name) {
    if (name === undefined) {
      measures.length = 0;
      entries = entries.filter(function(e){return e.entryType !== 'measure';});
    } else {
      var key = String(name);
      measures = measures.filter(function(m){return m.name !== key;});
      entries = entries.filter(function(e){return !(e.entryType === 'measure' && e.name === key);});
    }
  };
  performance.getEntries = function() { return entries.slice(); };
  performance.getEntriesByName = function(name, type) {
    var key = String(name);
    return entries.filter(function(e){
      return e.name === key && (type === undefined || e.entryType === type);
    });
  };
  performance.getEntriesByType = function(type) {
    return entries.filter(function(e){ return e.entryType === type; });
  };
})();
