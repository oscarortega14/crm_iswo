/**
 * Sonido de "mensaje nuevo" sintetizado con Web Audio — sin archivo de audio
 * externo que mantener/alojar. Dos tonos cortos ascendentes, similar al
 * "ding" de apps de chat.
 *
 * Los navegadores bloquean reproducir audio (incluso sintetizado) hasta que
 * hubo una interacción real del usuario en la página — un poll en background
 * no cuenta. `unlockAudioOnFirstInteraction()` engancha el primer click/tecla
 * para "despertar" el AudioContext, así el sonido dispara de verdad cuando
 * después llega un mensaje nuevo por poll.
 */
const SOUND_STORAGE_KEY = 'crm-iswo-sound-enabled'

let sharedContext: AudioContext | null = null
let unlockListenersAttached = false

function getContext(): AudioContext | null {
  if (typeof window === 'undefined') return null
  const Ctor = window.AudioContext || (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
  if (!Ctor) return null
  if (!sharedContext) sharedContext = new Ctor()
  return sharedContext
}

function playTone(ctx: AudioContext, frequency: number, startAt: number, duration: number) {
  const oscillator = ctx.createOscillator()
  const gain = ctx.createGain()
  oscillator.type = 'sine'
  oscillator.frequency.value = frequency
  gain.gain.setValueAtTime(0, startAt)
  gain.gain.linearRampToValueAtTime(0.15, startAt + 0.01)
  gain.gain.exponentialRampToValueAtTime(0.001, startAt + duration)
  oscillator.connect(gain)
  gain.connect(ctx.destination)
  oscillator.start(startAt)
  oscillator.stop(startAt + duration)
}

/** Lee la preferencia de sonido (default: activado si nunca se tocó el switch). */
export function isSoundEnabled(): boolean {
  try {
    const stored = localStorage.getItem(SOUND_STORAGE_KEY)
    return stored === null ? true : stored === 'true'
  } catch {
    return true
  }
}

export function setSoundEnabled(enabled: boolean) {
  try {
    localStorage.setItem(SOUND_STORAGE_KEY, String(enabled))
  } catch {
    // localStorage no disponible (modo privado, etc.) — se ignora.
  }
}

/** Eventos que el navegador acepta como "activación del usuario" para
 * desbloquear audio. `pointerdown` solo cuenta con mouse: en pantallas
 * táctiles el gesto válido es `touchend`/`click` — escuchar solo
 * `pointerdown` dejaba el sonido bloqueado para siempre en mobile. */
const UNLOCK_EVENTS = ['pointerdown', 'touchend', 'click', 'keydown'] as const

/** Enganchar una sola vez, apenas monta la página — despierta el AudioContext
 * con una interacción real para que los sonidos disparados por poll (sin
 * interacción directa) no queden bloqueados por la política de autoplay.
 * Los listeners se quitan recién cuando el contexto quedó `running`: si el
 * primer intento no cuenta como gesto válido, se reintenta en el siguiente. */
export function unlockAudioOnFirstInteraction() {
  if (unlockListenersAttached || typeof window === 'undefined') return
  unlockListenersAttached = true

  const detach = () => {
    for (const ev of UNLOCK_EVENTS) window.removeEventListener(ev, unlock, true)
  }

  function unlock() {
    const ctx = getContext()
    if (!ctx) return detach()
    if (ctx.state === 'running') return detach()
    void ctx.resume().then(() => {
      if (ctx.state === 'running') detach()
    }).catch(() => {
      // Gesto no válido para el navegador — se reintenta en el próximo.
    })
  }

  for (const ev of UNLOCK_EVENTS) window.addEventListener(ev, unlock, true)
}

export function playNewMessageSound() {
  if (!isSoundEnabled()) return
  try {
    const ctx = getContext()
    if (!ctx) return
    if (ctx.state === 'suspended') void ctx.resume()
    const now = ctx.currentTime
    playTone(ctx, 740, now, 0.12)
    playTone(ctx, 988, now + 0.09, 0.16)
  } catch {
    // Autoplay bloqueado u otro fallo de audio — no es crítico, se ignora.
  }
}

/**
 * ¿Llegó un mensaje entrante nuevo entre dos consultas de stats?
 * `previous === undefined` = primera carga (nunca suena al abrir la app).
 */
export function isNewInboundMessage(
  previous: number | null | undefined,
  latest: number | null | undefined,
): boolean {
  if (previous === undefined || latest == null) return false
  return previous == null || latest > previous
}
