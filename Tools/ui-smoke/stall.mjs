/**
 * Runs a command the way the sandbox's `run` does, but stops it once it has printed nothing for `quiet` ms. xcodebuild
 * can wait forever on a simulator that stopped answering, before any test starts, where no test timeout applies; a
 * running UI test prints each of its steps, and a hung one fails at its time allowance (at most 15 minutes here), so a
 * longer silence means nothing is running. A stopped command throws an error marked `stalled`, also when its cleanup
 * fails (the cleanup error is its cause), and a command that cannot be stopped ends the wait instead of holding it.
 */
export async function runUntilQuiet(launch, command, args, options, { quiet, interval = 30_000 }) {
  const group = launch(command, args, options);
  let last = Date.now(), stopping, unstoppable;
  for (const stream of [group.child.stdout, group.child.stderr]) stream.on('data', () => { last = Date.now(); });
  const refused = new Promise((_, reject) => { unstoppable = reject; });
  refused.catch(() => {});
  const watch = setInterval(() => {
    if (stopping || Date.now() - last < quiet) return;
    stopping = group.stop();
    stopping.catch(unstoppable);
  }, Math.min(interval, quiet));
  let code, failure, cleanup;
  try {
    code = await Promise.race([refused, new Promise((resolve, reject) => {
      group.child.once('error', reject);
      group.child.once('exit', resolve);
    })]);
  } catch (error) { failure = error; }
  clearInterval(watch);
  try { await group.stop(); } catch (error) { cleanup = error; }
  if (stopping) throw Object.assign(new Error(`${command} printed nothing for ${quiet / 1000} s and was stopped: ${group.output}`, { cause: cleanup }), { stalled: true });
  if (failure) throw failure;
  if (cleanup) throw cleanup;
  if (code !== 0) throw new Error(`${command} exited ${code}: ${group.output}`);
  return group.output;
}
