// RuteStrip 3D replay: flies a camera along a saved recording over terrain.
// The app calls replayStart(jsonString) once after load and replayControl(cmd, arg)
// for play, pause, speed and restart. Messages back go through the RS channel.
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
  var calloutTimer = null;
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
    map.getSource('wpts').setData(wptData());
    clearTimeout(calloutTimer);
    calloutTimer = setTimeout(function () {
      box.hidden = true;
    }, 4500);
  }

  function render(now) {
    var dt = lastFrame ? Math.min(0.1, (now - lastFrame) / 1000) : 0;
    lastFrame = now;
    if (playing) {
      s = Math.min(total, s + dt * mPerSec * speed);
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
    if (!map || failed) return;
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
