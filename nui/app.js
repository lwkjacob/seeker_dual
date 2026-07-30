/* Font-based 7-segment display using Segment7Standard */
function createDigitDisplay(count = 3, containerClass = '') {
    const wrap = document.createElement('div');
    wrap.className = `digit-display ${containerClass}`;
    const ghost = document.createElement('span');
    ghost.className = 'digit-ghost';
    ghost.textContent = '888';
    wrap.appendChild(ghost);
    const span = document.createElement('span');
    span.className = 'digit-text';
    span.textContent = '   ';
    wrap.appendChild(span);
    return wrap;
}

function updateDigitDisplay(wrap, str) {
    const text = String(str).padStart(3).slice(-3);
    const span = wrap.querySelector('.digit-text');
    if (span) span.textContent = text;
}

const container = document.getElementById('radar-container');
const overlays = {
    xmit: document.getElementById('overlay-xmit'),
    fast: document.getElementById('overlay-fast'),
    front: document.getElementById('overlay-front'),
    rear: document.getElementById('overlay-rear'),
    same: document.getElementById('overlay-same'),
    lock: document.getElementById('overlay-lock'),
    // Arrow pair beside the FAST window. Element ids and PNG names are historical ("lock"):
    // they used to follow the antenna lock, they now follow the FAST reading.
    fastFrontArrow: document.getElementById('overlay-lock-front'),
    fastRearArrow: document.getElementById('overlay-lock-rear'),
    targetFrontArrow: document.getElementById('overlay-target-front'),
    targetRearArrow: document.getElementById('overlay-target-rear'),
};
const speedTarget = document.getElementById('speed-target');
const speedFast = document.getElementById('speed-fast');
const speedPatrol = document.getElementById('speed-patrol');
const resizeHandle = document.getElementById('resize-handle');
const radarPowerBtn = document.getElementById('btn-power-radar');
const plateReader = document.getElementById('plate-reader');
const plateFrontBg = document.getElementById('plate-front-bg');
const plateRearBg = document.getElementById('plate-rear-bg');
const plateFrontText = document.getElementById('plate-front-text');
const plateRearText = document.getElementById('plate-rear-text');
const plateFrontLocked = document.getElementById('plate-front-locked');
const plateRearLocked = document.getElementById('plate-rear-locked');

function initDigitDisplays() {
    [speedTarget, speedFast, speedPatrol].forEach((el, i) => {
        const wrap = createDigitDisplay(3, ['target', 'fast', 'patrol'][i]);
        el.appendChild(wrap);
    });
}
initDigitDisplays();

/* DUI mode — the same page, loaded a second time by client/dui.lua with ?dui=1 and
   rendered onto the `seeker_front` texture of the radar prop. The prop is the physical
   unit, so it draws the radar face alone: no plate reader, no remote, no drag/scale.
   Audio is muted here because the on-screen NUI is already playing every beep, voice
   enunciator and the Doppler tone — unmuted, the player would hear all of it twice. */
const DUI_MODE = new URLSearchParams(window.location.search).get('dui') === '1';
/** .radar-container's native box. The whole layout is authored against these numbers. */
const DUI_BASE_WIDTH = 400;
const DUI_BASE_HEIGHT = 200;
/** Native size of images/seeker_dual_dsr_base.png, and of the seeker_front texture it
 *  replaces. `object-fit: contain` fits the artwork to this ratio inside the 2:1 box. */
const DUI_ART_ASPECT = 715 / 230;

/** Fits the radar face to the DUI surface. CSS cannot divide a viewport unit by a length,
 *  so both the scale factor and the letterbox crop are computed here for the stylesheet. */
function applyDuiScale() {
    const scale = window.innerWidth / DUI_BASE_WIDTH;
    // Height the artwork actually occupies inside the base box, and the empty strip above it.
    const artHeight = DUI_BASE_WIDTH / DUI_ART_ASPECT;
    const bar = (DUI_BASE_HEIGHT - artHeight) / 2;

    const root = document.documentElement.style;
    root.setProperty('--dui-scale', scale);
    root.setProperty('--dui-shift', `${-bar * scale}px`);
}

if (DUI_MODE) {
    document.body.classList.add('dui-mode');
    applyDuiScale();
    // Config.radarProp.duiWidth/duiHeight can change between sessions, and CEF reports the
    // surface size late on a cold start, so the fit is recomputed rather than assumed.
    window.addEventListener('resize', applyDuiScale);
    // The prop screen has no show/hide of its own: the unit is bolted in the car whether
    // or not it is powered, and reads dark when off because every window blanks.
    container.classList.add('visible');
}

/** Self-test pass cue (nui/sounds/<name>.wav). Swap the file or this name to change it. */
const SELF_TEST_PASS_SOUND = 'stupidfuckinghappysound';
/** Trim applied on top of master volume. 0.6 ≈ -4.4 dB; lower it further to taste. */
const SELF_TEST_PASS_GAIN = 0.6;

const sounds = {};
const SOUND_NAMES = ['XmitOn', 'XmitOff', 'Beep', 'Away', 'Closing', 'Front', 'Rear', 'alpr_hit', SELF_TEST_PASS_SOUND];

function loadSounds() {
    SOUND_NAMES.forEach(name => {
        const audio = new Audio(`sounds/${name}.wav`);
        audio.preload = 'auto';
        audio.volume = 1.0;
        sounds[name] = audio;
        audio.load();
    });
}
if (!DUI_MODE) loadSounds();

function postRemoteAction(action) {
    if (DUI_MODE || !action) return;
    fetch(`https://${GetParentResourceName()}/remoteBtn`, {
        method: 'POST',
        body: JSON.stringify({ action }),
    }).catch(() => {});
}

if (radarPowerBtn) {
    radarPowerBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        postRemoteAction('power');
    });
}

