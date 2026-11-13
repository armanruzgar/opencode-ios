// Prints the local checks a change needs (see scope.mjs).
//   node Tools/checks/index.mjs                 # the working tree against origin/main, untracked files included
//   node Tools/checks/index.mjs <base>          # against another base revision
import { execFileSync } from 'node:child_process';
import { scope } from './scope.mjs';

const base = process.argv[2] ?? 'origin/main';
const git = args => execFileSync('git', args, { encoding: 'utf8' }).split('\n').filter(Boolean);
const paths = [...new Set([...git(['diff', '--name-only', base]), ...git(['ls-files', '--others', '--exclude-standard'])])];
const needed = scope(paths);
console.log(`${paths.length} changed paths against ${base}.`);
if (needed.length === 0) console.log('No local checks: nothing here can change what they test.');
for (const item of needed) {
  const shown = item.paths.slice(0, 3).join(', ') + (item.paths.length > 3 ? `, and ${item.paths.length - 3} more` : '');
  console.log(`\n${item.what}:\n  ${item.command}\n  for ${shown}`);
}
