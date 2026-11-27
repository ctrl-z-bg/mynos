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
    o = type === 1 ? new Element(h, type, name)
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
    appendChild(c) { D("insert", this.__h, c.__h, ""); return c; }
    insertBefore(c, ref) { D("insert", this.__h, c.__h, ref ? ref.__h : ""); return c; }
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
    constructor(el) { this.el = el; }
    get __all() { return (this.el.getAttribute("class") || "").split(/\s+/).filter(Boolean); }
    __set(l) { this.el.setAttribute("class", l.join(" ")); }
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
    get href() { const h = this.getAttribute("href"); return h === null ? "" : new URL(h, g.location.href).href; }
    set href(v) { this.setAttribute("href", v); }
    get src() { const s = this.getAttribute("src"); return s === null ? "" : new URL(s, g.location.href).href; }
    set src(v) { this.setAttribute("src", v); }
    get children() { return list(D("elements", this.__h)); }
    get childElementCount() { return this.children.length; }
    get firstElementChild() { return this.children[0] || null; }
    get lastElementChild() { const c = this.children; return c[c.length - 1] || null; }
    get nextElementSibling() { let n = this.nextSibling; while (n && n.nodeType !== 1) n = n.nextSibling; return n; }
    get previousElementSibling() { let n = this.previousSibling; while (n && n.nodeType !== 1) n = n.previousSibling; return n; }
    get innerHTML() { return D("html", this.__h)[0]; } set innerHTML(v) { D("setHtml", this.__h, str(v)); }
    get outerHTML() { return D("outerHtml", this.__h)[0]; }
    set outerHTML(v) { this.insertAdjacentHTML("beforebegin", v); this.remove(); }
    get innerText() { return this.textContent; } set innerText(v) { this.textContent = v; }
    insertAdjacentHTML(w, s) { D("insertHtml", this.__h, w, str(s)); }
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
    get value() { return D("value", this.__h)[0]; } set value(v) { D("setValue", this.__h, str(v)); }
    get checked() { return D("checked", this.__h)[0] === "1"; } set checked(v) { D("setChecked", this.__h, v ? "1" : "0"); }
    get disabled() { return this.hasAttribute("disabled"); } set disabled(v) { this.toggleAttribute("disabled", !!v); }
    get name() { return this.getAttribute("name") || ""; } set name(v) { this.setAttribute("name", v); }
    get type() { return (this.getAttribute("type") || "").toLowerCase(); } set type(v) { this.setAttribute("type", v); }
    get content() { return this; }   // a template's
    focus() {} blur() {}
    click() { this.dispatchEvent(new Event("click", { bubbles: true, cancelable: true })); }
    getBoundingClientRect() { return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }; }
    getClientRects() { return []; }
    get offsetWidth() { return 0; } get offsetHeight() { return 0; }
    get clientWidth() { return 0; } get clientHeight() { return 0; }
    scrollIntoView() {}
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
    createElement(t) { return one(D("create", str(t))); }
    createElementNS(ns, t) { return this.createElement(t); }
    createTextNode(s) { return one(D("createText", str(s))); }
    createComment(s) { return one(D("createComment", str(s))); }
    createDocumentFragment() { return one(D("createFragment")); }
    createEvent() { return new Event(""); }
    get readyState() { return g.__readyState; }
    get cookie() { return D("cookie")[0]; } set cookie(v) { D("setCookie", str(v)); }
    get referrer() { return ""; }
    get defaultView() { return g; }
    get location() { return g.location; }
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
  g.__runTimers = function (ms) {
    const until = now + ms;
    let n = 0;
    while (n < 1000) {
      timers.sort((a, b) => a.at - b.at || a.id - b.id);
      const t = timers[0];
      if (!t || t.at > until) break;
      now = Math.max(now, t.at);
      if (t.every) t.at = now + t.every; else timers.shift();
      try { typeof t.f === "function" ? t.f(...t.a) : (0, eval)(String(t.f)); }
      catch (e) { console.error(String(e) + (e && e.stack ? "\n" + e.stack : "")); }
      n++;
    }
    now = until;
    return timers.length;
  };

  g.window = g; g.self = g; g.top = g; g.parent = g; g.frames = g;
  Object.setPrototypeOf(g, EventTarget.prototype);
  g.Node = Node; g.Element = Element; g.HTMLElement = Element; g.Text = Text; g.Document = Document;
  g.EventTarget = EventTarget; g.Event = Event; g.CustomEvent = CustomEvent;
  g.navigator = { userAgent: "Mozilla/5.0 (MyNOS) Ariadne/0.1", language: "en", languages: ["en"], platform: "MyNOS",
                  cookieEnabled: true, onLine: true };
  g.innerWidth = 878; g.innerHeight = 600; g.devicePixelRatio = 1;
  g.screen = { width: 1024, height: 768 };
  g.getComputedStyle = el => el.style;
  g.matchMedia = q => ({ matches: false, media: q, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
  g.localStorage = g.sessionStorage = (function () {
    const m = new Map();
    return { getItem: k => m.has(String(k)) ? m.get(String(k)) : null, setItem: (k, v) => m.set(String(k), String(v)),
             removeItem: k => m.delete(String(k)), clear: () => m.clear(), key: i => [...m.keys()][i] || null,
             get length() { return m.size; } };
  })();
  g.alert = m => console.log("alert: " + m);
  g.confirm = () => false; g.prompt = () => null;
  g.scrollTo = g.scroll = g.scrollBy = () => {};
  g.__readyState = "loading";

  g.__init = function (url, width, height, sid) {
    g.__sid = String(sid);
    g.innerWidth = width; g.innerHeight = height;
    const u = new URL(url);
    g.location = {
      href: u.href, protocol: u.protocol, host: u.host, hostname: u.hostname, port: u.port,
      pathname: u.pathname, search: u.search, hash: u.hash, origin: u.origin,
      toString() { return this.href; }, assign() {}, replace() {}, reload() {}
    };
    g.document = one(D("document"));
  };
  // an event from the user (Ariadne): whether its default action stays
  g.__event = function (h, type, name, what) {
    const n = wrap(h, type, name);
    const ev = new Event(what, { bubbles: what !== "load", cancelable: what === "click" || what === "submit" });
    return n.dispatchEvent(ev);
  };
  g.__afterScripts = function () {
    g.__readyState = "interactive";
    g.document.dispatchEvent(new Event("DOMContentLoaded", { bubbles: true }));
    g.__readyState = "complete";
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
