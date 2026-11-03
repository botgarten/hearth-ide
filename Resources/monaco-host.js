// Host page script for Hearth's Monaco editor (loaded by MonacoPage; talks to Swift through the
// "hearth" script message handler). One editor instance per Preview pane, one Monaco model per
// open file: undo history, cursor and scroll position survive tab switches.
(function () {
  'use strict';
  const cfg = window.__hearth || {};
  const labels = cfg.labels || {};
  const base = 'hearth-monaco://editor';
  const post = (m) => { try { window.webkit.messageHandlers.hearth.postMessage(m); } catch (e) { /* page without host */ } };

  for (const level of ['error', 'warn']) {
    const original = console[level].bind(console);
    console[level] = (...args) => { original(...args); post({ t: 'log', level, message: args.map(String).join(' ').slice(0, 500) }); };
  }
  window.addEventListener('error', (e) => post({ t: 'error', message: String(e.message || e) }));
  window.addEventListener('unhandledrejection', (e) => post({ t: 'error', message: String(e.reason && e.reason.message || e.reason) }));

  // Web workers: a blob worker that pulls Monaco's worker bootstrap from the closed scheme.
  self.MonacoEnvironment = {
    getWorker(_id, label) {
      const src = "self.MonacoEnvironment={baseUrl:'" + base + "/'};importScripts('" + base + "/vs/base/worker/workerMain.js');";
      return new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })), { name: label });
    },
  };

  const nls = cfg.locale === 'de' ? { availableLanguages: { '*': 'de' } } : {};
  require.config({ paths: { vs: 'vs' }, 'vs/nls': nls });
  require(['vs/editor/editor.main'], boot, (err) => post({ t: 'error', message: 'Monaco failed to load: ' + (err && err.message || err) }));

  function boot() {
    const monaco = window.monaco;
    const container = document.getElementById('editor');

    // The TypeScript service only knows the files that are open here. Keep what is right for a
    // single file (completion, hover, syntax) and switch off what would be misleading
    // (cross-file errors, definitions, references, rename): Hearth searches the workspace itself.
    for (const defaults of [monaco.languages.typescript.javascriptDefaults, monaco.languages.typescript.typescriptDefaults]) {
      defaults.setDiagnosticsOptions({ noSemanticValidation: true, noSyntaxValidation: false, noSuggestionDiagnostics: true });
      defaults.setCompilerOptions({ allowJs: true, allowNonTsExtensions: true, checkJs: false, noResolve: true,
        target: monaco.languages.typescript.ScriptTarget.ESNext, jsx: monaco.languages.typescript.JsxEmit.Preserve });
      defaults.setModeConfiguration({ completionItems: true, hovers: true, documentSymbols: true, definitions: false,
        references: false, documentHighlights: true, rename: false, diagnostics: true, documentRangeFormattingEdits: true,
        signatureHelp: true, onTypeFormattingEdits: true, codeActions: false, inlayHints: false });
    }

    const editor = monaco.editor.create(container, {
      model: null,
      automaticLayout: true,
      fontFamily: 'SF Mono, Menlo, Monaco, monospace',
      fontSize: 12,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      smoothScrolling: true,
      renderWhitespace: 'selection',
      lineNumbersMinChars: 3,
      lineDecorationsWidth: 12,
      glyphMargin: false,
      padding: { top: 6, bottom: 6 },
      stickyScroll: { enabled: true },
      bracketPairColorization: { enabled: true },
      accessibilitySupport: 'off',
      mouseWheelZoom: false,
      contextmenu: true,
      wordBasedSuggestions: 'currentDocument',
      renderLineHighlight: 'line',
      scrollbar: { useShadows: false },
      overviewRulerBorder: false,
      unicodeHighlight: { ambiguousCharacters: false },
    });

    const docs = new Map();          // key -> { model, view, pending, hunks, selected }
    let currentKey = null;
    let changeTimer = null;
    let themeCounter = 0;
    let findDecorations = editor.createDecorationsCollection();
    let flashDecorations = editor.createDecorationsCollection();
    let hunkDecorations = editor.createDecorationsCollection();
    let linkDecorations = editor.createDecorationsCollection();
    let flashTimer = null;
    const hasHunks = editor.createContextKey('hearthHasHunks', false);

    // ---- change reporting ------------------------------------------------------------------

    function reportPending() {
      if (changeTimer !== null) { clearTimeout(changeTimer); changeTimer = null; }
      for (const [key, d] of docs) {
        if (!d.pending) continue;
        d.pending = false;
        post({ t: 'change', key, text: d.model.getValue() });
      }
    }

    function attach(key, text, language) {
      const model = monaco.editor.createModel(text, language, monaco.Uri.file(key));
      const d = { model, view: null, pending: false, hunks: [], selected: null, language };
      model.onDidChangeContent(() => {
        if (applying) return;
        d.pending = true;
        if (changeTimer === null) changeTimer = setTimeout(reportPending, 80);
      });
      docs.set(key, d);
      return d;
    }

    let applying = false;
    function setText(d, text) {
      if (d.model.getValue() === text) return;
      applying = true;
      try {
        // A full replace keeps the undo stack, so ⌘Z brings back what "Discard" removed.
        d.model.pushEditOperations([], [{ range: d.model.getFullModelRange(), text }], () => null);
        d.model.pushStackElement();
      } finally { applying = false; }
      d.pending = false;
    }

    // ---- state from Swift --------------------------------------------------------------------

    function showModel(key) {
      if (currentKey === key) return;
      reportPending();
      const old = currentKey && docs.get(currentKey);
      if (old) old.view = editor.saveViewState();
      currentKey = key;
      const d = docs.get(key);
      editor.setModel(d.model);
      if (d.view) editor.restoreViewState(d.view);
      paintHunks();
      findDecorations.clear();
      linkDecorations.clear();
    }

    function paintHunks() {
      const d = currentKey && docs.get(currentKey);
      const out = [];
      if (d) {
        const lines = d.model.getLineCount();
        for (const h of d.hunks) {
          const sel = h.id === d.selected ? ' hh-selected' : '';
          if (h.kind === 'deleted') {
            const line = Math.min(Math.max(1, h.anchor), lines);
            out.push({ range: new monaco.Range(line, 1, line, 1),
              options: { isWholeLine: true, linesDecorationsClassName: 'hh-bar hh-bar-deleted' + sel, className: sel ? 'hh-line-deleted' : '' } });
          } else {
            const from = Math.min(Math.max(1, h.start), lines), to = Math.min(h.start + h.count - 1, lines);
            out.push({ range: new monaco.Range(from, 1, Math.max(from, to), 1),
              options: { isWholeLine: true, className: 'hh-line-' + h.kind + sel, linesDecorationsClassName: 'hh-bar hh-bar-' + h.kind + sel } });
          }
        }
        hasHunks.set(d.hunks.length > 0);
      }
      hunkDecorations.set(out);
    }

    function markTerm(term, line) {
      findDecorations.clear();
      const model = editor.getModel();
      if (!model || !term) return;
      const matches = model.findMatches(term, false, false, false, null, false, 5000);
      findDecorations.set(matches.map((m) => ({ range: m.range,
        options: { inlineClassName: 'hh-find', overviewRuler: { color: 'rgba(255,160,0,.8)', position: monaco.editor.OverviewRulerLane.Center } } })));
      const target = (line && matches.find((m) => m.range.startLineNumber === line)) || matches[0];
      if (target) {
        editor.setSelection(target.range);
        editor.revealRangeInCenterIfOutsideViewport(target.range, monaco.editor.ScrollType.Immediate);
      }
    }

    function flashLine(line) {
      clearTimeout(flashTimer);
      flashDecorations.set([{ range: new monaco.Range(line, 1, line, 1), options: { isWholeLine: true, className: 'hh-flash' } }]);
      flashTimer = setTimeout(() => flashDecorations.clear(), 1600);
    }

    function reveal(r) {
      const model = editor.getModel();
      if (!model) return;
      if (r.line) {
        const line = Math.min(Math.max(1, r.line), model.getLineCount());
        editor.setPosition({ lineNumber: line, column: 1 });
        editor.revealLineInCenter(line, monaco.editor.ScrollType.Immediate);
        flashLine(line);
      }
      markTerm(r.term, r.line);
    }

    function defineTheme(t) {
      const name = 'hearth-' + (++themeCounter);
      monaco.editor.defineTheme(name, t);
      monaco.editor.setTheme(name);
      document.documentElement.style.setProperty('--hh-bg', (t.colors && t.colors['editor.background']) || '#fff');
    }

    window.hearth = {
      apply(s) {
        if (s.theme) defineTheme(s.theme);
        if (s.fontSize) editor.updateOptions({ fontSize: s.fontSize });
        if (s.doc) {
          let d = docs.get(s.doc.key);
          if (!d) d = attach(s.doc.key, s.doc.text, s.doc.language);
          else {
            if (d.language !== s.doc.language) { monaco.editor.setModelLanguage(d.model, s.doc.language); d.language = s.doc.language; }
            if (s.doc.text !== null) setText(d, s.doc.text);
          }
          showModel(s.doc.key);
        }
        if (s.hunks) {
          const d = docs.get(s.hunks.key);
          if (d) { d.hunks = s.hunks.list; d.selected = s.hunks.selected; if (s.hunks.key === currentKey) paintHunks(); }
        }
        if (s.retain) {
          const keep = new Set(s.retain);
          for (const [key, d] of docs) {
            if (key === currentKey || keep.has(key)) continue;
            d.model.dispose();
            docs.delete(key);
          }
        }
        if (s.reveal) reveal(s.reveal);
        if (s.focus) editor.focus();
      },
      /** Pushes pending edits now and returns the shown document's text (used before saving). */
      flush() {
        reportPending();
        return currentKey ? { key: currentKey, text: docs.get(currentKey).model.getValue() } : null;
      },
    };

    // ---- messages to Swift ------------------------------------------------------------------

    editor.onDidFocusEditorText(() => post({ t: 'focus' }));
    window.addEventListener('blur', reportPending);

    function identifierAt(model, pos) {
      const w = model.getWordAtPosition(pos);
      if (!w || !/^[A-Za-z_$][\w$]*$/.test(w.word)) return null;
      const before = model.getValueInRange({ startLineNumber: pos.lineNumber, startColumn: 1, endLineNumber: pos.lineNumber, endColumn: w.startColumn });
      const q = /([A-Za-z_$][\w$]*)\s*\.\s*$/.exec(before);
      return { word: w.word, qualifier: q ? q[1] : null, range: new monaco.Range(pos.lineNumber, w.startColumn, pos.lineNumber, w.endColumn) };
    }

    function symbolAtCursor() {
      const model = editor.getModel(), sel = editor.getSelection();
      if (!model || !sel) return null;
      if (!sel.isEmpty()) {
        const text = model.getValueInRange(sel).trim();
        if (/^[A-Za-z_$][\w$]*$/.test(text)) return { word: text, qualifier: null };
      }
      return identifierAt(model, sel.getPosition());
    }

    // ⌘-click on a name: go to definition (Swift looks in the whole workspace).
    container.addEventListener('mousedown', (e) => {
      if (!e.metaKey || e.button !== 0) return;
      const t = editor.getTargetAtClientPoint(e.clientX, e.clientY);
      if (!t || t.type !== monaco.editor.MouseTargetType.CONTENT_TEXT || !t.position) return;
      const id = identifierAt(editor.getModel(), t.position);
      if (!id) return;
      e.preventDefault();
      e.stopPropagation();
      post({ t: 'define', symbol: id.word, qualifier: id.qualifier, line: t.position.lineNumber });
    }, true);

    // Underline the name under the pointer while ⌘ is held.
    let metaDown = false;
    function underline(e) {
      if (!metaDown) { linkDecorations.clear(); container.classList.remove('hh-cmd'); return; }
      const t = e && editor.getTargetAtClientPoint(e.clientX, e.clientY);
      const id = t && t.type === monaco.editor.MouseTargetType.CONTENT_TEXT && t.position && identifierAt(editor.getModel(), t.position);
      container.classList.toggle('hh-cmd', !!id);
      linkDecorations.set(id ? [{ range: id.range, options: { inlineClassName: 'hh-link' } }] : []);
    }
    window.addEventListener('keydown', (e) => { if (e.key === 'Meta' && !metaDown) { metaDown = true; } }, true);
    window.addEventListener('keyup', (e) => { if (e.key === 'Meta') { metaDown = false; underline(null); } }, true);
    window.addEventListener('blur', () => { metaDown = false; underline(null); });
    container.addEventListener('mousemove', (e) => { metaDown = e.metaKey; if (metaDown) underline(e); else if (container.classList.contains('hh-cmd')) underline(null); });

    // Keys that belong to the app (menu shortcuts): Monaco must not take them.
    const appKeys = new Set(['shift+o', 'shift+f', 'shift+a', 'w', '=', '+', '-', '0', ',', 'q', 'h', 'm', 'n', 't']);
    window.addEventListener('keydown', (e) => {
      if (!e.metaKey || e.altKey || e.ctrlKey) return;
      const k = (e.shiftKey ? 'shift+' : '') + e.key.toLowerCase();
      if (appKeys.has(k)) e.stopPropagation();   // not preventDefault: WebKit hands it to the menu
    }, true);

    const KM = monaco.KeyMod, KC = monaco.KeyCode;
    editor.addCommand(KM.CtrlCmd | KC.KeyS, () => { reportPending(); post({ t: 'save', key: currentKey }); });
    editor.addCommand(KM.CtrlCmd | KC.BracketLeft, () => post({ t: 'nav', dir: -1 }));
    editor.addCommand(KM.CtrlCmd | KC.BracketRight, () => post({ t: 'nav', dir: 1 }));
    editor.addCommand(KM.CtrlCmd | KM.Alt | KC.UpArrow, () => post({ t: 'hunk', dir: -1 }), 'hearthHasHunks');
    editor.addCommand(KM.CtrlCmd | KM.Alt | KC.DownArrow, () => post({ t: 'hunk', dir: 1 }), 'hearthHasHunks');
    editor.addCommand(KM.CtrlCmd | KC.KeyL, () => editor.getAction('editor.action.gotoLine').run());
    editor.addCommand(KC.F12, () => {
      const id = symbolAtCursor();
      if (id) post({ t: 'define', symbol: id.word, qualifier: id.qualifier, line: editor.getPosition().lineNumber });
    });

    editor.addAction({
      id: 'hearth.findUsages',
      label: labels.findUsages || 'Find Usages',
      keybindings: [KM.Alt | KC.F7],
      contextMenuGroupId: 'navigation',
      contextMenuOrder: 1.1,
      run() {
        const id = symbolAtCursor();
        if (id) post({ t: 'usages', symbol: id.word, qualifier: id.qualifier, line: editor.getPosition().lineNumber });
      },
    });
    editor.addAction({
      id: 'hearth.goToDefinition',
      label: labels.goToDefinition || 'Go to Definition',
      contextMenuGroupId: 'navigation',
      contextMenuOrder: 1.0,
      run() {
        const id = symbolAtCursor();
        if (id) post({ t: 'define', symbol: id.word, qualifier: id.qualifier, line: editor.getPosition().lineNumber });
      },
    });

    // A click in the change bar selects the hunk for review.
    editor.onMouseDown((e) => {
      if (e.target.type !== monaco.editor.MouseTargetType.GUTTER_LINE_DECORATIONS || !e.target.position || !currentKey) return;
      const line = e.target.position.lineNumber;
      const hit = docs.get(currentKey).hunks.find((h) => h.kind === 'deleted' ? h.anchor === line : line >= h.start && line < h.start + h.count);
      if (hit) post({ t: 'hunk-click', id: hit.id });
    });

    post({ t: 'ready' });
  }
})();
