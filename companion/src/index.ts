import type { Plugin } from '@opencode/plugin'
import { createTally } from './tally.ts'

export default {
  id: 'tally',
  async setup(ctx) {
    const tally = createTally(ctx.options)
    await ctx.tool.transform(editor => editor.add(tally))
  },
} satisfies Plugin.Plugin
