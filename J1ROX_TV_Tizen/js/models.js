/* Shared data contract with the existing ATODO clients; no platform dependencies. */
(function (root, factory) {
    var model = factory();
    if (typeof module === 'object' && module.exports) module.exports = model;
    else { root.JTV = root.JTV || {}; root.JTV.model = model; }
}(this, function () {
    'use strict';
    function text(obj, keys) {
        obj = obj || {};
        for (var i = 0; i < keys.length; i++) {
            var value = obj[keys[i]];
            if (typeof value === 'string' && value.trim()) return value.trim();
            if (typeof value === 'number') return String(value);
        }
        return '';
    }
    function object(value) { return value && typeof value === 'object' && !Array.isArray(value); }
    function unwrap(value) {
        if (!object(value)) return {};
        var keys = ['data', 'result', 'item', 'movie'];
        for (var i = 0; i < keys.length; i++) if (object(value[keys[i]])) return value[keys[i]];
        return value;
    }
    function list(value) {
        if (Array.isArray(value)) return value;
        if (!object(value)) return [];
        var keys = ['results', 'items', 'data', 'movies', 'content', 'list', 'docs'];
        for (var i = 0; i < keys.length; i++) {
            if (value[keys[i]]) { var found = list(value[keys[i]]); if (found.length) return found; }
        }
        return [];
    }
    function url(value) {
        if (typeof value !== 'string') return '';
        value = value.replace(/\\\//g, '/').split('|')[0].trim();
        return /^https?:\/\/[^\s/?#]+(?:[/?#][^\s]*)?$/i.test(value) ? value : '';
    }
    function image(value) {
        if (!value) return '';
        if (value.indexOf('//') === 0) return url('https:' + value);
        if (value.charAt(0) === '/') return 'https://image.tmdb.org/t/p/w780' + value;
        return url(value);
    }
    function media(raw, type) {
        var year = text(raw, ['first_air_date', 'release_date', 'year']).slice(0, 4);
        var rating = Number(raw.vote_average || raw.rating || 0);
        var canonical = {
            id: text(raw, ['id', 'tmdb_id']), title: text(raw, ['title', 'name']),
            original_title: text(raw, ['original_title', 'original_name']),
            original_language: text(raw, ['original_language']),
            imdb_id: text(raw, ['imdb_id']) || text(raw.external_ids, ['imdb_id']),
            year: year, type: raw.media_type === 'tv' || raw.type === 'tv' || type === 'tv' || raw.first_air_date ? 'tv' : 'movie'
        };
        Object.keys(canonical).forEach(function (key) { if (!canonical[key]) delete canonical[key]; });
        return {
            id: canonical.id, type: canonical.type, title: canonical.title || 'Без названия', year: year,
            overview: text(raw, ['overview', 'description']), rating: isFinite(rating) && rating > 0 ? rating.toFixed(1) : '',
            poster: image(text(raw, ['poster_path', 'poster', 'image'])), backdrop: image(text(raw, ['backdrop_path', 'backdrop'])),
            genres: (Array.isArray(raw.genres) ? raw.genres : []).map(function (g) { return typeof g === 'string' ? g : text(g, ['name']); }).filter(Boolean).join(' · '),
            canonical: canonical
        };
    }
    function collection(value, kind) {
        if (!value || typeof value !== 'object') return [];
        var keys = kind === 'translation' ? ['translation_id', 'id'] : [kind + '_number', kind, 'number', kind + '_id', 'id'];
        return Object.keys(value).map(function (key, index) {
            var node = value[key];
            if (!object(node)) return null;
            var fallback = Array.isArray(value) ? String(index + 1) : key;
            var number = text(node, keys) || fallback;
            return { id: text(node, [kind + '_id', 'id']) || number, number: number,
                name: text(node, [kind + '_name', 'name', 'title', 'label', 'voice', 'studio']) ||
                    (kind === 'translation' ? 'Озвучка ' : kind === 'season' ? 'Сезон ' : 'Серия ') + number,
                payload: node };
        }).filter(Boolean).sort(function (a, b) { return a.number.localeCompare(b.number, 'en', { numeric: true }); });
    }
    function streams(payload) {
        var found = [];
        function add(value, hls) {
            var clean = url(value);
            if (clean && !found.some(function (x) { return x.url === clean; })) found.push({ url: clean, hls: !!hls || /\.m3u8(?:[?#]|$)/i.test(clean) });
        }
        function walk(node, key) {
            if (object(node)) {
                var video = node.streams && node.streams.video;
                if (video) ['hls', 'http'].forEach(function (transport) {
                    var stream = video[transport];
                    if (!object(stream)) return;
                    add(stream.master, transport === 'hls');
                    Object.keys(stream.qualities || {}).sort(function (a, b) { return parseInt(b, 10) - parseInt(a, 10); }).forEach(function (q) { add(stream.qualities[q], transport === 'hls'); });
                });
                Object.keys(node).forEach(function (k) { walk(node[k], k.toLowerCase()); });
            } else if (Array.isArray(node)) node.forEach(function (n) { walk(n, key); });
            else if (typeof node === 'string' && (/^(url|src|file|stream|hls|master)$/.test(key) || /\.(m3u8|mp4)(?:[?#|]|$)/i.test(node))) add(node, key === 'hls');
        }
        walk(payload, '');
        return found.filter(function (x) { return x.hls; }).concat(found.filter(function (x) { return !x.hls; }));
    }
    function selection(detail) {
        return { source: detail.source, voice: detail.voice && detail.voice.id, voiceName: detail.voice && detail.voice.name,
            season: detail.season && detail.season.number, episode: detail.episode && detail.episode.number };
    }
    function sameEpisode(a, b) { return (a.season || '') === (b.season || '') && (a.episode || '') === (b.episode || ''); }
    function nextEpisode(voice, season, episode) {
        var seasons = collection(voice && voice.payload.seasons, 'season');
        for (var s = 0; s < seasons.length; s++) {
            if (seasons[s].number !== season.number) continue;
            var episodes = collection(seasons[s].payload.episodes, 'episode');
            for (var e = 0; e < episodes.length; e++) if (episodes[e].number === episode.number) {
                if (episodes[e + 1]) return { season: seasons[s], episode: episodes[e + 1] };
                for (var n = s + 1; n < seasons.length; n++) {
                    var next = collection(seasons[n].payload.episodes, 'episode')[0];
                    if (next) return { season: seasons[n], episode: next };
                }
            }
        }
        return null;
    }
    return { text: text, object: object, unwrap: unwrap, list: list, url: url, media: media, collection: collection,
        streams: streams, selection: selection, sameEpisode: sameEpisode, nextEpisode: nextEpisode };
}));