// Handshake so client can re-send persisted display config after NUI boot.
// Skipped in DUI mode: the prop screen has no saved layout, and a DUI page is not the
// resource's NUI frame, so the callback would not resolve anyway.
if (!DUI_MODE) {
    fetch(`https://${GetParentResourceName()}/nuiReady`, {
        method: 'POST',
        body: '{}',
    }).catch(() => {});
}

let voiceQueue = [];
let voicePlaying = false;

function playVoiceSequence(names, vol = 1.0) {
    if (DUI_MODE) return;
    voiceQueue = [...names];
    voicePlaying = true;
    playNextVoice(vol);
}

function playNextVoice(vol) {
    if (voiceQueue.length === 0) { voicePlaying = false; return; }
    const name = voiceQueue.shift();
    if (!sounds[name]) { playNextVoice(vol); return; }
    const audio = sounds[name];
    audio.volume = vol;
    audio.currentTime = 0;
    audio.onended = () => { setTimeout(() => playNextVoice(vol), 100); };
    audio.play().catch(() => { playNextVoice(vol); });
}

// Doppler: pitch/volume scale linearly with every mph (no stepped threshold bands)
const DOPPLER_PITCH_SCALE = 0.87; // <1 = lower overall pitch
const DOPPLER_GAIN_SCALE = 0.52; // master output quieter
/** Exponential smoothing time constant (seconds) for pitch/volume. setTargetAtTime lands ~95%
 *  of the way in 3x this, so 0.008 settles in ~24ms — under one 33ms radar tick. That reads as a
 *  snap between two speeds while still taking the click off the transition; the old 0.04 (~120ms)
 *  was long enough to hear as a glide up to the new pitch. Raise it for a softer sweep, but going
 *  much below ~0.004 starts to click. */
const DOPPLER_PARAM_SMOOTH_S = 0.008;

let dopplerCtx = null;
let dopplerBuffer = null;
let dopplerGain = null;
let dopplerSource = null;
let currentDopplerSpeed = null;

/* The radar is powered and already capturing targets while the self-test runs, so update
   ticks carry a live dopplerSpeedMph the whole time. Hold the tone off until the sequence
   finishes and the windows show real readings again. */
let selfTestRunning = false;

// 0 mph → pitchMin / volMin; at each maxSpeed → pitchMax / volMax (flat above that speed)
let dopplerPitchMin = 1.0;
let dopplerPitchMax = 2.5;
let dopplerPitchMaxSpeedMph = 150;
let dopplerVolMin = 0.2;
let dopplerVolMax = 1.0;
let dopplerVolMaxSpeedMph = 150;

/** Map speed (mph) to pitch/volume: continuous linear ramps (each mph nudges tone slightly). */
function dopplerLinearMap(speedMph) {
    const pMax = Math.max(dopplerPitchMaxSpeedMph, 1);
    const sP = Math.max(0, Math.min(speedMph, pMax));
    const tP = sP / pMax;
    const pitch = dopplerPitchMin + tP * (dopplerPitchMax - dopplerPitchMin);

    const vMax = Math.max(dopplerVolMaxSpeedMph, 1);
    const sV = Math.max(0, Math.min(speedMph, vMax));
    const tV = sV / vMax;
    const vol = dopplerVolMin + tV * (dopplerVolMax - dopplerVolMin);

    return { pitch, vol };
}

/** Lazily create the one shared AudioContext (browsers cap how many you may open). */
function getAudioCtx() {
    if (!dopplerCtx) {
        try {
            dopplerCtx = new (window.AudioContext || window.webkitAudioContext)();
        } catch (e) {
            return null;
        }
    }
    return dopplerCtx;
}

async function loadDopplerSound() {
    try {
        if (!getAudioCtx()) throw new Error('no AudioContext');
        const res = await fetch('sounds/doppler/0.wav');
        const arr = await res.arrayBuffer();
        dopplerBuffer = await dopplerCtx.decodeAudioData(arr);
        dopplerGain = dopplerCtx.createGain();
        dopplerGain.connect(dopplerCtx.destination);
    } catch (e) { console.warn('Doppler load failed:', e); }
}
loadDopplerSound();


function playDopplerStart(speedMph, masterVolume) {
    if (!dopplerCtx || !dopplerBuffer || !dopplerGain) return;
    const { pitch, vol: volMult } = dopplerLinearMap(speedMph);
    const rate = pitch * DOPPLER_PITCH_SCALE;
    const gainLinear = masterVolume * volMult * DOPPLER_GAIN_SCALE;

    const src = dopplerCtx.createBufferSource();
    src.buffer = dopplerBuffer;
    src.loop = true;
    src.playbackRate.setValueAtTime(rate, dopplerCtx.currentTime);
    dopplerGain.gain.setValueAtTime(gainLinear, dopplerCtx.currentTime);
    src.connect(dopplerGain);
    src.start(0);
    dopplerSource = src;
}

/** Silence the loop and reset the ramp so the next target starts a fresh source. */
function stopDopplerTone() {
    if (dopplerSource) {
        dopplerSource.stop();
        dopplerSource.disconnect();
        dopplerSource = null;
    }
    currentDopplerSpeed = null;
}

function updateDoppler(speedMph, masterVolume = 1.0) {
    if (DUI_MODE) return;
    const hasTarget = !selfTestRunning && speedMph !== null && speedMph !== undefined && speedMph >= 0;

    if (!dopplerCtx || !dopplerBuffer) return;

    if (hasTarget) {
        if (dopplerCtx.state === 'suspended') dopplerCtx.resume();
    }

    if (hasTarget) {
        const { pitch, vol: volMult } = dopplerLinearMap(speedMph);
        const rate = pitch * DOPPLER_PITCH_SCALE;

        if (currentDopplerSpeed === null) {
            playDopplerStart(speedMph, masterVolume);
        }
        if (dopplerSource) {
            const now = dopplerCtx.currentTime;
            dopplerSource.playbackRate.setTargetAtTime(rate, now, DOPPLER_PARAM_SMOOTH_S);
            dopplerGain.gain.setTargetAtTime(masterVolume * volMult * DOPPLER_GAIN_SCALE, now, DOPPLER_PARAM_SMOOTH_S);
        }
        currentDopplerSpeed = speedMph;
    } else {
        stopDopplerTone();
    }
}

