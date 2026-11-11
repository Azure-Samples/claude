import { MAX_TOKENS, TOTAL_TIMEOUT_MS, describeError, noText, type RunIO, type RunOptions } from './main.ts';
import { configuredClient, loadSettings, type Environment } from './sample_client.ts';

export const FIRST_PROMPT = 'Remember the code ORCHID-47. Reply with OK.';
export const SECOND_PROMPT = 'What code did I ask you to remember? Reply with only the code.';
const USAGE = 'Usage: node src/message_threads.ts';

export async function run(argv: readonly string[], env: Environment, io: RunIO, options: RunOptions = {}): Promise<number> {
  if (argv.length > 0) {
    const help = argv.length === 1 && (argv[0] === '--help' || argv[0] === '-h');
    (help ? io.stdout : io.stderr).write(`${USAGE}\n`);
    return help ? 0 : 2;
  }
  const timeoutMs = options.totalTimeoutMs ?? TOTAL_TIMEOUT_MS;
  const signal = AbortSignal.timeout(timeoutMs);
  try {
    const settings = loadSettings(env);
    const client = configuredClient(settings, options);
    const thread = client.beta.messages.thread({
      model: settings.model, max_tokens: MAX_TOKENS, system: 'Keep replies short.',
    }, { signal });
    await thread.send({ role: 'user', content: FIRST_PROMPT });
    const reply = await thread.send({ role: 'user', content: SECOND_PROMPT });
    const texts = reply.content.flatMap((block) => block.type === 'text' && block.text.trim() ? [block.text] : []);
    if (texts.length === 0) return noText(reply.stop_reason, io);
    for (const text of texts) io.stdout.write(`${text}\n`);
    return 0;
  } catch (error) {
    io.stderr.write(`${describeError(error, signal, timeoutMs)}\n`);
    return 1;
  }
}

if (import.meta.main) {
  process.exitCode = await run(process.argv.slice(2), process.env, process);
}
