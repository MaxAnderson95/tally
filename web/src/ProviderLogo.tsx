import logos from '../../Sources/TallyApp/Resources/logos.json'

export const providers = ['anthropic', 'openai', 'opencode-go', 'xai'] as const
export function providerName(provider: string) {
  const key = providers.find(key => key === provider)
  return key ? logos[key].name : provider
}

export function ProviderLogo({ provider, color }: { provider: string; color: number }) {
  const key = providers.find(key => key === provider)
  if (!key) return null
  // Only the release-bundled, accepted prototype artwork enters this markup.
  return <span className={`logo identity-${color}`} role="img" aria-label={logos[key].name} dangerouslySetInnerHTML={{ __html: logos[key].svg }} />
}
