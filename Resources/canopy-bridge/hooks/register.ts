// Canopy reads these lines off the stream-json wire (system/ui_log, plugin
// "canopy-bridge") and never forwards them to the webview.
export function register(on) {
  on('session.measure', async ($, e, next) => {
    const r = await next(e)
    if (e.changed?.includes('context') && e.context) {
      $.ui.log(JSON.stringify({ v: 1, context: { tokens: e.context.tokens ?? null, window: e.context.window ?? null } }))
    }
    return r
  })
}
