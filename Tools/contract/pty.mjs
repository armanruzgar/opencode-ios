// The PTY and shell contract the terminal relies on, against the sandbox: the REST routes and events, the socket's
// handshake with the Authorization header, replay frames then one 0x00 control frame, the UTF-16 cursor, a cursor of -1,
// single-use tickets, the 2 MiB retained buffer and the gap a stale cursor sees, close codes 1000 and 4404, and the
// shell service's paging and removal. Returns the measured buffer numbers.
import assert from 'node:assert/strict';
import { Capture, until } from '../fixture-recorder/transport.mjs';
import { connectWS } from '../fixture-recorder/websocket.mjs';

const control = frame => frame.opcode === 2 && frame.bytes[0] === 0;
const cursorOf = frame => JSON.parse(frame.bytes.subarray(1).toString('utf8')).cursor;
const closeOf = frames => {
  const frame = frames.find(item => item.opcode === 8);
  return frame && { code: frame.bytes.readUInt16BE(0), reason: frame.bytes.subarray(2).toString('utf8') };
};
/** Text received after the control frame; JavaScript's string length is the server's cursor unit. */
const liveText = socket => {
  const marker = socket.received.findIndex(control);
  return socket.received.slice(marker + 1).filter(frame => frame.opcode === 1).map(frame => frame.bytes.toString('utf8')).join('');
};
const replayText = socket => {
  const marker = socket.received.findIndex(control);
  return socket.received.slice(0, marker).filter(frame => frame.opcode === 1).map(frame => frame.bytes.toString('utf8'));
};
/** 3,000,000 bytes of output, then a marker. bash echoes the command line first, so printf assembles the marker: the
 * echo never contains it, and a wait for it ends only when the output does. */
export const bufferCommand = "head -c 3000000 /dev/zero | tr '\\0' a; echo; printf 'buffer-%s\\n' done\n";
export const bufferDone = text => text.includes('buffer-done\r\n');
/** How many of the written bytes arrived live: the run of `a` that ends at the marker. */
export const bufferRun = text => {
  const done = text.indexOf('\r\nbuffer-done\r\n');
  let first = done;
  while (first > 0 && text[first - 1] === 'a') first--;
  return done - first;
};

