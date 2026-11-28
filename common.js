// Shared helpers: storage, download, upload
const Store = {
  key: (type, id) => `office:${type}:${id}`,
  list(type) {
    const out = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k.startsWith(`office:${type}:`)) {
        try { const d = JSON.parse(localStorage.getItem(k)); out.push({ id: k.split(':')[2], title: d.title || 'Untitled', modified: d.modified || 0 }); } catch (e) {}
      }
    }
    return out.sort((a, b) => b.modified - a.modified);
  },
  load(type, id) { try { return JSON.parse(localStorage.getItem(Store.key(type, id))); } catch (e) { return null; } },
  save(type, id, data) { data.modified = Date.now(); localStorage.setItem(Store.key(type, id), JSON.stringify(data)); },
  remove(type, id) { localStorage.removeItem(Store.key(type, id)); },
  newId: () => Math.random().toString(36).slice(2, 10),
};
function docId(type) {
  const p = new URLSearchParams(location.search);
  let id = window.__FO_DOC || p.get('id');
  if (!id) { id = Store.newId(); history.replaceState(null, '', `?id=${id}`); }
  return id;
}
function download(name, text, mime = 'text/plain') {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type: mime }));
  a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
function pickFile(accept, cb) {
  const i = document.createElement('input'); i.type = 'file'; i.accept = accept;
  i.onchange = () => { const f = i.files[0]; if (!f) return; const r = new FileReader(); r.onload = () => cb(r.result, f.name); r.readAsText(f); };
  i.click();
}
function debounce(fn, ms = 400) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }

// ---- App registry & shared helpers ----
const APPS = {
  writer: { one: 'document', name: 'Writer',  mark: 'Fw', icon: '📝', page: 'writer.html', blurb: 'Documents' },
  sheets: { one: 'spreadsheet', name: 'Sheets',  mark: 'Fs', icon: '📊', page: 'sheets.html', blurb: 'Spreadsheets' },
  slides: { one: 'presentation', name: 'Slides',  mark: 'Fl', icon: '🎞️', page: 'slides.html', blurb: 'Presentations' },
  poster: { one: 'poster', name: 'Poster',  mark: 'Fp', icon: '🎨', page: 'poster.html', blurb: 'Posters & layouts' },
  data:   { one: 'database', name: 'Data',    mark: 'Fd', icon: '🗄️', page: 'data.html',   blurb: 'Databases' },
};
// "FreeOffice" link goes back to wherever the launcher was opened from (all apps, or one standalone app)
document.addEventListener('DOMContentLoaded', () => {
  let home = 'index.html';
  try { home = sessionStorage.getItem('fo-home') || home; } catch (e) {}
  document.querySelectorAll('a.home').forEach(a => {
    a.href = home; a.textContent = 'FreeOffice';
    // inside the native SwiftUI shell the toolbar provides "back", so hide the web link
    if (window.__FO_NATIVE) a.style.display = 'none';
  });
});
// In the Mac apps, native code mirrors office:* keys to disk (shared by every FreeOffice app).
(function () {
  const h = window.webkit && webkit.messageHandlers && webkit.messageHandlers.store;
  if (!h) return;
  const set = Storage.prototype.setItem, del = Storage.prototype.removeItem;
  Storage.prototype.setItem = function (k, v) { set.call(this, k, v); if (this === localStorage && k.startsWith('office:')) h.postMessage({ k, v: String(v) }); };
  Storage.prototype.removeItem = function (k) { del.call(this, k); if (this === localStorage && k.startsWith('office:')) h.postMessage({ k, v: null }); };
})();