function playSound(name, vol = 1.0) {
    if (DUI_MODE) return;
    if (!sounds[name]) return;
    let audio = sounds[name];
    if (audio.error) {
        audio = new Audio(`sounds/${name}.wav`);
        audio.preload = 'auto';
        sounds[name] = audio;
    }
    // Clamped: assigning outside 0..1 throws and would abort the caller mid-sequence.
    audio.volume = Math.max(0, Math.min(1, vol));
    audio.currentTime = 0;
    audio.play().catch(() => {});
}

/* Self-test, mirroring the STALKER DUAL power-on sequence. Each step is one screen:
   `at` is ms from the start of the run, and t/f/p are the literal 3-character
   contents of the TARGET / FAST / PATROL windows. Values are pre-padded to 3 so the
   alignment is explicit — "S  " sits at the left of the FAST window so PAS|S reads
   as one word across the two windows, where the default right-align would strand it. */
const ST_BLANK = '   ';
const ST_DEG_F = '\u00B0F '; // U+00B0 renders as the top four segments in Segment7; escaped so a re-save can't mangle it
const SELF_TEST_STEPS = [
    { at: 0,    t: '888',   f: '888',    p: '888',   lamps: true },  // lamp test: every segment + indicator
    { at: 1200, t: ST_BLANK, f: ST_BLANK, p: ST_BLANK, lamps: false },
    { at: 1450, t: 'bAt',   f: '139',    p: ST_BLANK },              // battery voltage, 13.9 V
    { at: 2450, t: '107',   f: ST_DEG_F, p: ST_BLANK },              // internal temperature
    { at: 3450, t: ST_BLANK, f: ST_BLANK, p: ST_BLANK },
    { at: 3650, t: ' 10',   f: ST_BLANK, p: ' 10' },                 // speed display check
    { at: 4200, t: ' 35',   f: ST_BLANK, p: ' 35' },
    { at: 4750, t: ' 65',   f: ST_BLANK, p: ' 65' },
    { at: 5300, t: 'PAS',   f: 'S  ',    p: ST_BLANK },              // "PASS"
];
const SELF_TEST_PASS_SOUND_AT = 5500;
const SELF_TEST_END_AT = 6300; // holds the PASS screen until the pass sound (0.57s) finishes

let selfTestTimers = [];

function clearSelfTest() {
    selfTestTimers.forEach(clearTimeout);
    selfTestTimers = [];
}

function runSelfTestSequence(vol) {
    // Restart cleanly: without this a second TEST press interleaves its screens with
    // the run already in progress (easy to hit, since power-on fires one too).
    clearSelfTest();
    clearTimeout(window._tempDisplayTimer);
    tempDisplayActive = true;
    // Also covers TEST pressed mid-patrol: the tone cuts out for the run, not just on power-up.
    selfTestRunning = true;
    stopDopplerTone();

    const tW = speedTarget.querySelector('.digit-display');
    const fW = speedFast.querySelector('.digit-display');
    const pW = speedPatrol.querySelector('.digit-display');

    function setOverlaysAll(on) {
        ['xmit','fast','front','rear','same','lock','fastFrontArrow','fastRearArrow','targetFrontArrow','targetRearArrow']
            .forEach(k => setOverlay(k, on));
    }

    function showStep(step) {
        if (tW) updateDigitDisplay(tW, step.t);
        if (fW) updateDigitDisplay(fW, step.f);
        if (pW) updateDigitDisplay(pW, step.p);
        if (step.lamps !== undefined) setOverlaysAll(step.lamps);
    }

    function after(ms, fn) {
        selfTestTimers.push(setTimeout(fn, ms));
    }

    SELF_TEST_STEPS.forEach(step => {
        if (step.at <= 0) showStep(step); else after(step.at, () => showStep(step));
    });

    after(SELF_TEST_PASS_SOUND_AT, () => playSound(SELF_TEST_PASS_SOUND, vol * SELF_TEST_PASS_GAIN));

    after(SELF_TEST_END_AT, () => {
        tempDisplayActive = false;
        // The next update tick (33-100ms) restarts the tone if a target is actually being read.
        selfTestRunning = false;
    });
}

function setOverlay(id, active) {
    const el = overlays[id];
    if (el) {
        el.classList.toggle('active', !!active);
    }
}

function clampPlateStyle(style) {
    let s = Number(style);
    if (Number.isNaN(s)) s = 0;
    if (s < 0) s = 0;
    if (s > 5) s = s % 6;
    return s;
}

function getPlateTextColor(style) {
    // Explicit mapping per plate style.
    if (style === 1) return '#ffd34a'; // Yellow
    if (style === 2) return '#d3b247'; // Slightly darker yellow
    return '#111111'; // Plate styles 0,3,4,5 use black
}

