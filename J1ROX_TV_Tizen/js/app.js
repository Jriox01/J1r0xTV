(function (app) {
    'use strict';
    var M = app.model, api = app.api, library = app.library, focus = app.focus, player = app.player;
    var content = document.getElementById('content'), stage = document.getElementById('stage');
    var playback = document.getElementById('playback'), controls = document.getElementById('player-controls');
    var route = { name: 'home' }, stack = [], revision = 0, detail = null, playing = false;
    var query = '', latin = false, toastTimer, lastSaved = 0, ended = false, playerError = false;
    var playbackSelection = null, controlsAction = false, suspended = false;
    function node(tag, className, value) {
        var el = document.createElement(tag);
        if (className) el.className = className;
        if (value != null) el.textContent = value;
        return el;
    }
    function button(label, id, action, className) {
        var el = node('button', className, label);
        el.type = 'button'; el.setAttribute('data-focus', id); el.onclick = action;
        return el;
    }
    function append(parent, children) { children.forEach(function (el) { if (el) parent.appendChild(el); }); return parent; }
    function poster(src, title, className) {
        var el = node('img', className); el.alt = title;
        el.src = src || 'assets/poster.svg';
        el.onerror = function () { el.onerror = null; el.src = 'assets/poster.svg'; };
        return el;
    }
    function currentFocus() { return document.activeElement && document.activeElement.getAttribute('data-focus'); }
    function restore(id) { focus.restore(id || route.focus, content); }
    function status(message) { content.appendChild(node('div', 'loading', message)); }
    function error(message, retry) {
        var box = node('div', 'error', message);
        if (retry) box.appendChild(button('Повторить', 'retry', retry));
        content.appendChild(box); restore('retry');
    }
    function screenError(err, token) {
        if (token !== revision) return;
        content.innerHTML = ''; error(err.message || String(err), render);
    }
    app.notify = function (message) {
        var toast = document.getElementById('toast'); toast.textContent = message; toast.hidden = false;
        clearTimeout(toastTimer); toastTimer = setTimeout(function () { toast.hidden = true; }, 6000);
    };
    function nav() {
        var target = document.getElementById('nav'); target.innerHTML = '';
        [['home', 'Главная'], ['search', 'Поиск'], ['movie', 'Фильмы'], ['tv', 'Сериалы'], ['library', 'Моё']].forEach(function (entry) {
            target.appendChild(button(entry[1], 'nav-' + entry[0], function () {
                stack = []; route = { name: entry[0] }; detail = null; render();
            }, route.name === entry[0] ? 'selected' : ''));
        });
    }
    function go(next) {
        route.focus = currentFocus(); route.scroll = content.scrollTop;
        stack.push(route); route = next; render();
    }
    function back() {
        if (playing) {
            if (!controls.hidden && !playerError) { showControls(false); return; }
            exitPlayer(); return;
        }
        if (stack.length) { route = stack.pop(); detail = null; render(); }
        else if (route.name !== 'home') { route = { name: 'home' }; detail = null; render(); }
        else {
            ++revision; // Ignore catalog responses while the exit dialog owns focus.
            content.innerHTML = ''; content.appendChild(node('h1', '', 'Завершить просмотр?'));
            content.appendChild(button('Остаться в J1ROX TV', 'stay', render, 'primary'));
            content.appendChild(button('Выйти', 'exit', function () {
                if (window.tizen && tizen.application) tizen.application.getCurrentApplication().exit();
                else { app.notify('Выход доступен на Samsung TV.'); render(); }
            })); restore('stay');
        }
    }
    function card(item) {
        var el = button('', 'media-' + item.type + '-' + item.id, function () { go({ name: 'details', item: item }); }, 'card');
        append(el, [poster(item.poster, item.title, 'poster'), node('span', 'card-name', item.title), node('span', 'card-meta', [item.year, item.rating && '★ ' + item.rating, item.type === 'tv' ? 'Сериал' : 'Фильм'].filter(Boolean).join(' · '))]);
        return el;
    }
    function rail(title, items) {
        if (!items.length) return;
        content.appendChild(node('h2', '', title));
        var row = node('div', 'rail'); items.forEach(function (item) { row.appendChild(card(item)); }); content.appendChild(row);
    }
    function home(token) {
        status('Загружаем каталог…');
        Promise.all([api.catalog('movie', 1), api.catalog('tv', 1)]).then(function (lists) {
            if (token !== revision) return;
            content.innerHTML = '';
            var featured = lists[0][0] || lists[1][0];
            if (featured) {
                var hero = node('section', 'hero'), copy = node('div', 'hero-copy');
                if (featured.backdrop) hero.appendChild(poster(featured.backdrop, '', 'hero-image'));
                append(copy, [node('div', 'eyebrow', 'J1ROX TV · ВАШ ВЕЧЕР НАЧИНАЕТСЯ ЗДЕСЬ'), node('h1', '', featured.title), node('p', '', featured.overview || 'Фильмы и сериалы на большом экране'), button('Открыть фильм', 'featured', function () { go({ name: 'details', item: featured }); }, 'primary')]);
                hero.appendChild(copy); content.appendChild(hero);
            }
            rail('Продолжить просмотр', library.history()); rail('Фильмы', lists[0]); rail('Сериалы', lists[1]);
            if (!featured) status('Каталог пока пуст. Откройте поиск или повторите позже.');
            restore(); content.scrollTop = route.scroll || 0;
        }).catch(function (err) { screenError(err, token); });
    }
    function catalog(token, isSearch) {
        var page = route.page || 1;
        content.appendChild(node('h1', '', isSearch ? 'Результаты: ' + route.query : route.name === 'tv' ? 'Сериалы' : 'Фильмы'));
        status('Загрузка…');
        var job = isSearch ? api.search(route.query, page) : api.catalog(route.name, page);
        job.then(function (items) {
            if (token !== revision) return;
            content.removeChild(content.querySelector('.loading'));
            if (!items.length) content.appendChild(node('div', 'empty', 'Ничего не найдено. Попробуйте другую страницу или запрос.'));
            var grid = node('div', 'catalog-grid'); items.forEach(function (item) { grid.appendChild(card(item)); }); content.appendChild(grid);
            var pages = node('div', 'actions');
            if (page > 1) pages.appendChild(button('← Страница ' + (page - 1), 'previous-page', function () { route.page = page - 1; route.focus = null; route.scroll = 0; render(); }));
            if (items.length) pages.appendChild(button('Страница ' + (page + 1) + ' →', 'next-page', function () { route.page = page + 1; route.focus = null; route.scroll = 0; render(); }));
            content.appendChild(pages); restore(); content.scrollTop = route.scroll || 0;
        }).catch(function (err) { screenError(err, token); });
    }
    function search() {
        content.appendChild(node('h1', '', 'Что будем смотреть?'));
        var line = node('div', 'search-line'), value = node('div', 'query', query || 'Введите название с помощью пульта');
        value.id = 'search-query'; value.setAttribute('aria-live', 'polite');
        append(line, [value, button('Найти', 'search-submit', function () {
            if (!query.trim()) { app.notify('Введите название.'); return; }
            go({ name: 'results', query: query.trim() });
        }, 'primary')]); content.appendChild(line);
        var keyboard = node('div', 'keyboard');
        var letters = (latin ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' : 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ') + '0123456789';
        function change(text) { query = text.slice(0, 100); value.textContent = query || 'Введите название с помощью пульта'; }
        letters.split('').forEach(function (letter) { keyboard.appendChild(button(letter, 'key-' + letter, function () { change(query + letter); })); });
        keyboard.appendChild(button('Пробел', 'key-space', function () { change(query + ' '); }, 'wide'));
        keyboard.appendChild(button('⌫', 'key-delete', function () { change(query.slice(0, -1)); }, 'wide'));
        keyboard.appendChild(button('Очистить', 'key-clear', function () { change(''); }, 'wide'));
        keyboard.appendChild(button(latin ? 'АБВ' : 'ABC', 'key-language', function () { latin = !latin; route.focus = 'key-language'; render(); }, 'wide'));
        content.appendChild(keyboard); content.appendChild(node('p', 'hint', 'Выбирайте буквы стрелками и кнопкой OK. Поиск выполняется кнопкой «Найти».')); restore();
    }
    function showLibrary() {
        content.appendChild(node('h1', '', 'Моё кино'));
        rail('Продолжить просмотр', library.history()); rail('Избранное', library.favorites());
        if (!library.history().length && !library.favorites().length) content.appendChild(node('div', 'empty', 'Здесь появятся избранные фильмы и незавершённые просмотры. Библиотека хранится на этом телевизоре.'));
        restore(); if (!focus.available(content).length) focus.restore('nav-library', document.getElementById('nav'));
    }
    function loadDetails(token) {
        status('Загружаем фильм и источники…');
        var item = route.item;
        api.details(item).then(function (full) {
            if (!full.id) throw new Error('API не вернул карточку фильма.');
            return api.sources(full).then(function (sources) { return { item: full, sources: sources }; });
        }).then(function (result) {
            if (token !== revision) return;
            var saved = library.progress(result.item);
            var preferred = saved && saved.selection || {};
            detail = { item: result.item, sources: result.sources, source: '', voices: [], voice: null, season: null, episode: null, busy: false, error: '' };
            var source = result.sources.filter(function (s) { return s.id === preferred.source; })[0] || result.sources[0];
            if (!source) { detail.error = 'Для этого фильма источники не найдены.'; drawDetails(); return; }
            loadSource(source.id, preferred);
        }).catch(function (err) { screenError(err, token); });
    }
    function chooseVoice(voice, preferred, preserve) {
        detail.voice = voice; detail.season = null; detail.episode = null;
        if (detail.item.type !== 'tv' || !voice) return;
        var seasons = M.collection(voice.payload.seasons, 'season');
        detail.season = seasons.filter(function (s) { return s.number === preferred.season; })[0] || (!preserve || !preferred.season ? seasons[0] : null);
        if (detail.season) chooseSeason(detail.season, preferred.episode, preserve);
    }
    function chooseSeason(season, number, preserve) {
        detail.season = season;
        var episodes = M.collection(season.payload.episodes, 'episode');
        detail.episode = episodes.filter(function (e) { return e.number === number; })[0] || (!preserve || !number ? episodes[0] : null);
    }
    function loadSource(source, preferred) {
        var owner = detail, token = ++revision;
        detail.source = source; detail.busy = true; detail.error = ''; detail.voices = []; detail.voice = detail.season = detail.episode = null;
        drawDetails('source-' + source);
        api.content(detail.item, source).then(function (payload) {
            if (token !== revision || detail !== owner) return;
            detail.busy = false; detail.payload = payload;
            detail.voices = M.collection(payload.translations, 'translation');
            // A film can expose a stream directly, without a translation list.
            if (!detail.voices.length && (M.streams(payload).length || payload.data || payload.seasons)) detail.voices = [{ id: 'original', name: 'Основная', payload: payload }];
            var voice = detail.voices.filter(function (v) { return v.id === preferred.voice && (!preferred.voiceName || v.name === preferred.voiceName); })[0] ||
                detail.voices.filter(function (v) { return v.name === preferred.voiceName; })[0] || detail.voices[0];
            chooseVoice(voice, preferred, true);
            if (!voice) detail.error = 'Источник не вернул озвучки или видео. Выберите другой источник.';
            drawDetails('source-' + source);
        }).catch(function (err) { if (token === revision && detail === owner) { detail.busy = false; detail.error = err.message; drawDetails('source-' + source); } });
    }
    function choices(parent, title, options, selected, prefix, action) {
        if (!options.length) return;
        parent.appendChild(node('div', 'selector-label', title));
        var row = node('div', 'choices');
        options.forEach(function (option) { row.appendChild(button(option.name, prefix + option.id, function () { action(option); }, selected === option.id ? 'selected' : '')); });
        parent.appendChild(row);
    }
    function playable() { return detail && !detail.busy && detail.voice && (detail.item.type !== 'tv' || detail.episode); }
    function resumePosition() {
        var saved = library.progress(detail.item);
        return saved && !saved.completed && M.sameEpisode(saved.selection || {}, M.selection(detail)) ? saved.position : 0;
    }
    function drawDetails(focusId) {
        var previous = focusId || currentFocus(), scroll = content.scrollTop;
        content.innerHTML = '';
        var top = node('section', 'details'), copy = node('div', 'detail-copy'), item = detail.item;
        append(top, [poster(item.poster, item.title, 'detail-poster'), copy]);
        append(copy, [node('div', 'eyebrow', item.type === 'tv' ? 'СЕРИАЛ' : 'ФИЛЬМ'), node('h1', '', item.title),
            node('div', 'muted', [item.year, item.genres, item.rating && '★ ' + item.rating].filter(Boolean).join(' · '))]);
        var overview = node('p', 'overview', item.overview || 'Описание пока отсутствует.');
        overview.tabIndex = 0; overview.setAttribute('data-focus', 'overview'); copy.appendChild(overview);
        var actions = node('div', 'actions'), resume = resumePosition();
        var playButton = button(resume > 10 ? 'Продолжить с ' + time(resume) : 'Смотреть', 'play', function () { startPlayer(resumePosition()); }, 'primary'); playButton.disabled = !playable();
        actions.appendChild(playButton);
        if (resume > 10) { var restart = button('С начала', 'restart', function () { startPlayer(0); }); restart.disabled = !playable(); actions.appendChild(restart); }
        actions.appendChild(button(library.has(item) ? '♥ В избранном' : '+ В избранное', 'favorite', function () { library.toggle(item); drawDetails('favorite'); }));
        copy.appendChild(actions); content.appendChild(top);
        choices(content, 'Источник', detail.sources, detail.source, 'source-', function (source) { loadSource(source.id, M.selection(detail)); });
        if (detail.busy) content.appendChild(node('div', 'loading', 'Получаем озвучки и серии…'));
        if (detail.error) {
            var box = node('div', 'error', detail.error);
            if (detail.source) box.appendChild(button('Повторить источник', 'retry-source', function () { loadSource(detail.source, M.selection(detail)); }));
            content.appendChild(box);
        }
        choices(content, 'Озвучка', detail.voices, detail.voice && detail.voice.id, 'voice-', function (voice) {
            var preferred = M.selection(detail); chooseVoice(voice, preferred, true); drawDetails('voice-' + voice.id);
        });
        if (detail.item.type === 'tv' && detail.voice) {
            choices(content, 'Сезон', M.collection(detail.voice.payload.seasons, 'season'), detail.season && detail.season.id, 'season-', function (season) { chooseSeason(season, '', false); drawDetails('season-' + season.id); });
            if (detail.season) choices(content, 'Серия', M.collection(detail.season.payload.episodes, 'episode'), detail.episode && detail.episode.id, 'episode-', function (episode) { detail.episode = episode; drawDetails('episode-' + episode.id); });
            if (!detail.season || !detail.episode) content.appendChild(node('div', 'empty', 'Выбранной серии нет в этой озвучке. Выберите доступные сезон и серию.'));
        }
        restore(previous || 'play'); content.scrollTop = scroll;
    }
    function time(seconds) {
        seconds = Math.max(0, Math.floor(seconds || 0));
        var minutes = Math.floor(seconds / 60), rest = seconds % 60;
        return (minutes >= 60 ? Math.floor(minutes / 60) + ':' + ('0' + minutes % 60).slice(-2) : minutes) + ':' + ('0' + rest).slice(-2);
    }
    function saveProgress(completed) {
        if (!detail || !playbackSelection || (ended && !completed)) return;
        var snapshot = player.snapshot();
        if (snapshot.started || completed) library.record(detail.item, playbackSelection, snapshot.position, snapshot.duration, completed);
    }
    function showControls(show) {
        controls.hidden = !show; controlsAction = false;
        playback.focus();
    }
    function next() {
        var following = detail.voice && detail.season && detail.episode && M.nextEpisode(detail.voice, detail.season, detail.episode);
        if (!following) { app.notify('Это последняя доступная серия.'); return; }
        if (!ended) saveProgress(false);
        detail.season = following.season; detail.episode = following.episode;
        startPlayer(0);
    }
    function playerActions() {
        var target = document.getElementById('player-actions'); target.innerHTML = '';
        target.appendChild(button(playerError ? 'Повторить' : ended ? 'Сначала' : 'Пауза / Play', 'player-toggle', function () {
            if (playerError || ended) startPlayer(playerError ? resumePosition() : 0); else player.toggle();
        }, 'primary'));
        if (detail.item.type === 'tv' && detail.episode && M.nextEpisode(detail.voice, detail.season, detail.episode)) target.appendChild(button('Следующая серия', 'player-next', next));
        target.appendChild(button('Источники и озвучки', 'player-sources', exitPlayer));
        target.appendChild(button('Скрыть панель', 'player-hide', function () { showControls(false); }));
        target.appendChild(button('Закрыть', 'player-close', exitPlayer));
    }
    function startPlayer(resume) {
        if (!playable()) return;
        player.close();
        var token = ++revision;
        playing = true; ended = false; playerError = false; suspended = false; lastSaved = Date.now();
        playbackSelection = M.selection(detail);
        document.getElementById('header').hidden = true; content.hidden = true; document.getElementById('footer').hidden = true;
        playback.hidden = false; showControls(true); playerActions();
        document.getElementById('player-title').textContent = detail.item.title;
        document.getElementById('player-description').textContent = [detail.voice.name, detail.season && detail.season.name, detail.episode && detail.episode.name].filter(Boolean).join(' · ');
        document.getElementById('player-time').textContent = 'Подготовка…'; document.getElementById('timeline').value = 0;
        document.getElementById('player-status').textContent = 'Получаем актуальную ссылку…';
        // Resolve anew on every play/retry, including the provider tree: signed URLs can expire while browsing.
        api.content(detail.item, detail.source).then(function (payload) {
            if (token !== revision) return null;
            var voices = M.collection(payload.translations, 'translation');
            var voice = voices.filter(function (v) { return v.id === playbackSelection.voice && v.name === playbackSelection.voiceName; })[0] ||
                voices.filter(function (v) { return v.name === playbackSelection.voiceName; })[0];
            var leaf = voice ? voice.payload : !voices.length ? payload : null;
            if (detail.item.type === 'tv' && leaf) {
                var season = M.collection(leaf.seasons, 'season').filter(function (s) { return s.number === playbackSelection.season; })[0];
                var episode = season && M.collection(season.payload.episodes, 'episode').filter(function (e) { return e.number === playbackSelection.episode; })[0];
                leaf = episode && episode.payload;
            }
            if (!leaf) throw new Error('Выбранная озвучка или серия больше не доступна у источника. Вернитесь к выбору.');
            return api.resolve(detail.source, leaf);
        }).then(function (streams) {
            if (token !== revision || !streams) return;
            document.getElementById('player-status').textContent = 'Подготовка видео…';
            player.open(streams[0], resume, {
                ready: function () { if (token !== revision) return; document.getElementById('player-status').textContent = ''; showControls(false); },
                buffer: function (active, percent) { if (token === revision) document.getElementById('player-status').textContent = active ? 'Буферизация' + (percent != null ? ': ' + percent + '%' : '…') : ''; },
                time: function (position, duration) {
                    if (token !== revision) return;
                    var bar = document.getElementById('timeline'); bar.max = duration || 1; bar.value = position;
                    document.getElementById('player-time').textContent = time(position) + ' / ' + (duration ? time(duration) : 'LIVE');
                    if (Date.now() - lastSaved >= 5000) { saveProgress(false); lastSaved = Date.now(); }
                },
                state: function (paused) { if (paused) { saveProgress(false); showControls(true); } },
                notice: app.notify,
                error: function (message) { if (token !== revision) return; playerError = true; document.getElementById('player-status').textContent = message; showControls(true); playerActions(); controlsAction = true; focus.restore('player-toggle', controls); },
                ended: function () {
                    if (token !== revision) return;
                    saveProgress(true); ended = true; player.pause(); document.getElementById('player-status').textContent = 'Просмотр завершён';
                    showControls(true); playerActions(); controlsAction = true;
                    focus.restore(detail.item.type === 'tv' ? 'player-next' : 'player-toggle', controls);
                }
            });
        }).catch(function (err) {
            if (token !== revision) return;
            playerError = true; document.getElementById('player-status').textContent = err.message;
            showControls(true); playerActions(); controlsAction = true; focus.restore('player-toggle', controls);
        });
    }
    function exitPlayer() {
        if (!ended) saveProgress(false);
        ++revision; player.close(); playing = false; playback.hidden = true;
        document.getElementById('header').hidden = false; content.hidden = false; document.getElementById('footer').hidden = false;
        drawDetails('play');
    }
    function render() {
        var token = ++revision; nav(); content.innerHTML = ''; content.scrollTop = 0;
        // Keep a valid focus while asynchronous data is loading.
        focus.restore('nav-' + route.name, document.getElementById('nav'));
        if (route.name === 'home') home(token);
        else if (route.name === 'movie' || route.name === 'tv') catalog(token, false);
        else if (route.name === 'results') catalog(token, true);
        else if (route.name === 'search') search();
        else if (route.name === 'library') showLibrary();
        else if (route.name === 'details') loadDetails(token);
    }
    function playerKey(code) {
        if (code === 10009 || code === 27 || code === 8) { back(); return; }
        if (code === 37 || code === 39 || code === 412 || code === 417) { player.seek(code === 37 || code === 412 ? -10 : 10); showControls(true); return; }
        if (code === 415) { player.play(); return; }
        if (code === 19) { player.pause(); return; }
        if (code === 10252 || code === 32) { player.toggle(); return; }
        if (code === 413) { exitPlayer(); return; }
        if (code === 10233) { next(); return; }
        if (code === 38 || code === 40) {
            if (controls.hidden) showControls(true);
            var buttons = focus.available(controls), index = buttons.indexOf(document.activeElement);
            controlsAction = true; focus.set(buttons[index < 0 ? 0 : (index + (code === 40 ? 1 : -1) + buttons.length) % buttons.length]); return;
        }
        if (code === 13) {
            if (controlsAction && document.activeElement.tagName === 'BUTTON') document.activeElement.click();
            else showControls(controls.hidden);
        }
    }
    document.addEventListener('keydown', function (event) {
        var code = event.keyCode || event.which;
        if ([8, 13, 19, 27, 32, 37, 38, 39, 40, 10009, 415, 413, 412, 417, 10252, 10233].indexOf(code) < 0) return;
        event.preventDefault();
        if (playing) { playerKey(code); return; }
        if (code === 10009 || code === 27 || code === 8) { back(); return; }
        if (code >= 37 && code <= 40) {
            var active = document.activeElement;
            if (active.className === 'overview' && (code === 38 || code === 40)) {
                var before = active.scrollTop; active.scrollTop += code === 40 ? 70 : -70;
                if (before !== active.scrollTop) return;
            }
            focus.move(code); return;
        }
        if (code === 13 && document.activeElement.tagName === 'BUTTON') document.activeElement.click();
    });
    document.addEventListener('visibilitychange', function () {
        if (!playing) return;
        if (document.hidden) { if (!ended) saveProgress(false); ++revision; player.close(); suspended = true; }
        else if (suspended) { suspended = false; exitPlayer(); app.notify('Продолжите просмотр — ссылка будет обновлена после возвращения.'); }
    });
    window.addEventListener('pagehide', function () { if (playing && !ended) saveProgress(false); player.close(); });
    function scale() {
        var ratio = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
        stage.style.transform = 'scale(' + ratio + ')';
        stage.style.left = (window.innerWidth - 1920 * ratio) / 2 + 'px'; stage.style.top = (window.innerHeight - 1080 * ratio) / 2 + 'px';
    }
    window.addEventListener('resize', scale); scale();
    if (player.native) document.body.classList.add('native-player');
    if (window.tizen && tizen.tvinputdevice) ['MediaPlay', 'MediaPause', 'MediaPlayPause', 'MediaStop', 'MediaRewind', 'MediaFastForward', 'MediaTrackNext'].forEach(function (key) {
        try { tizen.tvinputdevice.registerKey(key); } catch (err) { console.warn('[Remote] ' + key + ': ' + err.name); }
    });
    render();
}(window.JTV));
