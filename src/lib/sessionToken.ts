/** Matches the Postgres `digest(secret || window::text, 'sha256')` token used by live QR codes. */
export async function computeSessionToken(secret: string, window: number): Promise<string> {
  const msgBuffer = new TextEncoder().encode(secret + window.toString())
  const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer)
  const hashArray = Array.from(new Uint8Array(hashBuffer))
  return hashArray.map((b) => b.toString(16).padStart(2, '0')).join('').substring(0, 8)
}

export function currentTokenWindow(now = Date.now()) {
  return Math.floor(now / 1000 / 10)
}

export function createSessionSecret() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    return crypto.randomUUID().replace(/-/g, '')
  }
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2)}${Math.random().toString(36).slice(2)}`
}
