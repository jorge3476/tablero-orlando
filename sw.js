// Guarda el tablero en el iPad para que abra sin internet. Spotify siempre va por red.
var CACHE = 'orlando-v13';
var SHELL = ['./', './index.html', './manifest.webmanifest', './icon-192.png',
  './cars/orlando-principal.webp', './cars/orlando.glb', './car3d.js',
  './lib/three/build/three.module.min.js', './lib/three/examples/jsm/loaders/GLTFLoader.js', './lib/three/examples/jsm/controls/OrbitControls.js',
  './lib/three/examples/jsm/environments/RoomEnvironment.js', './lib/three/examples/jsm/utils/BufferGeometryUtils.js'];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) {
    return Promise.all(SHELL.map(function (u) { return c.add(u).catch(function () {}); }));
  }));
  self.skipWaiting();
});

self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }));
  self.clients.claim();
});

self.addEventListener('fetch', function (e) {
  var req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.hostname.indexOf('spotify.com') > -1 || url.hostname.indexOf('tomtom.com') > -1 || url.hostname.indexOf('scdn.co') > -1) { return; }
  e.respondWith(
    caches.match(req).then(function (hit) {
      var net = fetch(req).then(function (res) {
        if (res && res.ok) { var copy = res.clone(); caches.open(CACHE).then(function (c) { c.put(req, copy); }); }
        return res;
      }).catch(function () { return hit; });
      return hit || net;
    })
  );
});
