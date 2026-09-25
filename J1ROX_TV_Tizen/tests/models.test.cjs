const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../js/models.js');

test('canonical metadata preserves TV identity, year and external IMDb', () => {
    const result = M.media({ id: 1399, name: 'Сериал', original_name: 'Series', first_air_date: '2011-04-17', external_ids: { imdb_id: 'tt0944947' }, poster_path: '/poster.jpg', genres: [{ name: 'Драма' }] });
    assert.deepEqual(result.canonical, { id: '1399', title: 'Сериал', original_title: 'Series', imdb_id: 'tt0944947', year: '2011', type: 'tv' });
    assert.equal(result.poster, 'https://image.tmdb.org/t/p/w780/poster.jpg');
    assert.equal(result.genres, 'Драма');
});
test('nested lists and details use existing backend wrappers', () => {
    assert.deepEqual(M.list({ data: { results: [{ id: 550 }] } }), [{ id: 550 }]);
    assert.deepEqual(M.unwrap({ result: { id: 550 } }), { id: 550 });
    assert.deepEqual(M.list({ data: {} }), []);
});
test('HLS master takes priority over direct MP4 and signed extensionless HTTP', () => {
    const streams = M.streams({ url: 'https://cdn.example/video.mp4', streams: { video: {
        http: { master: 'http://cdn.example/?signature=abc' },
        hls: { master: 'https://cdn.example/manifest?token=123', qualities: { 720: 'https://cdn.example/720.m3u8', 1080: 'https://cdn.example/1080.m3u8' } }
    } } });
    assert.equal(streams[0].url, 'https://cdn.example/manifest?token=123');
    assert.equal(streams[0].hls, true);
    assert.equal(streams[1].url, 'https://cdn.example/1080.m3u8');
    assert.ok(streams.some(s => s.url === 'http://cdn.example/?signature=abc'));
    assert.equal(new Set(streams.map(s => s.url)).size, streams.length);
});
test('stream parsing rejects scripts and preserves signed HTTP without protocol rewriting', () => {
    assert.equal(M.url('javascript:alert(1)'), '');
    assert.equal(M.url('http://cdn.example/a.mp4?x=1|Referer=test'), 'http://cdn.example/a.mp4?x=1');
    assert.equal(M.url('https:\\/\\/cdn.example/a.m3u8'), 'https://cdn.example/a.m3u8');
    assert.deepEqual(M.streams({ image: 'https://image.example/poster.jpg' }), []);
});
test('array and map voices, natural episode ordering, next across empty seasons', () => {
    const voices = M.collection({ voice: { name: 'Дубляж', seasons: {
        1: { episodes: { 10: { url: 'https://example.test/10.m3u8' }, 2: { url: 'https://example.test/2.m3u8' } } },
        2: { episodes: {} }, 3: { episodes: [{ episode_number: 1 }] }
    } } }, 'translation');
    const seasons = M.collection(voices[0].payload.seasons, 'season');
    const episodes = M.collection(seasons[0].payload.episodes, 'episode');
    assert.deepEqual(episodes.map(e => e.number), ['2', '10']);
    assert.equal(M.nextEpisode(voices[0], seasons[0], episodes[0]).episode.number, '10');
    const next = M.nextEpisode(voices[0], seasons[0], episodes[1]);
    assert.equal(next.season.number, '3');
    assert.equal(next.episode.number, '1');
    assert.equal(M.nextEpisode(voices[0], next.season, next.episode), null);
});
test('resume follows logical episode independent of provider/voice', () => {
    assert.equal(M.sameEpisode({ season: '1', episode: '2', source: 'a' }, { season: '1', episode: '2', source: 'b' }), true);
    assert.equal(M.sameEpisode({ season: '1', episode: '2' }, { season: '1', episode: '3' }), false);
});
