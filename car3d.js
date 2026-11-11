// Visor 3D del Orlando. Carga three.js desde lib/ (funciona sin internet).
// Modelo: "Chevrolet Orlando 2011" por Q.SARDOR (Sketchfab), CC BY 4.0, simplificado.
import * as THREE from 'three';
import { GLTFLoader } from './lib/three/examples/jsm/loaders/GLTFLoader.js';
import { OrbitControls } from './lib/three/examples/jsm/controls/OrbitControls.js';
import { RoomEnvironment } from './lib/three/examples/jsm/environments/RoomEnvironment.js';

let renderer, scene, camera, controls, host, plateTex, plateCanvas, loaded = false, failed = false, visible = false;
const plateMeshes = [];
let rafId = 0, moving = 0;
const HOME = { pos: new THREE.Vector3(-4.6, 1.95, 5.4), target: new THREE.Vector3(0, 0.68, 0) };

function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }

function requestRender() { if (!visible || !renderer) return; if (!rafId) rafId = requestAnimationFrame(frame); }
function frame() {
  rafId = 0;
  const changed = controls.update();
  renderer.render(scene, camera);
  if (changed || moving > 0) { moving = Math.max(0, moving - 1); rafId = requestAnimationFrame(frame); }
}

function resize() {
  if (!renderer || !host) return;
  const w = host.clientWidth, h = host.clientHeight;
  if (w < 10 || h < 10) return;
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  // en pantallas angostas se aleja un poco para que quepa el carro completo
  camera.zoom = Math.min(1, (w / h) / 1.15);
  camera.updateProjectionMatrix();
  requestRender();
}

function shadowTexture() {
  const c = document.createElement('canvas'); c.width = c.height = 256;
  const x = c.getContext('2d'); const g = x.createRadialGradient(128, 128, 10, 128, 128, 128);
  g.addColorStop(0, 'rgba(0,0,0,0.65)'); g.addColorStop(0.55, 'rgba(0,0,0,0.35)'); g.addColorStop(1, 'rgba(0,0,0,0)');
  x.fillStyle = g; x.fillRect(0, 0, 256, 256);
  return new THREE.CanvasTexture(c);
}

/* Placa estilo California: fondo azul, texto superior en cursiva blanca y caracteres amarillos */
async function drawPlate(top, num) {
  if (!plateCanvas) { plateCanvas = document.createElement('canvas'); plateCanvas.width = 1024; plateCanvas.height = 512; }
  const W = 1024, H = 512, x = plateCanvas.getContext('2d');
  try { await Promise.race([Promise.all([document.fonts.load('90px "Yellowtail"'), document.fonts.load('600 200px "Oswald"')]), new Promise(r => setTimeout(r, 2500))]); } catch (e) {}
  const rr = (X, Y, w, h, r) => { x.beginPath(); x.moveTo(X + r, Y); x.arcTo(X + w, Y, X + w, Y + h, r); x.arcTo(X + w, Y + h, X, Y + h, r); x.arcTo(X, Y + h, X, Y, r); x.arcTo(X, Y, X + w, Y, r); x.closePath(); };
  x.clearRect(0, 0, W, H);
  rr(0, 0, W, H, 34); x.fillStyle = '#084a96'; x.fill();
  rr(6, 6, W - 12, H - 12, 30); const bg = x.createLinearGradient(0, 0, 0, H); bg.addColorStop(0, '#0d62b6'); bg.addColorStop(1, '#0a56a6'); x.fillStyle = bg; x.fill();
  rr(16, 16, W - 32, H - 32, 24); x.lineWidth = 4; x.strokeStyle = '#063e80'; x.stroke();
  for (const [cx, cy] of [[205, 44], [819, 44], [205, 468], [819, 468]]) {
    x.beginPath(); x.arc(cx, cy, 13, 0, 7); x.fillStyle = '#ebf0f5'; x.fill();
    x.beginPath(); x.arc(cx, cy, 8, 0, 7); x.fillStyle = '#1e2837'; x.fill();
  }
  x.textAlign = 'center'; x.textBaseline = 'alphabetic';
  x.fillStyle = '#ffffff'; x.font = '96px "Yellowtail", "Brush Script MT", cursive';
  x.fillText(top || '', W / 2, 128);
  // caracteres altos y angostos, como la placa original
  x.save(); x.fillStyle = '#ffcd18'; x.font = '600 230px "Oswald", "Arial Narrow", sans-serif';
  const t = (num || '').toUpperCase(); let wTxt = x.measureText(t).width; const maxW = W - 120;
  const sx = wTxt > maxW ? maxW / wTxt : 1;
  x.translate(W / 2, 440); x.scale(sx, 1.12); x.fillText(t, 0, 0); x.restore();
  if (!plateTex) {
    plateTex = new THREE.CanvasTexture(plateCanvas);
    plateTex.flipY = false; plateTex.colorSpace = THREE.SRGBColorSpace; plateTex.anisotropy = 4;
  }
  plateTex.needsUpdate = true;
  plateMeshes.forEach((o) => { if (o.material.map !== plateTex) { o.material = o.material.clone(); o.material.map = plateTex; o.material.needsUpdate = true; } });
  requestRender();
}

