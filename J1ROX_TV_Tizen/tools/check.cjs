const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');
const root = path.resolve(__dirname, '..');
for (const file of fs.readdirSync(path.join(root, 'js'))) {
    const source = fs.readFileSync(path.join(root, 'js', file), 'utf8');
    new vm.Script(source, { filename: file });
    acorn.parse(source, { ecmaVersion: 5 });
    console.log('ES5 syntax OK:', file);
}
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
for (const match of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
    if (match[1].startsWith('$WEBAPIS')) continue;
    if (!fs.existsSync(path.join(root, match[1]))) throw new Error('Missing runtime resource: ' + match[1]);
}
console.log('Runtime resource references OK');
