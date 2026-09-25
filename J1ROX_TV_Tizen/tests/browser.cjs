/* Desktop UI/remote integration tests. The AVPlay test double is NOT a decoder/TV test. */
const { chromium } = require('playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const live = process.argv.includes('--live');
const movie = { id: 550, title: 'Бойцовский клуб', original_title: 'Fight Club', release_date: '1999-10-15', overview: 'История о поиске себя, неожиданных встречах и решениях, которые меняют всё.', vote_average: 8.4, genres: [{ name: 'Драма' }], imdb_id: 'tt0137523' };
const series = { id: 1399, name: 'Игра престолов', original_name: 'Game of Thrones', first_air_date: '2011-04-17', overview: 'Семь королевств, великие дома и борьба за Железный трон.', vote_average: 8.4, media_type: 'tv' };
const tree = {
    translations: {
        dub: { name: 'Дубляж', data: { film: 'пример' }, seasons: { 1: { episodes: { 1: { data: { episode: 1 } }, 2: { data: { episode: 2 } } } }, 2: { episodes: { 1: { data: { episode: 3 } } } } } },
        sub: { name: 'Другая озвучка', data: { film: 'other' }, seasons: { 1: { episodes: { 1: { data: { episode: 1 } } } } } }
    }
};
const server = http.createServer((req, res) => {
    const relative = decodeURIComponent(req.url.split('?')[0]);
    const file = path.resolve(root, '.' + (relative === '/' ? '/index.html' : relative));
    if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); res.end(); return; }
    const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };
    if (path.extname(file) === '.html') {
        const config = fs.readFileSync(path.join(root, 'config.xml'), 'utf8');
        res.setHeader('Content-Security-Policy', config.match(/<tizen:content-security-policy>(.*?)<\/tizen:content-security-policy>/)[1]);
    }
    res.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
    res.end(fs.readFileSync(file));
});
async function main() {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const executable = process.env.JTV_BROWSER || (process.platform === 'win32' ? 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe' : undefined);
    const browser = await chromium.launch({ executablePath: executable, headless: true });
    try {
        const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
        const errors = [], calls = [];
        page.on('pageerror', error => errors.push(error.message));
        // The SDK script exists only on TV. Desktop preview intentionally runs without it.
        await page.route('**/$WEBAPIS/**', route => route.fulfill({ contentType: 'text/javascript', body: '' }));
        if (!live) {
            await page.route('https://api.atodo.fun/**', route => {
                const url = new URL(route.request().url()); calls.push(url);
                let response;
                if (url.pathname === '/api/list') {
                    const item = url.searchParams.get('type_movie') === 'tv' ? series : movie;
                    response = { results: Array.from({ length: 10 }, (_, i) => ({ ...item, id: i === 0 ? item.id : item.id + i, title: item.title && (i ? item.title + ' ' + i : item.title) })) };
                } else if (url.pathname === '/api/search') response = { results: [movie, series] };
                else if (url.pathname.startsWith('/api/details/')) response = url.pathname.includes('/tv/') ? series : movie;
                else if (url.pathname === '/api/source/list') response = { balancers: [{ id: 'one', name: '№1' }, { id: 'two', name: '№2' }] };
                else if (url.searchParams.has('data')) response = { streams: { video: { hls: { master: 'https://cdn.example.test/master.m3u8?token=test-only' }, http: { master: 'http://cdn.example.test/video.mp4' } } } };
                else response = tree;
                return route.fulfill({ json: response, headers: { 'Access-Control-Allow-Origin': '*' } });
            });
            await page.addInitScript(() => {
                let state = 'NONE', listener, time = 0;
                window.__avCalls = [];
                window.__av = {
                    emitTime: seconds => { time = seconds * 1000; listener.oncurrentplaytime(time); },
                    end: () => listener.onstreamcompleted(),
                    error: () => listener.onerror('PLAYER_ERROR_CONNECTION_FAILED')
                };
                window.webapis = { avplay: {
                    getState: () => state,
                    open: url => { state = 'IDLE'; window.__avCalls.push(['open', url]); },
                    close: () => { state = 'NONE'; window.__avCalls.push(['close']); },
                    stop: () => { state = 'IDLE'; },
                    setListener: value => { listener = value; },
                    setDisplayRect: () => {}, setDisplayMethod: () => {},
                    prepareAsync: ready => { setTimeout(() => { state = 'READY'; ready(); }, 30); },
                    play: () => { state = 'PLAYING'; window.__avCalls.push(['play']); },
                    pause: () => { state = 'PAUSED'; window.__avCalls.push(['pause']); },
                    seekTo: (ms, done) => { time = ms; window.__avCalls.push(['seek', ms]); done(); },
                    getCurrentTime: () => time, getDuration: () => 120000
                } };
            });
        }
        await page.goto('http://127.0.0.1:' + server.address().port);
        await page.locator('.hero').waitFor({ timeout: 60000 });
        if (live) {
            await page.waitForFunction(() => Array.from(document.querySelectorAll('.poster')).slice(0, 6).every(img => img.complete), null, { timeout: 20000 }).catch(() => {});
            console.log('LIVE POSTERS:', JSON.stringify(await page.locator('.poster').evaluateAll(images => ({
                total: images.length,
                loaded: images.filter(img => img.complete && img.naturalWidth && !img.src.endsWith('/assets/poster.svg')).length,
                fallback: images.filter(img => img.src.endsWith('/assets/poster.svg')).length
            }))));
        }
        fs.mkdirSync(path.join(root, '.build'), { recursive: true });
        await page.screenshot({ path: path.join(root, '.build', live ? 'home-live.png' : 'home-test.png') });
        assert.equal(await page.locator(':focus').getAttribute('data-focus'), 'featured');
        await page.keyboard.press('ArrowDown');
        assert.match(await page.locator(':focus').getAttribute('data-focus'), /^media-/);
        await page.keyboard.press('ArrowRight');
        assert.match(await page.locator(':focus').getAttribute('data-focus'), /^media-/);
        // Deliberately traverse past the visible viewport: the focused card must stay on screen.
        for (let i = 0; i < 8; i++) await page.keyboard.press('ArrowRight');
        const bounds = await page.locator(':focus').boundingBox();
        assert.ok(bounds.x >= 0 && bounds.x + bounds.width <= 1921);
        if (live) {
            // Browser XHR uses its real origin; no Origin/Referer/User-Agent spoofing.
            const report = await page.evaluate(async () => {
                const item = await JTV.api.details({ id: '550', type: 'movie' });
                const sources = await JTV.api.sources(item);
                const output = [];
                for (const source of sources.slice(0, 2)) {
                    try {
                        const payload = await JTV.api.content(item, source.id);
                        const voices = JTV.model.collection(payload.translations, 'translation');
                        const streams = await JTV.api.resolve(source.id, voices.length ? voices[0].payload : payload);
                        output.push({ source: source.id, voices: voices.length, streams: streams.length, hls: streams[0].hls, endpoint: new URL(streams[0].url).origin });
                    } catch (e) { output.push({ source: source.id, error: e.message }); }
                }
                return { title: item.title, sources: output };
            });
            console.log('LIVE BROWSER API/CORS:', JSON.stringify(report));
        } else {
            // Independent scenario setup uses focus(); interactions themselves use only remote keys.
            async function activate(id) { await page.locator('[data-focus="' + id + '"]').focus(); await page.keyboard.press('Enter'); }
            await activate('nav-search');
            await activate('key-А'); await activate('key-Б');
            assert.equal(await page.locator('#search-query').textContent(), 'АБ');
            await activate('search-submit'); await page.locator('.catalog-grid .card').first().waitFor();
            assert.equal(calls.filter(u => u.pathname === '/api/search').at(-1).searchParams.get('query'), 'АБ');
            await activate('media-tv-1399');
            await page.locator('[data-focus="episode-2"]').waitFor();
            await activate('source-two');
            await page.locator('[data-focus="episode-2"]').waitFor();
            assert.ok(calls.some(u => u.pathname === '/api/source/two'));
            assert.equal(await page.locator(':focus').getAttribute('data-focus'), 'source-two');
            await activate('source-one');
            await page.locator('[data-focus="episode-2"]').waitFor();
            await activate('favorite');
            await activate('episode-2');
            await activate('voice-sub');
            assert.equal(await page.locator('[data-focus="play"]').isDisabled(), true, 'Missing episode must not silently change to episode 1');
            await activate('voice-dub');
            await activate('episode-2');
            await activate('play');
            await page.waitForFunction(() => document.body.classList.contains('video-visible'));
            assert.equal(await page.locator('#player-controls').isHidden(), true);
            const av = await page.evaluate(() => window.__avCalls);
            assert.ok(av.some(c => c[0] === 'open' && c[1].includes('master.m3u8')));
            await page.evaluate(() => window.__av.emitTime(35));
            await page.keyboard.press('ArrowRight');
            assert.ok((await page.evaluate(() => window.__avCalls)).some(c => c[0] === 'seek' && c[1] === 45000));
            await page.keyboard.press('Enter'); // hides panel after seek
            assert.equal(await page.locator('#player-controls').isHidden(), true);
            await page.keyboard.press('Enter'); // reveals panel
            await page.keyboard.press('ArrowDown');
            assert.equal(await page.locator(':focus').getAttribute('data-focus'), 'player-toggle');
            await page.keyboard.press('Enter'); // pause
            await page.keyboard.press('Escape'); // closes controls first
            assert.equal(await page.locator('#playback').isVisible(), true);
            assert.equal(await page.locator('#player-controls').isHidden(), true);
            await page.keyboard.press('Escape'); // exits player, resumes details
            assert.equal(await page.locator('#playback').isHidden(), true);
            assert.match(await page.locator('[data-focus="play"]').textContent(), /0:45/);
            await activate('play');
            await page.waitForFunction(() => document.body.classList.contains('video-visible'));
            const seeks = await page.evaluate(() => window.__avCalls.filter(c => c[0] === 'seek'));
            assert.equal(seeks.at(-1)[1], 45000);
            await page.evaluate(() => window.__av.end());
            assert.equal(await page.evaluate(() => JTV.library.progress({ type: 'tv', id: '1399' }).completed), true, 'Pause after end must preserve completion');
            assert.equal(await page.locator(':focus').getAttribute('data-focus'), 'player-next');
            await page.keyboard.press('Enter');
            await page.waitForFunction(() => document.body.classList.contains('video-visible'));
            assert.match(await page.locator('#player-description').textContent(), /Сезон 2.*Серия 1/);
            await page.evaluate(() => window.__av.error());
            await page.locator('#player-status').filter({ hasText: 'PLAYER_ERROR_CONNECTION_FAILED' }).waitFor();
            await page.keyboard.press('Escape');
            assert.equal(await page.locator('#playback').isHidden(), true);
            await activate('nav-library');
            assert.ok(await page.locator('.card').count() >= 1);
            await page.reload();
            await page.locator('.hero').waitFor();
            await activate('nav-library');
            assert.ok(await page.locator('.card').count() >= 1, 'Favorites survive reload');
            assert.equal((await page.evaluate(() => localStorage.getItem('j1rox.tizen.library.v1'))).includes('token=test-only'), false);
            await page.setViewportSize({ width: 3840, height: 2160 });
            await page.waitForTimeout(50);
            assert.match(await page.locator('#stage').getAttribute('style'), /scale\(2\)/);
            // A slow home response must not steal focus from the exit confirmation.
            let releaseCatalog;
            const catalogGate = new Promise(resolve => { releaseCatalog = resolve; });
            await page.route('https://api.atodo.fun/api/list?**', async route => {
                await catalogGate;
                await route.fulfill({ json: { results: [movie] } });
            });
            await activate('nav-home');
            await page.keyboard.press('Escape');
            releaseCatalog();
            await page.waitForTimeout(150);
            assert.equal(await page.locator(':focus').getAttribute('data-focus'), 'stay');
            assert.equal(await page.locator('[data-focus="stay"]').count(), 1);
            console.log('BROWSER PASS: catalog, rail scrolling, search, selectors, missing episode, HLS resolution, seek, pause, resume, next season, error, Back, favorites, 4K scaling');
        }
        assert.deepEqual(errors, []);
        console.log('No unhandled JavaScript exceptions. Screenshots in .build/.');
    } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => server.close());
