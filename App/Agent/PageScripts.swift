import Foundation

/// JavaScript that runs inside Wink's private isolated world (see CDPSession).
/// It shares the DOM with the page but not its JavaScript globals, so pages
/// cannot observe or tamper with the agent. CDPSession installs it once per
/// execution context and re-installs it after navigations.
enum PageScripts {
    static let version = 6

    static let library = #"""
    (() => {
      if (globalThis.__wink && globalThis.__wink.v === 6) return;
      const W = { v: 6 };
      globalThis.__wink = W;
      let nextRef = 1;
      const refToEl = new Map();
      const elToRef = new WeakMap();

      const clean = (s, max = 120) => {
        s = String(s ?? '').replace(/\s+/g, ' ').trim();
        return s.length > max ? s.slice(0, max - 1) + '…' : s;
      };
      const quote = (s) => String(s).replace(/"/g, "'");
      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'META', 'LINK', 'HEAD', 'svg', 'SVG', 'PATH', 'OBJECT']);
      const INTERACTIVE = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox',
        'listbox', 'option', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'tab', 'switch', 'slider',
        'spinbutton', 'treeitem', 'clickable']);
      const STRUCTURE = new Set(['heading', 'banner', 'navigation', 'main', 'complementary', 'contentinfo',
        'form', 'dialog', 'alertdialog', 'region', 'article', 'list', 'table', 'img', 'iframe', 'alert', 'status', 'menu', 'tablist', 'search']);

      // A ref remembers what it pointed at (role + name), so when a page
      // re-renders (React and friends replace nodes all the time) the ref
      // follows the element instead of going stale.
      const refSig = new Map();
      W.refFor = (el, role, name) => {
        let r = elToRef.get(el);
        if (!r) { r = 'e' + (nextRef++); elToRef.set(el, r); }
        refToEl.set(r, new WeakRef(el));
        if (role && !refSig.has(r)) refSig.set(r, { role, name: name || '' });
        return r;
      };
      const rebind = (ref, el) => { elToRef.set(el, ref); refToEl.set(ref, new WeakRef(el)); };
      const ROLE_SELECTOR = {
        button: 'button,[role=button],input[type=submit],input[type=button],input[type=reset],input[type=image],input[type=file],summary',
        link: 'a[href],[role=link]', checkbox: 'input[type=checkbox],[role=checkbox]', radio: 'input[type=radio],[role=radio]',
        textbox: 'input,textarea,[contenteditable],[role=textbox]', searchbox: 'input,[role=searchbox]',
        combobox: 'select,input,[role=combobox]', option: 'option,[role=option]', tab: '[role=tab]', switch: '[role=switch]',
        menuitem: '[role=menuitem]', heading: 'h1,h2,h3,h4,h5,h6,[role=heading]',
      };
      // Live elements with this role and name (a ref's signature).
      const matching = (sig, root = document) => {
        const out = [];
        for (const el of root.querySelectorAll(ROLE_SELECTOR[sig.role] || '*')) {
          if (roleOf(el) !== sig.role || !visible(el)) continue;
          if (nameOf(el, sig.role) === sig.name) out.push(el);
          if (out.length > 3) break;
        }
        return out;
      };
      W.el = (ref) => {
        const key = String(ref).replace(/^\[?(ref=)?/, '').replace(/\]$/, '');
        const w = refToEl.get(key);
        const el = w && w.deref();
        if (el && el.isConnected) return el;
        const sig = refSig.get(key);
        if (sig && sig.name) {
          const found = matching(sig);
          if (found.length === 1) { rebind(key, found[0]); return found[0]; }
        }
        throw new Error(`Element ${key} is no longer on the page. Call find or snapshot for fresh refs.`);
      };

      const visible = (el) => {
        if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) {
          return getComputedStyle(el).display === 'contents';
        }
        return true;
      };
      const isSensitive = (el) => {
        const hint = `${el.type || ''} ${el.autocomplete || ''} ${el.name || ''} ${el.id || ''}`.toLowerCase();
        return el.type === 'password' || /cc-|card|cvc|cvv|iban|password|one-time-code|otp|ssn/.test(hint);
      };
      const isEditable = (el) => el.isContentEditable ||
        (el.tagName === 'TEXTAREA') ||
        (el.tagName === 'INPUT' && !['button', 'submit', 'reset', 'checkbox', 'radio', 'range', 'file', 'image', 'color', 'hidden'].includes(el.type));

      const roleOf = (el) => {
        const explicit = (el.getAttribute('role') || '').split(' ')[0];
        if (explicit && explicit !== 'presentation' && explicit !== 'none' && explicit !== 'generic') return explicit;
        const tag = el.tagName;
        switch (tag) {
          case 'A': return el.hasAttribute('href') ? 'link' : null;
          case 'BUTTON': case 'SUMMARY': return 'button';
          case 'INPUT': {
            const t = (el.type || 'text').toLowerCase();
            if (t === 'hidden') return null;
            if (['button', 'submit', 'reset', 'image', 'file'].includes(t)) return 'button';
            if (t === 'checkbox') return 'checkbox';
            if (t === 'radio') return 'radio';
            if (t === 'range') return 'slider';
            if (t === 'number') return 'spinbutton';
            if (t === 'search') return 'searchbox';
            return 'textbox';
          }
          case 'TEXTAREA': return 'textbox';
          case 'SELECT': return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
          case 'OPTION': return 'option';
          case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
          case 'IMG': return (el.alt || '').trim() ? 'img' : null;
          case 'NAV': return 'navigation';
          case 'MAIN': return 'main';
          case 'ASIDE': return 'complementary';
          case 'HEADER': return el.closest('article,section,main') ? null : 'banner';
          case 'FOOTER': return el.closest('article,section,main') ? null : 'contentinfo';
          case 'FORM': return 'form';
          case 'DIALOG': return el.open ? 'dialog' : null;
          case 'ARTICLE': return 'article';
          case 'TABLE': return 'table';
          case 'UL': case 'OL': return 'list';
          case 'IFRAME': return 'iframe';
          // A styled "Choose file" label over a hidden file input acts as its button.
          case 'LABEL': if (el.control && el.control.type === 'file') return 'button'; break;
        }
        if (el.isContentEditable && el.getAttribute('contenteditable') !== null) return 'textbox';
        if (el.hasAttribute('onclick') || (el.tabIndex >= 0 && el.hasAttribute('tabindex')) || el.getAttribute('draggable') === 'true') return 'clickable';
        if ((tag === 'DIV' || tag === 'SPAN' || tag === 'LI') && el.childElementCount < 6) {
          const style = getComputedStyle(el);
          if (style.cursor === 'pointer' && !(el.parentElement && getComputedStyle(el.parentElement).cursor === 'pointer')) return 'clickable';
        }
        return null;
      };

      const nameOf = (el, role) => {
        const doc = el.ownerDocument;
        const labelledby = el.getAttribute('aria-labelledby');
        if (labelledby) {
          const t = labelledby.split(/\s+/).map(id => doc.getElementById(id)?.innerText || '').join(' ');
          if (clean(t)) return clean(t);
        }
        const aria = el.getAttribute('aria-label');
        if (aria && aria.trim()) return clean(aria);
        const tag = el.tagName;
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
          if (el.id) {
            const label = doc.querySelector(`label[for="${CSS.escape(el.id)}"]`);
            if (label && clean(label.innerText)) return clean(label.innerText);
          }
          const wrapping = el.closest('label');
          if (wrapping) {
            // The label's own words, not the control's (a <select>'s options).
            let text = '';
            const walk = (n) => {
              if (n === el) return;
              if (n.nodeType === 3) text += n.textContent;
              else if (n.nodeType === 1 && !SKIP.has(n.tagName)) { for (const c of n.childNodes) walk(c); if (getComputedStyle(n).display === 'block') text += ' '; }
            };
            walk(wrapping);
            if (clean(text)) return clean(text);
          }
          if (['submit', 'button', 'reset'].includes(el.type) && el.value) return clean(el.value);
          if (el.placeholder) return clean(el.placeholder);
          if (el.title) return clean(el.title);
          return clean(el.name || '');
        }
        if (tag === 'IMG') return clean(el.alt || el.title);
        if (role === 'heading' || role === 'link' || role === 'button' || INTERACTIVE.has(role)) {
          const text = clean(el.innerText || el.textContent, 100);
          if (text) return text;
          const img = el.querySelector('img[alt]');
          if (img && img.alt.trim()) return clean(img.alt);
          const svgTitle = el.querySelector('svg title');
          if (svgTitle) return clean(svgTitle.textContent);
        }
        return clean(el.title || el.getAttribute('data-tooltip') || el.getAttribute('aria-description') ||
          el.getAttribute('aria-placeholder') || el.getAttribute('data-placeholder') || '');
      };

      const statesOf = (el, role) => {
        const s = [];
        if (role === 'heading') s.push('level=' + (Number(el.tagName[1]) || el.getAttribute('aria-level') || 2));
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') s.push('disabled');
        if (role === 'checkbox' || role === 'radio' || role === 'switch' || role === 'menuitemcheckbox') {
          const checked = typeof el.checked === 'boolean' ? el.checked : el.getAttribute('aria-checked') === 'true';
          s.push(checked ? 'checked' : 'unchecked');
        }
        const expanded = el.getAttribute('aria-expanded');
        if (expanded) s.push('expanded=' + expanded);
        if (el.getAttribute('aria-pressed') === 'true') s.push('pressed');
        if (el.getAttribute('aria-selected') === 'true' || (role === 'option' && el.selected)) s.push('selected');
        if (el.required || el.getAttribute('aria-required') === 'true') s.push('required');
        if (['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider'].includes(role)) {
          let value = el.isContentEditable ? el.innerText : el.value;
          if (role === 'combobox' && el.tagName === 'SELECT') value = el.options[el.selectedIndex]?.text;
          if (value) s.push(isSensitive(el) ? 'value=(hidden)' : `value="${clean(value, 80)}"`);
          if (isSensitive(el)) s.push('sensitive');
        }
        if (deepActive() === el) s.push('focused');
        return s;
      };

      const hrefOf = (el) => {
        const raw = el.getAttribute('href');
        if (!raw || raw.startsWith('javascript:')) return '';
        try {
          const u = new URL(raw, location.href);
          return clean(u.origin === location.origin ? (u.pathname + u.search + u.hash) : u.href, 90);
        } catch { return ''; }
      };

      const childrenOf = (el) => {
        if (el.tagName === 'SLOT') return el.assignedNodes({ flatten: true });
        if (el.shadowRoot) return Array.from(el.shadowRoot.childNodes);
        return Array.from(el.childNodes);
      };

      // One outline line for an interactive element.
      const describe = (el, role) => {
        role = role || roleOf(el) || el.tagName.toLowerCase();
        const name = nameOf(el, role);
        const states = statesOf(el, role);
        let line = `${role}${name ? ` "${quote(name)}"` : ''} [ref=${W.refFor(el, role, name)}]`;
        if (states.length) line += ' [' + states.join(', ') + ']';
        if (role === 'link') { const h = hrefOf(el); if (h) line += ' → ' + h; }
        if (role === 'combobox' && el.tagName === 'SELECT') {
          const opts = Array.from(el.options).slice(0, 12).map(o => clean(o.text, 30));
          line += ` options: ${opts.join(' | ')}${el.options.length > 12 ? ' | …' : ''}`;
        }
        return line;
      };

      const deepActive = () => {
        let el = document.activeElement;
        for (let i = 0; i < 8 && el; i++) {
          if (el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
          if (el.tagName === 'IFRAME') {
            try { const inner = el.contentDocument && el.contentDocument.activeElement; if (inner && inner !== el.contentDocument.body) { el = inner; continue; } } catch {}
          }
          break;
        }
        return el;
      };

      // Viewport rect in top-level CSS pixels (same-origin iframes included).
      const rectOf = (el) => {
        const r = el.getBoundingClientRect();
        let x = r.left, y = r.top;
        let win = el.ownerDocument.defaultView;
        while (win && win !== window && win.frameElement) {
          const fr = win.frameElement.getBoundingClientRect();
          x += fr.left; y += fr.top;
          win = win.parent;
        }
        return { x, y, width: r.width, height: r.height };
      };

      const interactiveAncestor = (el) => {
        for (let n = el, i = 0; n && n.nodeType === 1 && i < 7; n = n.parentElement || (n.getRootNode && n.getRootNode().host), i++) {
          const role = roleOf(n);
          if (role && INTERACTIVE.has(role)) return n;
        }
        return null;
      };

      const directText = (el) => {
        let t = '';
        for (const n of el.childNodes) if (n.nodeType === 3) t += n.textContent;
        return clean(t, 160);
      };
      const INLINE = new Set(['A', 'SPAN', 'CODE', 'EM', 'STRONG', 'B', 'I', 'U', 'S', 'SMALL', 'SUB', 'SUP', 'MARK',
        'ABBR', 'TIME', 'KBD', 'BR', 'IMG', 'LABEL', 'Q', 'CITE', 'DFN', 'VAR', 'SAMP', 'DATA', 'BDI', 'WBR', 'FONT']);
      // A block whose children are all inline (a paragraph with links/code):
      // describe it as one line of text instead of fragments.
      const inlineOnly = (el) => {
        if (!directText(el)) return false;
        for (const c of el.children) if (!INLINE.has(c.tagName)) return false;
        return true;
      };

      W.snapshot = (opts = {}) => {
        const maxLines = opts.maxLines || 500;
        const viewportOnly = !!opts.viewportOnly;
        const lines = [];
        let truncated = false;
        let lastText = '';
        const vh = innerHeight;

        const emit = (depth, text) => {
          if (lines.length >= maxLines) { truncated = true; return false; }
          lines.push('  '.repeat(depth) + '- ' + text);
          return true;
        };

        const visit = (node, depth, doc, quiet = false) => {
          if (truncated || node.nodeType !== 1) return;
          const el = node;
          if (SKIP.has(el.tagName) || el.getAttribute('aria-hidden') === 'true' || el.hidden || el.inert) return;
          if (!visible(el)) return;
          const role = roleOf(el);
          if (viewportOnly && role && doc === document) {
            const r = el.getBoundingClientRect();
            if (r.bottom < 0 || r.top > vh) {
              if (INTERACTIVE.has(role) || role === 'heading' || role === 'img') return;
            }
          }
          if (role && INTERACTIVE.has(role)) {
            emit(depth, describe(el, role));
            if (role === 'listbox' || role === 'menu' || role === 'clickable' && el.childElementCount > 3) {
              for (const c of childrenOf(el)) visit(c, depth + 1, doc);
            }
            return;
          }
          if (role === 'iframe') {
            let inner = null;
            try { inner = el.contentDocument; } catch {}
            if (inner && inner.body) {
              if (!emit(depth, `iframe "${clean(el.title || el.name || '', 60)}"`)) return;
              for (const c of inner.body.childNodes) visit(c, depth + 1, inner);
            } else {
              emit(depth, `iframe (cross-origin) ${clean(el.src, 80)}`);
            }
            return;
          }
          let childDepth = depth;
          if (role && STRUCTURE.has(role)) {
            const name = role === 'list' || role === 'table' ? '' : nameOf(el, role);
            if (role === 'heading') {
              if (name) emit(depth, `heading "${quote(name)}" [${statesOf(el, role).join(', ')}]`);
              return;
            }
            if (role === 'img') { if (name) emit(depth, `img "${name}"`); return; }
            if (!emit(depth, role + (name ? ` "${clean(name, 60)}"` : ''))) return;
            childDepth = depth + 1;
          } else if (!quiet) {
            const whole = inlineOnly(el);
            const text = whole ? clean(el.innerText, 220) : directText(el);
            if (text.length > 1 && text !== lastText) {
              lastText = text;
              if (!emit(depth, `text "${quote(text)}"`)) return;
            }
            if (whole) quiet = true;  // children only add refs, not text again
          }
          for (const c of childrenOf(el)) visit(c, childDepth, doc, quiet);
        };

        visit(document.body || document.documentElement, 0, document);
        const se = document.scrollingElement || document.documentElement;
        const header = [
          `Page: ${clean(document.title, 120)}`,
          `URL: ${location.href}`,
          `Scroll: ${Math.round(scrollY)}px of ${se.scrollHeight}px (viewport ${innerWidth}×${innerHeight})`,
          '',
        ];
        if (truncated) lines.push(`… (truncated at ${maxLines} lines — use find to locate specific elements, viewport_only, or read_page for text)`);
        if (lines.length === 0) lines.push('(no visible content)');
        return header.concat(lines).join('\n');
      };

      W.read = (maxChars = 20000, match = '') => {
        if (match) return W.grep(maxChars, match);
        const root = document.querySelector('main, article, [role=main]') || document.body;
        const out = [];
        let len = 0;
        const push = (s) => { if (len <= maxChars) { out.push(s); len += s.length + 1; } };
        const abs = (u) => { try { return new URL(u, location.href).href; } catch { return u; } };
        const BLOCK = new Set(['DIV', 'SECTION', 'ARTICLE', 'MAIN', 'P', 'UL', 'OL', 'TABLE', 'H1', 'H2', 'H3', 'H4',
          'H5', 'H6', 'PRE', 'BLOCKQUOTE', 'FORM', 'HEADER', 'FOOTER', 'NAV', 'ASIDE', 'FIGURE', 'DL', 'DETAILS', 'LI', 'HR', 'FIELDSET']);
        const inline = (node) => {
          if (node.nodeType === 3) return node.textContent.replace(/\s+/g, ' ');
          if (node.nodeType !== 1) return '';
          const el = node;
          if (SKIP.has(el.tagName) || el.getAttribute('aria-hidden') === 'true' || !visible(el)) return '';
          const tag = el.tagName;
          const inner = () => childrenOf(el).map(inline).join('');
          if (tag === 'BR') return '\n';
          if (tag === 'A') {
            const t = inner().trim();
            const href = el.getAttribute('href');
            return t && href && !href.startsWith('javascript:') ? `[${t}](${abs(href)})` : t;
          }
          if (tag === 'IMG') return el.alt ? `![${clean(el.alt, 80)}]` : '';
          if (tag === 'CODE' || tag === 'KBD') return '`' + el.textContent + '`';
          if (tag === 'STRONG' || tag === 'B') { const t = inner().trim(); return t ? `**${t}**` : ''; }
          if (tag === 'EM' || tag === 'I') { const t = inner().trim(); return t ? `_${t}_` : ''; }
          if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || tag === 'BUTTON') return '';
          return inner();
        };
        const table = (el) => {
          const rows = Array.from(el.rows).slice(0, 60).map(r => Array.from(r.cells).map(c => clean(c.innerText, 60).replace(/\|/g, '/')));
          if (!rows.length) return '';
          const width = Math.max(...rows.map(r => r.length));
          const md = rows.map(r => '| ' + r.concat(Array(width - r.length).fill('')).join(' | ') + ' |');
          md.splice(1, 0, '|' + ' --- |'.repeat(width));
          return md.join('\n');
        };
        const block = (el, depth) => {
          for (const node of childrenOf(el)) {
            if (len > maxChars) return;
            if (node.nodeType === 3) { const t = clean(node.textContent, 2000); if (t.length > 1) push(t); continue; }
            if (node.nodeType !== 1) continue;
            const c = node;
            const tag = c.tagName;
            if (SKIP.has(tag) || c.getAttribute('aria-hidden') === 'true' || !visible(c)) continue;
            if (root === document.body && (['NAV', 'FOOTER', 'ASIDE'].includes(tag) || c.getAttribute('role') === 'navigation')) continue;
            if (/^H[1-6]$/.test(tag)) { const t = clean(c.innerText, 300); if (t) push('\n' + '#'.repeat(Number(tag[1])) + ' ' + t + '\n'); continue; }
            if (tag === 'P') { const t = inline(c).trim(); if (t) push(t + '\n'); continue; }
            if (tag === 'UL' || tag === 'OL') {
              let i = 1;
              for (const li of c.children) {
                if (li.tagName !== 'LI' || !visible(li)) continue;
                const t = inline(li).replace(/\s*\n\s*/g, ' ').trim();
                if (t) push('  '.repeat(depth) + (tag === 'OL' ? `${i++}. ` : '- ') + t);
              }
              push('');
              continue;
            }
            if (tag === 'PRE') { push('```\n' + c.innerText.slice(0, 6000) + '\n```'); continue; }
            if (tag === 'BLOCKQUOTE') { push('> ' + inline(c).trim().replace(/\n/g, '\n> ')); continue; }
            if (tag === 'TABLE') { push(table(c) + '\n'); continue; }
            if (tag === 'IMG') { if (c.alt) push(`![${clean(c.alt)}](${abs(c.currentSrc || c.src)})`); continue; }
            if (tag === 'HR') { push('---'); continue; }
            if (tag === 'IFRAME' || tag === 'VIDEO' || tag === 'AUDIO' || tag === 'CANVAS') continue;
            const hasBlockChild = Array.from(c.children).some(k => BLOCK.has(k.tagName));
            if (hasBlockChild || c.shadowRoot) block(c, depth);
            else { const t = inline(c).trim(); if (t) push(t); }
          }
        };
        block(root, 0);
        let text = out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
        const total = text.length;
        if (total > maxChars) text = text.slice(0, maxChars) + `\n\n[… truncated: ${total - maxChars} more characters. Call read_page with a larger max_chars or scroll + snapshot.]`;
        return `# ${clean(document.title, 200)}\n${location.href}\n\n${text || '(no readable text)'}`;
      };

      // Only the parts of the page that mention `match` (paragraphs, list
      // items, table rows), each under its nearest heading: read one fact
      // from a long page without reading the page.
      W.grep = (maxChars, match) => {
        const needle = String(match).toLowerCase();
        const full = (() => {
          const text = W.read(400000).split('\n');
          return text.slice(2);
        })();
        const out = [];
        let heading = '', lastHeading = '', len = 0, hits = 0;
        for (const line of full) {
          if (/^#{1,6} /.test(line)) {
            heading = line;
            if (!line.toLowerCase().includes(needle)) continue;
            out.push('\n' + line); lastHeading = line; hits++; len += line.length;
            continue;
          }
          if (!line.toLowerCase().includes(needle)) continue;
          if (heading && heading !== lastHeading) { out.push('\n' + heading); lastHeading = heading; }
          const l = line.length > 600 ? line.slice(0, 600) + '…' : line;
          out.push(l);
          hits++;
          len += l.length;
          if (len > maxChars) { out.push('… (more matches; narrow the match text)'); break; }
        }
        const head = `# ${clean(document.title, 200)}\n${location.href}\n`;
        return hits ? `${head}\n${hits} part${hits === 1 ? '' : 's'} mention “${match}”:\n${out.join('\n').trim()}`
                    : `${head}\nNothing on the page mentions “${match}”. Try a shorter word, or read_page without match.`;
      };

      const composedParent = (n) => n.parentNode || (n instanceof ShadowRoot ? n.host : null) || n.host || null;
      const isWithin = (inner, outer) => { for (let n = inner; n; n = composedParent(n)) if (n === outer) return true; return false; };

      // --- Consequential actions (guardrails) ------------------------------
      // Matched against the accessible name of what the agent is about to
      // click. English plus the most common European verbs.
      const RISK = [
        ['purchase', /\b(buy|purchase|pay|checkout|check out|place (your |my )?order|order now|complete (your |my )?(order|purchase)|subscribe|donate|start (my |your )?(free )?trial|upgrade now|confirm (and )?pay|book now|reserve now)\b|\b(acheter|payer|commander|kaufen|bezahlen|bestellen|comprar|pagar|kopen|betalen|acquista|paga)\b/],
        ['delete', /\b(delete|remove|discard|erase|unsubscribe|deactivate|close (my |your )?account|cancel (my |your |this )?(subscription|order|plan|membership|account|booking)|withdraw|transfer|unfollow|disconnect|block)\b|\b(supprimer|löschen|eliminar|borrar|verwijderen|elimina)\b/],
        ['send', /\b(send|submit|post|publish|tweet|repost|sign up|create (an |my )?account|register|confirm|approve)\b|\b(envoyer|publier|soumettre|senden|absenden|veröffentlichen|enviar|publicar|verzenden|versturen|plaatsen|invia|pubblica)\b/],
        ['connect', /\b(connect|invite|follow|add (as )?friend|endorse|accept (the )?invitation)\b/],
      ];
      const inSearchForm = (el) => {
        const form = el.form || el.closest && el.closest('form');
        if (!form) return false;
        return form.getAttribute('role') === 'search' || !!form.querySelector('input[type=search]') || /search/i.test(form.getAttribute('action') || '');
      };
      W.riskOf = (el) => {
        if (!el || el.nodeType !== 1) return null;
        const target = interactiveAncestor(el) || el;
        const role = roleOf(target) || '';
        if (!['button', 'link', 'menuitem', 'clickable', 'option', 'tab', 'switch', 'checkbox'].includes(role)) return null;
        if (inSearchForm(target)) return null;
        const name = nameOf(target, role || 'button');
        if (!name) return null;
        const lower = name.toLowerCase();
        for (const [kind, re] of RISK) if (re.test(lower)) return { kind, label: clean(name, 80) };
        return null;
      };
      // Pressing Enter in a field: does it submit something consequential?
      W.enterRisk = () => {
        const el = deepActive();
        if (!el || el === document.body) return null;
        const hint = `${el.getAttribute('aria-label') || ''} ${el.getAttribute('placeholder') || ''} ${el.getAttribute('aria-placeholder') || ''} ${el.getAttribute('data-placeholder') || ''} ${el.name || ''} ${el.id || ''}`.toLowerCase();
        if (el.type === 'search' || /search|query|filter|\bfind\b/.test(hint) || inSearchForm(el)) return null;
        const form = el.form || el.closest('form');
        if (form) {
          const submit = form.querySelector('button[type=submit],input[type=submit],button:not([type])');
          const r = submit ? W.riskOf(submit) : null;
          if (r) return { kind: r.kind, label: `Enter → ${r.label}` };
        }
        if (el.isContentEditable || el.tagName === 'TEXTAREA') {
          if (/message|reply|comment|post|tweet|write|what.?s on your mind|chat|send|note/.test(hint)) {
            return { kind: 'send', label: `Enter in “${clean(hint, 40)}”` };
          }
        }
        return null;
      };

      // --- Locating targets ----------------------------------------------
      // The element's own corner radius, so the agent's outline can sit
      // concentric to it.
      const cornerOf = (el) => parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0;
      const fullyInView = (r) => r.y >= 0 && r.x >= 0 && r.y + r.height <= innerHeight && r.x + r.width <= innerWidth;

      W.locate = (ref) => {
        const el = W.el(ref);
        let r = rectOf(el);
        // Only scroll when needed: keeps the page still while the user watches.
        if (!fullyInView(r)) {
          el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
          r = rectOf(el);
        }
        if (r.width < 1 || r.height < 1) throw new Error(`Element ${ref} is not visible (zero size).`);
        const x = r.x + r.width / 2, y = r.y + r.height / 2;
        let obscuredBy = null;
        if (el.ownerDocument === document) {
          const top = document.elementFromPoint(x, y);
          if (top && !isWithin(top, el) && !isWithin(el, top)) {
            obscuredBy = clean(`${top.tagName.toLowerCase()}${top.id ? '#' + top.id : ''} "${top.getAttribute('aria-label') || top.innerText || ''}"`, 90);
          }
        }
        const role = roleOf(el) || el.tagName.toLowerCase();
        const name = nameOf(el, role);
        return { x, y, rect: r, radius: cornerOf(el), role, name, sensitive: isSensitive(el),
                 editable: isEditable(el), obscuredBy, risk: W.riskOf(el), ref: W.refFor(el, role, name) };
      };

      // What is at a viewport point (for coordinate clicks)?
      W.at = (x, y) => {
        let el = document.elementFromPoint(x, y);
        for (let i = 0; i < 6 && el && el.shadowRoot; i++) {
          const inner = el.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === el) break;
          el = inner;
        }
        if (el && el.tagName === 'IFRAME') {
          try {
            const fr = el.getBoundingClientRect();
            const inner = el.contentDocument && el.contentDocument.elementFromPoint(x - fr.left, y - fr.top);
            if (inner) el = inner;
          } catch {}
        }
        if (!el) return null;
        const target = interactiveAncestor(el) || el;
        const role = roleOf(target) || target.tagName.toLowerCase();
        return { ref: W.refFor(target), role, name: nameOf(target, role), rect: rectOf(target), radius: cornerOf(target),
                 sensitive: isSensitive(target), editable: isEditable(target), risk: W.riskOf(target) };
      };

      // Interactive elements on screen, for labelled screenshots.
      W.targets = (max = 120) => {
        const out = [];
        const vw = innerWidth, vh = innerHeight;
        const walk = (root) => {
          for (const el of root.querySelectorAll('*')) {
            if (out.length >= max) return;
            if (el.shadowRoot) walk(el.shadowRoot);
            const role = roleOf(el);
            if (!role || !INTERACTIVE.has(role)) continue;
            const r = el.getBoundingClientRect();
            if (r.width < 6 || r.height < 6 || r.bottom <= 0 || r.right <= 0 || r.top >= vh || r.left >= vw) continue;
            const cx = Math.min(vw - 1, Math.max(0, r.left + r.width / 2)), cy = Math.min(vh - 1, Math.max(0, r.top + r.height / 2));
            const top = root.elementFromPoint ? root.elementFromPoint(cx, cy) : document.elementFromPoint(cx, cy);
            if (top && !isWithin(top, el) && !isWithin(el, top)) continue;  // covered (e.g. behind a dialog)
            out.push({ ref: W.refFor(el), x: r.left, y: r.top, w: r.width, h: r.height });
          }
        };
        walk(document);
        return out;
      };

      // Interactive elements whose label contains `query`, with context.
      W.find = (query, opts = {}) => {
        const q = String(query || '').toLowerCase().trim();
        const wantRole = opts.role ? String(opts.role).toLowerCase() : '';
        const max = Math.min(opts.max || 25, 100);
        if (!q && !wantRole) throw new Error('find needs text or role.');
        const found = [];
        const seen = new Set();
        const contextOf = (el) => {
          const own = clean(el.innerText || '', 400);
          for (let n = el.parentElement, i = 0; n && i < 9; n = n.parentElement, i++) {
            const tag = n.tagName;
            const role = n.getAttribute('role');
            const text = clean(n.innerText || '', 400);
            const card = tag === 'LI' || tag === 'ARTICLE' || tag === 'TR' || role === 'listitem' || role === 'article' || role === 'row';
            if ((card || text.length >= 40) && text.length > own.length + 8) {
              return clean(text.replace(own, '').trim(), 140);
            }
          }
          return '';
        };
        const consider = (el) => {
          if (seen.has(el) || found.length >= max) return;
          const role = roleOf(el);
          if (!role || !(INTERACTIVE.has(role) || role === 'heading')) return;
          if (wantRole && role !== wantRole && !(wantRole === 'button' && role === 'clickable')) return;
          if (!visible(el)) return;
          const name = nameOf(el, role);
          if (q && !name.toLowerCase().includes(q) && !(el.value && String(el.value).toLowerCase().includes(q))) return;
          seen.add(el);
          const r = el.getBoundingClientRect();
          const where = r.bottom < 0 ? ' (above, scrolled out)' : r.top > innerHeight ? ' (below, scrolled out)' : '';
          const ctx = contextOf(el);
          found.push(describe(el, role) + where + (ctx ? `\n    in: “${ctx}”` : ''));
        };
        const walk = (root) => {
          for (const el of root.querySelectorAll('*')) {
            if (found.length >= max) return;
            if (el.shadowRoot) walk(el.shadowRoot);
            if (el.tagName === 'IFRAME') { try { if (el.contentDocument) walk(el.contentDocument); } catch {} }
            if (!q) { consider(el); continue; }
            const own = (el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('placeholder') || '') + ' ' + (el.getAttribute('title') || '');
            if (own.toLowerCase().includes(q)) { consider(el); continue; }
            // Text matches resolve to the element the user would click.
            const text = el.childElementCount === 0 ? (el.textContent || '') : directText(el);
            if (text.toLowerCase().includes(q)) {
              const target = interactiveAncestor(el);
              if (target) consider(target);
              else if (/^H[1-6]$/.test(el.tagName)) consider(el);
              // Text in a <label> names its control (a checkbox next to the text).
              const label = el.closest && el.closest('label');
              if (label && label.control) consider(label.control);
            }
          }
        };
        walk(document);
        const header = `${found.length} match${found.length === 1 ? '' : 'es'} for ${q ? `“${query}”` : ''}${wantRole ? ` role=${wantRole}` : ''}${found.length >= max ? ` (first ${max})` : ''}`;
        return found.length ? header + '\n' + found.map(l => '- ' + l).join('\n') : header + '. Try a shorter text, or snapshot.';
      };

      // Any visible element showing `text` (drop zones are often plain divs):
      // the innermost one, so a column's heading stands for its column.
      W.refByText = (text) => {
        const needle = String(text).toLowerCase().trim();
        let best = null, bestLen = Infinity;
        for (const el of document.body.querySelectorAll('*')) {
          if (SKIP.has(el.tagName) || !visible(el)) continue;
          const label = (el.getAttribute('aria-label') || '').toLowerCase();
          const own = label || (el.childElementCount === 0 ? (el.textContent || '').toLowerCase() : directText(el).toLowerCase());
          if (!own.includes(needle)) continue;
          const r = el.getBoundingClientRect();
          if (r.width < 2 || r.height < 2) continue;
          const len = own.length + (label ? 0 : 1);
          if (len < bestLen) { best = el; bestLen = len; }
        }
        if (!best) throw new Error(`Nothing on the page shows “${text}”.`);
        const role = roleOf(best) || 'element';
        return W.refFor(best, role, nameOf(best, role));
      };

      W.findByText = (text, soft) => {
        const needle = String(text).toLowerCase().trim();
        const dialogs = dialogsNow();
        const scope = dialogs.length ? dialogs[dialogs.length - 1] : document;
        const pick = (root) => {
          const candidates = root.querySelectorAll(
            'a[href],button,input[type=submit],input[type=button],[role=button],[role=link],[role=menuitem],[role=tab],[role=option],[role=checkbox],[role=switch],summary,label,[onclick]');
          let best = null, bestScore = 0;
          for (const el of candidates) {
            if (!visible(el)) continue;
            const name = nameOf(el, roleOf(el) || 'button').toLowerCase();
            if (!name) continue;
            const score = name === needle ? 3 : name.startsWith(needle) ? 2 : name.includes(needle) ? 1 : 0;
            if (score > bestScore) { best = el; bestScore = score; if (score === 3) break; }
          }
          return best;
        };
        // Prefer the open dialog: that's where the next step usually is.
        const best = pick(scope) || (scope !== document ? pick(document) : null);
        if (!best) {
          if (soft) return null;
          throw new Error(`Nothing clickable labelled "${text}". Use find or snapshot, then click by ref.`);
        }
        return W.refFor(best);
      };

      // --- Watching what an action changes ---------------------------------
      const dialogsNow = () => {
        const out = [];
        for (const d of document.querySelectorAll('dialog[open],[role=dialog],[role=alertdialog],[aria-modal=true]')) {
          const r = d.getBoundingClientRect();
          if (r.width > 0 && r.height > 0 && visible(d)) out.push(d);
        }
        return out;
      };
      const dialogTitle = (d) => {
        const by = d.getAttribute('aria-labelledby');
        if (by) { const t = by.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' '); if (clean(t)) return clean(t, 80); }
        if (d.getAttribute('aria-label')) return clean(d.getAttribute('aria-label'), 80);
        const h = d.querySelector('h1,h2,h3,h4,[role=heading]');
        return h ? clean(h.innerText, 80) : '';
      };
      const interactiveIn = (root, max, skip) => {
        const lines = [];
        const visit = (el) => {
          if (lines.length >= max || el.nodeType !== 1) return;
          if (skip && skip.has(el)) return;
          if (SKIP.has(el.tagName) || el.getAttribute('aria-hidden') === 'true' || el.hidden || !visible(el)) return;
          const role = roleOf(el);
          if (role && INTERACTIVE.has(role)) { lines.push(describe(el, role)); if (role !== 'listbox' && role !== 'menu') return; }
          for (const c of childrenOf(el)) visit(c);
        };
        visit(root);
        return lines;
      };

      // State of an element that matters for "did it change" (not focus).
      const stateKey = (el, role) => statesOf(el, role).filter(x => x !== 'focused').join(',');
      const interactiveEls = (root, max, skip) => {
        const out = [];
        const visit = (el) => {
          if (out.length >= max || el.nodeType !== 1) return;
          if (skip && skip.has(el)) return;
          if (SKIP.has(el.tagName) || el.getAttribute('aria-hidden') === 'true' || el.hidden || !visible(el)) return;
          const role = roleOf(el);
          if (role && INTERACTIVE.has(role)) { out.push([el, role]); if (role !== 'listbox' && role !== 'menu') return; }
          for (const c of childrenOf(el)) visit(c);
        };
        visit(root);
        return out;
      };

      W.watch = () => {
        if (W._mo) W._mo.disconnect();
        // What the agent already knows: its refs, their role/name and state.
        const known = [];
        for (const [ref, w] of refToEl) {
          if (known.length >= 600) break;
          const el = w.deref(), sig = refSig.get(ref);
          if (!el || !sig || !el.isConnected) continue;
          known.push({ ref, el, sig, state: stateKey(el, sig.role) });
        }
        const st = { added: new Set(), touched: new Set(), texted: new Set(), revealed: new Set(), muts: 0, last: performance.now(),
                     url: location.href, title: document.title, dialogs: new Set(dialogsNow()), focus: deepActive(), known };
        W._st = st;
        W._mo = new MutationObserver((records) => {
          st.muts += records.length;
          st.last = performance.now();
          for (const r of records) {
            if (r.type === 'childList') {
              for (const n of r.addedNodes) {
                if (n.nodeType === 1) st.added.add(n);
                else if (n.nodeType === 3 && n.parentElement) { st.touched.add(n.parentElement); st.texted.add(n.parentElement); }
              }
              if (r.removedNodes.length && r.target.nodeType === 1) st.touched.add(r.target);
            } else if (r.type === 'characterData') {
              if (r.target.parentElement) { st.touched.add(r.target.parentElement); st.texted.add(r.target.parentElement); }
            } else if (r.type === 'attributes') {
              st.touched.add(r.target);
              if (r.attributeName === 'hidden' || r.attributeName === 'open') st.revealed.add(r.target);
            }
          }
        });
        W._mo.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true,
          attributeFilter: ['aria-label', 'aria-expanded', 'aria-pressed', 'aria-checked', 'aria-selected', 'aria-disabled',
                            'disabled', 'open', 'hidden', 'value'] });
        return true;
      };

      // [mutation count, ms since the last one]; -1 when nothing is being watched
      // (the document was replaced by a navigation).
      W.muts = () => W._st ? [W._st.muts, performance.now() - W._st.last] : [-1, 0];

      // Summarises what changed since watch(): dialogs, notices, controls that
      // changed state, controls that went away, new controls, short texts that
      // changed — nearest to (cx, cy) first. Re-rendered copies of elements the
      // agent knew keep their refs and are only reported if they changed.
      W.changes = (limit = 22, cx = -1, cy = -1) => {
        const st = W._st;
        if (!st) return '';
        if (W._mo) { W._mo.disconnect(); W._mo = null; }
        W._st = null;
        const dist = (el) => {
          if (cx < 0 || !el.isConnected) return 0;
          const r = el.getBoundingClientRect();
          const dx = Math.max(r.left - cx, 0, cx - r.right), dy = Math.max(r.top - cy, 0, cy - r.bottom);
          return dx * dx + dy * dy;
        };
        const lines = [];
        const opened = [];
        const nowDialogs = dialogsNow();
        for (const d of nowDialogs) {
          if (st.dialogs.has(d)) continue;
          opened.push(d);
          const title = dialogTitle(d);
          lines.push(`dialog${title ? ` “${title}”` : ''} opened:`);
          for (const line of interactiveIn(d, 12)) lines.push('    ' + line);
        }
        for (const d of st.dialogs) {
          if (!nowDialogs.includes(d)) { const t = d.isConnected ? dialogTitle(d) : ''; lines.push(`dialog${t ? ` “${t}”` : ''} closed`); }
        }
        const inOpened = (el) => opened.some(d => d.contains(el));

        // Notices: only what is new — a toast that appeared, or text that changed
        // inside a live region (not the region's older messages).
        const notices = new Set();
        const noticeSelector = '[role=alert],[role=status],[aria-live=assertive],[aria-live=polite]';
        const notice = (region, text) => {
          const t = clean(text, 160);
          if (t && !inOpened(region)) notices.add(`${region.getAttribute('role') === 'alert' ? 'alert' : 'notice'}: “${t}”`);
        };
        for (const n of st.added) {
          if (!n.isConnected || n.nodeType !== 1 || !visible(n)) continue;
          const region = n.closest(noticeSelector);
          if (region) { notice(region, n.innerText); continue; }
          if (n.matches(noticeSelector)) { notice(n, n.innerText); continue; }
          for (const r of n.querySelectorAll(noticeSelector)) if (visible(r)) notice(r, r.innerText);
        }
        const inNotice = new Set();
        for (const n of st.texted) {
          if (!n.isConnected) continue;
          const region = n.closest(noticeSelector);
          if (region && visible(region)) { notice(region, n.innerText); inNotice.add(n); }
        }
        notices.forEach(line => lines.push(line));

        // Elements the agent knew that were replaced: hand their refs to the
        // re-rendered copies (same role and name).
        const orphans = new Map();  // "role|name" → [known entries whose element left]
        for (const k of st.known) {
          if (k.el.isConnected) continue;
          const key = k.sig.role + '|' + k.sig.name;
          if (!orphans.has(key)) orphans.set(key, []);
          orphans.get(key).push(k);
        }
        const nowLines = [], freshLines = [];
        const reported = new Set();
        const skip = new Set(opened);
        const candidates = [];
        for (const n of [...st.added, ...st.revealed]) {
          if (!n.isConnected || inOpened(n) || opened.includes(n)) continue;
          for (const pair of interactiveEls(n, 40, skip)) candidates.push(pair);
          if (candidates.length > 400) break;
        }
        for (const [el, role] of candidates) {
          if (reported.has(el)) continue;
          reported.add(el);
          const name = nameOf(el, role);
          const list = orphans.get(role + '|' + name);
          if (list && list.length) {
            const k = list.shift();
            rebind(k.ref, el);
            if (stateKey(el, role) !== k.state) nowLines.push({ line: describe(el, role), d: dist(el) });
          } else {
            freshLines.push({ line: describe(el, role), d: dist(el) });
          }
        }
        // Controls that stayed but changed state.
        const changed = new Set();
        for (const n of st.touched) {
          if (!n.isConnected) continue;
          const el = interactiveAncestor(n);
          if (el && !reported.has(el) && !inOpened(el) && visible(el)) changed.add(el);
        }
        for (const el of changed) {
          const ref = elToRef.get(el);
          const k = ref && st.known.find(x => x.ref === ref);
          if (k && stateKey(el, k.sig.role) === k.state) continue;
          nowLines.push({ line: describe(el), d: dist(el) });
        }
        nowLines.sort((a, b) => a.d - b.d).slice(0, 8).forEach(({ line }) => lines.push('now: ' + line));
        const gone = [];
        for (const list of orphans.values()) for (const k of list) gone.push(`${k.sig.role}${k.sig.name ? ` "${quote(k.sig.name)}"` : ''} [ref=${k.ref}]`);
        gone.slice(0, 6).forEach(g => lines.push('gone: ' + g));
        if (gone.length > 6) lines.push(`gone: … ${gone.length - 6} more`);
        freshLines.sort((a, b) => a.d - b.d).slice(0, 8).forEach(({ line }) => lines.push('new: ' + line));
        if (freshLines.length > 8) lines.push(`new: … ${freshLines.length - 8} more`);

        // Short texts that changed (counters, totals, inline messages).
        const texts = [];
        const seenText = new Set();
        for (const n of st.texted) {
          if (!n.isConnected || inNotice.has(n) || inOpened(n) || interactiveAncestor(n) || !visible(n)) continue;
          if (n.childElementCount > 2) continue;
          const t = clean(n.innerText, 100);
          if (!t || t.length > 90 || seenText.has(t)) continue;
          seenText.add(t);
          texts.push({ line: `text: “${t}”`, d: dist(n) });
        }
        texts.sort((a, b) => a.d - b.d).slice(0, 4).forEach(({ line }) => lines.push(line));

        // Focus is news only when it lands in a field (e.g. a composer opened).
        const f = deepActive();
        if (f && f !== st.focus && isEditable(f) && !inOpened(f) && !reported.has(f)) {
          lines.push(`focus: ${describe(f, roleOf(f) || 'textbox')}`);
        }
        if (location.href !== st.url) lines.push(`URL now: ${location.href}`);
        if (document.title !== st.title) lines.push(`title now: “${clean(document.title, 100)}”`);
        if (lines.length > limit) { const extra = lines.length - limit; lines.length = limit; lines.push(`… ${extra} more (call snapshot for the full page)`); }
        return lines.join('\n');
      };

      W.prepareTyping = (ref, clear) => {
        const el = W.el(ref);
        el.focus({ preventScroll: true });
        if (clear) {
          if ((el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && el.select) el.select();
          else if (el.isContentEditable) {
            const range = el.ownerDocument.createRange();
            range.selectNodeContents(el);
            const sel = el.ownerDocument.getSelection();
            sel.removeAllRanges(); sel.addRange(range);
          }
        }
        return { sensitive: isSensitive(el), editable: isEditable(el), focused: el.ownerDocument.activeElement === el };
      };

      // Typing verification: what the field holds now.
      W.valueOf = (ref) => {
        const el = W.el(ref);
        return String(el.isContentEditable ? el.innerText : (el.value ?? ''));
      };
      // Fallback when keystrokes didn't land (custom inputs, odd focus): set the
      // value through the native setter so frameworks (React's value tracker
      // included) see a real change, then fire input + change.
      W.setValue = (ref, text, clear) => {
        const el = W.el(ref);
        el.focus({ preventScroll: true });
        if (el.isContentEditable) {
          if (clear) el.textContent = '';
          el.ownerDocument.execCommand('insertText', false, text);
        } else {
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype
            : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, clear ? text : String(el.value ?? '') + text);
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        return W.valueOf(ref);
      };
      W.checkedOf = (ref) => {
        const el = W.el(ref);
        return typeof el.checked === 'boolean' ? el.checked : el.getAttribute('aria-checked') === 'true';
      };

      // The <input type=file> behind a ref: the input itself, one inside it,
      // its label's control, or the only file input in its form or page.
      W.fileInput = (ref) => {
        const el = W.el(ref);
        const isFile = (x) => x && x.tagName === 'INPUT' && x.type === 'file';
        if (isFile(el)) return el;
        const inside = el.querySelector && el.querySelector('input[type=file]');
        if (inside) return inside;
        const label = el.closest && el.closest('label');
        if (label && isFile(label.control)) return label.control;
        const scope = (el.closest && el.closest('form')) || document;
        const all = scope.querySelectorAll('input[type=file]');
        if (all.length === 1) return all[0];
        const page = document.querySelectorAll('input[type=file]');
        if (page.length === 1) return page[0];
        throw new Error(`No file input found for ${ref}. Pass the ref of the <input type=file> (find role button "Choose file" or snapshot).`);
      };

      // How Playwright should find an element: by role and accessible name when
      // that's unique, else test id, id, or a CSS path.
      const ARIA = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox', 'option',
        'menuitem', 'menuitemcheckbox', 'menuitemradio', 'tab', 'switch', 'slider', 'spinbutton', 'treeitem', 'heading']);
      const cssPath = (el) => {
        const parts = [];
        for (let n = el; n && n.nodeType === 1 && n !== document.documentElement; n = n.parentElement) {
          if (n.id && document.querySelectorAll('#' + CSS.escape(n.id)).length === 1) { parts.unshift('#' + CSS.escape(n.id)); break; }
          let part = n.tagName.toLowerCase();
          const sameTag = n.parentElement ? Array.from(n.parentElement.children).filter(c => c.tagName === n.tagName) : [];
          if (sameTag.length > 1) part += `:nth-of-type(${sameTag.indexOf(n) + 1})`;
          parts.unshift(part);
        }
        return parts.join(' > ');
      };
      W.locatorOf = (ref) => {
        const el = W.el(ref);
        const role = roleOf(el) || '';
        const name = nameOf(el, role);
        const testId = el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-test');
        // File inputs are usually hidden, so not in the accessibility tree.
        if (el.tagName === 'INPUT' && el.type === 'file') return testId ? { testId } : { css: cssPath(el) };
        if (ARIA.has(role) && name && !name.endsWith('…')) {
          const all = matching({ role, name });
          if (all.length <= 1) return { role, name };
          if (!testId) return { role, name, nth: Math.max(0, all.indexOf(el)) };
        }
        if (testId) return { testId };
        if (role === 'clickable' && name && !name.endsWith('…')) return { text: name };
        return { css: cssPath(el) };
      };

      // Assertions for exported tests, checked against the live page first.
      W.verify = (check) => {
        if (check.text != null) {
          const ok = (document.body?.innerText || '').includes(check.text);
          return { ok, actual: ok ? '' : 'text not on the page' };
        }
        const el = W.el(check.ref);
        if (check.checked != null) { const v = W.checkedOf(check.ref); return { ok: v === check.checked, actual: v ? 'checked' : 'unchecked' }; }
        if (check.value != null) { const v = W.valueOf(check.ref); return { ok: v === check.value, actual: `value "${clean(v, 60)}"` }; }
        const v = visible(el) && el.getBoundingClientRect().width > 0;
        return { ok: check.visible === false ? !v : v, actual: v ? 'visible' : 'hidden' };
      };

      W.selectOption = (ref, value) => {
        const el = W.el(ref);
        if (el.tagName !== 'SELECT') throw new Error(`Element ${ref} is not a <select>. Click it and pick the option instead.`);
        const wanted = String(value).trim().toLowerCase();
        const opt = Array.from(el.options).find(o => o.value.toLowerCase() === wanted || o.text.trim().toLowerCase() === wanted)
          || Array.from(el.options).find(o => o.text.trim().toLowerCase().includes(wanted));
        if (!opt) throw new Error(`No option "${value}". Options: ${Array.from(el.options).map(o => o.text.trim()).slice(0, 20).join(', ')}`);
        el.value = opt.value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return clean(opt.text);
      };

      W.scrollElement = (ref, direction, amount) => {
        const el = ref ? W.el(ref) : (document.scrollingElement || document.documentElement);
        const dy = amount || Math.round((ref ? el.clientHeight : innerHeight) * 0.85);
        const dx = amount || Math.round((ref ? el.clientWidth : innerWidth) * 0.85);
        const o = { behavior: 'instant' };
        if (direction === 'top') el.scrollTo({ top: 0, ...o });
        else if (direction === 'bottom') el.scrollTo({ top: el.scrollHeight, ...o });
        else if (direction === 'up') el.scrollBy({ top: -dy, ...o });
        else if (direction === 'down') el.scrollBy({ top: dy, ...o });
        else if (direction === 'left') el.scrollBy({ left: -dx, ...o });
        else if (direction === 'right') el.scrollBy({ left: dx, ...o });
        return W.position();
      };

      W.position = () => {
        const se = document.scrollingElement || document.documentElement;
        return `Scrolled to ${Math.round(scrollY)}px of ${se.scrollHeight}px (viewport ${innerHeight}px).`;
      };

      W.waitFor = (text, selector, gone, timeout) => new Promise((resolve) => {
        const check = () => {
          let found = false;
          if (selector) found = !!document.querySelector(selector);
          if (text) found = (document.body?.innerText || '').includes(text);
          return gone ? !found : found;
        };
        if (check()) return resolve(true);
        let pending = false;
        const observer = new MutationObserver(() => {
          if (pending) return;
          pending = true;
          queueMicrotask(() => { pending = false; if (check()) { observer.disconnect(); clearTimeout(timer); resolve(true); } });
        });
        observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
        const timer = setTimeout(() => { observer.disconnect(); resolve(check()); }, timeout);
      });

      W.selection = () => String(getSelection() || '');

      // --- When real input doesn't arrive ---------------------------------
      // Chromium stops delivering input to pages while the Mac's display is
      // asleep or the screen is locked. Wink listens for the real event first
      // (this page and its same-origin frames); if it never comes, it plays
      // the same events from inside the page, so agents keep working while
      // the user is away.
      const sameOriginWindows = () => {
        const out = [window];
        for (const f of document.querySelectorAll('iframe')) { try { if (f.contentWindow && f.contentDocument) out.push(f.contentWindow); } catch {} }
        return out;
      };
      W.armInput = (type) => {
        if (W._disarm) W._disarm();
        W._arrived = false;
        const handler = () => { W._arrived = true; };
        const wins = sameOriginWindows();
        for (const w of wins) w.addEventListener(type, handler, true);
        W._disarm = () => { for (const w of wins) { try { w.removeEventListener(type, handler, true); } catch {} } };
        return true;
      };
      // null when nothing is armed (e.g. the click navigated to a new page):
      // the caller then assumes the input arrived.
      W.inputArrived = () => {
        if (!W._disarm) return null;
        const arrived = !!W._arrived;
        if (W._disarm) W._disarm();
        W._disarm = null;
        return arrived;
      };
      // The element at a viewport point, through shadow roots and same-origin
      // frames, with the point in that element's own frame.
      const pointTarget = (x, y) => {
        let doc = document, el = document.elementFromPoint(x, y), fx = x, fy = y;
        for (let i = 0; i < 8 && el; i++) {
          if (el.shadowRoot) { const inner = el.shadowRoot.elementFromPoint(fx, fy); if (inner && inner !== el) { el = inner; continue; } }
          if (el.tagName === 'IFRAME') {
            try {
              const r = el.getBoundingClientRect();
              const d = el.contentDocument;
              if (d) { fx -= r.left; fy -= r.top; doc = d; const inner = d.elementFromPoint(fx, fy); if (inner) { el = inner; continue; } }
            } catch {}
          }
          break;
        }
        return el ? { el, x: fx, y: fy, view: (el.ownerDocument || doc).defaultView } : null;
      };
      const mouseInit = (t, button, buttons, detail) => ({ bubbles: true, cancelable: true, composed: true, view: t.view,
        clientX: t.x, clientY: t.y, screenX: t.x, screenY: t.y, button, buttons, detail });
      const fire = (t, Type, type, init) => {
        const C = t.view && t.view[Type] || globalThis[Type];
        return t.el.dispatchEvent(new C(type, init));
      };
      const focusFor = (el) => {
        const f = el.closest && el.closest('input,textarea,select,button,a[href],[tabindex],[contenteditable=""],[contenteditable=true]');
        if (f && f.focus) f.focus({ preventScroll: true });
      };
      W.syntheticClick = (x, y, buttonName, count) => {
        const t = pointTarget(x, y);
        if (!t) return false;
        const button = buttonName === 'right' ? 2 : buttonName === 'middle' ? 1 : 0;
        const bits = button === 2 ? 2 : button === 1 ? 4 : 1;
        for (let i = 1; i <= Math.max(1, count); i++) {
          fire(t, 'PointerEvent', 'pointerover', { ...mouseInit(t, 0, 0, 0), pointerType: 'mouse', isPrimary: true });
          fire(t, 'MouseEvent', 'mouseover', mouseInit(t, 0, 0, 0));
          fire(t, 'PointerEvent', 'pointerdown', { ...mouseInit(t, button, bits, i), pointerType: 'mouse', isPrimary: true });
          if (fire(t, 'MouseEvent', 'mousedown', mouseInit(t, button, bits, i))) focusFor(t.el);
          fire(t, 'PointerEvent', 'pointerup', { ...mouseInit(t, button, 0, i), pointerType: 'mouse', isPrimary: true });
          fire(t, 'MouseEvent', 'mouseup', mouseInit(t, button, 0, i));
          if (button === 2) fire(t, 'MouseEvent', 'contextmenu', mouseInit(t, 2, 0, i));
          else if (button === 0) fire(t, 'MouseEvent', 'click', mouseInit(t, 0, 0, i));
        }
        if (count >= 2 && button === 0) fire(t, 'MouseEvent', 'dblclick', mouseInit(t, 0, 0, 2));
        return true;
      };
      W.syntheticHover = (x, y) => {
        const t = pointTarget(x, y);
        if (!t) return false;
        fire(t, 'PointerEvent', 'pointerover', { ...mouseInit(t, 0, 0, 0), pointerType: 'mouse', isPrimary: true });
        fire(t, 'PointerEvent', 'pointerenter', { ...mouseInit(t, 0, 0, 0), bubbles: false, pointerType: 'mouse', isPrimary: true });
        fire(t, 'MouseEvent', 'mouseover', mouseInit(t, 0, 0, 0));
        fire(t, 'MouseEvent', 'mouseenter', { ...mouseInit(t, 0, 0, 0), bubbles: false });
        fire(t, 'PointerEvent', 'pointermove', { ...mouseInit(t, 0, 0, 0), pointerType: 'mouse', isPrimary: true });
        fire(t, 'MouseEvent', 'mousemove', mouseInit(t, 0, 0, 0));
        return true;
      };
      const focusables = () => Array.from(document.querySelectorAll('input:not([type=hidden]),textarea,select,button,a[href],[tabindex]:not([tabindex="-1"]),[contenteditable=""],[contenteditable=true]'))
        .filter(el => !el.disabled && visible(el) && el.getBoundingClientRect().width > 0);
      W.syntheticKey = (key, code, keyCode, text, mods) => {
        const el = deepActive() || document.body;
        const view = el.ownerDocument.defaultView;
        const init = { key, code, keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true, view,
                       altKey: !!(mods & 1), ctrlKey: !!(mods & 2), metaKey: !!(mods & 4), shiftKey: !!(mods & 8) };
        const K = view.KeyboardEvent;
        const proceed = el.dispatchEvent(new K('keydown', init));
        if (proceed) {
          if (text && text !== '\r') {
            el.dispatchEvent(new K('keypress', { ...init, charCode: text.charCodeAt(0) }));
            if (isEditable(el)) el.ownerDocument.execCommand('insertText', false, text);
          } else if (key === 'Enter') {
            el.dispatchEvent(new K('keypress', { ...init, charCode: 13 }));
            if (el.tagName === 'INPUT' && el.form) el.form.requestSubmit();
            else if (el.tagName === 'TEXTAREA' || el.isContentEditable) el.ownerDocument.execCommand('insertLineBreak');
            else if (el.tagName === 'BUTTON' || (el.tagName === 'A' && el.href)) el.click();
          } else if (key === ' ' && (el.tagName === 'BUTTON' || el.type === 'checkbox' || el.type === 'radio')) {
            el.click();
          } else if (key === 'Backspace' && isEditable(el)) {
            el.ownerDocument.execCommand('delete');
          } else if (key === 'Tab') {
            const list = focusables();
            const i = list.indexOf(el);
            const next = list[(i + (mods & 8 ? -1 : 1) + list.length) % list.length];
            if (next) next.focus();
          }
        }
        el.dispatchEvent(new K('keyup', init));
        return true;
      };
      W.syntheticDrag = (fx, fy, tx, ty) => {
        const from = pointTarget(fx, fy), to = pointTarget(tx, ty);
        if (!from || !to) return false;
        fire(from, 'PointerEvent', 'pointerdown', { ...mouseInit(from, 0, 1, 1), pointerType: 'mouse', isPrimary: true });
        fire(from, 'MouseEvent', 'mousedown', mouseInit(from, 0, 1, 1));
        const draggable = from.el.closest && from.el.closest('[draggable=true],a[href],img');
        if (draggable) {
          const dt = new DataTransfer();
          const src = { ...from, el: draggable };
          const init = (t) => ({ ...mouseInit(t, 0, 1, 0), dataTransfer: dt });
          if (fire(src, 'DragEvent', 'dragstart', init(src))) {
            fire(to, 'DragEvent', 'dragenter', init(to));
            const over = fire(to, 'DragEvent', 'dragover', init(to));
            if (!over) fire(to, 'DragEvent', 'drop', init(to));
          }
          fire(src, 'DragEvent', 'dragend', init(src));
        } else {
          for (let i = 1; i <= 8; i++) {
            const x = fx + (tx - fx) * i / 8, y = fy + (ty - fy) * i / 8;
            const t = pointTarget(x, y) || to;
            fire(t, 'PointerEvent', 'pointermove', { ...mouseInit({ ...t, x, y }, 0, 1, 0), pointerType: 'mouse', isPrimary: true });
            fire(t, 'MouseEvent', 'mousemove', mouseInit({ ...t, x, y }, 0, 1, 0));
          }
        }
        fire(to, 'PointerEvent', 'pointerup', { ...mouseInit(to, 0, 0, 1), pointerType: 'mouse', isPrimary: true });
        fire(to, 'MouseEvent', 'mouseup', mouseInit(to, 0, 0, 1));
        return true;
      };

      W.mediaPlaying = () => Array.from(document.querySelectorAll('video,audio')).some(m => !m.paused && !m.muted && m.volume > 0);
    })();
    """#
}
