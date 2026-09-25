(function (app) {
    'use strict';
    var KEY = 'j1rox.tizen.library.v1';
    var data = { favorites: {}, history: {} };
    function key(item) { return item.type + ':' + item.id; }
    try {
        var saved = JSON.parse(localStorage.getItem(KEY) || 'null');
        if (saved && saved.favorites && saved.history) data = saved;
    } catch (err) { console.warn('[Library] Cannot read local storage', err.name); }
    function save() {
        try { localStorage.setItem(KEY, JSON.stringify(data)); }
        catch (err) { if (app.notify) app.notify('Не удалось сохранить библиотеку: ' + err.name); }
    }
    function entries(group) { return Object.keys(data[group]).map(function (k) { return data[group][k]; }).filter(function (e) { return e && e.item && e.item.id; }).sort(function (a, b) { return b.updated - a.updated; }); }
    app.library = {
        favorites: function () { return entries('favorites').map(function (e) { return e.item; }); },
        history: function () { return entries('history').filter(function (e) { return e.position > 0 && !e.completed; }).map(function (e) { return e.item; }); },
        has: function (item) { return !!data.favorites[key(item)]; },
        toggle: function (item) {
            if (this.has(item)) delete data.favorites[key(item)];
            else data.favorites[key(item)] = { item: item, updated: Date.now() };
            save();
        },
        progress: function (item) { return data.history[key(item)] || null; },
        record: function (item, selection, position, duration, completed) {
            if (!isFinite(position) || position < 0) return;
            // Media metadata + logical episode identifiers only, never expiring CDN URLs.
            data.history[key(item)] = { item: item, selection: selection, position: completed ? 0 : position,
                duration: isFinite(duration) ? duration : 0, completed: !!completed, updated: Date.now() };
            entries('history').slice(100).forEach(function (e) { delete data.history[key(e.item)]; });
            save();
        }
    };
}(window.JTV));
