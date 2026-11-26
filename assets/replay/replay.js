// RuteStrip 3D replay: flies a camera along a saved recording over terrain.
// The app calls replayStart(jsonString) once after load and replayControl(cmd, arg)
// for play, pause, speed and restart; replayExport(cmd, json) records the replay as a video.
// Messages back go through the RS channel.
(function () {
  'use strict';

  var EMERALD = '#047857';
  var PITCH = 60;
  var ZOOM = 13.6;

  function post(msg) {
    try {
      window.RS.postMessage(msg);
    } catch (e) {
      /* no channel (opened in a plain browser) */
    }
  }

  function hasWebGL() {
    try {
      var c = document.createElement('canvas');
      return !!(c.getContext('webgl2') || c.getContext('webgl'));
    } catch (e) {
      return false;
    }
  }

  var data, map, pts, total, wpts = [];
  var s = 0, playing = false, speed = 1, lastFrame = 0, bear = null, failed = false, drawnAt = -1;
  var mPerSec = 1;
  var hud = {};
  var nf0, nf2;

  function fail(kind) {
    if (failed) return;
    failed = true;
    playing = false;
    exportAbort(null);
    post('error:' + kind);
  }

  // Interpolated state at distance d along the track: [lng, lat, t, gain].
  function at(d) {
    if (d <= 0) return [pts[0][0], pts[0][1], pts[0][3], pts[0][5]];
    var n = pts.length;
    if (d >= total) return [pts[n - 1][0], pts[n - 1][1], pts[n - 1][3], pts[n - 1][5]];
    var lo = 0, hi = n - 1;
    while (hi - lo > 1) {
      var mid = (lo + hi) >> 1;
      if (pts[mid][4] <= d) lo = mid;
      else hi = mid;
    }
    var a = pts[lo], b = pts[hi];
    var span = b[4] - a[4];
    var f = span > 0 ? (d - a[4]) / span : 0;
    var t = a[3] == null || b[3] == null ? null : a[3] + (b[3] - a[3]) * f;
    return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, t, a[5] + (b[5] - a[5]) * f];
  }

  function bearingTo(a, b) {
    var r = Math.PI / 180;
    var y = Math.sin((b[0] - a[0]) * r) * Math.cos(b[1] * r);
    var x = Math.cos(a[1] * r) * Math.sin(b[1] * r) - Math.sin(a[1] * r) * Math.cos(b[1] * r) * Math.cos((b[0] - a[0]) * r);
    return Math.atan2(y, x) / r;
  }

  function hm(sec) {
    var m = Math.floor(sec / 60);
    var h = Math.floor(m / 60);
    m = m % 60;
    return h + ':' + (m < 10 ? '0' : '') + m;
  }

  function lineExpr(color, frac) {
    var stop = Math.max(0.000001, frac);
    if (frac >= 1) return ['step', ['line-progress'], color, 2, color];
    return ['step', ['line-progress'], color, stop, 'rgba(0,0,0,0)'];
  }

  function updateHud(p) {
    if (data.hasTime && p[2] != null) hud.time.textContent = hm(p[2]);
    hud.dist.textContent = nf2.format(s / 1000);
    hud.gain.textContent = nf0.format(p[3]);
  }

  function wptData() {
    return {
      type: 'FeatureCollection',
      features: wpts.map(function (w) {
        return { type: 'Feature', properties: { passed: w.shown }, geometry: { type: 'Point', coordinates: [w.lng, w.lat] } };
      }),
    };
  }

  // A card under the HUD (text only, never HTML) while the replay passes a marked point.
  var calloutTimer = null, shownCallout = null;
  function callout(w) {
    var box = document.getElementById('callout');
    box.textContent = '';
    var n = document.createElement('div');
    n.className = 'n';
    n.textContent = w.name;
    box.appendChild(n);
    var parts = [];
    if (w.ele != null) parts.push(nf0.format(w.ele) + ' m');
    if (w.clock) parts.push(w.clock);
    if (parts.length) {
      var m = document.createElement('div');
      m.className = 'm';
      m.textContent = parts.join(' · ');
      box.appendChild(m);
    }
    box.hidden = false;
    shownCallout = { w: w, until: performance.now() + 4500 };
    map.getSource('wpts').setData(wptData());
    clearTimeout(calloutTimer);
    calloutTimer = setTimeout(function () {
      box.hidden = true;
    }, 4500);
  }

  function render(now) {
    // While exporting, slow frames take bigger steps so the video keeps its length.
    var dt = lastFrame ? Math.min(rec && rec.phase === 'fly' ? 0.3 : 0.1, (now - lastFrame) / 1000) : 0;
    lastFrame = now;
    if (playing) {
      s = Math.min(total, s + dt * (rec && rec.phase === 'fly' ? rec.rate : mPerSec * speed));
      for (var i = 0; i < wpts.length; i++) {
        if (!wpts[i].shown && s >= wpts[i].d) {
          wpts[i].shown = true;
          callout(wpts[i]);
        }
      }
    }
    var p = at(s);
    // Heading over a fixed window of track ahead (behind, near the end), smoothed below.
    var look = Math.max(120, Math.min(600, total * 0.04));
    var from = Math.max(0, Math.min(s, total - look));
    var target = bearingTo(at(from), at(Math.min(total, from + look)));
    var diff = 0;
    if (bear == null) bear = target;
    else {
      diff = ((target - bear + 540) % 360) - 180;
      bear += diff * Math.min(1, dt * 1.2);
    }
    // While paused and settled, leave the map alone so it can stop drawing.
    if (playing || s !== drawnAt || Math.abs(diff) > 0.05) {
      drawnAt = s;
      map.getSource('hiker').setData({ type: 'Point', coordinates: [p[0], p[1]] });
      map.jumpTo({ center: [p[0], p[1]], bearing: bear, pitch: PITCH, zoom: ZOOM });
      var frac = total > 0 ? s / total : 1;
      map.setPaintProperty('trk-casing', 'line-gradient', lineExpr('#ffffff', frac));
      map.setPaintProperty('trk-line', 'line-gradient', lineExpr(EMERALD, frac));
      updateHud(p);
    }
    if (playing && s >= total) {
      playing = false;
      post('ended');
      // Hold the last view for a moment, then the end card.
      if (rec && rec.phase === 'fly') setTimeout(exportEndCard, 500);
    }
    if (!failed) requestAnimationFrame(render);
  }

  function init() {
    var lang = data.lang === 'en' ? 'en-US' : 'id-ID';
    nf0 = new Intl.NumberFormat(lang, { maximumFractionDigits: 0 });
    nf2 = new Intl.NumberFormat(lang, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    pts = data.pts;
    total = pts[pts.length - 1][4];
    // About 30 s plus 6 s per km at 1x, between 40 s and 2 min.
    var secs = Math.max(40, Math.min(120, 30 + (total / 1000) * 6));
    mPerSec = total > 0 ? total / secs : 1;

    hud.time = document.getElementById('v-time');
    hud.dist = document.getElementById('v-dist');
    hud.gain = document.getElementById('v-gain');
    document.getElementById('k-time').textContent = data.labels.time;
    document.getElementById('k-dist').textContent = data.labels.dist;
    document.getElementById('k-gain').textContent = data.labels.gain;
    document.getElementById('cell-time').hidden = !data.hasTime;
    document.getElementById('hud').hidden = false;

    var coords = pts.map(function (p) {
      return [p[0], p[1]];
    });
    var start = coords[0];
    var h = window.innerHeight || 600;
    wpts = (data.wpts || []).map(function (w) {
      return { name: w.name, ele: w.ele, clock: w.clock, lng: w.lng, lat: w.lat, d: w.d, shown: false };
    });

    map = new maplibregl.Map({
      container: 'map',
      center: start,
      zoom: ZOOM,
      pitch: PITCH,
      bearing: bearingTo(start, at(Math.min(total, 300))),
      maxPitch: 70,
      minZoom: 8,
      maxZoom: 16,
      interactive: false,
      fadeDuration: 0,
      pixelRatio: Math.min(window.devicePixelRatio || 1, 1.5),
      attributionControl: { compact: false },
      canvasContextAttributes: { antialias: false, powerPreference: 'default' },
      style: {
        version: 8,
        sources: {
          osm: {
            type: 'raster',
            tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
            tileSize: 256,
            maxzoom: 15,
            attribution: '© OpenStreetMap contributors',
          },
          dem: {
            type: 'raster-dem',
            tiles: ['https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png'],
            encoding: 'terrarium',
            tileSize: 256,
            maxzoom: 15,
            attribution: 'Terrain Tiles: Mapzen, AWS',
          },
          trk: { type: 'geojson', lineMetrics: true, data: { type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: coords } } },
          wpts: { type: 'geojson', data: wptData() },
          hiker: { type: 'geojson', data: { type: 'Point', coordinates: start } },
        },
        terrain: { source: 'dem', exaggeration: 1.3 },
        sky: {
          'sky-color': '#7fb0d3',
          'horizon-color': '#f6f4ec',
          'fog-color': '#e7efe9',
          'fog-ground-blend': 0.6,
          'horizon-fog-blend': 0.7,
          'sky-horizon-blend': 0.6,
          'atmosphere-blend': 0,
        },
        layers: [
          { id: 'osm', type: 'raster', source: 'osm', paint: { 'raster-fade-duration': 0 } },
          {
            id: 'trk-ahead',
            type: 'line',
            source: 'trk',
            layout: { 'line-join': 'round', 'line-cap': 'round' },
            paint: { 'line-color': '#ffffff', 'line-opacity': 0.6, 'line-width': 2.5, 'line-dasharray': [2, 2] },
          },
          {
            id: 'trk-casing',
            type: 'line',
            source: 'trk',
            layout: { 'line-join': 'round', 'line-cap': 'round' },
            paint: { 'line-width': 10, 'line-gradient': lineExpr('#ffffff', 0) },
          },
          {
            id: 'trk-line',
            type: 'line',
            source: 'trk',
            layout: { 'line-join': 'round', 'line-cap': 'round' },
            paint: { 'line-width': 4.5, 'line-gradient': lineExpr(EMERALD, 0) },
          },
          {
            id: 'wpts',
            type: 'circle',
            source: 'wpts',
            paint: {
              'circle-radius': 7,
              'circle-color': ['case', ['get', 'passed'], EMERALD, '#ffffff'],
              'circle-stroke-width': 3,
              'circle-stroke-color': ['case', ['get', 'passed'], '#ffffff', '#053b30'],
              'circle-pitch-alignment': 'viewport',
            },
          },
          {
            id: 'hiker',
            type: 'circle',
            source: 'hiker',
            paint: {
              'circle-radius': 9,
              'circle-color': EMERALD,
              'circle-stroke-width': 3.5,
              'circle-stroke-color': '#ffffff',
              'circle-pitch-alignment': 'viewport',
            },
          },
        ],
      },
    });
    // Keep the hiker in the lower part of the screen, under the HUD.
    map.setPadding({ top: Math.round(h * 0.3), bottom: 0, left: 0, right: 0 });

    var tilesOk = false, tileErrors = 0;
    map.on('webglcontextlost', function () {
      fail('webgl');
    });
    map.on('sourcedata', function (e) {
      if (e.sourceId === 'osm' && e.tile) tilesOk = true;
    });
    map.on('error', function (e) {
      if (e && e.sourceId) {
        tileErrors++;
        if (!tilesOk && tileErrors >= 6) fail('tiles');
      }
    });
    setTimeout(function () {
      if (!tilesOk) fail('tiles');
    }, 20000);

    map.on('render', compose);
    map.once('load', function () {
      post('ready');
      requestAnimationFrame(render);
      // Give the first tiles a moment, then start.
      var started = false;
      var go = function () {
        if (started || failed) return;
        started = true;
        playing = true;
        post('playing');
      };
      map.once('idle', go);
      setTimeout(go, 4000);
    });
  }

  // ---- Video export ----
  // The replay is flown once from start to end at a fixed pace. Every map frame is drawn onto
  // an offscreen 2D canvas (at most 720 x 1280) together with the HUD, the map credit and the
  // RuteStrip mark, then an end card; MediaRecorder records that canvas. The file goes to the
  // app in base64 chunks, one per replayExport('next') call, so memory stays flat.

  var MIMES = ['video/mp4;codecs=avc1', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
  var CHUNK = 512 * 1024;
  var END_SECS = 1.5;
  var rec = null;

  function pickMime() {
    if (!window.MediaRecorder || typeof MediaRecorder.isTypeSupported !== 'function') return null;
    for (var i = 0; i < MIMES.length; i++) {
      if (MediaRecorder.isTypeSupported(MIMES[i])) return MIMES[i];
    }
    return null;
  }

  function even(v) {
    return Math.max(2, Math.round(v / 2) * 2);
  }

  function plate(g, x, y, w, h, r) {
    g.beginPath();
    g.moveTo(x + r, y);
    g.arcTo(x + w, y, x + w, y + h, r);
    g.arcTo(x + w, y + h, x, y + h, r);
    g.arcTo(x, y + h, x, y, r);
    g.arcTo(x, y, x + w, y, r);
    g.closePath();
    g.fill();
  }

  function font(weight, px, display) {
    return weight + ' ' + Math.round(px) + 'px ' + (display ? '"Barlow Condensed", sans-serif' : 'Inter, sans-serif');
  }

  // Text cut with an ellipsis to fit maxW.
  function fit(g, text, maxW) {
    if (g.measureText(text).width <= maxW) return text;
    var t = text;
    while (t.length > 1 && g.measureText(t + '…').width > maxW) t = t.slice(0, -1);
    return t + '…';
  }

  function drawHud(g, r, p) {
    var u = r.u, x = 10 * u, y = 10 * u, w = r.W - 20 * u, pad = 12 * u;
    var cells = [];
    if (data.hasTime && p[2] != null) cells.push([data.labels.time, hm(p[2]), '']);
    cells.push([data.labels.dist, nf2.format(s / 1000), ' km']);
    cells.push([data.labels.gain, nf0.format(p[3]), ' m']);
    var h = (r.title ? 27 : 0) * u + 62 * u;
    g.fillStyle = 'rgba(5, 59, 48, 0.88)';
    plate(g, x, y, w, h, 10 * u);
    g.textBaseline = 'top';
    var cy = y + 9 * u;
    if (r.title) {
      g.font = font(800, 21 * u, true);
      g.fillStyle = '#ffffff';
      g.fillText(fit(g, r.title.toUpperCase(), w - 2 * pad), x + pad, cy);
      cy += 27 * u;
    }
    var cw = (w - 2 * pad) / cells.length;
    for (var i = 0; i < cells.length; i++) {
      var c = cells[i], cx = x + pad + i * cw;
      g.font = font(600, 11 * u);
      g.fillStyle = '#a7f3d0';
      g.fillText(fit(g, String(c[0]).toUpperCase(), cw - 6 * u), cx, cy);
      g.font = font(800, 30 * u, true);
      g.fillStyle = '#ffffff';
      g.fillText(c[1], cx, cy + 16 * u);
      if (c[2]) {
        var vw = g.measureText(c[1]).width;
        g.font = font(800, 16 * u, true);
        g.fillText(c[2], cx + vw, cy + 28 * u);
      }
    }
    return y + h;
  }

  function drawCallout(g, r, top, now) {
    var c = shownCallout;
    if (!c || now > c.until) return;
    var u = r.u, x = 10 * u, y = top + 10 * u, pad = 14 * u;
    var meta = [];
    if (c.w.ele != null) meta.push(nf0.format(c.w.ele) + ' m');
    if (c.w.clock) meta.push(c.w.clock);
    g.font = font(800, 24 * u, true);
    var name = fit(g, String(c.w.name).toUpperCase(), r.W - 20 * u - 2 * pad - 5 * u);
    var w = g.measureText(name).width;
    g.font = font(600, 14 * u);
    var m = meta.join(' · ');
    w = Math.max(w, g.measureText(m).width) + 2 * pad + 5 * u;
    var h = (meta.length ? 48 : 30) * u;
    g.fillStyle = '#f6f4ec';
    plate(g, x, y, w, h, 8 * u);
    g.fillStyle = '#047857';
    g.fillRect(x, y + 2 * u, 5 * u, h - 4 * u);
    g.textBaseline = 'top';
    g.fillStyle = '#053b30';
    g.font = font(800, 24 * u, true);
    g.fillText(name, x + 5 * u + pad, y + 4 * u);
    if (meta.length) {
      g.fillStyle = '#4b5d55';
      g.font = font(600, 14 * u);
      g.fillText(m, x + 5 * u + pad, y + 29 * u);
    }
  }

  // Map credit bottom left, RuteStrip mark bottom right, both on small plates.
  function drawMarks(g, r) {
    var u = r.u, W = r.W, H = r.H;
    g.textBaseline = 'middle';
    g.font = font(400, 10 * u);
    var credit = '© OpenStreetMap contributors · Mapzen';
    var cw = g.measureText(credit).width + 10 * u;
    g.fillStyle = 'rgba(246, 244, 236, 0.8)';
    plate(g, 8 * u, H - 8 * u - 16 * u, cw, 16 * u, 4 * u);
    g.fillStyle = '#14231d';
    g.fillText(credit, 13 * u, H - 16 * u);

    var ls = 32 * u, pad = 7 * u, gap = r.logo ? ls + 7 * u : 0;
    g.font = font(800, 21 * u, true);
    var t1 = g.measureText('RuteStrip').width;
    g.font = font(600, 10.5 * u);
    var t2 = g.measureText('rutestrip.ai.id').width;
    var w = pad + gap + Math.max(t1, t2) + pad + 2 * u, h = ls + 2 * pad;
    var x = W - w - 8 * u, y = H - h - 30 * u;
    g.fillStyle = 'rgba(0, 0, 0, 0.42)';
    plate(g, x, y, w, h, 9 * u);
    if (r.logo) g.drawImage(r.logo, x + pad, y + pad, ls, ls);
    g.textBaseline = 'top';
    g.fillStyle = '#ffffff';
    g.font = font(800, 21 * u, true);
    g.fillText('RuteStrip', x + pad + gap, y + pad - 1 * u);
    g.fillStyle = 'rgba(255, 255, 255, 0.82)';
    g.font = font(600, 10.5 * u);
    g.fillText('rutestrip.ai.id', x + pad + gap, y + pad + 21 * u);
  }

  function progress(r, f) {
    var now = performance.now();
    if (now - r.sentAt < 250 && f < 1) return;
    r.sentAt = now;
    post('export:progress:' + Math.max(0, Math.min(1, f)).toFixed(3));
  }

  // Runs on every map frame (MapLibre's render event), while the WebGL buffer still holds it.
  function compose() {
    var r = rec;
    if (!r || r.phase !== 'fly') return;
    var g = r.g, now = performance.now();
    g.drawImage(map.getCanvas(), 0, 0, r.W, r.H);
    var bottom = drawHud(g, r, at(s));
    drawCallout(g, r, bottom, now);
    drawMarks(g, r);
    progress(r, total > 0 ? (0.95 * s) / total : 0.95);
  }

  function drawEnd(g, r, f) {
    var u = r.u, W = r.W, H = r.H, cx = W / 2;
    g.globalAlpha = 1;
    g.drawImage(r.base, 0, 0);
    g.globalAlpha = f;
    g.fillStyle = 'rgba(5, 59, 48, 0.94)';
    g.fillRect(0, 0, W, H);
    var ls = 104 * u, y = H / 2 - 120 * u;
    if (r.logo) g.drawImage(r.logo, cx - ls / 2, y, ls, ls);
    y += ls + 18 * u;
    g.textAlign = 'center';
    g.textBaseline = 'top';
    if (r.title) {
      g.fillStyle = '#ffffff';
      g.font = font(800, 30 * u, true);
      g.fillText(fit(g, r.title.toUpperCase(), W - 40 * u), cx, y);
      y += 38 * u;
    }
    g.fillStyle = '#a7f3d0';
    g.font = font(600, 16 * u);
    g.fillText(nf2.format(total / 1000) + ' km · +' + nf0.format(pts[pts.length - 1][5]) + ' m', cx, y);
    y += 40 * u;
    g.fillStyle = '#ffffff';
    g.font = font(600, 17 * u);
    g.fillText(r.endLabel || 'RuteStrip', cx, y);
    y += 26 * u;
    g.fillStyle = 'rgba(255, 255, 255, 0.8)';
    g.font = font(400, 14 * u);
    g.fillText('rutestrip.ai.id', cx, y);
    g.textAlign = 'left';
    g.globalAlpha = 1;
  }

  function exportEndCard() {
    var r = rec;
    if (!r || r.phase !== 'fly') return;
    r.phase = 'end';
    r.base = document.createElement('canvas');
    r.base.width = r.W;
    r.base.height = r.H;
    r.base.getContext('2d').drawImage(r.out, 0, 0);
    var t0 = performance.now();
    var frame = function (now) {
      if (rec !== r || r.phase !== 'end') return;
      var t = Math.max(0, (now - t0) / 1000);
      drawEnd(r.g, r, Math.min(1, t / 0.35));
      progress(r, 0.95 + 0.05 * Math.min(1, t / END_SECS));
      if (t >= END_SECS) {
        r.phase = 'stop';
        r.durMs = performance.now() - r.t0;
        try {
          r.mr.stop();
        } catch (e) {
          exportAbort('failed');
        }
        return;
      }
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }

  function releaseView(r) {
    if (r.stream) {
      r.stream.getTracks().forEach(function (t) {
        t.stop();
      });
      r.stream = null;
    }
    if (r.lock) {
      r.lock.release().catch(function () {});
      r.lock = null;
    }
    if (r.viewKept) return;
    r.viewKept = true;
    playing = false;
    try {
      map.setPixelRatio(r.pr);
    } catch (e) {
      /* map gone */
    }
  }

  // Stops and forgets the export; kind (if any) goes to the app as export:error:<kind>.
  function exportAbort(kind) {
    var r = rec;
    if (!r) return;
    rec = null;
    r.cancelled = true;
    try {
      if (r.mr && r.mr.state !== 'inactive') r.mr.stop();
    } catch (e) {
      /* already stopped */
    }
    releaseView(r);
    r.parts = [];
    r.blob = null;
    r.base = null;
    if (kind) post('export:error:' + kind);
    if (!failed) post('paused');
  }

  function onRecorded(r) {
    releaseView(r);
    if (r.cancelled || rec !== r) return;
    post('export:encoding');
    var type = r.mime.split(';')[0];
    var blob = new Blob(r.parts, { type: type });
    r.parts = [];
    r.base = null;
    var ready = function (b) {
      if (rec !== r) return;
      if (!b.size) return exportAbort('failed');
      r.blob = b;
      r.n = Math.ceil(b.size / CHUNK);
      r.i = 0;
      post('export:file:' + JSON.stringify({ ext: type === 'video/mp4' ? 'mp4' : 'webm', mime: type, size: b.size, n: r.n }));
    };
    if (type === 'video/webm') {
      fixWebmDuration(blob, r.durMs).then(ready, function () {
        ready(blob);
      });
    } else ready(blob);
  }

  function exportNext() {
    var r = rec;
    if (!r || !r.blob) return;
    if (r.i >= r.n) {
      rec = null;
      r.blob = null;
      post('export:end');
      return;
    }
    var i = r.i++;
    var fr = new FileReader();
    fr.onload = function () {
      if (rec !== r) return;
      var d = String(fr.result);
      post('export:chunk:' + i + ':' + d.slice(d.indexOf(',') + 1));
    };
    fr.onerror = function () {
      exportAbort('failed');
    };
    fr.readAsDataURL(r.blob.slice(i * CHUNK, (i + 1) * CHUNK));
  }

  function exportStart(opts) {
    if (rec || !map || failed) return;
    var mime = pickMime();
    var out = document.createElement('canvas');
    if (!mime || typeof out.captureStream !== 'function') return post('export:error:unsupported');
    var box = map.getContainer();
    var cw = box.clientWidth || window.innerWidth || 360, ch = box.clientHeight || window.innerHeight || 640;
    var k = Math.min(720 / cw, 1280 / ch);
    var W = even(cw * k), H = even(ch * k);
    out.width = W;
    out.height = H;
    var g = out.getContext('2d');
    if (!g) return post('export:error:unsupported');
    // About half the 1x replay time: 20 to 45 s whatever the track length.
    var secs = Math.max(20, Math.min(45, total / mPerSec / 2));
    var r = (rec = {
      mime: mime,
      out: out,
      g: g,
      W: W,
      H: H,
      u: W / 400,
      title: String(opts.title || ''),
      endLabel: String(opts.end || ''),
      logo: null,
      rate: total > 0 ? total / secs : 1,
      phase: 'prep',
      parts: [],
      sentAt: 0,
      pr: map.getPixelRatio(),
    });
    if (opts.logo) {
      var img = new Image();
      img.onload = function () {
        r.logo = img;
      };
      img.src = opts.logo;
    }
    if (navigator.wakeLock && navigator.wakeLock.request) {
      navigator.wakeLock.request('screen').then(
        function (l) {
          if (rec === r) r.lock = l;
          else l.release();
        },
        function () {},
      );
    }
    // Back to the start, map drawn at the video's resolution.
    playing = false;
    s = 0;
    bear = null;
    drawnAt = -1;
    shownCallout = null;
    wpts.forEach(function (w) {
      w.shown = false;
    });
    map.getSource('wpts').setData(wptData());
    document.getElementById('callout').hidden = true;
    map.setPixelRatio(Math.min(2, Math.max(r.pr, W / cw)));
    post('paused');

    var begun = false;
    var begin = function () {
      if (begun || rec !== r) return;
      begun = true;
      try {
        r.stream = out.captureStream(30);
        r.mr = new MediaRecorder(r.stream, { mimeType: mime, videoBitsPerSecond: 4000000 });
      } catch (e) {
        return exportAbort('unsupported');
      }
      r.mr.ondataavailable = function (e) {
        if (rec === r && e.data && e.data.size) r.parts.push(e.data);
      };
      r.mr.onstop = function () {
        onRecorded(r);
      };
      r.mr.onerror = function () {
        exportAbort('failed');
      };
      r.phase = 'fly';
      compose();
      try {
        r.mr.start(1000);
      } catch (e) {
        return exportAbort('unsupported');
      }
      r.t0 = performance.now();
      playing = true;
      post('playing');
    };
    // Let the first tiles arrive (fonts too), but never wait long.
    map.once('idle', function () {
      (document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve()).then(begin, begin);
    });
    setTimeout(begin, 6000);
    post('export:started');
  }

  // MediaRecorder WebM has no duration, so galleries show 0:00 and cannot seek well. Adds a
  // Duration element to the Segment Info (Chrome writes no SeekHead or Cues that would move).
  function fixWebmDuration(blob, ms) {
    return blob
      .slice(0, Math.min(blob.size, 65536))
      .arrayBuffer()
      .then(function (ab) {
        var b = new Uint8Array(ab);
        var len = function (x) {
          for (var n = 1; n <= 8; n++) if (x & (0x100 >> n)) return n;
          throw new Error('vint');
        };
        var id = function (p) {
          var n = len(b[p]), v = 0;
          for (var i = 0; i < n; i++) v = v * 256 + b[p + i];
          return { v: v, n: n };
        };
        var size = function (p) {
          var n = len(b[p]), v = b[p] & (0xff >> n), unknown = v === 0xff >> n;
          for (var i = 1; i < n; i++) {
            v = v * 256 + b[p + i];
            if (b[p + i] !== 0xff) unknown = false;
          }
          return { v: unknown ? -1 : v, n: n };
        };
        var e = id(0);
        if (e.v !== 0x1a45dfa3) throw new Error('not webm');
        var z = size(e.n);
        var p = e.n + z.n + z.v;
        e = id(p);
        if (e.v !== 0x18538067) throw new Error('no segment');
        p += e.n + size(p + e.n).n;
        while (p < b.length - 12) {
          e = id(p);
          z = size(p + e.n);
          var cs = p + e.n + z.n, ce = cs + z.v;
          if (e.v === 0x1f43b675 || z.v < 0 || ce > b.length) throw new Error('no info');
          if (e.v === 0x1549a966) {
            var scale = 1e6;
            for (var q = cs; q < ce; ) {
              var ci = id(q), cz = size(q + ci.n), vs = q + ci.n + cz.n;
              if (ci.v === 0x4489) throw new Error('has duration');
              if (ci.v === 0x2ad7b1) {
                scale = 0;
                for (var i = 0; i < cz.v; i++) scale = scale * 256 + b[vs + i];
              }
              q = vs + cz.v;
            }
            var dur = new Uint8Array(11);
            dur.set([0x44, 0x89, 0x88]);
            new DataView(dur.buffer).setFloat64(3, (ms * 1e6) / (scale || 1e6));
            var body = z.v + 11;
            var head = new Uint8Array(12);
            head.set([0x15, 0x49, 0xa9, 0x66, 0x01]);
            for (var j = 0; j < 7; j++) head[11 - j] = Math.floor(body / Math.pow(256, j)) & 0xff;
            return new Blob([blob.slice(0, p), head, blob.slice(cs, ce), dur, blob.slice(ce)], { type: blob.type });
          }
          p = ce;
        }
        throw new Error('no info');
      });
  }

  window.replayExport = function (cmd, json) {
    if (cmd === 'start') {
      var o = {};
      try {
        o = JSON.parse(json || '{}') || {};
      } catch (e) {
        /* defaults */
      }
      exportStart(o);
    } else if (cmd === 'next') exportNext();
    else if (cmd === 'cancel') exportAbort(null);
  };

  window.replayStart = function (json) {
    if (map) return;
    try {
      data = JSON.parse(json);
    } catch (e) {
      fail('data');
      return;
    }
    if (!navigator.onLine) {
      fail('tiles');
      return;
    }
    if (!window.maplibregl || !hasWebGL()) {
      fail('webgl');
      return;
    }
    try {
      init();
    } catch (e) {
      fail('webgl');
    }
  };

  window.replayControl = function (cmd, arg) {
    if (!map || failed || rec) return;
    if (cmd === 'play') {
      if (s >= total) cmd = 'restart';
      else {
        playing = true;
        post('playing');
      }
    }
    if (cmd === 'pause') {
      playing = false;
      post('paused');
    } else if (cmd === 'speed') {
      speed = arg === 4 ? 4 : arg === 2 ? 2 : 1;
    }
    if (cmd === 'restart') {
      s = 0;
      bear = null;
      wpts.forEach(function (w) {
        w.shown = false;
      });
      map.getSource('wpts').setData(wptData());
      document.getElementById('callout').hidden = true;
      playing = true;
      post('playing');
    }
  };
})();
