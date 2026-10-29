import type { RpcTransport } from "@zmkfirmware/zmk-studio-ts-client/transport/index";
import {
  findRememberedSerialPort,
  getPairedSerialPorts,
  rememberSerialPort,
} from "@cormoran/zmk-studio-react-hook";

type SerialPort = Parameters<typeof rememberSerialPort>[0];

// Own both pipe promises: aborting a locked browser stream directly rejects.
// pipeTo releases its locks before settling, so close the port only afterwards.
const sessions = new Map<
  SerialPort,
  { abort: () => void; closed: Promise<void> }
>();
const opening = new Set<SerialPort>();

export async function connectToSerialPort(
  port: SerialPort,
): Promise<RpcTransport> {
  if (opening.has(port))
    throw new Error("A serial connection is already starting.");
  opening.add(port);
  try {
    const previous = sessions.get(port);
    if (previous) {
      previous.abort();
      await previous.closed;
    }
    await port.open({ baudRate: 12500 });
    const abortController = new AbortController();
    const signal = abortController.signal;
    let finished = false;
    let closing: Promise<void> | undefined;
    const pipes: Promise<void>[] = [];
    const cleanup = () => {
      if (!closing) {
        closing = Promise.resolve()
          .then(async () => {
            await Promise.allSettled(pipes);
            await port.close();
          })
          .finally(() => {
            finished = true;
            sessions.delete(port);
          });
        abortController.abort();
      }
      return closing;
    };
    try {
      if (!port.readable || !port.writable)
        throw new Error("Serial streams unavailable.");
      const incoming = new TransformStream<Uint8Array, Uint8Array>();
      const outgoing = new TransformStream<Uint8Array, Uint8Array>();
      pipes.push(port.readable.pipeTo(incoming.writable, { signal }));
      pipes.push(outgoing.readable.pipeTo(port.writable, { signal }));
      // Observe failures immediately; a USB unplug must close the other pipe too.
      for (const pipe of pipes)
        void pipe.then(cleanup, cleanup).catch(() => {});
      signal.addEventListener(
        "abort",
        () => {
          void cleanup().catch(() => {});
        },
        { once: true },
      );
      // Keep a completion promise available before the next connection attempt.
      let resolveClosed!: () => void;
      let rejectClosed!: (reason: unknown) => void;
      const closed = new Promise<void>((resolve, reject) => {
        resolveClosed = resolve;
        rejectClosed = reject;
      });
      void closed.catch(() => {});
      sessions.set(port, {
        abort: () => {
          void cleanup().then(resolveClosed, rejectClosed);
        },
        closed,
      });
      signal.addEventListener(
        "abort",
        () => {
          void cleanup().then(resolveClosed, rejectClosed);
        },
        { once: true },
      );
      const info = port.getInfo();
      return {
        label: `${info.usbVendorId ?? ""}:${info.usbProductId ?? ""}`,
        abortController,
        readable: incoming.readable,
        writable: outgoing.writable,
      };
    } catch (error) {
      if (!finished) await cleanup();
      throw error;
    }
  } finally {
    opening.delete(port);
  }
}

export function releaseSerialConnections() {
  for (const session of sessions.values()) session.abort();
}

export async function connectSerial(): Promise<RpcTransport> {
  const serial = (
    navigator as Navigator & { serial?: { requestPort(): Promise<SerialPort> } }
  ).serial;
  if (!serial)
    throw new Error("Web Serial API is not available in this browser.");
  const port = await serial.requestPort();
  const transport = await connectToSerialPort(port);
  try {
    rememberSerialPort(port, await getPairedSerialPorts());
  } catch {
    /* Remembering a port must not leak or discard a working connection. */
  }
  return transport;
}

export async function connectToPairedSerial(): Promise<RpcTransport | null> {
  const ports = await getPairedSerialPorts();
  if (!ports.length) return null;
  const port = findRememberedSerialPort(ports) ?? ports[0];
  const transport = await connectToSerialPort(port);
  try {
    rememberSerialPort(port, ports);
  } catch {
    /* Port preference storage is optional. */
  }
  return transport;
}
