import { connect as connectWebBluetooth } from "@zmkfirmware/zmk-studio-ts-client/transport/gatt";
import {
  connectBluetooth,
  isBluetoothConnectionAvailable,
  isNativeBluetoothAvailable,
} from "../bluetooth";

jest.mock("@zmkfirmware/zmk-studio-ts-client/transport/gatt", () => ({
  connect: jest.fn(),
}));

describe("Bluetooth transport selection", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    delete window.dyaNative;
  });

  test("uses Web Bluetooth in a browser", async () => {
    await connectBluetooth();
    expect(connectWebBluetooth).toHaveBeenCalledTimes(1);
  });

  test("reports the macOS native bridge as Bluetooth-capable", () => {
    window.dyaNative = { platform: "macOS" } as DYANativeBridge;
    expect(isNativeBluetoothAvailable()).toBe(true);
    expect(isBluetoothConnectionAvailable()).toBe(true);
  });

  test("creates a stream transport through the native bridge", async () => {
    const listeners = new Map<string, (event: DYANativeEvent) => void>();
    const request = jest.fn(async (method: string) => {
      if (method === "ble.connect") return { label: "DYA BLE" };
      return true;
    });
    window.dyaNative = {
      platform: "macOS",
      request,
      addEventListener: (type, listener) => listeners.set(type, listener),
      removeEventListener: (type) => listeners.delete(type),
    };

    const transport = await connectBluetooth();
    expect(transport.label).toBe("DYA BLE");
    expect(request).toHaveBeenCalledWith("ble.connect");

    const reader = transport.readable.getReader();
    listeners.get("ble-data")?.({
      type: "ble-data",
      detail: { base64: btoa("abc") },
    });
    await expect(reader.read()).resolves.toEqual({
      done: false,
      value: new Uint8Array([97, 98, 99]),
    });

    const writer = transport.writable.getWriter();
    await writer.write(new Uint8Array([1, 2, 3]));
    expect(request).toHaveBeenCalledWith("ble.write", { base64: "AQID" });

    transport.abortController.abort();
    expect(request).toHaveBeenCalledWith("ble.disconnect");
  });
});
