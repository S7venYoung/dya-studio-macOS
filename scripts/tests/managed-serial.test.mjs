// Run with Node 24: node --test scripts/tests/managed-serial.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
let source = readFileSync(
  new URL("../../src/lib/transport/managedSerial.ts", import.meta.url),
  "utf8",
);
source = source.replace(/import type[^;]+;/g, "").replace(
  /import \{[^}]+\} from "@cormoran\/zmk-studio-react-hook";/,
  `
const getPairedSerialPorts = async () => [];
const findRememberedSerialPort = () => null;
const rememberSerialPort = () => {};
`,
);
const { connectToSerialPort, releaseSerialConnections } = await import(
  "data:text/javascript;base64," +
    Buffer.from(stripTypeScriptTypes(source)).toString("base64")
);
const tick = () => new Promise((resolve) => setTimeout(resolve, 10));
function fakePort() {
  return {
    opens: 0,
    closes: 0,
    isOpen: false,
    async open() {
      assert.equal(this.isOpen, false, "cannot open an occupied port");
      this.isOpen = true;
      this.opens++;
      this.readable = new ReadableStream({
        start: (c) => {
          this.input = c;
        },
      });
      this.writable = new WritableStream({ write() {} });
    },
    getInfo: () => ({ usbVendorId: 1, usbProductId: 2 }),
    async close() {
      assert.equal(
        this.readable.locked,
        false,
        "read lock released before close",
      );
      assert.equal(
        this.writable.locked,
        false,
        "write lock released before close",
      );
      this.isOpen = false;
      this.closes++;
    },
  };
}
test("abort releases locked browser streams and allows immediate reconnect", async () => {
  const port = fakePort();
  const first = await connectToSerialPort(port);
  // Model RPC holding both returned stream locks during a failed handshake.
  const reader = first.readable.getReader();
  const writer = first.writable.getWriter();
  const pending = reader.read().catch(() => {});
  first.abortController.abort();
  const second = await connectToSerialPort(port);
  await pending;
  reader.releaseLock();
  writer.releaseLock();
  assert.equal(port.closes, 1);
  second.abortController.abort();
  await tick();
  assert.equal(port.closes, 2);
});
test("duplicate open while starting is rejected without a second open", async () => {
  const port = fakePort();
  const first = connectToSerialPort(port);
  await assert.rejects(connectToSerialPort(port), /already starting/);
  const transport = await first;
  transport.abortController.abort();
  await tick();
  assert.equal(port.opens, 1);
  assert.equal(port.closes, 1);
});
test("USB read error closes both pipes and port", async () => {
  const port = fakePort();
  await connectToSerialPort(port);
  port.input.error(new Error("USB unplugged"));
  await tick();
  assert.equal(port.isOpen, false);
  assert.equal(port.closes, 1);
});
test("pagehide cleanup is idempotent and releases every session", async () => {
  const a = fakePort(),
    b = fakePort();
  await connectToSerialPort(a);
  await connectToSerialPort(b);
  releaseSerialConnections();
  releaseSerialConnections();
  await tick();
  assert.equal(a.closes, 1);
  assert.equal(b.closes, 1);
});
test("normal end-of-stream releases the port", async () => {
  const port = fakePort();
  await connectToSerialPort(port);
  port.input.close();
  await tick();
  assert.equal(port.closes, 1);
});
test("open failure does not close a port owned elsewhere", async () => {
  const port = fakePort();
  port.open = async () => {
    throw new Error("already open");
  };
  await assert.rejects(connectToSerialPort(port), /already open/);
  assert.equal(port.closes, 0);
});
