(function (app) {
    'use strict';
    var BASE = 'https://api.atodo.fun/';
    var M = app.model;
    function debug(message) {
        try { if (localStorage.getItem('j1rox.debug') === '1') console.debug('[API] ' + message); } catch (err) { /* optional diagnostics */ }
    }
    function request(path, params) {
        var query = Object.keys(params || {}).filter(function (k) { return params[k] !== '' && params[k] != null; }).map(function (k) {
            return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
        }).join('&');
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            var original = BASE + path + (query ? '?' + query : '');
            debug('Original URL: ' + original);
            xhr.open('GET', original, true);
            xhr.timeout = 25000;
            // Origin, Referer and User-Agent are browser-controlled; never spoof them.
            xhr.setRequestHeader('Accept', 'application/json, text/plain, */*');
            xhr.onload = function () {
                debug('HTTP ' + xhr.status + ' Final response URL: ' + (xhr.responseURL || original));
                if (xhr.status < 200 || xhr.status >= 300) { reject(new Error('API ' + path.split('?')[0] + ': HTTP ' + xhr.status)); return; }
                try { resolve(JSON.parse(xhr.responseText)); }
                catch (err) { reject(new Error('API вернул не JSON (' + path + '). Возможно, ответ защиты сервера.')); }
            };
            xhr.onerror = function () { reject(new Error('API недоступен: сеть, TLS или CORS (XHR status 0). ' + BASE + path + '. Проверьте сеть и Web Inspector.')); };
            xhr.ontimeout = function () { reject(new Error('API: время ожидания 25 секунд истекло (' + path + ').')); };
            xhr.send();
        });
    }
    function content(item, source) { return request('api/source/' + encodeURIComponent(source), item.canonical).then(M.unwrap); }
    app.api = {
        base: BASE, request: request,
        catalog: function (type, page) { return request('api/list', { type_movie: type, page: page || 1 }).then(function (r) { return M.list(r).map(function (x) { return M.media(x, type); }).filter(function (x) { return x.id; }); }); },
        search: function (query, page) { return request('api/search', { query: query, page: page || 1 }).then(function (r) { return M.list(r).map(function (x) { return M.media(x); }).filter(function (x) { return x.id; }); }); },
        details: function (item) { return request('api/details/' + item.type + '/' + encodeURIComponent(item.id)).then(function (r) { return M.media(M.unwrap(r), item.type); }); },
        sources: function (item) { return request('api/source/list', item.canonical).then(function (r) { return (M.unwrap(r).balancers || []).map(function (s) { return { id: M.text(s, ['id', 'source_id', 'key']), name: M.text(s, ['name', 'title', 'label', 'id']) }; }).filter(function (s) { return s.id; }); }); },
        content: content,
        resolve: function (source, container) {
            var direct = M.streams(container);
            if (direct.length) return Promise.resolve(direct);
            if (!container || !M.object(container.data)) return Promise.reject(new Error('Источник не вернул видео или данные для его получения. Выберите другую озвучку или источник.'));
            var bytes = unescape(encodeURIComponent(JSON.stringify(container.data)));
            return request('api/source/' + encodeURIComponent(source), { data: btoa(bytes) }).then(function (r) {
                var result = M.streams(r);
                if (!result.length) throw new Error('Источник не вернул HTTP/HLS поток. Выберите другой источник.');
                return result;
            });
        }
    };
}(window.JTV));
