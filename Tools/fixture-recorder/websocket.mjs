// Small RFC 6455 client so fixtures retain individual text, binary and control
// frames, rather than WebSocket API messages that may combine fragments.
import http from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import assert from 'node:assert/strict';
import { until } from './transport.mjs';
import { basic } from '../opencode-sandbox/index.mjs';

/** `auth: false` sends no Authorization header, for a connection a ticket authenticates. */
export async function connectWS(capture, path, connection, { auth = true } = {}) {
  const key = randomBytes(16).toString('base64');
  let socket, buffer = Buffer.alloc(0), failure, closed = false;
  const received = [], frames = capture.frames;
  const frame = (direction, opcode, payload, fin = true) => {
    const row = { connection, direction, opcode, fin, encoding: 'base64', payload: payload.toString('base64') };
    frames.push(row);
    if (direction === 'received') received.push({ ...row, bytes: payload });
  };
  const send = (opcode, payload) => {
    payload = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
    assert.ok(payload.length < 65536, 'Client fixture frames are limited to 64 KiB');
    const mask = randomBytes(4), header = Buffer.alloc(payload.length < 126 ? 2 : 4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | (payload.length < 126 ? payload.length : 126);
    if (payload.length >= 126) header.writeUInt16BE(payload.length, 2);
    const masked = Buffer.from(payload);
    for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
    frame('sent', opcode, payload);
    socket.write(Buffer.concat([header, mask, masked]));
  };
  function parse(bytes) {
    buffer = Buffer.concat([buffer, bytes]);
    try {
      while (buffer.length >= 2) {
        assert.equal(buffer[0] & 0x70, 0, 'Unexpected RSV flags');
        assert.equal(buffer[1] & 0x80, 0, 'Server frames must be unmasked');
        const fin = Boolean(buffer[0] & 0x80), opcode = buffer[0] & 0x0f;
        let size = buffer[1] & 0x7f, offset = 2;
        if (size === 126) { if (buffer.length < 4) return; size = buffer.readUInt16BE(2); offset = 4; }
        else if (size === 127) { if (buffer.length < 10) return; size = Number(buffer.readBigUInt64BE(2)); offset = 10; }
        assert.ok(Number.isSafeInteger(size) && size <= 16 * 1024 * 1024, 'Oversized frame');
        if (buffer.length < offset + size) return;
        const payload = Buffer.from(buffer.subarray(offset, offset + size));
        buffer = buffer.subarray(offset + size);
        frame('received', opcode, payload, fin);
        if (opcode === 9) send(10, payload);
        if (opcode === 8 && !closed) { closed = true; send(8, payload); socket.end(); }
      }
    } catch (error) { failure = error; socket.destroy(); }
  }
  const request = http.request(capture.sandbox.baseURL + path, { headers: { connection: 'Upgrade', upgrade: 'websocket', 'sec-websocket-version': '13', 'sec-websocket-key': key, ...(auth ? { authorization: basic(capture.sandbox.password) } : {}) } });
  let timer;
  try {
    await new Promise((resolve, reject) => {
      timer = setTimeout(() => { request.destroy(); reject(new Error('WebSocket upgrade timeout')); }, 10000);
      request.once('error', reject);
      request.once('response', response => { response.resume(); reject(new Error(`WebSocket upgrade status ${response.statusCode}`)); });
      request.once('upgrade', (response, upgraded, head) => {
        socket = upgraded;
        try {
          assert.equal(response.headers['sec-websocket-accept'], createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64'));
          frames.push({ connection, direction: 'handshake', path: capture.redact(path), status: response.statusCode });
          socket.on('data', parse);
          socket.on('error', error => { failure = error; });
          if (head.length) parse(head);
          resolve();
        } catch (error) { socket.destroy(); reject(error); }
      });
      request.end();
    });
  } finally { clearTimeout(timer); }
  return {
    received,
    text: () => received.filter(frame => frame.opcode === 1 || frame.opcode === 0).map(frame => frame.bytes.toString('utf8')).join(''),
    send: text => send(1, text),
    wait(predicate, label, timeout) { return until(() => { if (failure) throw failure; return predicate(received); }, label, timeout); },
    async close() {
      if (!socket.destroyed) {
        closed = true;
        send(8, Buffer.from([3, 232]));
        await new Promise(resolve => { const timeout = setTimeout(() => { socket.destroy(); resolve(); }, 500); socket.once('close', () => { clearTimeout(timeout); resolve(); }); });
      }
    },
  };
}
