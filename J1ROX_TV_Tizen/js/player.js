(function (app) {
    'use strict';
    // AVPlay is a singleton. Each open owns a generation so late callbacks cannot restart a closed video.
    var av = window.webapis && window.webapis.avplay;
    var video = document.getElementById('web-player');
    var generation = 0, callback = {}, timeout = null, seeking = false, queuedSeek = null, seekTarget = null;
    var position = 0, duration = 0, stream = null, started = false, paused = false;
    function clearTimer() { clearTimeout(timeout); timeout = null; }
    function screenSaver(enabled) {
        var common = window.webapis && window.webapis.appcommon;
        if (!common) return;
        try { common.setScreenSaver(common.AppCommonScreenSaverState[enabled ? 'SCREEN_SAVER_ON' : 'SCREEN_SAVER_OFF'],
            function () {}, function (err) { console.warn('[ScreenSaver]', errorText(err)); }); }
        catch (err) { console.warn('[ScreenSaver]', errorText(err)); }
    }
    function errorText(error) {
        if (typeof error === 'string') return error;
        return error && ((error.name || '') + ': ' + (error.message || error.code || '')) || 'UnknownError';
    }
    function fail(error, token) {
        if (token !== generation) return;
        clearTimer();
        var endpoint = stream ? stream.url.split('/').slice(0, 3).join('/') : '';
        var message = errorText(error) + ' · ' + endpoint +
            '. Возможны ограничения кодека/контейнера, HTTP/TLS или сервера. Браузерный режим также зависит от CORS и mixed content. Выберите другой источник или повторите запрос.';
        console.error('[Player]', errorText(error), endpoint);
        var report = callback.error;
        close();
        if (report) report(message);
    }
    function update(ms) {
        position = Math.max(0, ms / 1000 || 0);
        if (av) { try { duration = Math.max(0, av.getDuration() / 1000 || 0); } catch (err) { /* not prepared yet */ } }
        else duration = isFinite(video.duration) ? video.duration : 0;
        if (callback.time) callback.time(position, duration);
    }
    function close() {
        generation++; clearTimer(); seeking = false; queuedSeek = null; seekTarget = null;
        screenSaver(true);
        started = false; paused = false;
        if (av) {
            try { var state = av.getState(); if (state === 'PLAYING' || state === 'PAUSED' || state === 'READY') av.stop(); } catch (err) { console.warn('[Player] stop', errorText(err)); }
            try { if (av.getState() !== 'NONE') av.close(); } catch (err) { console.warn('[Player] close', errorText(err)); }
        } else {
            video.onloadedmetadata = video.ontimeupdate = video.onended = video.onerror = video.onwaiting = video.onplaying = null;
            video.pause(); video.removeAttribute('src'); video.load();
        }
        document.body.classList.remove('video-visible');
    }
    function seekAbsolute(seconds, onDone) {
        if (!started) { if (onDone) onDone(); return; }
        var target = Math.max(0, duration > 0 ? Math.min(seconds, Math.max(0, duration - 1)) : seconds);
        var token = generation;
        if (av) {
            if (seeking) { queuedSeek = target; return; }
            seeking = true; seekTarget = target;
            function done() {
                if (token !== generation) return;
                seeking = false; seekTarget = null; update(target * 1000);
                if (onDone) onDone();
                if (queuedSeek !== null) { var next = queuedSeek; queuedSeek = null; seekAbsolute(next); }
            }
            try { av.seekTo(Math.round(target * 1000), done, function (err) {
                if (token !== generation) return;
                seeking = false; queuedSeek = null; seekTarget = null;
                if (callback.notice) callback.notice('Перемотка недоступна: ' + errorText(err));
                if (onDone) onDone();
            }); } catch (err) { seeking = false; seekTarget = null; queuedSeek = null; if (callback.notice) callback.notice(errorText(err)); if (onDone) onDone(); }
        } else {
            try { video.currentTime = target; } catch (err) { if (callback.notice) callback.notice(errorText(err)); }
            if (onDone) onDone();
        }
    }
    function play() {
        if (!started) return;
        try {
            if (av) av.play();
            else { var promise = video.play(); if (promise && promise.catch) promise.catch(function (err) { if (callback.notice) callback.notice('Play: ' + errorText(err)); }); }
            paused = false; screenSaver(false); if (callback.state) callback.state(false);
        } catch (err) { if (callback.notice) callback.notice(errorText(err)); }
    }
    function pause() {
        if (!started) return;
        try { if (av) { if (av.getState() === 'PLAYING') av.pause(); } else video.pause(); paused = true; screenSaver(true); if (callback.state) callback.state(true); }
        catch (err) { if (callback.notice) callback.notice(errorText(err)); }
    }
    app.player = {
        native: !!av, close: close, play: play, pause: pause,
        toggle: function () { if (paused) play(); else pause(); },
        seek: function (delta) { seekAbsolute((queuedSeek !== null ? queuedSeek : seekTarget !== null ? seekTarget : position) + delta); },
        snapshot: function () { return { position: position, duration: duration, started: started }; },
        open: function (source, resume, handlers) {
            close(); stream = source; callback = handlers; position = 0; duration = 0;
            var token = generation;
            // Full URLs can contain short-lived tokens: explicitly opt in through localStorage/Web Inspector.
            try { if (localStorage.getItem('j1rox.debug') === '1') console.debug('[Player] Final stream URL: ' + source.url); } catch (err) { /* storage optional */ }
            timeout = setTimeout(function () { fail('PrepareTimeout: подготовка видео заняла более 45 секунд', token); }, 45000);
            if (av) {
                try {
                    av.open(source.url);
                    av.setDisplayRect(0, 0, 1920, 1080);
                    av.setDisplayMethod('PLAYER_DISPLAY_MODE_LETTER_BOX');
                    av.setListener({
                        onbufferingstart: function () { if (token === generation && callback.buffer) callback.buffer(true); },
                        onbufferingprogress: function (percent) { if (token === generation && callback.buffer) callback.buffer(true, percent); },
                        onbufferingcomplete: function () { if (token === generation && callback.buffer) callback.buffer(false); },
                        oncurrentplaytime: function (ms) { if (token === generation) update(ms); },
                        onstreamcompleted: function () { if (token === generation && callback.ended) callback.ended(); },
                        onerror: function (error) { fail(error, token); },
                        onerrormsg: function (event, message) { if (token === generation) console.error('[AVPlay]', event, message); }
                    });
                    av.prepareAsync(function () {
                        if (token !== generation) return;
                        clearTimer(); started = true; update(0);
                        document.body.classList.add('video-visible');
                        function begin() { if (token === generation) { play(); if (callback.ready) callback.ready(); } }
                        if (resume > 0) seekAbsolute(resume, begin); else begin();
                    }, function (err) { fail(err, token); });
                } catch (err) { fail(err, token); }
            } else {
                if (source.hls && !video.canPlayType('application/vnd.apple.mpegurl')) {
                    fail('HLSNotSupported: этот браузер не поддерживает HLS. На Samsung используется нативный AVPlay', token); return;
                }
                video.onloadedmetadata = function () {
                    if (token !== generation) return;
                    clearTimer(); started = true; update(0);
                    document.body.classList.add('video-visible');
                    if (resume > 0) seekAbsolute(resume);
                    play(); if (callback.ready) callback.ready();
                };
                video.ontimeupdate = function () { if (token === generation) update(video.currentTime * 1000); };
                video.onended = function () { if (token === generation && callback.ended) callback.ended(); };
                video.onerror = function () { fail('HTMLMediaError code=' + (video.error && video.error.code) + ' ' + (video.error && video.error.message || ''), token); };
                video.onwaiting = function () { if (token === generation && callback.buffer) callback.buffer(true); };
                video.onplaying = function () { if (token === generation && callback.buffer) callback.buffer(false); };
                video.src = source.url; video.load();
            }
        }
    };
}(window.JTV));
