import { useEffect, useState, type FormEvent } from 'react'
import { browserSupportsWebAuthn, startAuthentication, startRegistration, WebAuthnError,
  type PublicKeyCredentialCreationOptionsJSON, type PublicKeyCredentialRequestOptionsJSON } from '@simplewebauthn/browser'
import type { Fault } from './api'

type AuthState = { passwordEnabled: boolean; hasPasskeys: boolean }
type Ceremony<Options> = { ceremonyId: string; options: Options }
export type Passkey = { id: string; name: string; createdAt: string; lastUsedAt: string | null }

class AuthError extends Error { constructor(readonly status: number, message: string) { super(message) } }

async function call<T>(path: string, method: 'GET' | 'POST' | 'DELETE' = 'GET', body: unknown = {}): Promise<T> {
  const response = await fetch(`/api/v1/auth${path}`, {
    method, cache: 'no-store', signal: AbortSignal.timeout(15_000),
    ...(method === 'GET' ? {} : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }),
  })
  if (!response.ok) {
    const result: { error?: Fault } | null = await response.json().catch(() => null)
    throw new AuthError(response.status, result?.error?.message ?? `Tally answered HTTP ${response.status}.`)
  }
  return response.json()
}

/** Only a 401 means signed out; an unreachable Mac falls through to the dashboard, which reports the connection. */
export async function hasSession(): Promise<boolean> {
  try { await call('/me'); return true }
  catch (failure) { return !(failure instanceof AuthError && failure.status === 401) }
}

export const signOut = () => call('/logout', 'POST')

// Browsers reject IP addresses as WebAuthn relying-party IDs, so 127.0.0.1 offers the password only.
const passkeysAvailable = () => window.isSecureContext && browserSupportsWebAuthn() && !/^[\d.]+$|^\[/.test(location.hostname)

function message(failure: unknown, fallback: string): string {
  if (failure instanceof WebAuthnError && failure.code === 'ERROR_CEREMONY_ABORTED') return 'Passkey request cancelled.'
  if (failure instanceof DOMException && failure.name === 'NotAllowedError') return 'Passkey request cancelled or timed out.'
  if (failure instanceof WebAuthnError && failure.code === 'ERROR_AUTHENTICATOR_PREVIOUSLY_REGISTERED') return 'This device already has a Tally passkey for this address.'
  return failure instanceof Error ? failure.message : fallback
}

export function Login({ signedIn }: { signedIn: () => void }) {
  const [state, setState] = useState<AuthState>()
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string>()
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    call<AuthState>('/state').then(setState).catch(() => setState({ passwordEnabled: true, hasPasskeys: false }))
  }, [])
  async function attempt(action: () => Promise<unknown>, fallback: string) {
    setBusy(true); setError(undefined)
    try { await action(); signedIn() }
    catch (failure) { setError(message(failure, fallback)) }
    finally { setBusy(false) }
  }
  const passkey = () => attempt(async () => {
    const begin = await call<Ceremony<PublicKeyCredentialRequestOptionsJSON>>('/passkeys/login/begin', 'POST')
    const credential = await startAuthentication({ optionsJSON: begin.options })
    await call('/passkeys/login/finish', 'POST', { ceremonyId: begin.ceremonyId, credential })
  }, 'Passkey sign-in failed.')
  const submit = (event: FormEvent) => { event.preventDefault(); void attempt(() => call('/login', 'POST', { password }), 'Sign-in failed.') }
  return <main className="sign-in">
    <h1 className="wordmark"><img src="/favicon.svg" alt="" width="28" height="28" />Tally</h1>
    {state && <div className="sign-in-panel">
      {state.hasPasskeys && passkeysAvailable() && <button className="primary-button" disabled={busy} onClick={() => void passkey()}>Sign in with passkey</button>}
      {state.passwordEnabled && <form onSubmit={submit}>
        {/* 16px text keeps iOS Safari from zooming on focus. */}
        <input type="password" autoComplete="current-password" placeholder="Password" aria-label="Password" value={password} onChange={event => setPassword(event.target.value)} autoFocus={!state.hasPasskeys} />
        <button type="submit" className="quiet-button" disabled={busy || password === ''}>Sign in with password</button>
      </form>}
      {!state.passwordEnabled && !state.hasPasskeys && <p className="fine-print">Browser sign-in is off because Tally has only an API token. Set a web password in Tally's settings on your Mac.</p>}
      {error && <p className="note-warn" role="alert">{error}</p>}
    </div>}
  </main>
}

const dateLabel = (date: string) => new Date(date).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })

export function SignInPreferences({ signedOut }: { signedOut: () => void }) {
  const [passkeys, setPasskeys] = useState<Passkey[]>()
  const [name, setName] = useState('')
  const [error, setError] = useState<string>()
  const [busy, setBusy] = useState(false)
  const load = () => call<{ passkeys: Passkey[] }>('/passkeys').then(result => setPasskeys(result.passkeys))
  useEffect(() => { load().catch(failure => setError(message(failure, 'Could not read passkeys.'))) }, [])
  async function run(action: () => Promise<unknown>, fallback: string) {
    setBusy(true); setError(undefined)
    try { await action(); await load() }
    catch (failure) { setError(message(failure, fallback)) }
    finally { setBusy(false) }
  }
  const add = (event: FormEvent) => {
    event.preventDefault()
    void run(async () => {
      const begin = await call<Ceremony<PublicKeyCredentialCreationOptionsJSON>>('/passkeys/register/begin', 'POST')
      const credential = await startRegistration({ optionsJSON: begin.options })
      await call('/passkeys/register/finish', 'POST', { ceremonyId: begin.ceremonyId, name, credential })
      setName('')
    }, 'Passkey could not be added.')
  }
  return <div className="sign-in-preferences">
    <p className="settings-intro">Passkeys sign this browser in with Face ID or Touch ID instead of the password. Each passkey works only at the address you add it from, here {location.host}.</p>
    {error && <p className="note-warn" role="alert">{error}</p>}
    {passkeys && passkeys.length > 0 && <ul className="passkeys">{passkeys.map(passkey => <li key={passkey.id}>
      <span>{passkey.name}<small>Added {dateLabel(passkey.createdAt)}{passkey.lastUsedAt ? `, last used ${dateLabel(passkey.lastUsedAt)}` : ''}</small></span>
      <button className="quiet-button" disabled={busy} onClick={() => void run(() => call(`/passkeys/${encodeURIComponent(passkey.id)}`, 'DELETE'), 'Passkey could not be removed.')}>Remove</button>
    </li>)}</ul>}
    {passkeys?.length === 0 && <p className="fine-print">No passkeys yet.</p>}
    {passkeysAvailable()
      ? <form className="passkey-add" onSubmit={add}>
        <input placeholder="Name, such as iPhone" aria-label="Passkey name" maxLength={64} value={name} onChange={event => setName(event.target.value)} />
        <button type="submit" className="primary-button" disabled={busy}>Add passkey</button>
      </form>
      : <p className="fine-print">Passkeys need an HTTPS address or localhost, not an IP address.</p>}
    <button className="quiet-button sign-out" disabled={busy} onClick={() => { void signOut().catch(() => undefined).finally(signedOut) }}>Sign out</button>
  </div>
}
