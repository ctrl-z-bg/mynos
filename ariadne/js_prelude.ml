(* The DOM's API for a page's scripts, in JavaScript, over jsd's __dom(op,
   ...args) (Dom_api's operations, served by Ariadne): run in each page's
   context before its scripts. Nodes are objects holding a handle (an
   integer as a string), one object a handle (a === b holds, and
   properties put on a node stay). Then __init(url, title) is called;
   after the scripts, Ariadne calls __afterScripts() (DOMContentLoaded,
   load) and __runTimers(ms) (setTimeout, setInterval). *)

let source = {js|
(function () {
  "use strict";
  const raw = globalThis.__dom;
  const D = (op, ...a) => raw(op, g.__sid, ...a);   // the page's session first
  const objects = new Map();
  const g = globalThis;

  function wrap(h, type, name) {
    let o = objects.get(h);
    if (o) return o;
    type = +type;
    o = type === 1 ? new (interfaceOf(name))(h, type, name)
      : type === 3 ? new Text(h, type, name)
      : type === 9 ? new Document(h, type, name)
      : new Node(h, type, name);
    objects.set(h, o);
    return o;
  }
  function list(r) {
    const out = [];
    for (let i = 0; i + 2 < r.length; i += 3) out.push(wrap(r[i], r[i + 1], r[i + 2]));
    out.item = function (i) { return this[i] || null; };
    return out;
  }
  function one(r) { return r.length >= 3 ? wrap(r[0], r[1], r[2]) : null; }
  function boxOf(el) { const r = D("box", el.__h); return r.length ? r.map(Number) : null; }
  function view() { const v = D("viewport").map(Number); return { sx: v[0], sy: v[1], w: v[2], h: v[3], ph: v[4] }; }
  class DOMRect {
    constructor(x, y, w, h) { this.x = x; this.y = y; this.width = w; this.height = h;
                              this.left = x; this.top = y; this.right = x + w; this.bottom = y + h; }
    toJSON() { return { x: this.x, y: this.y, width: this.width, height: this.height, top: this.top,
                        left: this.left, right: this.right, bottom: this.bottom }; }
  }
  function str(v) { return v === null || v === undefined ? "" : String(v); }

  class EventTarget {
    addEventListener(type, f, opts) {
      if (typeof f !== "function" && !(f && typeof f.handleEvent === "function")) return;
      const l = this.__listeners || (this.__listeners = {});
      (l[type] || (l[type] = [])).push({ f, once: !!(opts && opts.once) });
    }
    removeEventListener(type, f) {
      const l = this.__listeners && this.__listeners[type];
      if (l) this.__listeners[type] = l.filter(x => x.f !== f);
    }
    dispatchEvent(ev) {
      ev.target = ev.target || this;
      for (let n = this; n; n = n === g ? null : n === g.document ? g : n.parentNode) {
        ev.currentTarget = n;
        const l = n.__listeners && n.__listeners[ev.type];
        if (l) for (const x of l.slice()) {
          try { typeof x.f === "function" ? x.f.call(n, ev) : x.f.handleEvent(ev); }
          catch (e) { console.error(String(e) + (e && e.stack ? "\n" + e.stack : "")); }
          if (x.once) n.removeEventListener(ev.type, x.f);
        }
        const on = n["on" + ev.type];
        if (typeof on === "function") {
          try { if (on.call(n, ev) === false) ev.preventDefault(); } catch (e) { console.error(String(e)); }
        } else if (n.nodeType === 1 && ev.type !== "load") {
          // an onclick="..." attribute
          const code = n.getAttribute("on" + ev.type);
          if (code) {
            try { if (new Function("event", code).call(n, ev) === false) ev.preventDefault(); }
            catch (e) { console.error(String(e) + (e && e.stack ? "\n" + e.stack : "")); }
          }
        }
        if (!ev.bubbles || ev.__stopped) break;
      }
      return !ev.defaultPrevented;
    }
  }

  class Event {
    constructor(type, init) {
      this.type = type; this.bubbles = !!(init && init.bubbles); this.cancelable = !!(init && init.cancelable);
      this.defaultPrevented = false; this.target = null; this.currentTarget = null; this.timeStamp = Date.now();
    }
    preventDefault() { if (this.cancelable) this.defaultPrevented = true; }
    stopPropagation() { this.__stopped = true; }
    stopImmediatePropagation() { this.__stopped = true; }
  }
  class CustomEvent extends Event { constructor(type, init) { super(type, init); this.detail = init ? init.detail : null; } }
  class MessageEvent extends Event {
    constructor(type, init) {
      super(type, init); init = init || {};
      this.data = init.data === undefined ? null : init.data; this.origin = init.origin || "";
      this.lastEventId = init.lastEventId || ""; this.source = init.source || null; this.ports = init.ports || [];
    }
  }

  // ---- scripts put in the page by scripts: run soon after (as browsers do,
  // asynchronously), their src fetched (no CORS for scripts), then their
  // load (or error) event; never twice, and not those innerHTML made ----
  const jsTypes = ["", "text/javascript", "application/javascript", "application/ecmascript", "text/ecmascript",
                   "application/x-javascript"];
  function runScript(s) {
    if (s.__started) return;
    s.__started = true;
    const type = (s.getAttribute("type") || "").trim().toLowerCase();
    if (!jsTypes.includes(type)) return;
    g.setTimeout(() => {
      const src = s.getAttribute("src");
      let code, failed = false;
      if (src !== null) {
        try {
          const r = request("GET", new URL(src, g.location.href).href, null, null, "script");
          if (r.status >= 400) failed = true; else code = r.body;
        } catch (e) { failed = true; console.warn("script " + src + ": " + (e && e.message)); }
      } else code = s.textContent;
      if (!failed) {
        g.__currentScript = s;
        try { (0, eval)(code); }
        catch (e) { console.error("script " + (src || "inline") + ": " + String(e) + (e && e.stack ? "\n" + e.stack : "")); }
        g.__currentScript = null;
      }
      s.dispatchEvent(new Event(failed ? "error" : "load"));
    }, 0);
  }
  // a node about to be put in: its scripts (a fragment's, before it
  // empties into the page); then, once in, run if it is in the page now
  function scriptsOf(n) {
    if (n.nodeType === 1 && n.nodeName === "SCRIPT") return [n];
    if (n.nodeType === 1 || n.nodeType === 11) return list(D("queryAll", n.__h, "script"));
    return [];
  }
  function inserted(scripts) {
    const todo = scripts.filter(s => !s.__started);
    if (todo.length && todo[0].isConnected) todo.forEach(runScript);
  }
  function markStarted(el) { for (const s of list(D("queryAll", el.__h, "script"))) s.__started = true; }

  class Node extends EventTarget {
    constructor(h, type, name) { super(); this.__h = h; this.nodeType = type; this.nodeName = name; }
    get parentNode() { return one(D("parent", this.__h)); }
    get parentElement() { const p = this.parentNode; return p && p.nodeType === 1 ? p : null; }
    get childNodes() { return list(D("children", this.__h)); }
    get firstChild() { return this.childNodes[0] || null; }
    get lastChild() { const c = this.childNodes; return c[c.length - 1] || null; }
    get nextSibling() { return one(D("next", this.__h)); }
    get previousSibling() { return one(D("prev", this.__h)); }
    get ownerDocument() { return g.document; }
    get isConnected() { for (let n = this; n; n = n.parentNode) if (n === g.document) return true; return false; }
    get textContent() { const r = D("text", this.__h); return r.length ? r[0] : null; }
    set textContent(v) { D("setText", this.__h, str(v)); }
    get nodeValue() { return this.nodeType === 1 || this.nodeType === 9 ? null : this.textContent; }
    set nodeValue(v) { if (this.nodeType !== 1 && this.nodeType !== 9) this.textContent = v; }
    hasChildNodes() { return this.childNodes.length > 0; }
    appendChild(c) { const sc = scriptsOf(c); D("insert", this.__h, c.__h, ""); inserted(sc); return c; }
    insertBefore(c, ref) { const sc = scriptsOf(c); D("insert", this.__h, c.__h, ref ? ref.__h : ""); inserted(sc); return c; }
    removeChild(c) { D("remove", c.__h); return c; }
    replaceChild(n, o) { this.insertBefore(n, o); this.removeChild(o); return o; }
    remove() { D("remove", this.__h); }
    append(...ns) { for (const n of ns) this.appendChild(typeof n === "string" ? g.document.createTextNode(n) : n); }
    prepend(...ns) { const f = this.firstChild; for (const n of ns) this.insertBefore(typeof n === "string" ? g.document.createTextNode(n) : n, f); }
    before(...ns) { const p = this.parentNode; if (p) for (const n of ns) p.insertBefore(typeof n === "string" ? g.document.createTextNode(n) : n, this); }
    after(...ns) { const p = this.parentNode, nx = this.nextSibling; if (p) for (const n of ns) p.insertBefore(typeof n === "string" ? g.document.createTextNode(n) : n, nx); }
    replaceWith(...ns) { this.before(...ns); this.remove(); }
    contains(o) { for (let n = o; n; n = n.parentNode) if (n === this) return true; return false; }
    cloneNode(deep) {
      if (this.nodeType === 3) return g.document.createTextNode(this.textContent);
      if (this.nodeType !== 1) return null;
      const t = g.document.createElement("template");
      t.innerHTML = deep ? this.outerHTML : this.outerHTML.replace(/>[\s\S]*$/, ">");
      return t.firstChild;
    }
  }
  Node.ELEMENT_NODE = 1; Node.TEXT_NODE = 3; Node.COMMENT_NODE = 8; Node.DOCUMENT_NODE = 9; Node.DOCUMENT_FRAGMENT_NODE = 11;

  class Text extends Node {
    get data() { return this.textContent; } set data(v) { this.textContent = v; }
    get length() { return this.textContent.length; }
  }

  function camelToKebab(k) { return k.replace(/[A-Z]/g, c => "-" + c.toLowerCase()); }
  function styleOf(el) {
    return new Proxy({}, {
      get(_, k) {
        if (typeof k !== "string") return undefined;
        const decls = parseStyle(el.getAttribute("style"));
        if (k === "cssText") return el.getAttribute("style") || "";
        if (k === "getPropertyValue") return p => decls[p] || "";
        if (k === "setProperty") return (p, v) => { decls[p] = str(v); writeStyle(el, decls); };
        if (k === "removeProperty") return p => { delete decls[p]; writeStyle(el, decls); };
        return decls[camelToKebab(k)] || "";
      },
      set(_, k, v) {
        if (k === "cssText") { el.setAttribute("style", str(v)); return true; }
        const decls = parseStyle(el.getAttribute("style"));
        const p = camelToKebab(String(k));
        if (v === null || v === "") delete decls[p]; else decls[p] = str(v);
        writeStyle(el, decls); return true;
      }
    });
  }
  function parseStyle(s) {
    const d = {};
    for (const part of (s || "").split(";")) {
      const i = part.indexOf(":");
      if (i > 0) d[part.slice(0, i).trim().toLowerCase()] = part.slice(i + 1).trim();
    }
    return d;
  }
  function writeStyle(el, d) { el.setAttribute("style", Object.keys(d).map(k => k + ": " + d[k]).join("; ")); }

  class ClassList {
    constructor(el, attr) { this.el = el; this.attr = attr || "class"; }
    get __all() { return (this.el.getAttribute(this.attr) || "").split(/\s+/).filter(Boolean); }
    __set(l) { this.el.setAttribute(this.attr, l.join(" ")); }
    get length() { return this.__all.length; }
    item(i) { return this.__all[i] || null; }
    contains(c) { return this.__all.includes(c); }
    add(...cs) { const l = this.__all; let ch = false; for (const c of cs) if (!l.includes(c)) { l.push(c); ch = true; } if (ch) this.__set(l); }
    remove(...cs) { const l = this.__all, m = l.filter(c => !cs.includes(c)); if (m.length !== l.length) this.__set(m); }
    toggle(c, force) {
      const has = this.contains(c), want = force === undefined ? !has : !!force;
      if (want && !has) this.add(c); else if (!want && has) this.remove(c);
      return want;
    }
    replace(a, b) { if (!this.contains(a)) return false; this.__set(this.__all.map(c => c === a ? b : c)); return true; }
    forEach(f) { this.__all.forEach(f); }
    toString() { return this.el.getAttribute("class") || ""; }
  }

  class Element extends Node {
    get tagName() { return this.nodeName; }
    get localName() { return this.nodeName.toLowerCase(); }
    getAttribute(k) { const r = D("getAttr", this.__h, k); return r.length ? r[0] : null; }
    setAttribute(k, v) { D("setAttr", this.__h, k, str(v)); }
    removeAttribute(k) { D("removeAttr", this.__h, k); }
    hasAttribute(k) { return this.getAttribute(k) !== null; }
    toggleAttribute(k, force) {
      const has = this.hasAttribute(k), want = force === undefined ? !has : !!force;
      if (want && !has) this.setAttribute(k, ""); else if (!want && has) this.removeAttribute(k);
      return want;
    }
    getAttributeNames() { return D("attrNames", this.__h); }
    get attributes() { return this.getAttributeNames().map(name => ({ name, value: this.getAttribute(name) })); }
    get id() { return this.getAttribute("id") || ""; } set id(v) { this.setAttribute("id", v); }
    get className() { return this.getAttribute("class") || ""; } set className(v) { this.setAttribute("class", v); }
    get classList() { return new ClassList(this); }
    get style() { return styleOf(this); }
    get dataset() {
      const el = this;
      const key = k => "data-" + camelToKebab(String(k));
      return new Proxy({}, {
        get(_, k) { return typeof k === "string" ? (el.getAttribute(key(k)) ?? undefined) : undefined; },
        set(_, k, v) { el.setAttribute(key(k), v); return true; },
        deleteProperty(_, k) { el.removeAttribute(key(k)); return true; }
      });
    }
    get hidden() { return this.hasAttribute("hidden"); } set hidden(v) { this.toggleAttribute("hidden", !!v); }
    get title() { return this.getAttribute("title") || ""; } set title(v) { this.setAttribute("title", v); }
    get children() { return list(D("elements", this.__h)); }
    get childElementCount() { return this.children.length; }
    get firstElementChild() { return this.children[0] || null; }
    get lastElementChild() { const c = this.children; return c[c.length - 1] || null; }
    get nextElementSibling() { let n = this.nextSibling; while (n && n.nodeType !== 1) n = n.nextSibling; return n; }
    get previousElementSibling() { let n = this.previousSibling; while (n && n.nodeType !== 1) n = n.previousSibling; return n; }
    get innerHTML() { return D("html", this.__h)[0]; }
    set innerHTML(v) { D("setHtml", this.__h, str(v)); markStarted(this); }
    get outerHTML() { return D("outerHtml", this.__h)[0]; }
    set outerHTML(v) { this.insertAdjacentHTML("beforebegin", v); this.remove(); }
    get innerText() { return this.textContent; } set innerText(v) { this.textContent = v; }
    insertAdjacentHTML(w, s) { D("insertHtml", this.__h, w, str(s)); markStarted(this.parentNode || this); }
    insertAdjacentElement(w, el) {
      const p = this.parentNode;
      switch (String(w).toLowerCase()) {
        case "beforebegin": if (p) p.insertBefore(el, this); break;
        case "afterbegin": this.insertBefore(el, this.firstChild); break;
        case "beforeend": this.appendChild(el); break;
        case "afterend": if (p) p.insertBefore(el, this.nextSibling); break;
      }
      return el;
    }
    insertAdjacentText(w, t) { this.insertAdjacentElement(w, g.document.createTextNode(t)); }
    querySelector(s) { return one(D("query", this.__h, s)); }
    querySelectorAll(s) { return list(D("queryAll", this.__h, s)); }
    getElementsByTagName(t) { return list(D("byTag", this.__h, t)); }
    getElementsByClassName(c) { return list(D("byClass", this.__h, c)); }
    matches(s) { return D("matches", this.__h, s)[0] === "1"; }
    closest(s) { return one(D("closest", this.__h, s)); }
    get content() { return this; }   // a template's
    focus() {} blur() {}
    click() { this.dispatchEvent(new Event("click", { bubbles: true, cancelable: true })); }
    // the layout (the browser's, of the page as it is now): border box on
    // the page [x, y, w, h, top, right, bottom, left borders], or null
    getBoundingClientRect() {
      const b = boxOf(this);
      if (!b) return new DOMRect(0, 0, 0, 0);
      const v = view();
      return new DOMRect(b[0] - v.sx, b[1] - v.sy, b[2], b[3]);
    }
    getClientRects() { return boxOf(this) ? [this.getBoundingClientRect()] : []; }
    get offsetParent() { return one(D("offsetParent", this.__h)); }
    get offsetWidth() { const b = boxOf(this); return b ? b[2] : 0; }
    get offsetHeight() { const b = boxOf(this); return b ? b[3] : 0; }
    get offsetLeft() {
      const b = boxOf(this); if (!b) return 0;
      const p = this.offsetParent, pb = p && boxOf(p);
      return b[0] - (pb ? pb[0] + pb[7] : 0);
    }
    get offsetTop() {
      const b = boxOf(this); if (!b) return 0;
      const p = this.offsetParent, pb = p && boxOf(p);
      return b[1] - (pb ? pb[1] + pb[4] : 0);
    }
    get clientWidth() {
      if (this === g.document.documentElement) return view().w;
      const b = boxOf(this); return b ? b[2] - b[5] - b[7] : 0;
    }
    get clientHeight() {
      if (this === g.document.documentElement) return view().h;
      const b = boxOf(this); return b ? b[3] - b[4] - b[6] : 0;
    }
    get clientTop() { const b = boxOf(this); return b ? b[4] : 0; }
    get clientLeft() { const b = boxOf(this); return b ? b[7] : 0; }
    // elements do not scroll in Ariadne: only the page
    get scrollWidth() { return this === g.document.documentElement ? view().w : this.clientWidth; }
    get scrollHeight() { return this === g.document.documentElement ? view().ph : this.clientHeight; }
    get scrollTop() { return this === g.document.documentElement || this === g.document.body ? view().sy : 0; }
    set scrollTop(v) { if (this === g.document.documentElement || this === g.document.body) g.scrollTo(0, v); }
    get scrollLeft() { return 0; } set scrollLeft(v) {}
    scrollIntoView() { const b = boxOf(this); if (b) g.scrollTo(0, b[1]); }
    setAttributeNS(ns, k, v) { this.setAttribute(k, v); }
    getAttributeNS(ns, k) { return this.getAttribute(k); }
  }

  class Document extends Node {
    get documentElement() { return one(D("documentElement")); }
    get body() { return one(D("body")); }
    get head() { return one(D("head")); }
    get title() { return D("title")[0]; } set title(v) { D("setTitle", str(v)); }
    getElementById(id) { return one(D("byId", str(id))); }
    querySelector(s) { return one(D("query", this.__h, s)); }
    querySelectorAll(s) { return list(D("queryAll", this.__h, s)); }
    getElementsByTagName(t) { return list(D("byTag", this.__h, t)); }
    getElementsByClassName(c) { return list(D("byClass", this.__h, c)); }
    getElementsByName(n) { return list(D("queryAll", this.__h, "[name=\"" + str(n).replace(/"/g, '\\"') + "\"]")); }
    createElement(t) { const el = one(D("create", str(t))); if (el) el.__made = true; return el; }
    get baseURI() {
      const b = this.querySelector("base[href]");
      try { return b ? new URL(b.getAttribute("href"), g.location.href).href : g.location.href; }
      catch (e) { return g.location.href; }
    }
    createElementNS(ns, t) { return this.createElement(t); }
    createTextNode(s) { return one(D("createText", str(s))); }
    createComment(s) { return one(D("createComment", str(s))); }
    createDocumentFragment() { return one(D("createFragment")); }
    createEvent() { return new Event(""); }
    get readyState() { return g.__readyState; }
    get currentScript() { return g.__currentScript || null; }
    get cookie() { return D("cookie")[0]; } set cookie(v) { D("setCookie", str(v)); }
    get referrer() { return ""; }
    get defaultView() { return g; }
    get location() { return g.location; } set location(v) { g.location = v; }
    get forms() { return this.getElementsByTagName("form"); }
    get images() { return this.getElementsByTagName("img"); }
    get links() { return this.querySelectorAll("a[href], area[href]"); }
    get scripts() { return this.getElementsByTagName("script"); }
    get activeElement() { return this.body; }
    hasFocus() { return true; }
    // after the page was parsed: what it writes goes at the end of the body
    write(...s) { const b = this.body; if (b) b.insertAdjacentHTML("beforeend", s.join("")); }
    writeln(...s) { this.write(...s, "\n"); }
  }

  // ---- the window ----
  const timers = [];
  let timerId = 0, now = 0;
  g.setTimeout = (f, ms, ...a) => { const id = ++timerId; timers.push({ id, f, at: now + (+ms || 0), a }); return id; };
  g.setInterval = (f, ms, ...a) => { const id = ++timerId; timers.push({ id, f, at: now + Math.max(+ms || 0, 1), every: Math.max(+ms || 0, 1), a }); return id; };
  g.clearTimeout = g.clearInterval = id => { const i = timers.findIndex(t => t.id === id); if (i >= 0) timers.splice(i, 1); };
  g.requestAnimationFrame = f => g.setTimeout(() => f(now), 16);
  g.cancelAnimationFrame = g.clearTimeout;
  g.queueMicrotask = f => Promise.resolve().then(f);
  // the timers due within [ms] of the page's time, in order (Ariadne calls it)
  // a run's worth (10 callbacks at most: each run of jsd is limited in
  // time): the window is [ms] from now, or the last one's (ms = 0, its
  // rest); "due waiting": those still due in the window, and in all
  let until = 0;
  g.__pendingTimers = () => timers.length;
  g.__runTimers = function (ms) {
    if (ms > 0 || until < now) until = now + ms;
    let n = 0;
    while (n < 10) {
      timers.sort((a, b) => a.at - b.at || a.id - b.id);
      const t = timers[0];
      if (!t || t.at > until) break;
      now = Math.max(now, t.at);
      if (t.every) t.at = now + t.every; else timers.shift();
      try { typeof t.f === "function" ? t.f(...t.a) : (0, eval)(String(t.f)); }
      catch (e) { console.error(String(e) + (e && e.stack ? "\n" + e.stack : "")); }
      n++;
    }
    const due = timers.filter(t => t.at <= until).length;
    if (due === 0) now = until;
    return due + " " + timers.length;
  };

  // ---- the network: fetch, XMLHttpRequest (the browser's, through __dom) ----
  class Headers {
    constructor(init) {
      this.__h = new Map();
      if (init instanceof Headers) init.forEach((v, k) => this.append(k, v));
      else if (Array.isArray(init)) for (const [k, v] of init) this.append(k, v);
      else if (init) for (const k of Object.keys(init)) this.append(k, init[k]);
    }
    append(k, v) { k = String(k).toLowerCase(); const o = this.__h.get(k); this.__h.set(k, o === undefined ? String(v) : o + ", " + v); }
    set(k, v) { this.__h.set(String(k).toLowerCase(), String(v)); }
    get(k) { const v = this.__h.get(String(k).toLowerCase()); return v === undefined ? null : v; }
    has(k) { return this.__h.has(String(k).toLowerCase()); }
    delete(k) { this.__h.delete(String(k).toLowerCase()); }
    forEach(f) { this.__h.forEach((v, k) => f(v, k, this)); }
    entries() { return this.__h.entries(); } keys() { return this.__h.keys(); } values() { return this.__h.values(); }
    [Symbol.iterator]() { return this.__h.entries(); }
  }
  class URLSearchParams {
    constructor(init) {
      this.__p = [];
      if (typeof init === "string") {
        for (const part of init.replace(/^\?/, "").split("&")) if (part) {
          const i = part.indexOf("="), dec = x => decodeURIComponent(x.replace(/\+/g, " "));
          this.__p.push(i < 0 ? [dec(part), ""] : [dec(part.slice(0, i)), dec(part.slice(i + 1))]);
        }
      } else if (init) for (const k of Object.keys(init)) this.__p.push([k, String(init[k])]);
    }
    append(k, v) { this.__p.push([String(k), String(v)]); }
    set(k, v) { this.delete(k); this.append(k, v); }
    get(k) { const p = this.__p.find(p => p[0] === k); return p ? p[1] : null; }
    getAll(k) { return this.__p.filter(p => p[0] === k).map(p => p[1]); }
    has(k) { return this.__p.some(p => p[0] === k); }
    delete(k) { this.__p = this.__p.filter(p => p[0] !== k); }
    forEach(f) { this.__p.forEach(p => f(p[1], p[0], this)); }
    toString() {
      const enc = x => encodeURIComponent(x).replace(/%20/g, "+");
      return this.__p.map(p => enc(p[0]) + "=" + enc(p[1])).join("&");
    }
  }
  class FormData extends URLSearchParams {
    constructor(form) {
      super();
      if (form && form.__h) for (const el of form.querySelectorAll("input[name], select[name], textarea[name]")) {
        const t = el.type;
        if ((t === "checkbox" || t === "radio") && !el.checked) continue;
        if (t === "submit" || t === "button" || t === "file") continue;
        this.append(el.name, el.value);
      }
    }
  }
  // DOMException (WebIDL), if the engine has none
  if (typeof g.DOMException !== "function") {
    const codes = { IndexSizeError: 1, NotFoundError: 8, NotSupportedError: 9, InvalidStateError: 11,
                    SyntaxError: 12, NetworkError: 19, AbortError: 20, TimeoutError: 23, DataCloneError: 25 };
    g.DOMException = class DOMException extends Error {
      constructor(message, name) {
        super(message === undefined ? "" : String(message));
        this.name = name === undefined ? "Error" : String(name);
        this.code = codes[this.name] || 0;
      }
    };
  }
  // TextEncoder, TextDecoder (the Encoding Standard): UTF-8, and decoding
  // UTF-16 and windows-1252 too
  class TextEncoder {
    get encoding() { return "utf-8"; }
    encode(input = "") {
      const s = String(input), out = [];
      for (let i = 0; i < s.length; i++) {
        let c = s.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
          const d = s.charCodeAt(i + 1);
          if (d >= 0xDC00 && d <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00); i++; }
          else c = 0xFFFD;
        } else if (c >= 0xD800 && c <= 0xDFFF) c = 0xFFFD;
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xC0 | c >> 6, 0x80 | c & 63);
        else if (c < 0x10000) out.push(0xE0 | c >> 12, 0x80 | c >> 6 & 63, 0x80 | c & 63);
        else out.push(0xF0 | c >> 18, 0x80 | c >> 12 & 63, 0x80 | c >> 6 & 63, 0x80 | c & 63);
      }
      return new Uint8Array(out);
    }
    encodeInto(input, dest) {
      const b = this.encode(input), n = Math.min(b.length, dest.length);
      // whole characters only
      let k = n; while (k > 0 && k < b.length && (b[k] & 0xC0) === 0x80) k--;
      dest.set(b.subarray(0, k));
      return { read: new TextDecoder().decode(b.subarray(0, k)).length, written: k };
    }
  }
  class TextDecoder {
    constructor(label = "utf-8", opts) {
      const l = String(label).trim().toLowerCase();
      this.encoding = ["utf8", "unicode-1-1-utf-8", "utf-8"].includes(l) ? "utf-8"
        : ["utf-16", "utf-16le"].includes(l) ? "utf-16le" : l === "utf-16be" ? "utf-16be"
        : ["latin1", "iso-8859-1", "ascii", "us-ascii", "windows-1252", "cp1252"].includes(l) ? "windows-1252" : null;
      if (!this.encoding) throw new RangeError("TextDecoder: the encoding " + label + " is not supported");
      this.fatal = !!(opts && opts.fatal); this.ignoreBOM = !!(opts && opts.ignoreBOM);
    }
    decode(input) {
      if (input === undefined) return "";
      const b = input instanceof ArrayBuffer ? new Uint8Array(input)
        : new Uint8Array(input.buffer, input.byteOffset || 0, input.byteLength);
      let out = "", i = 0;
      const bad = () => { if (this.fatal) throw new TypeError("TextDecoder: invalid data"); out += "�"; };
      if (this.encoding === "windows-1252") {
        for (; i < b.length; i++) out += String.fromCharCode(b[i]);
        return out;
      }
      if (this.encoding !== "utf-8") {
        const be = this.encoding === "utf-16be";
        if (!this.ignoreBOM && b.length >= 2 && (be ? b[0] === 0xFE && b[1] === 0xFF : b[0] === 0xFF && b[1] === 0xFE)) i = 2;
        for (; i + 1 < b.length; i += 2) out += String.fromCharCode(be ? b[i] << 8 | b[i + 1] : b[i] | b[i + 1] << 8);
        if (i < b.length) bad();
        return out;
      }
      if (!this.ignoreBOM && b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF) i = 3;
      while (i < b.length) {
        const c = b[i];
        let n = c < 0x80 ? 0 : c >= 0xC2 && c < 0xE0 ? 1 : c >= 0xE0 && c < 0xF0 ? 2 : c >= 0xF0 && c < 0xF5 ? 3 : -1;
        if (n < 0) { bad(); i++; continue; }
        if (n === 0) { out += String.fromCharCode(c); i++; continue; }
        let cp = c & (0x3F >> n), j = 1;
        for (; j <= n && i + j < b.length && (b[i + j] & 0xC0) === 0x80; j++) cp = cp << 6 | b[i + j] & 63;
        if (j <= n || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)
            || (n === 2 && cp < 0x800) || (n === 3 && cp < 0x10000)) { bad(); i += Math.max(1, j); continue; }
        out += String.fromCodePoint(cp); i += n + 1;
      }
      return out;
    }
  }
  g.TextEncoder = TextEncoder; g.TextDecoder = TextDecoder;
  // AbortController and AbortSignal (the DOM Standard): a signal is an
  // event target, aborted once (its reason, an "abort" event); abort(),
  // timeout() and any() make signals of their own
  class AbortSignal extends EventTarget {
    constructor(key) {
      super();
      if (key !== signalKey) throw new TypeError("Illegal constructor");
      this.aborted = false; this.reason = undefined; this.onabort = null; this.__followers = [];
    }
    throwIfAborted() { if (this.aborted) throw this.reason; }
    __abort(reason) {
      if (this.aborted) return;
      this.aborted = true;
      this.reason = reason === undefined ? new g.DOMException("signal is aborted without reason", "AbortError") : reason;
      const fs = this.__followers; this.__followers = [];
      this.dispatchEvent(new Event("abort"));
      for (const f of fs) f.__abort(this.reason);
    }
    static abort(reason) { const s = new AbortSignal(signalKey); s.__abort(reason); return s; }
    static timeout(ms) {
      const s = new AbortSignal(signalKey);
      g.setTimeout(() => s.__abort(new g.DOMException("signal timed out", "TimeoutError")), ms);
      return s;
    }
    static any(signals) {
      const s = new AbortSignal(signalKey);
      for (const x of signals) {
        if (x.aborted) { s.__abort(x.reason); return s; }
      }
      for (const x of signals) x.__followers.push(s);
      return s;
    }
  }
  const signalKey = {};
  class AbortController {
    constructor() { this.signal = new AbortSignal(signalKey); }
    abort(reason) { this.signal.__abort(reason); }
  }

  // one request: [status, reason, url, body, headers...]; a NetworkError thrown
  function request(method, url, headers, body, mode) {
    const h = [];
    if (headers) new Headers(headers).forEach((v, k) => h.push(k + ": " + v));
    const hasBody = body !== undefined && body !== null && method !== "GET" && method !== "HEAD";
    const r = D("fetch", method, String(url), h.join("\n"), hasBody ? "1" : "0", hasBody ? String(body) : "",
                mode || "cors");
    const hs = new Headers();
    for (let i = 4; i + 1 < r.length; i += 2) hs.append(r[i], r[i + 1]);
    return { status: +r[0], statusText: r[1], url: r[2], body: r[3], headers: hs };
  }

  class Response {
    constructor(body, init) {
      init = init || {};
      this.__body = body === undefined || body === null ? "" : String(body);
      this.status = init.status === undefined ? 200 : init.status;
      this.statusText = init.statusText || "";
      this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers);
      this.url = init.url || ""; this.ok = this.status >= 200 && this.status < 300;
      this.redirected = false; this.type = "basic"; this.bodyUsed = false;
    }
    text() { this.bodyUsed = true; return Promise.resolve(this.__body); }
    json() { this.bodyUsed = true; try { return Promise.resolve(JSON.parse(this.__body)); } catch (e) { return Promise.reject(e); } }
    blob() { return this.text(); }
    // the body as Ariadne holds it (text), in UTF-8
    arrayBuffer() { return this.text().then(t => new g.TextEncoder().encode(t).buffer); }
    clone() { return new Response(this.__body, this); }
  }

  g.fetch = function (input, init) {
    init = init || {};
    return new Promise((resolve, reject) => {
      try {
        const signal = init.signal || (input && input.signal);
        if (signal && signal.aborted) { reject(signal.reason); return; }
        const url = new URL(typeof input === "string" ? input : (input.url || String(input)), g.location.href).href;
        const method = String(init.method || (input && input.method) || "GET").toUpperCase();
        let body = init.body;
        if (body instanceof URLSearchParams) body = body.toString();
        const r = request(method, url, init.headers, body);
        resolve(new Response(r.body, { status: r.status, statusText: r.statusText, headers: r.headers, url: r.url }));
      } catch (e) { reject(new TypeError("Failed to fetch: " + (e && e.message))); }
    });
  };

  class XMLHttpRequest extends EventTarget {
    constructor() {
      super();
      this.readyState = 0; this.status = 0; this.statusText = ""; this.responseText = ""; this.responseType = "";
      this.response = null; this.responseURL = ""; this.timeout = 0; this.withCredentials = false;
      this.__headers = {}; this.__answer = null; this.upload = new EventTarget();
    }
    open(method, url, async) {
      this.__method = String(method).toUpperCase();
      this.__url = new URL(String(url), g.location.href).href;
      this.__async = async !== false;
      this.readyState = 1;
    }
    setRequestHeader(k, v) { this.__headers[k] = v; }
    getResponseHeader(k) { return this.__answer ? this.__answer.headers.get(k) : null; }
    getAllResponseHeaders() {
      if (!this.__answer) return "";
      let s = ""; this.__answer.headers.forEach((v, k) => { s += k + ": " + v + "\r\n"; }); return s;
    }
    overrideMimeType() {}
    abort() { this.__aborted = true; }
    __fire(type) { const ev = new Event(type); this.dispatchEvent(ev); }
    send(body) {
      if (body instanceof URLSearchParams) body = body.toString();
      const done = () => {
        if (this.__aborted) return;
        let ok = true;
        try {
          const r = request(this.__method, this.__url, this.__headers, body);
          this.__answer = r;
          this.status = r.status; this.statusText = r.statusText; this.responseURL = r.url;
          this.responseText = r.body;
          if (this.responseType === "json") { try { this.response = JSON.parse(r.body); } catch (e) { this.response = null; } }
          else this.response = r.body;
        } catch (e) { ok = false; this.status = 0; console.warn("XMLHttpRequest: " + (e && e.message)); }
        this.readyState = 4;
        this.__fire("readystatechange");
        this.__fire(ok ? "load" : "error");
        this.__fire("loadend");
      };
      if (this.__async) g.setTimeout(done, 0); else done();
    }
  }
  XMLHttpRequest.UNSENT = 0; XMLHttpRequest.OPENED = 1; XMLHttpRequest.HEADERS_RECEIVED = 2;
  XMLHttpRequest.LOADING = 3; XMLHttpRequest.DONE = 4;

  // DOMParser: the text parsed into a detached element (not a document of
  // its own): its queries, body, documentElement
  class DOMParser {
    parseFromString(text) {
      const root = g.document.createElement("div");
      root.innerHTML = String(text);
      return { documentElement: root, body: root, head: null,
               querySelector: s => root.querySelector(s), querySelectorAll: s => root.querySelectorAll(s),
               getElementById: id => root.querySelector("#" + id),
               getElementsByTagName: t => root.getElementsByTagName(t), title: "" };
    }
  }
  g.DOMParser = DOMParser;
  // IntersectionObserver: an element's box against the viewport (grown by
  // rootMargin, in px), its state reported when first observed, then when
  // it changes as the page scrolls (Ariadne calls __scrolled). Thresholds:
  // the crossing of 0 (in view or not)
  const observers = new Set();
  class IntersectionObserver {
    constructor(cb, opts) {
      this.__cb = cb; this.__targets = new Map(); this.root = null;
      this.rootMargin = (opts && opts.rootMargin) || "0px"; this.thresholds = [0];
      const m = this.rootMargin.split(/\s+/).map(x => parseFloat(x) || 0);
      const [t, r = t, b = t, l = r] = m;
      this.__margin = { t, r, b, l };
    }
    observe(el) {
      if (this.__targets.has(el)) return;
      this.__targets.set(el, undefined);
      observers.add(this);
      g.setTimeout(() => this.__check([el]), 0);
    }
    unobserve(el) { this.__targets.delete(el); }
    disconnect() { this.__targets.clear(); observers.delete(this); }
    takeRecords() { return []; }
    __check(els) {
      const v = view(), m = this.__margin;
      const top = v.sy - m.t, bottom = v.sy + v.h + m.b, left = v.sx - m.l, right = v.sx + v.w + m.r;
      const entries = [];
      for (const el of els || [...this.__targets.keys()]) {
        if (!this.__targets.has(el)) continue;
        const b = boxOf(el);
        let ratio = 0, inter = false;
        if (b) {
          const iw = Math.min(b[0] + b[2], right) - Math.max(b[0], left);
          const ih = Math.min(b[1] + b[3], bottom) - Math.max(b[1], top);
          inter = iw >= 0 && ih >= 0 && (iw > 0 || b[2] === 0) && (ih > 0 || b[3] === 0);
          ratio = inter && b[2] * b[3] > 0 ? (iw * ih) / (b[2] * b[3]) : (inter ? 1 : 0);
        }
        if (this.__targets.get(el) !== inter) {
          this.__targets.set(el, inter);
          const r = b ? new DOMRect(b[0] - v.sx, b[1] - v.sy, b[2], b[3]) : new DOMRect(0, 0, 0, 0);
          entries.push({ target: el, isIntersecting: inter, intersectionRatio: ratio, time: Date.now(),
                         boundingClientRect: r, intersectionRect: inter ? r : new DOMRect(0, 0, 0, 0),
                         rootBounds: new DOMRect(0, 0, v.w, v.h) });
        }
      }
      if (entries.length) {
        try { this.__cb(entries, this); }
        catch (e) { console.error(String(e) + (e && e.stack ? "\n" + e.stack : "")); }
      }
    }
  }
  // the page scrolled: the observers, and scroll events (the document's,
  // bubbling to the window)
  g.__scrolled = function () {
    for (const o of [...observers]) o.__check();
    if (g.document) g.document.dispatchEvent(new Event("scroll", { bubbles: true }));
  };
  // ---- the element interfaces (the HTML Standard's): each element's
  // object is of its tag's interface, which reflects its content attributes
  // as properties (link.rel, script.async, img.loading, input.type...)
  const baseUrl = () => (g.document && g.document.baseURI) || g.location.href;
  // [property, kind, attribute (default: the property in lower case), default]
  // kinds: s string, u URL, b boolean, n integer, e enumerated ([values,
  // missing, invalid]), c CORS setting (null when absent)
  function reflect(cls, spec) {
    for (const [prop, kind, attr0, def] of spec) {
      const a = attr0 || prop.toLowerCase();
      let get, set = function (v) { this.setAttribute(a, v); };
      switch (kind) {
        case "s": get = function () { const v = this.getAttribute(a); return v === null ? (def ?? "") : v; }; break;
        case "u": get = function () {
          const v = this.getAttribute(a);
          if (v === null) return def === "document" ? g.location.href : "";
          try { return new URL(v, baseUrl()).href; } catch (e) { return v; }
        }; break;
        case "b": get = function () { return this.hasAttribute(a); };
          set = function (v) { this.toggleAttribute(a, !!v); }; break;
        case "n": get = function () {
          const v = parseInt(this.getAttribute(a), 10);
          return isNaN(v) ? (def ?? 0) : v;
        }; set = function (v) { this.setAttribute(a, String(Math.trunc(Number(v)) || 0)); }; break;
        case "e": get = function () {
          const [values, missing, invalid] = def, v = this.getAttribute(a);
          if (v === null) return missing;
          const l = v.toLowerCase();
          return values.includes(l) ? l : invalid;
        }; break;
        case "c": get = function () {
          const v = this.getAttribute(a);
          return v === null ? null : v.toLowerCase() === "use-credentials" ? "use-credentials" : "anonymous";
        }; set = function (v) { if (v === null) this.removeAttribute(a); else this.setAttribute(a, v); }; break;
      }
      Object.defineProperty(cls.prototype, prop, { get, set, configurable: true, enumerable: true });
    }
  }
  class HTMLElement extends Element {}
  reflect(HTMLElement, [["lang", "s"], ["dir", "s"], ["accessKey", "s", "accesskey"], ["translate", "b"],
                        ["draggable", "b"], ["inert", "b"], ["nonce", "s"], ["autofocus", "b"]]);
  Object.defineProperty(HTMLElement.prototype, "tabIndex", { configurable: true, enumerable: true,
    get() {
      const v = parseInt(this.getAttribute("tabindex"), 10);
      if (!isNaN(v)) return v;
      return /^(A|AREA|BUTTON|INPUT|SELECT|TEXTAREA|IFRAME|SUMMARY)$/.test(this.nodeName) ? 0 : -1;
    },
    set(v) { this.setAttribute("tabindex", String(Math.trunc(Number(v)) || 0)); } });
  class SVGElement extends Element {}
  const ifaces = { HTMLElement, SVGElement };
  const byTag = {};
  function iface(name, tags, spec, extend) {
    const cls = ({ [name]: class extends (extend || HTMLElement) {} })[name];
    if (spec) reflect(cls, spec);
    for (const t of tags) byTag[t] = cls;
    ifaces[name] = cls;
    return cls;
  }
  function interfaceOf(name) {
    // HTML elements' names are in upper case (nodeName); the others, SVG's
    if (name !== name.toUpperCase()) return name === "svg" ? ifaces.SVGSVGElement : SVGElement;
    return byTag[name] || HTMLElement;
  }
  // a link's URL, in parts (HTMLHyperlinkElementUtils)
  function urlParts(cls) {
    for (const k of ["protocol", "username", "password", "host", "hostname", "port", "pathname", "search", "hash", "origin"])
      Object.defineProperty(cls.prototype, k, { configurable: true, enumerable: true,
        get() { const h = this.href; if (!h) return ""; try { return new URL(h)[k]; } catch (e) { return ""; } },
        set(v) { if (k === "origin") return; const u = new URL(this.href || baseUrl()); u[k] = v; this.href = u.href; } });
    cls.prototype.toString = function () { return this.href; };
  }
  const relList = cls => Object.defineProperty(cls.prototype, "relList", { configurable: true,
    get() { return new ClassList(this, "rel"); } });
  const controlValue = cls => Object.defineProperty(cls.prototype, "value", { configurable: true, enumerable: true,
    get() { return D("value", this.__h)[0]; }, set(v) { D("setValue", this.__h, str(v)); } });
  const formOwner = cls => Object.defineProperty(cls.prototype, "form", { configurable: true,
    get() { const id = this.getAttribute("form"); return id ? g.document.getElementById(id) : this.closest("form"); } });
  const ref = ["referrerPolicy", "s", "referrerpolicy"], co = ["crossOrigin", "c", "crossorigin"];
  urlParts(iface("HTMLAnchorElement", ["A"], [["href", "u"], ["target", "s"], ["download", "s"], ["rel", "s"],
    ["hreflang", "s"], ["type", "s"], ["ping", "s"], ref]));
  Object.defineProperty(ifaces.HTMLAnchorElement.prototype, "text", { configurable: true,
    get() { return this.textContent; }, set(v) { this.textContent = v; } });
  relList(ifaces.HTMLAnchorElement);
  urlParts(iface("HTMLAreaElement", ["AREA"], [["href", "u"], ["target", "s"], ["download", "s"], ["rel", "s"],
    ["alt", "s"], ["coords", "s"], ["shape", "s"], ref]));
  relList(iface("HTMLLinkElement", ["LINK"], [["href", "u"], ["rel", "s"], ["media", "s"], ["hreflang", "s"],
    ["type", "s"], ["as", "s"], ["sizes", "s"], ["integrity", "s"], ["imageSrcset", "s", "imagesrcset"],
    ["imageSizes", "s", "imagesizes"], ["disabled", "b"], ["fetchPriority", "s", "fetchpriority"], co, ref]));
  iface("HTMLScriptElement", ["SCRIPT"], [["src", "u"], ["type", "s"], ["defer", "b"], ["noModule", "b", "nomodule"],
    ["integrity", "s"], ["charset", "s"], ["event", "s"], ["htmlFor", "s", "for"], co, ref]);
  Object.defineProperties(ifaces.HTMLScriptElement.prototype, {
    text: { configurable: true, get() { return this.textContent; }, set(v) { this.textContent = v; } },
    // a script made by a script is async unless told otherwise ("force async")
    async: { configurable: true, enumerable: true,
      get() { return this.hasAttribute("async") || (!!this.__made && this.__async !== false); },
      set(v) { this.__async = !!v; this.toggleAttribute("async", !!v); } } });
  ifaces.HTMLScriptElement.supports = t => t === "classic";
  iface("HTMLImageElement", ["IMG"], [["src", "u"], ["alt", "s"], ["srcset", "s"], ["sizes", "s"], ["useMap", "s", "usemap"],
    ["isMap", "b", "ismap"], ["loading", "e", null, [["lazy", "eager"], "eager", "eager"]],
    ["decoding", "e", null, [["sync", "async", "auto"], "auto", "auto"]], ["fetchPriority", "s", "fetchpriority"], co, ref]);
  Object.defineProperties(ifaces.HTMLImageElement.prototype, {
    width: { configurable: true, get() { const b = boxOf(this); return b ? b[2] : parseInt(this.getAttribute("width"), 10) || 0; },
             set(v) { this.setAttribute("width", String(v)); } },
    height: { configurable: true, get() { const b = boxOf(this); return b ? b[3] : parseInt(this.getAttribute("height"), 10) || 0; },
              set(v) { this.setAttribute("height", String(v)); } },
    currentSrc: { configurable: true, get() { return this.src; } },
    complete: { configurable: true, get() { return true; } },
    decode: { configurable: true, value() { return Promise.resolve(); } } });
  iface("HTMLIFrameElement", ["IFRAME"], [["src", "u"], ["srcdoc", "s"], ["name", "s"], ["allow", "s"],
    ["allowFullscreen", "b", "allowfullscreen"], ["width", "s"], ["height", "s"], ["loading", "s"], ref]);
  Object.defineProperties(ifaces.HTMLIFrameElement.prototype, {
    contentWindow: { configurable: true, get() { return this.__cw || (this.__cw = windowProxy("frame:" + this.__h)); } },
    contentDocument: { configurable: true, get() { return null; } } });
  const field = [["name", "s"], ["disabled", "b"], ["autocomplete", "s"], ["required", "b"], ["readOnly", "b", "readonly"],
    ["placeholder", "s"]];
  const input = iface("HTMLInputElement", ["INPUT"], field.concat([["accept", "s"], ["alt", "s"], ["src", "u"],
    ["defaultValue", "s", "value"], ["defaultChecked", "b", "checked"], ["max", "s"], ["min", "s"], ["step", "s"],
    ["maxLength", "n", "maxlength", -1], ["minLength", "n", "minlength", -1], ["multiple", "b"], ["pattern", "s"],
    ["size", "n", null, 20], ["inputMode", "s", "inputmode"],
    ["type", "e", null, [["hidden", "text", "search", "tel", "url", "email", "password", "date", "month", "week",
      "time", "datetime-local", "number", "range", "color", "checkbox", "radio", "file", "submit", "image", "reset",
      "button"], "text", "text"]]]));
  controlValue(input); formOwner(input);
  Object.defineProperty(input.prototype, "checked", { configurable: true, enumerable: true,
    get() { return D("checked", this.__h)[0] === "1"; }, set(v) { D("setChecked", this.__h, v ? "1" : "0"); } });
  input.prototype.select = function () {}; input.prototype.setSelectionRange = function () {};
  const textarea = iface("HTMLTextAreaElement", ["TEXTAREA"], field.concat([["rows", "n", null, 2], ["cols", "n", null, 20],
    ["maxLength", "n", "maxlength", -1], ["wrap", "s"]]));
  controlValue(textarea); formOwner(textarea);
  Object.defineProperty(textarea.prototype, "defaultValue", { configurable: true,
    get() { return this.textContent; }, set(v) { this.textContent = v; } });
  const button = iface("HTMLButtonElement", ["BUTTON"], [["name", "s"], ["disabled", "b"], ["value", "s"],
    ["formAction", "u", "formaction"], ["formMethod", "s", "formmethod"], ["formTarget", "s", "formtarget"],
    ["type", "e", null, [["submit", "reset", "button"], "submit", "submit"]]]);
  formOwner(button);
  const option = iface("HTMLOptionElement", ["OPTION"], [["disabled", "b"], ["label", "s"],
    ["defaultSelected", "b", "selected"]]);
  Object.defineProperties(option.prototype, {
    value: { configurable: true, enumerable: true,
      get() { const v = this.getAttribute("value"); return v === null ? this.text : v; },
      set(v) { this.setAttribute("value", v); } },
    text: { configurable: true, get() { return this.textContent.replace(/\s+/g, " ").trim(); },
            set(v) { this.textContent = v; } },
    selected: { configurable: true, get() { const s = this.closest("select"); return !!s && s.value === this.value; },
                set(v) { const s = this.closest("select"); if (s && v) s.value = this.value; } },
    index: { configurable: true, get() { const s = this.closest("select"); return s ? s.options.indexOf(this) : 0; } } });
  formOwner(option);
  const select = iface("HTMLSelectElement", ["SELECT"], [["name", "s"], ["disabled", "b"], ["required", "b"],
    ["multiple", "b"], ["size", "n", null, 0], ["autocomplete", "s"]]);
  controlValue(select); formOwner(select);
  Object.defineProperties(select.prototype, {
    options: { configurable: true, get() { return this.querySelectorAll("option"); } },
    length: { configurable: true, get() { return this.options.length; } },
    type: { configurable: true, get() { return this.multiple ? "select-multiple" : "select-one"; } },
    selectedIndex: { configurable: true,
      get() { const v = this.value; return this.options.findIndex(o => o.value === v); },
      set(i) { const o = this.options[i]; if (o) this.value = o.value; } },
    selectedOptions: { configurable: true, get() { return this.options.filter(o => o.selected); } } });
  select.prototype.item = function (i) { return this.options[i] || null; };
  const form = iface("HTMLFormElement", ["FORM"], [["action", "u", null, "document"], ["target", "s"], ["name", "s"],
    ["noValidate", "b", "novalidate"], ["acceptCharset", "s", "accept-charset"], ["autocomplete", "s"],
    ["method", "e", null, [["get", "post", "dialog"], "get", "get"]],
    ["enctype", "e", null, [["application/x-www-form-urlencoded", "multipart/form-data", "text/plain"],
      "application/x-www-form-urlencoded", "application/x-www-form-urlencoded"]]]);
  Object.defineProperties(form.prototype, {
    elements: { configurable: true, get() { return this.querySelectorAll("input, select, textarea, button, fieldset, output, object"); } },
    length: { configurable: true, get() { return this.elements.length; } } });
  form.prototype.checkValidity = form.prototype.reportValidity = function () { return true; };
  iface("HTMLFieldSetElement", ["FIELDSET"], [["disabled", "b"], ["name", "s"]]);
  iface("HTMLOutputElement", ["OUTPUT"], [["name", "s"], ["htmlFor", "s", "for"]]);
  iface("HTMLLabelElement", ["LABEL"], [["htmlFor", "s", "for"]]);
  Object.defineProperty(ifaces.HTMLLabelElement.prototype, "control", { configurable: true,
    get() { const f = this.htmlFor; return f ? g.document.getElementById(f) : this.querySelector("input, select, textarea, button"); } });
  iface("HTMLMetaElement", ["META"], [["name", "s"], ["content", "s"], ["httpEquiv", "s", "http-equiv"], ["media", "s"]]);
  iface("HTMLBaseElement", ["BASE"], [["href", "u", null, "document"], ["target", "s"]]);
  iface("HTMLStyleElement", ["STYLE"], [["media", "s"], ["type", "s"], ["disabled", "b"]]);
  iface("HTMLTitleElement", ["TITLE"]);
  Object.defineProperty(ifaces.HTMLTitleElement.prototype, "text", { configurable: true,
    get() { return this.textContent; }, set(v) { this.textContent = v; } });
  const media = iface("HTMLMediaElement", [], [["src", "u"], ["autoplay", "b"], ["loop", "b"], ["controls", "b"],
    ["defaultMuted", "b", "muted"], ["preload", "s"], co]);
  Object.assign(media.prototype, { play() { return Promise.resolve(); }, pause() {}, load() {}, canPlayType() { return ""; } });
  Object.defineProperties(media.prototype, { paused: { configurable: true, get() { return true; } },
    muted: { configurable: true, get() { return this.hasAttribute("muted"); }, set(v) {} } });
  iface("HTMLVideoElement", ["VIDEO"], [["poster", "u"], ["playsInline", "b", "playsinline"], ["width", "n"], ["height", "n"]], media);
  iface("HTMLAudioElement", ["AUDIO"], null, media);
  iface("HTMLSourceElement", ["SOURCE"], [["src", "u"], ["type", "s"], ["srcset", "s"], ["sizes", "s"], ["media", "s"]]);
  iface("HTMLCanvasElement", ["CANVAS"], [["width", "n", null, 300], ["height", "n", null, 150]]);
  Object.assign(ifaces.HTMLCanvasElement.prototype, { getContext() { return null; }, toDataURL() { return "data:,"; } });
  iface("HTMLTableCellElement", ["TD", "TH"], [["colSpan", "n", "colspan", 1], ["rowSpan", "n", "rowspan", 1],
    ["headers", "s"], ["scope", "s"], ["abbr", "s"]]);
  iface("HTMLTableElement", ["TABLE"]);
  iface("HTMLTableRowElement", ["TR"]);
  iface("HTMLTableSectionElement", ["TBODY", "THEAD", "TFOOT"]);
  iface("HTMLOListElement", ["OL"], [["start", "n", null, 1], ["reversed", "b"], ["type", "s"]]);
  iface("HTMLUListElement", ["UL"]);
  iface("HTMLLIElement", ["LI"], [["value", "n"]]);
  iface("HTMLDetailsElement", ["DETAILS"], [["open", "b"], ["name", "s"]]);
  iface("HTMLDialogElement", ["DIALOG"], [["open", "b"]]);
  Object.assign(ifaces.HTMLDialogElement.prototype, {
    show() { this.open = true; }, showModal() { this.open = true; },
    close(v) { if (this.open) { this.open = false; if (v !== undefined) this.returnValue = String(v); this.dispatchEvent(new Event("close")); } } });
  iface("HTMLTemplateElement", ["TEMPLATE"]);
  iface("HTMLObjectElement", ["OBJECT"], [["data", "u"], ["type", "s"], ["name", "s"], ["width", "s"], ["height", "s"]]);
  iface("HTMLEmbedElement", ["EMBED"], [["src", "u"], ["type", "s"], ["width", "s"], ["height", "s"]]);
  iface("HTMLDataElement", ["DATA"], [["value", "s"]]);
  iface("HTMLTimeElement", ["TIME"], [["dateTime", "s", "datetime"]]);
  iface("HTMLQuoteElement", ["Q", "BLOCKQUOTE"], [["cite", "u"]]);
  iface("HTMLModElement", ["INS", "DEL"], [["cite", "u"], ["dateTime", "s", "datetime"]]);
  for (const [n, tags] of [["HTMLDivElement", ["DIV"]], ["HTMLSpanElement", ["SPAN"]], ["HTMLParagraphElement", ["P"]],
       ["HTMLHeadingElement", ["H1", "H2", "H3", "H4", "H5", "H6"]], ["HTMLBodyElement", ["BODY"]],
       ["HTMLHtmlElement", ["HTML"]], ["HTMLHeadElement", ["HEAD"]], ["HTMLPreElement", ["PRE", "LISTING", "XMP"]],
       ["HTMLBRElement", ["BR"]], ["HTMLHRElement", ["HR"]], ["HTMLPictureElement", ["PICTURE"]],
       ["HTMLDListElement", ["DL"]], ["HTMLMenuElement", ["MENU"]], ["HTMLMapElement", ["MAP"]],
       ["HTMLOptGroupElement", ["OPTGROUP"]], ["HTMLProgressElement", ["PROGRESS"]], ["HTMLMeterElement", ["METER"]],
       ["HTMLSlotElement", ["SLOT"]], ["HTMLTableCaptionElement", ["CAPTION"]], ["HTMLTableColElement", ["COL", "COLGROUP"]],
       ["HTMLUnknownElement", []]])
    iface(n, tags);
  // another frame's window (each frame is a context of its own): what a
  // cross-origin window offers, postMessage (the data as JSON: the
  // structured clone's plain values); Ariadne carries it
  function windowProxy(target) {
    const w = {
      postMessage(data, targetOrigin) {
        const o = targetOrigin && typeof targetOrigin === "object" ? targetOrigin.targetOrigin : targetOrigin;
        let json;
        try { json = JSON.stringify(data === undefined ? null : data); }
        catch (e) { throw new g.DOMException("postMessage: the data cannot be cloned", "DataCloneError"); }
        D("postMessage", target, json === undefined ? "null" : json, o === undefined ? "/" : String(o));
      },
      closed: false, focus() {}, blur() {}, close() {},
      get length() { return 0; }
    };
    w.window = w.self = w.frames = w;
    return w;
  }
  // MessageChannel (the HTML Standard): two entangled ports in this
  // context; a message reaches the other port soon (a task), once it is
  // started (start(), or setting onmessage); ports are not carried to
  // other frames yet
  class MessagePort extends EventTarget {
    constructor() { super(); this.__other = null; this.__started = false; this.__queue = []; this.__onmessage = null; this.__closed = false; }
    get onmessage() { return this.__onmessage; }
    set onmessage(f) { this.__onmessage = f; this.start(); }
    postMessage(data) {
      const to = this.__other;
      if (!to || this.__closed || to.__closed) return;
      let copy;
      try { copy = data === undefined ? undefined : JSON.parse(JSON.stringify(data)); }
      catch (e) { throw new g.DOMException("postMessage: the data cannot be cloned", "DataCloneError"); }
      to.__queue.push(copy);
      if (to.__started) to.__flush();
    }
    start() { if (!this.__started) { this.__started = true; this.__flush(); } }
    close() { this.__closed = true; }
    __flush() {
      if (!this.__queue.length || this.__scheduled) return;
      this.__scheduled = true;
      g.setTimeout(() => {
        this.__scheduled = false;
        const q = this.__queue; this.__queue = [];
        for (const data of q) {
          if (this.__closed) break;
          // its listeners, and onmessage (dispatchEvent calls it)
          this.dispatchEvent(new MessageEvent("message", { data }));
        }
      }, 0);
    }
  }
  class MessageChannel {
    constructor() {
      this.port1 = new MessagePort(); this.port2 = new MessagePort();
      this.port1.__other = this.port2; this.port2.__other = this.port1;
    }
  }
  g.MessageChannel = MessageChannel; g.MessagePort = MessagePort;
  // posted to this window itself: a message event, soon
  g.postMessage = function (data, targetOrigin) {
    const e = new MessageEvent("message", { data, origin: g.location.origin, source: g });
    g.setTimeout(() => g.dispatchEvent(e), 0);
  };
  // a message from another frame: [source] "parent", "top", or
  // "frame:" + the iframe's handle here
  g.__message = function (data, origin, source) {
    let src = null;
    if (source === "parent") src = g.parent;
    else if (source === "top") src = g.top;
    else if (source.startsWith("frame:")) {
      const el = wrap(source.slice(6), 1, "IFRAME");
      src = el.contentWindow;
    }
    g.dispatchEvent(new MessageEvent("message", { data: JSON.parse(data), origin, source: src }));
  };

  // the legacy constructors (named constructors): Image, Option, Audio
  g.Image = function Image(width, height) {
    const img = g.document.createElement("img");
    if (width !== undefined) img.setAttribute("width", String(width));
    if (height !== undefined) img.setAttribute("height", String(height));
    return img;
  };
  g.Image.prototype = ifaces.HTMLImageElement.prototype;
  g.Option = function Option(text, value, defaultSelected, selected) {
    const o = g.document.createElement("option");
    if (text !== undefined && text !== "") o.textContent = String(text);
    if (value !== undefined) o.setAttribute("value", String(value));
    if (defaultSelected) o.setAttribute("selected", "");
    if (selected) o.__selected = true;
    return o;
  };
  g.Option.prototype = option.prototype;
  g.Audio = function Audio(src) {
    const a = g.document.createElement("audio");
    a.setAttribute("preload", "auto");
    if (src !== undefined) a.setAttribute("src", String(src));
    return a;
  };
  g.Audio.prototype = ifaces.HTMLAudioElement.prototype;
  ifaces.SVGSVGElement = ({ SVGSVGElement: class extends SVGElement {} }).SVGSVGElement;
  ifaces.SVGGraphicsElement = SVGElement;
  // an SVG element's href (SVGAnimatedString), href or xlink:href
  Object.defineProperty(SVGElement.prototype, "href", { configurable: true,
    get() { const v = this.getAttribute("href") ?? this.getAttribute("xlink:href") ?? ""; return { baseVal: v, animVal: v }; } });

  class ResizeObserver { constructor() {} observe() {} unobserve() {} disconnect() {} }
  class MutationObserver { constructor() {} observe() {} disconnect() {} takeRecords() { return []; } }
  g.IntersectionObserver = IntersectionObserver; g.ResizeObserver = ResizeObserver; g.MutationObserver = MutationObserver;
  g.Headers = Headers; g.Response = Response; g.XMLHttpRequest = XMLHttpRequest;
  g.URLSearchParams = URLSearchParams; g.FormData = FormData; g.AbortController = AbortController; g.AbortSignal = AbortSignal;

  g.window = g; g.self = g; g.top = g; g.parent = g; g.frames = g;
  Object.setPrototypeOf(g, EventTarget.prototype);
  // the window's methods called bare (addEventListener("load", ...) at a
  // script's top level): the window is their this, as in browsers
  for (const k of ["addEventListener", "removeEventListener", "dispatchEvent"]) {
    const f = EventTarget.prototype[k];
    g[k] = function (...a) { return f.apply(this === undefined || this === null ? g : this, a); };
  }
  g.Node = Node; g.Element = Element; g.Text = Text; g.Document = Document;
  for (const k in ifaces) g[k] = ifaces[k];
  g.EventTarget = EventTarget; g.Event = Event; g.CustomEvent = CustomEvent; g.MessageEvent = MessageEvent; g.DOMRect = DOMRect;
  g.navigator = { userAgent: "Mozilla/5.0 (MyNOS) Ariadne/0.1", language: "en", languages: ["en"], platform: "MyNOS",
                  cookieEnabled: true, onLine: true };
  g.devicePixelRatio = 1;
  for (const [k, f] of [["innerWidth", v => v.w], ["innerHeight", v => v.h], ["outerWidth", v => v.w],
                        ["outerHeight", v => v.h], ["scrollX", v => v.sx], ["scrollY", v => v.sy],
                        ["pageXOffset", v => v.sx], ["pageYOffset", v => v.sy]])
    Object.defineProperty(g, k, { get: () => f(view()), configurable: true });
  g.screen = { get width() { return view().w; }, get height() { return view().h; },
               get availWidth() { return view().w; }, get availHeight() { return view().h; } };
  // getComputedStyle: the cascade's computed values (the browser's)
  g.getComputedStyle = el => new Proxy({}, {
    get(_, k) {
      if (typeof k !== "string") return undefined;
      if (k === "getPropertyValue") return p => D("computed", el.__h, String(p))[0];
      return D("computed", el.__h, camelToKebab(k))[0];
    }
  });
  g.matchMedia = q => ({ matches: false, media: q, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  g.localStorage = g.sessionStorage = (function () {
    const m = new Map();
    return { getItem: k => m.has(String(k)) ? m.get(String(k)) : null, setItem: (k, v) => m.set(String(k), String(v)),
             removeItem: k => m.delete(String(k)), clear: () => m.clear(), key: i => [...m.keys()][i] || null,
             get length() { return m.size; } };
  })();
  g.alert = m => console.log("alert: " + m);
  g.confirm = () => false; g.prompt = () => null;
  g.scrollTo = g.scroll = function (x, y) {
    if (typeof x === "object" && x) { y = x.top; x = x.left; }
    D("scrollTo", String(Math.round(+x || 0)), String(Math.round(+y || 0)));
  };
  g.scrollBy = function (dx, dy) {
    if (typeof dx === "object" && dx) { dy = dx.top; dx = dx.left; }
    const v = view(); g.scrollTo(v.sx + (+dx || 0), v.sy + (+dy || 0));
  };
  g.__readyState = "loading";

  g.__init = function (url, width, height, sid, framed) {
    g.__sid = String(sid);
    // in a frame: its parent and the top, other contexts (their proxies)
    if (framed) {
      g.parent = windowProxy("parent"); g.top = windowProxy("top");
      g.frameElement = null;
    }
    // Location (the HTML Standard): its URL, and navigating: Ariadne goes
    // there after this run (navigation is asynchronous); a change of the
    // fragment alone stays in the page (a scroll, hashchange)
    let here = new URL(url);
    const navigate = (to, replace) => {
      const u = new URL(String(to), (g.document && g.document.baseURI) || here.href);
      const same = u.href.split("#")[0] === here.href.split("#")[0];
      if (same && u.href.includes("#")) {
        const old = here.href;
        here = u;
        const id = decodeURIComponent(u.hash.slice(1));
        const el = id && (g.document.getElementById(id) || g.document.querySelector("a[name=\"" + id.replace(/"/g, "") + "\"]"));
        if (el) el.scrollIntoView(); else if (id === "" || id === "top") g.scrollTo(0, 0);
        const e = new Event("hashchange"); e.oldURL = old; e.newURL = u.href;
        g.setTimeout(() => g.dispatchEvent(e), 0);
        return;
      }
      D("navigate", u.href, replace ? "1" : "0");
    };
    class Location {
      get href() { return here.href; } set href(v) { navigate(v, false); }
      assign(v) { navigate(v, false); }
      replace(v) { navigate(v, true); }
      reload() { D("navigate", here.href, "1"); }
      toString() { return here.href; }
      get origin() { return here.origin; }
      get ancestorOrigins() { return []; }
    }
    for (const k of ["protocol", "host", "hostname", "port", "pathname", "search", "hash"])
      Object.defineProperty(Location.prototype, k, { enumerable: true, configurable: true,
        get() { return here[k]; },
        set(v) { const u = new URL(here.href); u[k] = v; navigate(u.href, false); } });
    const loc = new Location();
    Object.defineProperty(g, "location", { configurable: true, enumerable: true,
      get() { return loc; }, set(v) { navigate(v, false); } });
    g.Location = Location;
    g.document = one(D("document"));
    // the page's own scripts: Ariadne runs them
    markStarted(g.document);
  };
  // an event from the user (Ariadne): whether its default action stays
  g.__event = function (h, type, name, what) {
    const n = wrap(h, type, name);
    const ev = new Event(what, { bubbles: what !== "load", cancelable: what === "click" || what === "submit" });
    return n.dispatchEvent(ev);
  };
  // the document's readiness (the HTML Standard's "the end"): interactive
  // (readystatechange, then DOMContentLoaded), complete (readystatechange,
  // then the window's load)
  g.__afterScripts = function () {
    g.__readyState = "interactive";
    g.document.dispatchEvent(new Event("readystatechange"));
    g.document.dispatchEvent(new Event("DOMContentLoaded", { bubbles: true }));
    g.__readyState = "complete";
    g.document.dispatchEvent(new Event("readystatechange"));
    g.dispatchEvent(new Event("load"));
  };
})();
|js}

(* URL: QuickJS has none (it is the browser's): a small one, for the
   prelude's location and links *)
let url_polyfill = {js|
(function () {
  if (typeof globalThis.URL === "function") return;
  function parse(s) {
    const m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(?:\/\/([^\/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(s);
    if (!m) throw new TypeError("Invalid URL: " + s);
    const auth = m[2] || "", at = auth.lastIndexOf("@"), hp = at >= 0 ? auth.slice(at + 1) : auth;
    const c = hp.lastIndexOf(":");
    return { protocol: m[1].toLowerCase(), host: hp, hostname: c >= 0 ? hp.slice(0, c) : hp, port: c >= 0 ? hp.slice(c + 1) : "",
             pathname: m[3] || (m[2] !== undefined ? "/" : ""), search: m[4] || "", hash: m[5] || "", hasAuthority: m[2] !== undefined };
  }
  function dots(path) {
    const out = [];
    for (const seg of path.split("/")) {
      if (seg === "..") { if (out.length > 1) out.pop(); } else if (seg !== ".") out.push(seg);
    }
    let p = out.join("/");
    if (path.endsWith("/.") || path.endsWith("/..")) p += "/";
    return p;
  }
  class URL {
    constructor(s, base) {
      s = String(s).trim();
      let u;
      if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(s)) u = parse(s);
      else {
        if (base === undefined) throw new TypeError("Invalid URL: " + s);
        const b = parse(String(base));
        if (s.startsWith("//")) u = parse(b.protocol + s);
        else if (s.startsWith("/")) u = parse(b.protocol + "//" + b.host + s);
        else if (s.startsWith("?")) u = Object.assign({}, b, { search: s.replace(/#.*$/, ""), hash: (s.match(/#.*$/) || [""])[0] });
        else if (s.startsWith("#")) u = Object.assign({}, b, { hash: s });
        else if (s === "") u = Object.assign({}, b, { hash: "" });
        else {
          const dir = b.pathname.replace(/[^\/]*$/, "");
          u = parse(b.protocol + "//" + b.host + dir + s);
        }
      }
      if (u.hasAuthority !== false) u.pathname = dots(u.pathname || "/");
      Object.assign(this, u);
    }
    get origin() { return this.protocol + "//" + this.host; }
    get href() { return this.protocol + (this.hasAuthority === false ? "" : "//" + this.host) + this.pathname + this.search + this.hash; }
    toString() { return this.href; }
    toJSON() { return this.href; }
    get searchParams() {
      const q = this.search.replace(/^\?/, "");
      const pairs = q ? q.split("&").map(p => p.split("=").map(x => decodeURIComponent(x.replace(/\+/g, " ")))) : [];
      return { get: k => { const p = pairs.find(p => p[0] === k); return p ? (p[1] || "") : null; },
               has: k => pairs.some(p => p[0] === k), getAll: k => pairs.filter(p => p[0] === k).map(p => p[1] || ""),
               toString: () => q };
    }
  }
  globalThis.URL = URL;
})();
|js}
