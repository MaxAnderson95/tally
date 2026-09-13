import { useEffect, useRef, useState } from 'react'
import type { Account } from './api'
import { ProviderLogo, providerName } from './ProviderLogo'
import { WarmupPreferences, type useWarmups } from './WarmupPreferences'

export type PreferenceChange = { kind: 'color'; accountId: string; index: number } | { kind: 'pins' | 'unpinned-order'; accountIds: string[] }
type SavePreference = (change: PreferenceChange) => Promise<boolean>
const colors = ['Monochrome', 'Blue', 'Orange', 'Green', 'Purple', 'Pink']

export function ColorPicker({ account, save, disabled }: { account: Account; save: SavePreference; disabled: boolean }) {
  const [open, setOpen] = useState(false)
  const container = useRef<HTMLDivElement>(null)
  const trigger = useRef<HTMLButtonElement>(null)
  const options = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    options.current?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
    const outside = (event: PointerEvent) => { if (event.target instanceof Node && !container.current?.contains(event.target)) setOpen(false) }
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') { setOpen(false); trigger.current?.focus() } }
    document.addEventListener('pointerdown', outside)
    document.addEventListener('keydown', escape)
    return () => { document.removeEventListener('pointerdown', outside); document.removeEventListener('keydown', escape) }
  }, [open])
  return <div className="color-picker" ref={container}>
    <button ref={trigger} className="color-trigger" disabled={disabled} aria-label={`Change icon color for ${providerName(account.provider)} ${account.name}`} aria-expanded={open} onClick={() => setOpen(!open)}>
      <ProviderLogo provider={account.provider} color={account.identityColorIndex} />
    </button>
    {open && <div ref={options} className="color-options" role="group" aria-label="Icon color">
      <p>Icon color</p><div>{colors.map((name, index) => <button key={name} disabled={disabled} aria-label={name} aria-pressed={account.identityColorIndex === index} onClick={async () => {
        if (await save({ kind: 'color', accountId: account.id, index })) { setOpen(false); trigger.current?.focus() }
      }}><ProviderLogo provider={account.provider} color={index} /></button>)}</div>
    </div>}
  </div>
}

export function AccountPreferences({ accounts, open, close, save, disabled, error, timezone, warmups }: { accounts: Account[]; open: boolean; close: () => void; save: SavePreference; disabled: boolean; error: string | undefined; timezone: string; warmups: ReturnType<typeof useWarmups> }) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [section, setSection] = useState<'warmup' | 'menu'>('warmup')
  useEffect(() => {
    if (open) dialog.current?.showModal()
    else dialog.current?.close()
  }, [open])
  const pins = accounts.filter(account => account.pinned).map(account => account.id)
  function move(account: Account, index: number, direction: -1 | 1) {
    const next = accounts.filter(item => item.pinned === account.pinned).map(item => item.id)
    const destination = index + direction
    ;[next[index], next[destination]] = [next[destination], next[index]]
    void save({ kind: account.pinned ? 'pins' : 'unpinned-order', accountIds: next })
  }
  return <dialog ref={dialog} className="preferences-dialog" onClose={close} onClick={event => { if (event.target === event.currentTarget) close() }} aria-labelledby="preferences-title">
    <div className="preferences-toolbar">
      <header><h2 id="preferences-title">Account settings</h2><button onClick={close} aria-label="Close account settings">Close</button></header>
      <nav className="settings-sections" aria-label="Settings section"><button aria-pressed={section === 'warmup'} onClick={() => setSection('warmup')}>Warm-up</button><button aria-pressed={section === 'menu'} onClick={() => setSection('menu')}>Menu bar</button></nav>
    </div>
    <div className="preferences-content">
      {section === 'warmup' && open && <WarmupPreferences accounts={accounts} timezone={timezone} disabled={disabled} warmups={warmups} />}
      {section === 'menu' && <>
      <p>Colors and pins are shared with Tally on your Mac. Click an icon to change its color.</p>
      {error && <p className="account-error" role="alert">{error}</p>}
      <div className="preference-accounts">{accounts.map(account => {
        const siblings = accounts.filter(item => item.pinned === account.pinned)
        const index = siblings.findIndex(item => item.id === account.id)
        const name = `${providerName(account.provider)} ${account.name}`
        return <div className="preference-account" key={account.id}>
          <ColorPicker account={account} save={save} disabled={disabled} /><span>{account.name}<small>{providerName(account.provider)}</small></span>
          <div className="pin-controls">
            <button disabled={disabled} aria-label={`${account.pinned ? 'Unpin' : 'Pin'} ${name}`} onClick={() => void save({ kind: 'pins', accountIds: account.pinned ? pins.filter(id => id !== account.id) : [...pins, account.id] })}>{account.pinned ? 'Unpin' : 'Pin'}</button>
            <button disabled={disabled || index === 0} aria-label={`Move ${name} earlier`} onClick={() => move(account, index, -1)}>↑</button><button disabled={disabled || index === siblings.length - 1} aria-label={`Move ${name} later`} onClick={() => move(account, index, 1)}>↓</button>
          </div>
        </div>
      })}</div>
      </>}
      <p className="fine-print">Manage account names and authentication in OpenCode. Launch at login, database location, and connection settings are available in Tally on your Mac.</p>
    </div>
  </dialog>
}