function init() {
  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(26, 1, 0.1, 100);
  camera.position.copy(HOME.pos);
  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'low-power' });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.toneMappingExposure = 1.05;
  renderer.domElement.style.cssText = 'width:100%;height:100%;display:block;touch-action:none';
  host.appendChild(renderer.domElement);
  const pm = new THREE.PMREMGenerator(renderer);
  scene.environment = pm.fromScene(new RoomEnvironment(renderer), 0.04).texture;
  const sun = new THREE.DirectionalLight(0xffffff, 1.4); sun.position.set(-4, 8, 5); scene.add(sun);
  scene.add(new THREE.HemisphereLight(0xbfd6ff, 0x1a1d22, 0.35));
  const sh = new THREE.Mesh(new THREE.PlaneGeometry(3.4, 6.4), new THREE.MeshBasicMaterial({ map: shadowTexture(), transparent: true, depthWrite: false }));
  sh.rotation.x = -Math.PI / 2; sh.position.y = 0.005; scene.add(sh);

  controls = new OrbitControls(camera, renderer.domElement);
  controls.target.copy(HOME.target); controls.enableDamping = true; controls.dampingFactor = 0.09;
  controls.enablePan = false; controls.minDistance = 3.2; controls.maxDistance = 12;
  controls.minPolarAngle = 0.25; controls.maxPolarAngle = Math.PI / 2 - 0.04;
  controls.rotateSpeed = 0.8; controls.zoomSpeed = 0.6;
  controls.addEventListener('change', requestRender);
  controls.addEventListener('start', () => { moving = 60; requestRender(); });
  controls.addEventListener('end', () => { moving = 40; requestRender(); });
  controls.update();
  // doble toque: volver a la vista inicial
  let lastTap = 0;
  renderer.domElement.addEventListener('pointerup', () => { const n = Date.now(); if (n - lastTap < 320) resetView(); lastTap = n; });

  new ResizeObserver(resize).observe(host);
  resize();

  new GLTFLoader().load('cars/orlando.glb', (gltf) => {
    const car = gltf.scene; scene.add(car);
    car.traverse((o) => {
      if (!o.isMesh) return;
      const m = o.material;
      if (o.name.startsWith('plate') || (o.parent && o.parent.name.startsWith('plate'))) plateMeshes.push(o);
      if (m && m.name === 'carpaint') { m.envMapIntensity = 1.1; }
      if (m && (m.name === 'chrome' || m.name === 'mirror')) { m.envMapIntensity = 1.4; }
    });
    loaded = true; host.classList.add('ready');
    drawPlate(lsGet('plateTop') || 'Teacher', lsGet('plateNum') || 'LACO 52');
    // un frame inicial con la placa provisoria del modelo mientras cargan las fuentes
    requestRender();
    window.dispatchEvent(new Event('car3d-loaded'));
  }, undefined, (err) => { failed = true; window.dispatchEvent(new CustomEvent('car3d-fail', { detail: String(err) })); });
}

function resetView() {
  const fromP = camera.position.clone(), fromT = controls.target.clone(), t0 = performance.now();
  const step = (now) => {
    const k = Math.min(1, (now - t0) / 650), e = 1 - Math.pow(1 - k, 3);
    camera.position.lerpVectors(fromP, HOME.pos, e); controls.target.lerpVectors(fromT, HOME.target, e);
    controls.update(); renderer.render(scene, camera);
    if (k < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

window.Car3D = {
  show(el) {
    host = el; visible = true;
    if (!renderer) init(); else { resize(); requestRender(); }
    return !failed;
  },
  hide() { visible = false; },
  setPlate(top, num) { drawPlate(top, num); },
  reset: resetView,
  get loaded() { return loaded; },
  get failed() { return failed; },
};
window.dispatchEvent(new Event('car3d-ready'));