export async function ptyContract(sandbox) {
  const c = new Capture(sandbox);
  await c.openSSE();
  const sockets = [];
  const connect = async (path, options) => { const socket = await connectWS(c, path, sockets.length + 1, options); sockets.push(socket); return socket; };
  let id, big;
  try {
    const shells = await c.request('GET', '/api/config/shell');
    assert.ok(Array.isArray(shells) && shells.some(shell => shell.path === '/bin/bash' && typeof shell.name === 'string'), 'The shell list is a bare array');
    const info = (await c.request('POST', '/api/pty', { command: '/bin/bash', args: ['--noprofile', '--norc'], title: 'Contract PTY',
      env: { PS1: '$ ', PROMPT_COMMAND: '', HISTFILE: '/dev/null' } })).data;
    id = info.id;
    assert.ok(id.startsWith('pty_') && info.status === 'running' && Number.isInteger(info.pid) && info.cwd === sandbox.project);
    await c.event('pty.created', event => event.data.info.id === id);
    assert.ok((await c.request('GET', '/api/pty')).data.some(pty => pty.id === id));
    const renamed = (await c.request('PUT', `/api/pty/${id}`, { title: 'Renamed', size: { cols: 90, rows: 30 } })).data;
    assert.equal(renamed.title, 'Renamed');
    await c.event('pty.updated', event => event.data.info.id === id && event.data.info.title === 'Renamed');

    // The upgrade with the Authorization header; replay, then exactly one control frame.
    const first = await connect(`/api/pty/${id}/connect?cursor=0`);
    const marker = await first.wait(frames => frames.find(control), 'control frame');
    const start = cursorOf(marker);
    assert.equal(first.received.filter(control).length, 1);
    assert.equal(replayText(first).join('').length, start, 'The replay from 0 is the whole output so far');
    // UTF-16: an emoji is 2 units, a CJK character 1, a combining mark 1 more.
    first.send("printf '\\360\\237\\230\\200\\346\\274\\242e\\314\\201-end\\n'\n");
    await first.wait(() => liveText(first).includes('😀漢e\u0301-end\r\n'), 'UTF-8 echo');
    await new Promise(resolve => setTimeout(resolve, 300));
    const cursor = start + liveText(first).length;
    await first.close();
    const resumed = await connect(`/api/pty/${id}/connect?cursor=${cursor}`);
    assert.equal(cursorOf(await resumed.wait(frames => frames.find(control), 'resumed control')), cursor, 'The cursor counts UTF-16 code units');
    assert.equal(replayText(resumed).join(''), '', 'Nothing before the cursor is replayed');
    await resumed.close();
    const tail = await connect(`/api/pty/${id}/connect?cursor=-1`);
    assert.equal(cursorOf(await tail.wait(frames => frames.find(control), 'tail control')), cursor, '-1 tails from now');
    assert.equal(replayText(tail).length, 0);
    await tail.close();

    // Tickets: only with x-opencode-ticket, single use, and without the Authorization header.
    await c.request('POST', `/api/pty/${id}/connect-token`, undefined, { status: 403 });
    const { ticket, expires_in: expires } = (await c.request('POST', `/api/pty/${id}/connect-token`, undefined, { headers: { 'x-opencode-ticket': '1' } })).data;
    assert.ok(ticket && expires === 60);
    const ticketed = await connect(`/api/pty/${id}/connect?cursor=-1&ticket=${encodeURIComponent(ticket)}`, { auth: false });
    await ticketed.wait(frames => frames.find(control), 'ticketed control');
    await ticketed.close();
    await assert.rejects(connect(`/api/pty/${id}/connect?cursor=-1&ticket=${encodeURIComponent(ticket)}`, { auth: false }), /upgrade status 403/, 'A ticket works once');
    // v2.2.0 drops an upgrade without credentials before answering; the app falls back to a ticket either way.
    await assert.rejects(connect(`/api/pty/${id}/connect?cursor=-1`, { auth: false }), /upgrade status 401|socket hang up/, 'No ticket, no header');

    // The 2 MiB buffer: output beyond it is gone, and a stale cursor learns how much.
    const writer = await connect(`/api/pty/${id}/connect?cursor=-1`);
    await writer.wait(frames => frames.find(control), 'writer control');
    writer.send(bufferCommand);
    await writer.wait(() => bufferDone(liveText(writer)), 'buffer output', 60000);
    assert.equal(bufferRun(liveText(writer)), 3000000, 'Live output carries every byte');
    await new Promise(resolve => setTimeout(resolve, 500));
    const end = cursor + liveText(writer).length;
    await writer.close();
    const stale = await connect(`/api/pty/${id}/connect?cursor=${cursor}`);
    const staleEnd = cursorOf(await stale.wait(frames => frames.find(control), 'stale control', 60000));
    const replay = replayText(stale), replayed = replay.reduce((sum, text) => sum + text.length, 0);
    assert.equal(staleEnd, end);
    assert.equal(replayed, 2 * 1024 * 1024, 'The server keeps 2,097,152 UTF-16 code units');
    assert.ok(replay.every(text => text.length <= 65536), 'Replay frames hold at most 64 Ki units');
    big = { cursor, end, replayed, lost: end - cursor - replayed, bufferStart: end - replayed, frames: replay.length };
    assert.ok(big.lost > 0);
    await stale.close();
    const near = await connect(`/api/pty/${id}/connect?cursor=${end - 100}`);
    await near.wait(frames => frames.find(control), 'near control');
    assert.equal(replayText(near).join('').length, 100, 'A cursor inside the buffer replays exactly what follows it');
    await near.close();

    // Exit: close 1000 on the open socket, pty.exited with the code, and 4404 for a later connection.
    const exiting = await connect(`/api/pty/${id}/connect?cursor=-1`);
    await exiting.wait(frames => frames.find(control), 'exit control');
    exiting.send('exit 3\n');
    await exiting.wait(frames => frames.some(frame => frame.opcode === 8), 'close on exit');
    assert.equal(closeOf(exiting.received).code, 1000);
    await c.event('pty.exited', event => event.data.id === id && event.data.exitCode === 3);
    const exited = (await c.request('GET', `/api/pty/${id}`)).data;
    assert.ok(exited.status === 'exited' && exited.exitCode === 3);
    const late = await connect(`/api/pty/${id}/connect?cursor=0`);
    await late.wait(frames => frames.some(frame => frame.opcode === 8), 'close for an exited PTY');
    assert.deepEqual(closeOf(late.received), { code: 4404, reason: 'session exited' });
    assert.equal(late.received.filter(control).length, 0, 'An exited PTY replays nothing');

    // Removal: 204, pty.deleted, then 404 before any upgrade.
    await c.request('DELETE', `/api/pty/${id}`, undefined, { status: 204 });
    await c.event('pty.deleted', event => event.data.id === id);
    await c.request('GET', `/api/pty/${id}`, undefined, { status: 404 });
    await assert.rejects(connect(`/api/pty/${id}/connect?cursor=0`), /upgrade status 404/);
    id = undefined;

    // The shell service: running list, byte-cursor paging, and DELETE, which kills and drops the output.
    const shell = (await c.request('POST', '/api/shell', { command: "printf 'a\\nb\\n'; sleep 30" })).data;
    assert.ok(shell.id.startsWith('sh_') && shell.status === 'running');
    await c.event('shell.created', event => event.data.info.id === shell.id);
    assert.ok((await c.request('GET', '/api/shell')).data.some(item => item.id === shell.id));
    await until(async () => (await c.request('GET', `/api/shell/${shell.id}/output?cursor=0`)).data.size >= 4, 'shell output');
    const pages = [];
    for (let at = 0; at < 4;) {
      const page = (await c.request('GET', `/api/shell/${shell.id}/output?cursor=${at}&limit=1`)).data;
      assert.equal(page.cursor, at + 1); pages.push(page.output); at = page.cursor;
    }
    assert.equal(pages.join(''), 'a\nb\n');
    const caught = (await c.request('GET', `/api/shell/${shell.id}/output?cursor=4`)).data;
    assert.ok(caught.cursor === caught.size && caught.output === '');
    await c.request('DELETE', `/api/shell/${shell.id}`, undefined, { status: 204 });
    await c.event('shell.exited', event => event.data.id === shell.id && event.data.status === 'killed');
    await c.event('shell.deleted', event => event.data.id === shell.id);
    await c.request('GET', `/api/shell/${shell.id}/output`, undefined, { status: 404 });
    assert.ok(!(await c.request('GET', '/api/shell')).data.some(item => item.id === shell.id));
    return big;
  } finally {
    for (const socket of sockets) await socket.close().catch(() => {});
    if (id) await c.request('DELETE', `/api/pty/${id}`, undefined, { status: 204 }).catch(() => {});
    await c.closeSSE();
  }
}
