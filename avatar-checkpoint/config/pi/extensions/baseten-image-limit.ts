// Baseten hackathon endpoint permits at most eight images per request.
// Preserve the original reference and the seven most recent visual checks.
export function limitImages(messages, limit = 8) {
  const positions = [];
  messages.forEach((m, i) => {
    if (Array.isArray(m.content)) m.content.forEach((b, j) => {
      if (b.type === 'image') positions.push(`${i}:${j}`);
    });
  });
  if (positions.length <= limit) return messages;
  const keep = new Set([positions[0], ...positions.slice(-(limit - 1))]);
  return messages.map((m, i) => {
    if (!Array.isArray(m.content)) return m;
    const content = m.content.map((b, j) => b.type === 'image' && !keep.has(`${i}:${j}`)
      ? {type: 'text', text: '[Older image omitted to fit the endpoint image limit.]'} : b);
    return {...m, content};
  });
}
export default function(pi) {
  pi.on('context', (event, ctx) => {
    if (ctx.model?.provider !== 'baseten-hackathon') return;
    return {messages: limitImages(event.messages)};
  });
}
