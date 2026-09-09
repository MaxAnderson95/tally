import { useEffect, useState } from 'react'

const threshold = 64

export function PullToReload({ loading }: { loading: boolean }) {
  const [distance, setDistance] = useState(0)
  const [reloading, setReloading] = useState(false)
  useEffect(() => {
    let start: { x: number; y: number } | undefined
    let pulled = 0
    let pending = false
    let frame: number | undefined
    const begin = (event: TouchEvent) => {
      if (pending || window.scrollY > 0 || event.touches.length !== 1 || document.querySelector('dialog[open]')) return
      start = { x: event.touches[0].clientX, y: event.touches[0].clientY }
    }
    const move = (event: TouchEvent) => {
      if (!start || pending) return
      if (event.touches.length !== 1) { cancel(); return }
      const x = event.touches[0].clientX - start.x
      const y = event.touches[0].clientY - start.y
      if (Math.abs(x) > Math.abs(y)) { cancel(); return }
      if (y > 0) event.preventDefault()
      pulled = Math.min(96, Math.max(0, y * 0.5))
      setDistance(pulled)
    }
    const cancel = () => { start = undefined; pulled = 0; setDistance(0) }
    const end = () => {
      if (pending) return
      if (pulled < threshold) { cancel(); return }
      pending = true
      setReloading(true)
      frame = requestAnimationFrame(() => { frame = requestAnimationFrame(() => window.location.reload()) })
    }
    document.addEventListener('touchstart', begin, { passive: true })
    document.addEventListener('touchmove', move, { passive: false })
    document.addEventListener('touchend', end)
    document.addEventListener('touchcancel', cancel)
    return () => {
      document.removeEventListener('touchstart', begin)
      document.removeEventListener('touchmove', move)
      document.removeEventListener('touchend', end)
      document.removeEventListener('touchcancel', cancel)
      if (frame !== undefined) cancelAnimationFrame(frame)
    }
  }, [])
  const busy = loading || reloading
  if (distance === 0 && !busy) return null
  return <div className="pull-to-reload" role="status" data-state={busy ? 'loading' : distance >= threshold ? 'ready' : 'pulling'} style={{ transform: `translate(-50%, ${Math.min(distance, 48)}px)` }}>
    <span className={busy ? 'reload-spinner' : 'reload-arrow'} aria-hidden="true">{!busy && (distance >= threshold ? '↑' : '↓')}</span>
    <span>{busy ? 'Reloading saved usage…' : distance >= threshold ? 'Release to reload' : 'Pull to reload'}</span>
  </div>
}