function setPlateTextFit(el, textValue) {
    if (!el) return;
    let inner = el.querySelector('.plate-text-inner');
    if (!inner) {
        inner = document.createElement('span');
        inner.className = 'plate-text-inner';
        el.textContent = '';
        el.appendChild(inner);
    }

    const text = (textValue || '--------').toString().slice(0, 8).toUpperCase();
    inner.textContent = text;
    inner.style.lineHeight = '1';
    inner.style.maxWidth = 'none';
    el.style.fontSize = '';

    let layoutAttempts = 0;

    const fit = () => {
        layoutAttempts += 1;
        const cw = el.clientWidth;
        const ch = el.clientHeight;
        if ((cw < 12 || ch < 12) && layoutAttempts < 8) {
            requestAnimationFrame(fit);
            return;
        }
        if (cw < 12 || ch < 12) return;

        const padX = 4;
        const padY = 2;
        const maxW = cw - padX * 2;
        const maxH = ch - padY * 2;
        const minSize = 11;
        /* Cap keeps Impact-style mushing away; 34px max fills more of the plate art */
        const maxSize = 34;
        const len = Math.max(1, text.trim().length);
        /* Bold sans + tracking — slightly tighter width estimate allows a larger chosen size */
        const maxByWidth = Math.floor(maxW / (len * 0.68));
        const maxHGlyph = Math.max(12, Math.floor(maxH * 0.88));
        const rawStart = Math.min(maxSize, maxByWidth, maxHGlyph, Math.floor(maxH * 0.74));
        let size = Math.max(minSize, rawStart);
        for (; size >= minSize; size -= 1) {
            inner.style.fontSize = `${size}px`;
            /* Slightly wider tracking at larger sizes — keeps holes in 6/8/9/0 readable */
            const trackEm = Math.min(0.14, Math.max(0.06, 0.055 + (8 - len) * 0.012));
            inner.style.letterSpacing = `${trackEm}em`;
            const w = inner.offsetWidth;
            const h = inner.offsetHeight;
            if (w <= maxW && h <= maxHGlyph) break;
        }
    };

    fit();
    requestAnimationFrame(fit);
}

function updatePlateReader(data) {
    if (!plateReader) return;

    if (data.plateReaderVisible !== undefined) {
        plateReader.classList.toggle('visible', !!data.plateReaderVisible || plateAdjustMode);
    }

    if (data.frontPlateStyle !== undefined && plateFrontBg) {
        const frontStyle = clampPlateStyle(data.frontPlateStyle);
        plateFrontBg.src = `images/plates/${frontStyle}.png`;
        if (plateFrontText) plateFrontText.style.color = getPlateTextColor(frontStyle);
    }
    if (data.rearPlateStyle !== undefined && plateRearBg) {
        const rearStyle = clampPlateStyle(data.rearPlateStyle);
        plateRearBg.src = `images/plates/${rearStyle}.png`;
        if (plateRearText) plateRearText.style.color = getPlateTextColor(rearStyle);
    }
    if (data.frontPlateText !== undefined && plateFrontText) {
        setPlateTextFit(plateFrontText, data.frontPlateText);
    }
    if (data.rearPlateText !== undefined && plateRearText) {
        setPlateTextFit(plateRearText, data.rearPlateText);
    }
    if (data.frontPlateLocked !== undefined && plateFrontLocked) {
        plateFrontLocked.classList.toggle('active', !!data.frontPlateLocked);
    }
    if (data.rearPlateLocked !== undefined && plateRearLocked) {
        plateRearLocked.classList.toggle('active', !!data.rearPlateLocked);
    }
}

let tempDisplayActive = false;

function updateDisplay(data) {
    if (!data) return;
    if (data.displayed !== undefined && !DUI_MODE) {
        container.classList.toggle('visible', !!data.displayed);
    }
    if (!tempDisplayActive) {
        if (data.patrolSpeed !== undefined) {
            const wrap = speedPatrol.querySelector('.digit-display');
            if (wrap) updateDigitDisplay(wrap, data.patrolSpeed);
        }
        if (data.targetSpeed !== undefined) {
            const wrap = speedTarget.querySelector('.digit-display');
            if (wrap) updateDigitDisplay(wrap, data.targetSpeed);
        }
        if (data.fastValue !== undefined) {
            const wrap = speedFast.querySelector('.digit-display');
            if (wrap) updateDigitDisplay(wrap, data.fastValue);
        }
    }
    if (data.xmit !== undefined) setOverlay('xmit', data.xmit);
    if (data.fast !== undefined) setOverlay('fast', data.fast);
    if (data.front !== undefined) setOverlay('front', data.front);
    if (data.rear !== undefined) setOverlay('rear', data.rear);
    if (data.same !== undefined) setOverlay('same', data.same);
    if (data.lock !== undefined) setOverlay('lock', data.lock);
    if (data.fastFrontArrow !== undefined) setOverlay('fastFrontArrow', data.fastFrontArrow);
    if (data.fastRearArrow !== undefined) setOverlay('fastRearArrow', data.fastRearArrow);
    if (data.targetFrontArrow !== undefined) setOverlay('targetFrontArrow', data.targetFrontArrow);
    if (data.targetRearArrow !== undefined) setOverlay('targetRearArrow', data.targetRearArrow);
    if (data.brightness !== undefined) {
        container.style.opacity = data.brightness;
    }
    if (data.dopplerPitchMin !== undefined) dopplerPitchMin = Number(data.dopplerPitchMin);
    if (data.dopplerPitchMax !== undefined) dopplerPitchMax = Number(data.dopplerPitchMax);
    if (data.dopplerPitchMaxSpeedMph !== undefined && Number(data.dopplerPitchMaxSpeedMph) > 0) {
        dopplerPitchMaxSpeedMph = Number(data.dopplerPitchMaxSpeedMph);
    }
    if (data.dopplerVolMin !== undefined) dopplerVolMin = Number(data.dopplerVolMin);
    if (data.dopplerVolMax !== undefined) dopplerVolMax = Number(data.dopplerVolMax);
    if (data.dopplerVolMaxSpeedMph !== undefined && Number(data.dopplerVolMaxSpeedMph) > 0) {
        dopplerVolMaxSpeedMph = Number(data.dopplerVolMaxSpeedMph);
    }
    if (data.power === false) {
        // Radar powered off — hard-stop all Doppler
        stopDopplerTone();
    } else if (data.dopplerSpeedMph !== undefined || data.dopplerVolume !== undefined) {
        const speed = data.dopplerSpeedMph;
        const vol = data.dopplerVolume ?? 1.0;
        updateDoppler(speed, vol);
    }
    updatePlateReader(data);
}

