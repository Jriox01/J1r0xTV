const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const model = require('../js/models.js');
function load(name, context) { vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../js', name), 'utf8'), context); }
function apiHarness(response, mode = 'load') {
    const requests = [];
    function XHR() { requests.push(this); this.status = 200; this.responseText = JSON.stringify(response); this.headers = {}; }
    XHR.prototype.open = function (method, url) { this.method = method; this.url = url; };
    XHR.prototype.setRequestHeader = function (key, value) { this.headers[key] = value; };
    XHR.prototype.send = function () { this['on' + mode](); };
    const app = { model };
    load('api.js', { window: { JTV: app }, XMLHttpRequest: XHR, Promise, btoa: s => Buffer.from(s, 'binary').toString('base64'), unescape, encodeURIComponent });
    return { api: app.api, requests };
}
test('resolver sends UTF8 base64 provider data and no forbidden browser headers', async () => {
    const h = apiHarness({ streams: { video: { hls: { master: 'https://test.example/v.m3u8' } } } });
    const data = { title: 'Озвучка Ё', id: 5 };
    const streams = await h.api.resolve('provider', { data });
    const request = h.requests[0];
    assert.equal(new URL(request.url).pathname, '/api/source/provider');
    assert.deepEqual(JSON.parse(Buffer.from(new URL(request.url).searchParams.get('data'), 'base64').toString('utf8')), data);
    assert.deepEqual(Object.keys(request.headers), ['Accept']);
    assert.equal(streams[0].hls, true);
});
test('resolver rejects empty responses and does not fabricate URLs', async () => {
    const h = apiHarness({});
    await assert.rejects(h.api.resolve('p', { data: { id: 1 } }), /HTTP\/HLS/);
    await assert.rejects(h.api.resolve('p', {}), /не вернул видео/);
});
test('network status zero and timeout remain distinguishable', async () => {
    await assert.rejects(apiHarness({}, 'error').api.catalog('movie'), /TLS.*CORS/);
    await assert.rejects(apiHarness({}, 'timeout').api.catalog('movie'), /25 секунд/);
});
test('local progress persists logical selections, completed items leave continue rail', () => {
    let raw = null;
    const app = {}, localStorage = { getItem: () => raw, setItem: (k, v) => { raw = v; } };
    load('library.js', { window: { JTV: app }, localStorage, console });
    const item = model.media({ id: 1, title: 'Test' });
    app.library.toggle(item);
    app.library.record(item, { season: '1', episode: '2' }, 25, 100, false);
    assert.equal(app.library.history().length, 1);
    const again = {};
    load('library.js', { window: { JTV: again }, localStorage, console });
    assert.equal(again.library.has(item), true);
    assert.equal(again.library.progress(item).position, 25);
    again.library.record(item, { season: '1', episode: '2' }, 100, 100, true);
    assert.equal(again.library.history().length, 0);
    assert.equal(again.library.progress(item).position, 0);
    assert.equal(raw.includes('signature='), false);
});
function playerHarness(deferredSeek = false) {
    let state = 'NONE', prepared, listener;
    const calls = [], app = {}, seekCallbacks = [];
    const av = {
        getState: () => state, open: url => { calls.push(['open', url]); state = 'IDLE'; },
        close: () => { calls.push(['close']); state = 'NONE'; }, stop: () => { calls.push(['stop']); state = 'IDLE'; },
        setDisplayRect: (...args) => calls.push(['rect', ...args]), setDisplayMethod: () => {},
        setListener: value => { listener = value; }, prepareAsync: ready => { prepared = () => { state = 'READY'; ready(); }; },
        play: () => { calls.push(['play']); state = 'PLAYING'; }, pause: () => { state = 'PAUSED'; },
        getDuration: () => 120000, seekTo: (ms, success) => { calls.push(['seek', ms]); if (deferredSeek) seekCallbacks.push(success); else success(); }
    };
    const context = { window: { JTV: app, webapis: { avplay: av } }, document: { getElementById: () => ({}), body: { classList: { add() {}, remove() {} } } },
        localStorage: { getItem: () => null }, console, setTimeout, clearTimeout };
    load('player.js', context);
    return { player: app.player, calls, ready: () => prepared(), events: () => listener, finishSeek: () => seekCallbacks.shift()() };
}
test('rapid remote seeks accumulate while AVPlay seek callback is pending', () => {
    const h = playerHarness(true);
    h.player.open({ url: 'https://cdn.example/a.m3u8', hls: true }, 0, {});
    h.ready(); h.events().oncurrentplaytime(30000);
    h.player.seek(10); h.player.seek(10); h.player.seek(10);
    h.finishSeek();
    assert.deepEqual(h.calls.filter(c => c[0] === 'seek'), [['seek', 40000], ['seek', 60000]]);
    h.finishSeek(); h.player.close();
});
test('AVPlay opens unchanged HTTP URL, prepares, resumes in ms and clamps seek', () => {
    const h = playerHarness();
    h.player.open({ url: 'http://cdn.example/video.m3u8', hls: true }, 42, {});
    h.ready();
    assert.deepEqual(h.calls.find(c => c[0] === 'open'), ['open', 'http://cdn.example/video.m3u8']);
    assert.deepEqual(h.calls.find(c => c[0] === 'rect'), ['rect', 0, 0, 1920, 1080]);
    assert.ok(h.calls.findIndex(c => c[0] === 'seek') < h.calls.findIndex(c => c[0] === 'play'));
    assert.deepEqual(h.calls.find(c => c[0] === 'seek'), ['seek', 42000]);
    h.player.seek(1000);
    assert.deepEqual(h.calls.filter(c => c[0] === 'seek').at(-1), ['seek', 119000]);
    h.player.close();
});
test('late prepare callback cannot play after closing; native error code surfaces', () => {
    const h = playerHarness(); let error = '';
    h.player.open({ url: 'https://cdn.example/a.m3u8', hls: true }, 0, {});
    h.player.close(); h.ready();
    assert.equal(h.calls.some(c => c[0] === 'play'), false);
    h.player.open({ url: 'https://cdn.example/a.m3u8', hls: true }, 0, { error: message => { error = message; } });
    h.events().onerror('PLAYER_ERROR_NOT_SUPPORTED_FORMAT');
    assert.match(error, /PLAYER_ERROR_NOT_SUPPORTED_FORMAT/);
    h.player.close();
});
