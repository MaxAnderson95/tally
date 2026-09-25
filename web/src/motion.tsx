import { useEffect, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'

const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches

/** Keeps children mounted through the closing transition, then unmounts them. */
export function usePresence(open: boolean, duration: number) {
  const [mounted, setMounted] = useState(open)
  useEffect(() => {
    if (open) { setMounted(true); return }
    const timer = setTimeout(() => setMounted(false), reduced() ? 0 : duration)
    return () => clearTimeout(timer)
  }, [open, duration])
  return mounted
}

/** Height reveal: grid rows animate between 0fr and 1fr, so content of any height opens and closes smoothly. */
export function Collapse({ open, id, className, children }: { open: boolean; id?: string; className?: string; children: ReactNode }) {
  const mounted = usePresence(open, 320)
  const [shown, setShown] = useState(open)
  useEffect(() => {
    if (!open) { setShown(false); return }
    // Two frames: the closed state must be styled once before the open state, or the browser skips the transition.
    let frame = requestAnimationFrame(() => { frame = requestAnimationFrame(() => setShown(true)) })
    return () => cancelAnimationFrame(frame)
  }, [open])
  if (!mounted) return null
  return <div className="collapse" data-open={shown} id={id} inert={!open}><div className="collapse-inner"><div className={className}>{children}</div></div></div>
}

/** A pill that slides to whichever option is pressed. */
export function Segmented<T extends string>({ options, value, onChange, label, className }: {
  options: readonly { value: T; label: ReactNode }[]; value: T; onChange: (value: T) => void; label: string; className?: string
}) {
  const container = useRef<HTMLDivElement>(null)
  const [pill, setPill] = useState<{ x: number; width: number }>()
  useLayoutEffect(() => {
    const measure = () => {
      const active = container.current?.querySelector<HTMLElement>('button[aria-pressed="true"]')
      if (active) setPill({ x: active.offsetLeft, width: active.offsetWidth })
    }
    measure()
    const observer = new ResizeObserver(measure)
    if (container.current) observer.observe(container.current)
    return () => observer.disconnect()
  }, [value, options.length])
  return <div ref={container} className={`segmented${className ? ` ${className}` : ''}`} role="group" aria-label={label}>
    {pill && <span className="segmented-pill" aria-hidden="true" style={{ transform: `translateX(${pill.x}px)`, width: pill.width }} />}
    {options.map(option => <button key={option.value} aria-pressed={value === option.value} onClick={() => onChange(option.value)}>{option.label}</button>)}
  </div>
}

/** Plays a closing animation before a modal dialog actually closes, including Escape and backdrop dismissals. */
export function useDialogMotion(dialog: RefObject<HTMLDialogElement | null>) {
  return (after?: () => void) => {
    const element = dialog.current
    if (!element?.open || element.dataset.closing !== undefined) return
    const finish = () => { delete element.dataset.closing; element.close(); after?.() }
    if (reduced()) { finish(); return }
    element.dataset.closing = ''
    setTimeout(finish, 200)
  }
}

/** Re-keys its content whenever the value changes so the new value rises in with a short blur. */
export function Swap({ value, className, title }: { value: string; className?: string; title?: string }) {
  return <span className={`swap${className ? ` ${className}` : ''}`} title={title}><span key={value} className="swap-in">{value}</span></span>
}