let isDragging = false;
let isResizing = false;
let dragStartX, dragStartY, startLeft, startTop;
let resizeStartX, resizeStartY, startWidth, startHeight;
let isPlateDragging = false;
let plateDragStartX, plateDragStartY, plateStartLeft, plateStartTop;

function applyPosition(x, y, width, height, scaleVal) {
    if (x !== undefined && y !== undefined) {
        container.style.right = 'auto';
        container.style.bottom = 'auto';
        container.style.left = (typeof x === 'number' && x <= 1) ? `${x * 100}%` : `${x}px`;
        container.style.top = (typeof y === 'number' && y <= 1) ? `${y * 100}%` : `${y}px`;
    }
    if (width !== undefined) container.style.width = `${width}px`;
    if (height !== undefined) container.style.height = `${height}px`;
    if (scaleVal !== undefined) {
        scale = scaleVal;
        container.style.transform = `scale(${scale})`;
    }
}

let scale = 1.0;
let plateScale = 1.0;

/** Required for FiveM to decode NUI POST body into a Lua table reliably. */
const NUI_JSON_HEADERS = { 'Content-Type': 'application/json; charset=UTF-8' };

function savePosition() {
    if (DUI_MODE) return;
    const rect = container.getBoundingClientRect();
    const w = window.innerWidth;
    const h = window.innerHeight;
    /* Position uses on-screen rect (includes transform). Size must be layout box *before* scale —
       rect.width/height include transform and would double-apply scale on init (digits vs art drift). */
    const data = {
        x: rect.left / w,
        y: rect.top / h,
        width: Math.round(container.offsetWidth),
        height: Math.round(container.offsetHeight),
        scale: scale,
    };
    fetch(`https://${GetParentResourceName()}/saveDisplay`, {
        method: 'POST',
        headers: NUI_JSON_HEADERS,
        body: JSON.stringify(data),
    }).catch(() => {});
}

function applyPlatePosition(x, y, width, height, scaleVal) {
    if (!plateReader) return;
    if (x !== undefined && y !== undefined) {
        plateReader.style.left = (typeof x === 'number' && x <= 1) ? `${x * 100}%` : `${x}px`;
        plateReader.style.top = (typeof y === 'number' && y <= 1) ? `${y * 100}%` : `${y}px`;
        plateReader.style.right = 'auto';
        plateReader.style.bottom = 'auto';
    }
    if (width !== undefined) plateReader.style.width = `${width}px`;
    if (height !== undefined) plateReader.style.height = `${height}px`;
    if (scaleVal !== undefined) {
        plateScale = scaleVal;
        plateReader.style.transform = `scale(${plateScale})`;
        plateReader.style.transformOrigin = 'top left';
    }
}

function getPlatePositionData() {
    if (!plateReader) return null;
    const rect = plateReader.getBoundingClientRect();
    const w = window.innerWidth;
    const h = window.innerHeight;
    return {
        x: rect.left / w,
        y: rect.top / h,
        /* offset* = layout box before CSS transform; rect.* includes scale and skews save/load */
        width: Math.round(plateReader.offsetWidth),
        height: Math.round(plateReader.offsetHeight),
        scale: plateScale,
    };
}

function savePlatePosition() {
    if (DUI_MODE) return;
    requestAnimationFrame(() => {
        const data = getPlatePositionData();
        if (!data) return;
        fetch(`https://${GetParentResourceName()}/savePlateDisplay`, {
            method: 'POST',
            headers: NUI_JSON_HEADERS,
            body: JSON.stringify(data),
        }).catch(() => {});
    });
}

let adjustMode = false;
let plateAdjustMode = false;
let remoteOpen = false;
const remoteOverlay = document.getElementById('remote-overlay');
const remoteWrap = document.getElementById('remote-wrap');

let remoteAdjustMode = false;
let remoteScale = 1.0;
let isRemoteDragging = false;
let remoteDragStartX, remoteDragStartY, remoteStartLeft, remoteStartTop;

/* The remote overlay is display:none while closed, so it measures 0x0 and any centring
   done then would pin it to the top-left corner. Centring is therefore deferred until
   the remote is actually on screen. */
let remoteNeedsCenter = false;

/** True only when the remote is laid out and measurable. */
function remoteIsMeasurable() {
    return !!remoteWrap && remoteWrap.getBoundingClientRect().width > 0;
}

/** Centre from the measured flex-centred box, so it lands centred at any resolution
 *  rather than at a fraction tuned for one aspect ratio. */
function centerRemote() {
    if (!remoteWrap) return;
    // Drop to the un-positioned state so the overlay's flex centring supplies the box.
    remoteWrap.classList.remove('positioned');
    remoteWrap.style.left = '';
    remoteWrap.style.top = '';
    remoteWrap.style.transform = '';

    const rect = remoteWrap.getBoundingClientRect();
    if (rect.width === 0) {
        // Hidden: leave it flex-centred (a correct fallback) and finish when it opens.
        remoteNeedsCenter = true;
        return;
    }

    remoteWrap.classList.add('positioned');
    // .positioned switches transform-origin to top left, so offset by half the growth
    // to keep a scaled remote visually centred.
    remoteWrap.style.left = `${rect.left - (remoteScale - 1) * rect.width / 2}px`;
    remoteWrap.style.top = `${rect.top - (remoteScale - 1) * rect.height / 2}px`;
    remoteWrap.style.transform = `scale(${remoteScale})`;
    remoteNeedsCenter = false;
}

function applyRemotePosition(x, y, width, scaleVal) {
    if (!remoteWrap) return;
    if (width !== undefined) remoteWrap.style.width = `${width}px`;
    if (scaleVal !== undefined) remoteScale = scaleVal;

    if (typeof x === 'number' && typeof y === 'number') {
        remoteNeedsCenter = false;
        remoteWrap.classList.add('positioned');
        remoteWrap.style.left = x <= 1 ? `${x * 100}%` : `${x}px`;
        remoteWrap.style.top = y <= 1 ? `${y * 100}%` : `${y}px`;
        remoteWrap.style.right = 'auto';
        remoteWrap.style.bottom = 'auto';
        remoteWrap.style.transform = `scale(${remoteScale})`;
    } else {
        centerRemote();
    }
}

