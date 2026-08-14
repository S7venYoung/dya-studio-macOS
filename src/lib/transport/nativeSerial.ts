import type { RpcTransport } from "@zmkfirmware/zmk-studio-ts-client/transport/index";

type SerialDataEvent = DYANativeEvent<{ base64: string }>;

function decodeBase64(value: string) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function encodeBase64(value: Uint8Array) {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function isNativeSerialAvailable() {
  return window.dyaNative?.platform === "macOS";
}

export async function connectNativeSerial(): Promise<RpcTransport> {
  const bridge = window.dyaNative;
  if (!bridge) throw new Error("The macOS native bridge is unavailable");

  const device = await bridge.request<{ label: string }>("serial.connect");
  const abortController = new AbortController();
  let streamController: ReadableStreamDefaultController<Uint8Array> | undefined;

  const onData = (event: SerialDataEvent) => {
    streamController?.enqueue(decodeBase64(event.detail.base64));
  };
  const onDisconnect = () => {
    streamController?.close();
    abortController.abort("Serial device disconnected");
  };

  bridge.addEventListener("serial-data", onData);
  bridge.addEventListener("serial-disconnect", onDisconnect);

  const cleanup = () => {
    bridge.removeEventListener("serial-data", onData);
    bridge.removeEventListener("serial-disconnect", onDisconnect);
    void bridge.request("serial.disconnect").catch(() => undefined);
  };
  abortController.signal.addEventListener("abort", cleanup, { once: true });

  return {
    label: device.label,
    abortController,
    readable: new ReadableStream<Uint8Array>({
      start(controller) {
        streamController = controller;
      },
      cancel() {
        abortController.abort("Serial stream cancelled");
      },
    }),
    writable: new WritableStream<Uint8Array>({
      async write(chunk) {
        await bridge.request("serial.write", { base64: encodeBase64(chunk) });
      },
      close() {
        abortController.abort("Serial stream closed");
      },
      abort(reason) {
        abortController.abort(reason);
      },
    }),
  };
}
