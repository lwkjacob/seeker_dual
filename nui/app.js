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

// Doppler: smooth incremental pitch based on target speed (mph) - interpolates between thresholds
let dopplerCtx = null;
let dopplerBuffer = null;
let dopplerGain = null;
let dopplerSource = null;
let currentDopplerSpeed = null;

// Pitch/volume breakpoints (mph): interpolates smoothly between each
// 0-20: 1.0, 20-45: 1.0→1.25, 45-75: 1.25→1.5, 75-110: 1.5→2.0, 110-150: 2.0→2.5, 150+: 2.5
let DOPPLER_PITCH_BREAKPOINTS = [0, 20, 45, 75, 110, 150];
const DOPPLER_PITCH_VALUES = [1.0, 1.0, 1.25, 1.5, 2.0, 2.5];
let DOPPLER_VOL_BREAKPOINTS = [0, 20, 45, 75, 110, 150];
const DOPPLER_VOL_VALUES = [0.2, 0.2, 0.4, 0.6, 0.85, 1.0];

function lerp(speed, breaks, values) {
    if (speed <= breaks[0]) return values[0];
    for (let i = 1; i < breaks.length; i++) {
        if (speed <= breaks[i]) {
            const t = (speed - breaks[i - 1]) / (breaks[i] - breaks[i - 1]);
            return values[i - 1] + t * (values[i] - values[i - 1]);
        }
    }
    return values[values.length - 1];
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
    const rate = lerp(speedMph, DOPPLER_PITCH_BREAKPOINTS, DOPPLER_PITCH_VALUES);
    const volMult = lerp(speedMph, DOPPLER_VOL_BREAKPOINTS, DOPPLER_VOL_VALUES);
    dopplerGain.gain.setValueAtTime(masterVolume * volMult, dopplerCtx.currentTime);

    const src = dopplerCtx.createBufferSource();
    src.buffer = dopplerBuffer;
    src.loop = true;
    src.playbackRate.setValueAtTime(rate, dopplerCtx.currentTime);
    src.connect(dopplerGain);
    src.start(0);
    dopplerSource = src;
}

let squelchOverrideActive = false;
const SQUELCH_BASELINE_RATE = 0.3;
const SQUELCH_BASELINE_VOL = 0.08;

function updateDoppler(speedMph, masterVolume = 1.0) {
    const hasTarget = speedMph !== null && speedMph !== undefined && speedMph >= 0;

    if (!dopplerCtx || !dopplerBuffer) return;
    if (dopplerCtx.state === 'suspended') dopplerCtx.resume();

    if (hasTarget) {
        const rate = lerp(speedMph, DOPPLER_PITCH_BREAKPOINTS, DOPPLER_PITCH_VALUES);
        const volMult = lerp(speedMph, DOPPLER_VOL_BREAKPOINTS, DOPPLER_VOL_VALUES);

        if (currentDopplerSpeed === null) {
            playDopplerStart(speedMph, masterVolume);
        }
        dopplerSource.playbackRate.setValueAtTime(rate, dopplerCtx.currentTime);
        dopplerGain.gain.setValueAtTime(masterVolume * volMult, dopplerCtx.currentTime);
        currentDopplerSpeed = speedMph;
    } else if (squelchOverrideActive) {
        if (currentDopplerSpeed === null) {
            playDopplerStart(0, masterVolume);
        }
        dopplerSource.playbackRate.setValueAtTime(SQUELCH_BASELINE_RATE, dopplerCtx.currentTime);
        dopplerGain.gain.setValueAtTime(masterVolume * SQUELCH_BASELINE_VOL, dopplerCtx.currentTime);
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
    if (data.dopplerThresholds && Array.isArray(data.dopplerThresholds) && data.dopplerThresholds.length >= 4) {
        const t = data.dopplerThresholds;
        DOPPLER_PITCH_BREAKPOINTS = [0, t[0], t[1], t[2], t[3], (t[3] || 110) + 40];
        DOPPLER_VOL_BREAKPOINTS = [0, t[0], t[1], t[2], t[3], (t[3] || 110) + 40];
    }
    if (data.squelchOverride !== undefined) {
        squelchOverrideActive = !!data.squelchOverride;
    }
    if (data.dopplerSpeedMph !== undefined || data.dopplerVolume !== undefined) {
        const speed = data.dopplerSpeedMph;
        const vol = data.dopplerVolume ?? 1.0;
        updateDoppler(speed, vol);
    }
}

let isDragging = false;
let isResizing = false;
let dragStartX, dragStartY, startLeft, startTop;
let resizeStartX, resizeStartY, startWidth, startHeight;

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

function savePosition() {
    const rect = container.getBoundingClientRect();
    const w = window.innerWidth;
    const h = window.innerHeight;
    const data = {
        x: rect.left / w,
        y: rect.top / h,
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        scale: scale,
    };
    fetch(`https://${GetParentResourceName()}/saveDisplay`, {
        method: 'POST',
        body: JSON.stringify(data),
    }).catch(() => {});
}

container.addEventListener('mousedown', (e) => {
    if (e.target === resizeHandle) return;
    isDragging = true;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    const rect = container.getBoundingClientRect();
    startLeft = rect.left;
    startTop = rect.top;
});

resizeHandle.addEventListener('mousedown', (e) => {
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
});

document.addEventListener('mouseup', () => {
    if (isDragging || isResizing) {
        savePosition();
    }
    isDragging = false;
    isResizing = false;
});

container.addEventListener('wheel', (e) => {
    e.preventDefault();
    const delta = e.deltaY > 0 ? -0.05 : 0.05;
    scale = Math.max(0.5, Math.min(2, scale + delta));
    container.style.transform = `scale(${scale})`;
    savePosition();
}, { passive: false });

let adjustMode = false;

function setAdjustMode(active) {
    adjustMode = active;
    const hint = document.getElementById('adjust-hint');
    if (hint) hint.style.display = active ? 'block' : 'none';
}

// ===== Remote Control =====
const remoteOverlay = document.getElementById('remote-overlay');
let remoteOpen = false;

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
        fetch(`https://${GetParentResourceName()}/remoteBtn`, {
            method: 'POST',
            body: JSON.stringify({ action }),
        }).catch(() => {});
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
        if (remoteOpen) {
            showRemote(false);
            fetch(`https://${GetParentResourceName()}/closeRemote`, { method: 'POST', body: '{}' }).catch(() => {});
        }
        if (adjustMode) {
            setAdjustMode(false);
            fetch(`https://${GetParentResourceName()}/exitAdjustMode`, { method: 'POST', body: '{}' }).catch(() => {});
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
