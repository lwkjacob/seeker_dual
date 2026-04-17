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
    lockFrontArrow: document.getElementById('overlay-lock-front'),
    lockRearArrow: document.getElementById('overlay-lock-rear'),
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

const sounds = {};
const SOUND_NAMES = ['XmitOn', 'XmitOff', 'Beep', 'Away', 'Closing', 'Front', 'Rear'];

function loadSounds() {
    SOUND_NAMES.forEach(name => {
        const audio = new Audio(`sounds/${name}.wav`);
        audio.volume = 1.0;
        sounds[name] = audio;
    });
}
loadSounds();

function postRemoteAction(action) {
    if (!action) return;
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
fetch(`https://${GetParentResourceName()}/nuiReady`, {
    method: 'POST',
    body: '{}',
}).catch(() => {});

let voiceQueue = [];
let voicePlaying = false;

function playVoiceSequence(names, vol = 1.0) {
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
/** Exponential smoothing time constant (seconds) for pitch/volume — tuned for ~33ms radar ticks so pitch glides instead of stair-stepping */
const DOPPLER_PARAM_SMOOTH_S = 0.04;

let dopplerCtx = null;
let dopplerBuffer = null;
let dopplerGain = null;
let dopplerSource = null;
let currentDopplerSpeed = null;

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

async function loadDopplerSound() {
    try {
        dopplerCtx = new (window.AudioContext || window.webkitAudioContext)();
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

let squelchOverrideActive = false;
const SQUELCH_BASELINE_RATE = 0.3 * DOPPLER_PITCH_SCALE;
const SQUELCH_BASELINE_VOL = 0.08;

function updateDoppler(speedMph, masterVolume = 1.0) {
    const hasTarget = speedMph !== null && speedMph !== undefined && speedMph >= 0;

    if (!dopplerCtx || !dopplerBuffer) return;
    if (dopplerCtx.state === 'suspended') dopplerCtx.resume();

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
    } else if (squelchOverrideActive) {
        if (currentDopplerSpeed === null) {
            playDopplerStart(0, masterVolume);
        }
        if (dopplerSource) {
            const nowSq = dopplerCtx.currentTime;
            dopplerSource.playbackRate.setTargetAtTime(SQUELCH_BASELINE_RATE, nowSq, DOPPLER_PARAM_SMOOTH_S);
            dopplerGain.gain.setTargetAtTime(masterVolume * SQUELCH_BASELINE_VOL * DOPPLER_GAIN_SCALE, nowSq, DOPPLER_PARAM_SMOOTH_S);
        }
        currentDopplerSpeed = -1;
    } else {
        if (dopplerSource) {
            dopplerSource.stop();
            dopplerSource.disconnect();
            dopplerSource = null;
        }
        currentDopplerSpeed = null;
    }
}

function playSound(name, vol = 1.0) {
    if (sounds[name]) {
        sounds[name].volume = vol;
        sounds[name].currentTime = 0;
        sounds[name].play().catch(() => {});
    }
}

function runSelfTestSequence(vol) {
    tempDisplayActive = true;
    clearTimeout(window._selfTestTimer);
    clearTimeout(window._tempDisplayTimer);

    const tW = speedTarget.querySelector('.digit-display');
    const fW = speedFast.querySelector('.digit-display');
    const pW = speedPatrol.querySelector('.digit-display');

    function setAll(t, f, p) {
        if (tW) updateDigitDisplay(tW, t);
        if (fW) updateDigitDisplay(fW, f);
        if (pW) updateDigitDisplay(pW, p);
    }

    function setOverlaysAll(on) {
        ['xmit','fast','front','rear','same','lock','lockFrontArrow','lockRearArrow','targetFrontArrow','targetRearArrow']
            .forEach(k => setOverlay(k, on));
    }

    // Phase 1: All segments lit (888 888 888) + all indicators on
    setAll('888', '888', '888');
    setOverlaysAll(true);

    setTimeout(() => {
        // Phase 2: Blank briefly
        setAll('   ', '   ', '   ');
        setOverlaysAll(false);
    }, 1200);

    setTimeout(() => {
        // Phase 3: Test speed 10 in target window
        setAll(' 10', '   ', '   ');
    }, 1500);

    setTimeout(() => {
        // Phase 4: Test speed 35 in fast window
        setAll('   ', ' 35', '   ');
    }, 2100);

    setTimeout(() => {
        // Phase 5: Test speed 65 in patrol window
        setAll('   ', '   ', ' 65');
    }, 2700);

    setTimeout(() => {
        // Phase 6: PASS on all windows
        setAll('PAS', 'PAS', 'PAS');
    }, 3300);

    setTimeout(() => {
        // Phase 7: 4-beep happy tone
        let beepCount = 0;
        const beepInterval = setInterval(() => {
            playSound('Beep', vol);
            beepCount++;
            if (beepCount >= 4) clearInterval(beepInterval);
        }, 150);
    }, 3800);

    setTimeout(() => {
        // Phase 8: Clear and resume normal display
        tempDisplayActive = false;
    }, 4500);
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
    if (data.displayed !== undefined) {
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
    if (data.lockFrontArrow !== undefined) setOverlay('lockFrontArrow', data.lockFrontArrow);
    if (data.lockRearArrow !== undefined) setOverlay('lockRearArrow', data.lockRearArrow);
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
    if (data.squelchOverride !== undefined) {
        squelchOverrideActive = !!data.squelchOverride;
    }
    if (data.dopplerSpeedMph !== undefined || data.dopplerVolume !== undefined) {
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

// ===== Remote Control =====
let debugMode = false;
let debugDragging = null;
let debugDragStartX = 0, debugDragStartY = 0;
let debugBtnStartLeft = 0, debugBtnStartTop = 0;

function showRemote(show, debug) {
    remoteOpen = show;
    debugMode = !!debug;
    if (remoteOverlay) remoteOverlay.classList.toggle('active', show);
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
        if (debugMode) { e.preventDefault(); e.stopPropagation(); return; }
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

document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
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
        } else if (remoteOpen) {
            showRemote(false);
            fetch(`https://${GetParentResourceName()}/closeRemote`, { method: 'POST', body: '{}' }).catch(() => {});
        }
    }
});

window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || !data._type) return;

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
    }
});
