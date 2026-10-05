// Finds what breaks when a page gets narrow, inside Antsurance components only:
//   wrapped      a button label that has broken onto more than one line
//   cut off      text clipped by its own box (hidden overflow or an ellipsis)
//   spills       text wider than the box it sits in, so it runs into its neighbor
//   runs off     text or a chip that sticks out past the card or cell that holds it
//   column gone  a table heading that was there at full width and is not said anywhere now
//   covers       a floating button sitting on top of something a person reads
//   too tall     a component taller than the window
//   squeezed     a strip of tabs or buttons that scrolls sideways, shrunk until not one of them shows whole
//
// The script narrows the page itself. Never resize the browser window: it is shared.
//
// Run this file's contents TWICE in the tab (the browser tool's javascript_exec, or the console):
//   1st run  measures the page at full width, narrows it, and says so. Wait two seconds.
//   2nd run  measures again, checks, puts the page back, and returns one line per fault.
// The width is 1,024 unless you set one first:  window.NARROW_WIDTH = 900
// To put a page back by hand after a first run:  window.NARROW_RESET = true, then run once.
//
// How it narrows depends on the site, and each was measured:
//   Internal Lightning pages: the active page container (.oneContent.active) gets a width and a
//     max-width. Setting the body's width does NOT reflow a Lightning page, and page zoom only
//     makes it bigger. This narrows the page's own content; the Salesforce header, the navigation
//     bar and the utility bar are sized to the window and do not change, so they are not checked.
//   The customer portal (the Experience Cloud site at /portal): page zoom narrows the layout, so
//     the script sets a zoom that gives the asked width.
//
// It refuses to say "clean" when nothing reflowed: the closing line then reads "did not narrow".
// It walks shadow roots and names the component on every line.
(() => {
  const STATE = '__antsNarrow';
  const width = Number(window.NARROW_WIDTH) || 1024;
  const container = document.querySelector('.oneContent.active');

  // Every Antsurance component on the page, with the component it sits inside (if any).
  const hosts = () => {
    const found = [];
    const walk = (root, parent) => {
      root.querySelectorAll('*').forEach(el => {
        if (!el.shadowRoot) return;
        const tag = el.tagName.toLowerCase();
        const ours = tag.startsWith('c-antsurance');
        if (ours) found.push({ el, name: tag.slice(2), parent });
        walk(el.shadowRoot, ours ? el : parent);
      });
    };
    walk(document, null);
    return found;
  };
  const visible = el => {
    const box = el.getBoundingClientRect();
    return box.width > 1 && box.height > 1;
  };
  const words = el => el.textContent.replace(/\s+/g, ' ').trim();
  // Headings of a table or a list laid out as one: said once at full width, they must still be said when narrow.
  const headings = root => [...root.querySelectorAll('th, [role="columnheader"], [class*="__columns"] > *, [class*="__col-head"]')].filter(el => words(el) && words(el).length <= 24);

  const restore = () => {
    const state = window[STATE];
    if (!state) return;
    if (state.how === 'container' && state.container) {
      state.container.style.width = state.was.width;
      state.container.style.maxWidth = state.was.maxWidth;
      state.container.style.marginLeft = state.was.marginLeft;
    } else {
      document.documentElement.style.zoom = state.was.zoom;
    }
    window.dispatchEvent(new Event('resize'));
    delete window[STATE];
  };

  if (window.NARROW_RESET) {
    restore();
    delete window.NARROW_RESET;
    return 'page put back to full width';
  }

  // ---------- First run: measure, then narrow ----------
  if (!window[STATE]) {
    const all = hosts();
    if (all.length === 0) return 'no Antsurance components on this page: nothing to check';
    const before = all.filter(h => visible(h.el)).map(h => ({ el: h.el, name: h.name, width: h.el.getBoundingClientRect().width }));
    const columns = [];
    all.forEach(h => headings(h.el.shadowRoot).forEach(el => visible(el) && columns.push({ el, host: h.el, name: h.name, text: words(el) })));
    const state = { before, columns, width };
    if (container) {
      state.how = 'container';
      state.container = container;
      state.was = { width: container.style.width, maxWidth: container.style.maxWidth, marginLeft: container.style.marginLeft };
      container.style.width = `${width}px`;
      container.style.maxWidth = `${width}px`;
      container.style.marginLeft = '0';
    } else {
      state.how = 'zoom';
      state.was = { zoom: document.documentElement.style.zoom };
      document.documentElement.style.zoom = String(Math.max(1, window.innerWidth / width).toFixed(3));
    }
    window[STATE] = state;
    window.dispatchEvent(new Event('resize'));
    return `narrowing to ${width}px by ${state.how === 'container' ? 'the page container' : 'page zoom'}: wait two seconds, then run this again to check`;
  }

  // ---------- Second run: did it narrow, and what broke ----------
  const state = window[STATE];
  const faults = [];
  const seen = new Set();
  const label = el => words(el).slice(0, 48);
  const leaves = el => [...el.querySelectorAll('*')].filter(e => e.children.length === 0 && e.textContent.trim() && !e.closest('.slds-assistive-text'));
  const lineCount = el => {
    const range = document.createRange();
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const tops = [];
    let node;
    while ((node = walker.nextNode())) {
      if (!node.textContent.trim() || node.parentElement.closest('.slds-assistive-text')) continue;
      range.selectNodeContents(node);
      for (const box of range.getClientRects()) if (box.width > 1) tops.push(box.top);
    }
    tops.sort((a, b) => a - b);
    let lines = tops.length ? 1 : 0;
    for (let i = 1; i < tops.length; i++) if (tops[i] - tops[i - 1] > 8) lines++;
    return lines;
  };
  const clipper = el => {
    // The nearest box that hides what sticks out of it.
    for (let p = el.parentElement; p; p = p.parentElement) {
      const style = getComputedStyle(p);
      if (style.overflowX !== 'visible' || style.overflowY !== 'visible') return p;
    }
    return null;
  };
  // A box that scrolls on purpose (a table, a tab strip) is not a fault.
  const scrolls = style => style.overflowX === 'auto' || style.overflowX === 'scroll';
  // Where the words themselves end, whatever box they are in.
  const textRight = el => {
    const range = document.createRange();
    range.selectNodeContents(el);
    let right = -Infinity;
    for (const box of range.getClientRects()) if (box.width > 1) right = Math.max(right, box.right);
    return right;
  };
  const ruler = document.createElement('canvas').getContext('2d');
  // Every word a person can see in a component, in lower case, leaving one element out. It reads each
  // element's own text nodes: a tree walker started on a shadow root finds nothing in Lightning.
  const shownText = (root, except) => {
    let text = '';
    root.querySelectorAll('*').forEach(el => {
      if (el === except || el.closest('.slds-assistive-text') || !visible(el)) return;
      el.childNodes.forEach(node => {
        if (node.nodeType === 3 && node.textContent.trim()) text += ` ${node.textContent}`;
      });
    });
    return text.replace(/\s+/g, ' ').toLowerCase();
  };
  const check = (root, owner) => {
    root.querySelectorAll('button, a.slds-button, [role="button"]').forEach(button => {
      if (seen.has(button)) return;
      seen.add(button);
      const box = button.getBoundingClientRect();
      const text = label(button);
      // A row or tile that is clickable holds several pieces of text and may wrap; a label is one piece.
      if (!text || text.length > 32 || box.width === 0 || leaves(button).length > 1) return;
      if (lineCount(button) > 1) faults.push(`${owner}  wrapped  "${text}"  ${Math.round(box.width)}x${Math.round(box.height)}`);
    });
    root.querySelectorAll('*').forEach(el => {
      if (el.children.length > 0 || !el.textContent.trim() || el.closest('.slds-assistive-text')) return;
      const box = el.getBoundingClientRect();
      // Nothing to see, or text kept only for a screen reader in a box one pixel wide.
      if (box.width <= 1 || box.height <= 1) return;
      // The text itself, then the two boxes around it: a label inside a cell overflows the cell, not itself.
      let at = el;
      for (let depth = 0; depth < 3 && at && at !== root; depth++, at = at.parentElement) {
        if (seen.has(at)) continue;
        if (at.clientWidth === 0 || at.scrollWidth <= at.clientWidth + 1) continue;
        const style = getComputedStyle(at);
        if (scrolls(style)) break;
        // Wider inside than out is only a fault when the words pass the box's edge: a row that bleeds
        // into its card's padding for a hover tint is wider than its box and perfectly readable.
        const over = Math.round(textRight(el) - at.getBoundingClientRect().right);
        if (over <= 1) continue;
        // One line per fault: the boxes around this one overflow for the same reason.
        for (let up = at, level = 0; up && level < 3; up = up.parentElement, level++) seen.add(up);
        faults.push(`${owner}  ${style.overflowX === 'visible' ? 'spills' : 'cut off'}  "${label(el)}"  by ${over}px`);
        return;
      }
      const holder = clipper(el);
      if (holder && !scrolls(getComputedStyle(holder))) {
        const edge = holder.getBoundingClientRect();
        if (box.right > edge.right + 1 && box.left < edge.right) faults.push(`${owner}  runs off  "${label(el)}"  by ${Math.round(box.right - edge.right)}px`);
      }
    });
  };
  // A prompt inside a text box is cut silently: the box shows what fits and nothing says there was more.
  const checkPrompts = (root, owner) => {
    root.querySelectorAll('input[placeholder], textarea[placeholder]').forEach(input => {
      if (input.value || !input.placeholder || input.clientWidth === 0 || input.tagName === 'TEXTAREA') return;
      const style = getComputedStyle(input);
      ruler.font = style.font;
      const room = input.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      const over = Math.round(ruler.measureText(input.placeholder).width - room);
      if (over > 1) faults.push(`${owner}  cut off  prompt "${input.placeholder.slice(0, 48)}"  by ${over}px`);
    });
  };
  // A button that floats over the page must not sit on words.
  const checkFloating = (root, owner, all) => {
    root.querySelectorAll('button, a, [role="button"]').forEach(button => {
      let fixed = false;
      for (let p = button; p && p !== root; p = p.parentElement) {
        const position = getComputedStyle(p).position;
        if (position === 'fixed' || position === 'sticky') fixed = true;
      }
      if (!fixed || !visible(button)) return;
      const me = button.getBoundingClientRect();
      for (const host of all) {
        if (host.el.contains(button) || host.el.shadowRoot.contains(button)) continue;
        for (const leaf of leaves(host.el.shadowRoot)) {
          if (!visible(leaf)) continue;
          const right = textRight(leaf);
          const box = leaf.getBoundingClientRect();
          if (right > me.left + 2 && box.left < me.right - 2 && box.bottom > me.top + 2 && box.top < me.bottom - 2) {
            faults.push(`${owner}  covers  "${label(button)}" sits on "${label(leaf)}" in ${host.name}`);
            return;
          }
        }
      }
    });
  };

  // A box that scrolls sideways is passed over above, because a tab strip or a table is meant to. That
  // let through a strip of tabs squeezed by its flex parent to a 6px sliver with every tab hidden
  // inside it. A strip that scrolls is fine while a tab or two is out of view; it is broken when it is
  // narrower than its narrowest tab or button, so not one of them can be read or pressed.
  const checkSqueezed = (root, owner) => {
    root.querySelectorAll('*').forEach(strip => {
      if (strip.scrollWidth <= strip.clientWidth + 1 || !scrolls(getComputedStyle(strip))) return;
      const box = strip.getBoundingClientRect();
      if (box.height <= 1) return;
      const widths = [...strip.querySelectorAll('button, a, [role="tab"]')].map(item => item.getBoundingClientRect().width).filter(w => w > 1);
      if (widths.length === 0 || strip.clientWidth >= Math.min(...widths)) return;
      faults.push(`${owner}  squeezed  "${label(strip)}"  shows ${Math.round(box.width)}px of the ${strip.scrollWidth}px inside it`);
    });
  };

  const all = hosts();
  // Did the page really get narrower? Compare each component with its width at full size.
  let shrank = null;
  for (const was of state.before) {
    if (!was.el.isConnected) continue;
    const now = was.el.getBoundingClientRect().width;
    if (was.width - now >= 16 && (!shrank || was.width - now > shrank.by)) shrank = { name: was.name, from: Math.round(was.width), to: Math.round(now), by: was.width - now };
  }
  if (!shrank) {
    restore();
    return `did not narrow: no component got narrower at ${state.width}px (by ${state.how}). Narrow layouts are NOT checked on this page.`;
  }

  all.forEach(h => {
    check(h.el.shadowRoot, h.name);
    checkPrompts(h.el.shadowRoot, h.name);
    checkFloating(h.el.shadowRoot, h.name, all);
    checkSqueezed(h.el.shadowRoot, h.name);
  });
  // A heading that showed at full width and is gone now, with nothing in the component saying its name.
  state.columns.forEach(column => {
    if (!column.el.isConnected || visible(column.el)) return;
    const said = shownText(column.host.shadowRoot, column.el).includes(column.text.toLowerCase());
    if (!said) faults.push(`${column.name}  column gone  "${column.text}" showed at full width and is not said when narrow`);
  });
  // Taller than the window. The innermost tall component is the one named: a page is a stack of
  // components and is allowed to scroll, so a component holding three or more sizeable ones is a page
  // layout and is passed over, and so is one whose height comes from a tall component inside it.
  const heightOf = h => h.el.getBoundingClientRect().height;
  all.filter(h => visible(h.el) && heightOf(h) > window.innerHeight).forEach(h => {
    const inside = all.filter(k => k.parent === h.el && visible(k.el));
    if (inside.filter(k => heightOf(k) > 150).length >= 3) return;
    if (inside.some(k => heightOf(k) > window.innerHeight)) return;
    faults.push(`${h.name}  too tall  ${Math.round(heightOf(h))}px in a ${window.innerHeight}px window`);
  });

  const how = state.how;
  const asked = state.width;
  restore();
  const unique = [...new Set(faults)];
  const proof = `narrowed to ${asked}px by ${how === 'container' ? 'the page container' : 'page zoom'}; ${shrank.name} went ${shrank.from} to ${shrank.to}px`;
  return unique.length ? `${unique.length} faults (${proof}):\n${unique.join('\n')}` : `clean (${proof})`;
})()