function saveRemotePosition() {
    // Never persist a measurement taken while hidden — it would save 0,0.
    if (DUI_MODE || !remoteIsMeasurable()) return;
    const rect = remoteWrap.getBoundingClientRect();
    const data = {
        x: rect.left / window.innerWidth,
        y: rect.top / window.innerHeight,
        /* offsetWidth = layout box before transform; rect.width includes scale and would
           compound it on every reload. Height follows the image aspect, so it isn't stored. */
        width: Math.round(remoteWrap.offsetWidth),
        scale: remoteScale,
    };
    fetch(`https://${GetParentResourceName()}/saveRemoteDisplay`, {
        method: 'POST',
        headers: NUI_JSON_HEADERS,
        body: JSON.stringify(data),
    }).catch(() => {});
}

/** save:false is used by the reset path, which must not immediately re-write the KVP it just deleted. */
function setRemoteAdjustMode(active, { save = true } = {}) {
    remoteAdjustMode = !!active;
    if (remoteWrap) remoteWrap.classList.toggle('adjusting', remoteAdjustMode);
    if (!remoteAdjustMode) {
        isRemoteDragging = false;
        if (save) saveRemotePosition();
    }
}

/** Radar / plate move+scale: explicit /seeker_move OR while remote overlay is open */
function canLayoutDragRadar() {
    return adjustMode || remoteOpen;
}
function canLayoutDragPlate() {
    return plateAdjustMode || remoteOpen;
}

container.addEventListener('mousedown', (e) => {
    if (!canLayoutDragRadar()) return;
    if (e.target === resizeHandle) return;
    if (e.target.closest && e.target.closest('#btn-power-radar')) return;
    isDragging = true;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    const rect = container.getBoundingClientRect();
    startLeft = rect.left;
    startTop = rect.top;
});

resizeHandle.addEventListener('mousedown', (e) => {
    if (!canLayoutDragRadar()) return;
    e.preventDefault();
    isResizing = true;
    resizeStartX = e.clientX;
    resizeStartY = e.clientY;
    startWidth = container.offsetWidth;
    startHeight = container.offsetHeight;
});

document.addEventListener('mousemove', (e) => {
    if (isDragging) {
        const dx = e.clientX - dragStartX;
        const dy = e.clientY - dragStartY;
        container.style.left = `${startLeft + dx}px`;
        container.style.top = `${startTop + dy}px`;
        container.style.right = 'auto';
        container.style.bottom = 'auto';
    }
    if (isResizing) {
        const dx = e.clientX - resizeStartX;
        const dy = e.clientY - resizeStartY;
        const newWidth = Math.max(200, startWidth + dx);
        const newHeight = Math.max(100, startHeight + dy);
        container.style.width = `${newWidth}px`;
        container.style.height = `${newHeight}px`;
    }
    if (isPlateDragging && plateReader) {
        const dx = e.clientX - plateDragStartX;
        const dy = e.clientY - plateDragStartY;
        plateReader.style.left = `${plateStartLeft + dx}px`;
        plateReader.style.top = `${plateStartTop + dy}px`;
        plateReader.style.right = 'auto';
        plateReader.style.bottom = 'auto';
    }
});

document.addEventListener('mouseup', () => {
    if (isDragging || isResizing) {
        savePosition();
    }
    if (isPlateDragging) {
        savePlatePosition();
    }
    isDragging = false;
    isResizing = false;
    isPlateDragging = false;
});

container.addEventListener('wheel', (e) => {
    if (!canLayoutDragRadar()) return;
    e.preventDefault();
    const delta = e.deltaY > 0 ? -0.05 : 0.05;
    scale = Math.max(0.5, Math.min(2, scale + delta));
    container.style.transform = `scale(${scale})`;
    savePosition();
}, { passive: false });

function setAdjustMode(active) {
    adjustMode = active;
    if (active) plateAdjustMode = false;
    const hint = document.getElementById('adjust-hint');
    if (hint) hint.style.display = active ? 'block' : 'none';
    if (container) container.classList.toggle('nui-adjusting', !!active);
}

function setPlateAdjustMode(active) {
    plateAdjustMode = active;
    if (active) adjustMode = false;
    const hint = document.getElementById('adjust-hint');
    if (hint) hint.style.display = active ? 'block' : 'none';
    if (plateReader) {
        plateReader.classList.toggle('adjusting', !!active);
        if (active) {
            plateReader.classList.add('visible');
        }
    }
}

if (plateReader) {
    plateReader.addEventListener('mousedown', (e) => {
        if (!canLayoutDragPlate()) return;
        e.preventDefault();
        isPlateDragging = true;
        plateDragStartX = e.clientX;
        plateDragStartY = e.clientY;
        const rect = plateReader.getBoundingClientRect();
        plateStartLeft = rect.left;
        plateStartTop = rect.top;
    });

    plateReader.addEventListener('wheel', (e) => {
        if (!canLayoutDragPlate()) return;
        e.preventDefault();
        const delta = e.deltaY > 0 ? -0.05 : 0.05;
        plateScale = Math.max(0.5, Math.min(2, plateScale + delta));
        plateReader.style.transform = `scale(${plateScale})`;
        plateReader.style.transformOrigin = 'top left';
        savePlatePosition();
    }, { passive: false });
}

