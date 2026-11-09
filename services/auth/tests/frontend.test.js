const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const vector = JSON.parse(fs.readFileSync('kontrak/jwt-vektor.json', 'utf8'));
const storage = new Map();
const elements = new Map();
function element(id) {
    if (!elements.has(id)) {
        elements.set(id, { style: {}, textContent: '', value: '', innerHTML: '', reset() {} });
    }
    return elements.get(id);
}

let ready;
let lastFetch;
const context = {
    console,
    Date,
    JSON,
    Number,
    Promise,
    atob,
    escape,
    decodeURIComponent,
    setTimeout,
    clearTimeout,
    localStorage: {
        getItem: (key) => storage.get(key) || null,
        setItem: (key, value) => storage.set(key, value),
        removeItem: (key) => storage.delete(key),
    },
    document: { getElementById: element },
    window: { addEventListener: (name, callback) => { if (name === 'DOMContentLoaded') ready = callback; } },
    fetch: (url, options) => {
        lastFetch = { url, options };
        if (url === '/api/auth/login') {
            return Promise.resolve({ json: () => Promise.resolve({
                status: 'sukses', pesan: 'Login berhasil.',
                data: { token: vector.token_benar, user: { id: 1, username: 'penyair', nama: 'Penyair Uji' } },
            }) });
        }
        return Promise.resolve({ json: () => Promise.resolve({ status: 'sukses', data: [] }) });
    },
};

vm.createContext(context);
vm.runInContext(fs.readFileSync('web/js/api.js', 'utf8'), context, { filename: 'api.js' });
vm.runInContext(fs.readFileSync('web/js/auth.js', 'utf8'), context, { filename: 'auth.js' });
context.muatDaftarPuisi = () => {};

async function main() {
    assert.equal(context.klaimToken(vector.token_kedaluwarsa), null);
    assert.equal(context.klaimToken('malformed.token'), null);
    ready();
    assert.equal(element('area-auth').style.display, 'flex');

    element('login-username').value = 'penyair';
    element('login-password').value = 'password';
    context.prosesLogin({ preventDefault() {} });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(lastFetch.url, '/api/auth/login');
    assert.equal(lastFetch.options.credentials, 'omit');
    assert.equal(storage.get('puisi.token'), vector.token_benar);
    assert.equal(element('area-puisi').style.display, 'block');

    context.panggil('/api/puisi', { method: 'GET' });
    assert.equal(lastFetch.options.credentials, 'include');
    assert.equal(lastFetch.options.headers.Authorization, 'Bearer ' + vector.token_benar);

    ready();
    assert.equal(element('area-puisi').style.display, 'block');
    context.logout();
    assert.equal(storage.has('puisi.token'), false);
    assert.equal(element('area-auth').style.display, 'flex');
    console.log('PASS: frontend login, reload, logout, malformed/expired token, auth omit credentials, poem request compatibility');
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
