import type { RpcTransport } from "@zmkfirmware/zmk-studio-ts-client/transport/index";
import { connect as connectWebBluetooth } from "@zmkfirmware/zmk-studio-ts-client/transport/gatt";

type BluetoothDataEvent = DYANativeEvent<{ base64: string }>;

function decodeBase64(value: string) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function encodeBase64(value: Uint8Array) {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function isNativeBluetoothAvailable() {
  return window.dyaNative?.platform === "macOS";
}

export function isBluetoothConnectionAvailable() {
  return isNativeBluetoothAvailable() || "bluetooth" in navigator;
}

export async function connectBluetooth(): Promise<RpcTransport> {
  if (!isNativeBluetoothAvailable()) return connectWebBluetooth();

  const bridge = window.dyaNative;
  if (!bridge) throw new Error("The macOS native bridge is unavailable");

  const device = await bridge.request<{ label: string }>("ble.connect");
  const abortController = new AbortController();
  let streamController: ReadableStreamDefaultController<Uint8Array> | undefined;

  const onData = (event: BluetoothDataEvent) => {
    streamController?.enqueue(decodeBase64(event.detail.base64));
  };
  const onDisconnect = () => {
    streamController?.close();
    if (!abortController.signal.aborted) {
      abortController.abort("Bluetooth device disconnected");
    }
  };

  bridge.addEventListener("ble-data", onData);
  bridge.addEventListener("ble-disconnect", onDisconnect);

  const cleanup = () => {
    bridge.removeEventListener("ble-data", onData);
    bridge.removeEventListener("ble-disconnect", onDisconnect);
    void bridge.request("ble.disconnect").catch(() => undefined);
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
        abortController.abort("Bluetooth stream cancelled");
      },
    }),
    writable: new WritableStream<Uint8Array>({
      async write(chunk) {
        await bridge.request("ble.write", { base64: encodeBase64(chunk) });
      },
      close() {
        abortController.abort("Bluetooth stream closed");
      },
      abort(reason) {
        abortController.abort(reason);
      },
    }),
  };
}