if (remoteWrap) {
    /* Enter on a double-click of the remote body — deliberately not a button, so ordinary
       presses are untouched. Exit on a double-click anywhere, since .adjusting makes the
       buttons inert and the event lands on the wrap either way. */
    remoteWrap.addEventListener('dblclick', (e) => {
        if (!remoteOpen) return;
        if (!remoteAdjustMode && e.target.closest && e.target.closest('.remote-btn')) return;
        e.preventDefault();
        e.stopPropagation();
        setRemoteAdjustMode(!remoteAdjustMode);
    });

    remoteWrap.addEventListener('mousedown', (e) => {
        if (!remoteAdjustMode) return;
        e.preventDefault();
        e.stopPropagation();
        isRemoteDragging = true;
        remoteDragStartX = e.clientX;
        remoteDragStartY = e.clientY;
        const rect = remoteWrap.getBoundingClientRect();
        remoteStartLeft = rect.left;
        remoteStartTop = rect.top;
    });

    remoteWrap.addEventListener('wheel', (e) => {
        if (!remoteAdjustMode) return;
        e.preventDefault();
        e.stopPropagation();
        const delta = e.deltaY > 0 ? -0.05 : 0.05;
        remoteScale = Math.max(0.5, Math.min(2, remoteScale + delta));
        remoteWrap.style.transform = `scale(${remoteScale})`;
        saveRemotePosition();
    }, { passive: false });
}

document.addEventListener('mousemove', (e) => {
    if (!isRemoteDragging || !remoteWrap) return;
    remoteWrap.style.left = `${remoteStartLeft + (e.clientX - remoteDragStartX)}px`;
    remoteWrap.style.top = `${remoteStartTop + (e.clientY - remoteDragStartY)}px`;
    remoteWrap.style.right = 'auto';
    remoteWrap.style.bottom = 'auto';
});

document.addEventListener('mouseup', () => {
    if (!isRemoteDragging) return;
    isRemoteDragging = false;
    saveRemotePosition();
});

// ===== Remote Control =====
let debugMode = false;
let debugDragging = null;
let debugDragStartX = 0, debugDragStartY = 0;
let debugBtnStartLeft = 0, debugBtnStartTop = 0;

function showRemote(show, debug) {
    remoteOpen = show;
    // Closing the remote must not leave adjust mode armed for the next time it opens.
    if (!show && remoteAdjustMode) setRemoteAdjustMode(false);
    debugMode = !!debug;
    if (remoteOverlay) remoteOverlay.classList.toggle('active', show);
    // Now that it is laid out, finish any centring that was deferred while hidden.
    if (show && remoteNeedsCenter) centerRemote();
    const wrap = document.querySelector('.remote-wrap');
    if (wrap && debug !== undefined) {
        wrap.classList.toggle('debug', !!debug);
    }
    const exportBtn = document.getElementById('debug-export');
    if (exportBtn) exportBtn.style.display = debug ? 'block' : 'none';
    /* While remote is open, drag/scale radar & plate directly (no extra mode buttons). */
    if (container) container.classList.toggle('remote-layout-drag', !!show);
    if (plateReader) plateReader.classList.toggle('remote-layout-drag', !!show);
}

let debugSelected = null;

document.querySelectorAll('.remote-btn').forEach(btn => {
    btn.addEventListener('mousedown', (e) => {
        if (!debugMode) return;
        e.preventDefault();
        e.stopPropagation();
        // Right-click selects for resize info
        debugSelected = btn;
        document.querySelectorAll('.remote-btn').forEach(b => b.classList.remove('debug-selected'));
        btn.classList.add('debug-selected');
        debugDragging = btn;
        debugDragStartX = e.clientX;
        debugDragStartY = e.clientY;
        const wrap = document.querySelector('.remote-wrap');
        const wrapRect = wrap.getBoundingClientRect();
        debugBtnStartLeft = btn.getBoundingClientRect().left - wrapRect.left;
        debugBtnStartTop = btn.getBoundingClientRect().top - wrapRect.top;
    });

    // Scroll on button: shift=width, ctrl=height, plain=both
    btn.addEventListener('wheel', (e) => {
        if (!debugMode) return;
        e.preventDefault();
        e.stopPropagation();
        const wrap = document.querySelector('.remote-wrap');
        const wrapRect = wrap.getBoundingClientRect();
        const step = e.deltaY > 0 ? -1 : 1;
        const rect = btn.getBoundingClientRect();

        if (e.shiftKey || (!e.shiftKey && !e.ctrlKey)) {
            const curW = rect.width / wrapRect.width * 100;
            const newW = Math.max(2, curW + step);
            btn.style.width = newW + '%';
        }
        if (e.ctrlKey || (!e.shiftKey && !e.ctrlKey)) {
            const curH = rect.height / wrapRect.height * 100;
            const newH = Math.max(2, curH + step);
            btn.style.height = newH + '%';
        }
    }, { passive: false });

    btn.addEventListener('click', (e) => {
        if (debugMode || remoteAdjustMode) { e.preventDefault(); e.stopPropagation(); return; }
        const action = btn.dataset.action;
        if (!action) return;
        postRemoteAction(action);
    });
});

document.addEventListener('mousemove', (e) => {
    if (!debugDragging) return;
    const wrap = document.querySelector('.remote-wrap');
    const wrapRect = wrap.getBoundingClientRect();
    const dx = e.clientX - debugDragStartX;
    const dy = e.clientY - debugDragStartY;
    const newLeft = ((debugBtnStartLeft + dx) / wrapRect.width * 100);
    const newTop = ((debugBtnStartTop + dy) / wrapRect.height * 100);
    debugDragging.style.left = newLeft + '%';
    debugDragging.style.top = newTop + '%';
});

document.addEventListener('mouseup', () => {
    if (debugDragging) {
        const id = debugDragging.id;
        const left = parseFloat(debugDragging.style.left).toFixed(1);
        const top = parseFloat(debugDragging.style.top).toFixed(1);
        console.log(`#${id} { top: ${top}%; left: ${left}%; }`);
        debugDragging = null;
    }
});

function exportButtonCSS() {
    const wrap = document.querySelector('.remote-wrap');
    const wrapRect = wrap.getBoundingClientRect();
    let css = '';
    document.querySelectorAll('.remote-btn').forEach(btn => {
        const rect = btn.getBoundingClientRect();
        const left = ((rect.left - wrapRect.left) / wrapRect.width * 100).toFixed(1);
        const top = ((rect.top - wrapRect.top) / wrapRect.height * 100).toFixed(1);
        const w = (rect.width / wrapRect.width * 100).toFixed(1);
        const h = (rect.height / wrapRect.height * 100).toFixed(1);
        const padId = ('#' + btn.id).padEnd(20);
        css += `${padId}{ top: ${top}%; left: ${left}%; width: ${w}%; height: ${h}%; }\n`;
    });
    const output = document.getElementById('debug-output');
    if (output) {
        output.value = css;
        output.style.display = 'block';
        output.select();
    }
    console.log(css);
}

/* With input passthrough on, the game may hand ESC to us as a forwarded message while the
   browser also sees the keydown. Collapse the pair so one press takes one step down the
   chain instead of two. */
let lastEscapeAt = 0;

function handleEscape() {
    const now = Date.now();
    if (now - lastEscapeAt < 200) return;
    lastEscapeAt = now;

    // Exit layout adjust first so remote overlay can stay open.
    if (adjustMode) {
        setAdjustMode(false);
        fetch(`https://${GetParentResourceName()}/exitAdjustMode`, { method: 'POST', body: '{}' }).catch(() => {});
    } else if (plateAdjustMode) {
        const data = getPlatePositionData();
        setPlateAdjustMode(false);
        fetch(`https://${GetParentResourceName()}/exitPlateAdjustMode`, {
            method: 'POST',
            headers: NUI_JSON_HEADERS,
            body: JSON.stringify(data || {}),
        }).catch(() => {});
    } else if (remoteAdjustMode) {
        // Finish repositioning first so ESC doesn't also close the remote.
        setRemoteAdjustMode(false);
    } else if (remoteOpen) {
        showRemote(false);
        fetch(`https://${GetParentResourceName()}/closeRemote`, { method: 'POST', body: '{}' }).catch(() => {});
    }
}

document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') handleEscape();
});

/* The only messages that change what is drawn on the radar face. client/dui.lua already
   mirrors just these to the prop, so this is a second line of defence — it also keeps a
   stray postMessage from putting the prop screen into layout-adjust or opening a remote
   on a surface that has no cursor to close it with. */
const DUI_ALLOWED_TYPES = new Set(['update', 'selfTest', 'tempDisplay']);

window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || !data._type) return;
    if (DUI_MODE && !DUI_ALLOWED_TYPES.has(data._type)) return;

    switch (data._type) {
        case 'init':
            if (data.display) {
                const d = data.display;
                scale = d.scale || 1;
                applyPosition(d.x, d.y, d.width, d.height, scale);
            }
            if (data.plateDisplay) {
                const p = data.plateDisplay;
                plateScale = p.scale || 1;
                applyPlatePosition(p.x, p.y, p.width, p.height, plateScale);
            }
            if (data.remoteDisplay) {
                const r = data.remoteDisplay;
                applyRemotePosition(r.x, r.y, r.width, r.scale || 1);
            }
            break;
        case 'update':
            updateDisplay(data);
            break;
        case 'resetDisplay':
            if (data.display) {
                const d = data.display;
                scale = d.scale || 1;
                applyPosition(d.x, d.y, d.width, d.height, scale);
            }
            break;
        case 'resetRemoteDisplay': {
            const r = data.remoteDisplay || {};
            if (remoteAdjustMode) setRemoteAdjustMode(false, { save: false });
            applyRemotePosition(r.x, r.y, r.width, r.scale || 1);
            break;
        }
        case 'adjustMode':
            setAdjustMode(true);
            break;
        case 'plateAdjustMode':
            setPlateAdjustMode(true);
            break;
        case 'audio':
            if (data.name) playSound(data.name, data.vol ?? 1.0);
            break;
        case 'multiBeep': {
            const count = data.count || 1;
            const vol = data.vol ?? 1.0;
            let i = 0;
            const interval = setInterval(() => {
                playSound('Beep', vol);
                i++;
                if (i >= count) clearInterval(interval);
            }, 180);
            break;
        }
        case 'selfTest': {
            runSelfTestSequence(data.vol ?? 1.0);
            break;
        }
        case 'voiceEnunciator': {
            const voiceNames = [];
            if (data.antenna) voiceNames.push(data.antenna === 'front' ? 'Front' : 'Rear');
            if (data.direction) voiceNames.push(data.direction === 'closing' ? 'Closing' : 'Away');
            if (voiceNames.length > 0) playVoiceSequence(voiceNames, data.vol ?? 1.0);
            break;
        }
        case 'tempDisplay': {
            const dur = data.duration || 3000;
            tempDisplayActive = true;
            if (data.target !== undefined) {
                const wrap = speedTarget.querySelector('.digit-display');
                if (wrap) updateDigitDisplay(wrap, data.target);
            }
            if (data.fast !== undefined) {
                const wrap = speedFast.querySelector('.digit-display');
                if (wrap) updateDigitDisplay(wrap, data.fast);
            }
            if (data.patrol !== undefined) {
                const wrap = speedPatrol.querySelector('.digit-display');
                if (wrap) updateDigitDisplay(wrap, data.patrol);
            }
            clearTimeout(window._tempDisplayTimer);
            window._tempDisplayTimer = setTimeout(() => {
                tempDisplayActive = false;
            }, dur);
            break;
        }
        case 'showRemote':
            showRemote(true, data.debug);
            break;
        case 'hideRemote':
            showRemote(false);
            break;
        case 'escape':
            // Forwarded from Lua because the game's ESC control is disabled while focused.
            handleEscape();
            break;
    }
});
