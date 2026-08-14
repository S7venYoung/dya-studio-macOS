import type { RpcTransport } from "@zmkfirmware/zmk-studio-ts-client/transport/index";
import {
  connectSerial,
  isWebSerialSupported,
} from "@cormoran/zmk-studio-react-hook";
import { connect as connectWebUsb } from "./webUsb";
import {
  connectNativeSerial,
  isNativeSerialAvailable,
} from "./nativeSerial";

export function shouldUseWebUsbForUsbConnection(
  userAgent = navigator.userAgent,
) {
  return /\bAndroid\b/i.test(userAgent) && /\bChrome\//i.test(userAgent);
}

export function isUsbConnectionAvailable() {
  return (
    isNativeSerialAvailable() ||
    isWebSerialSupported() ||
    (shouldUseWebUsbForUsbConnection() && "usb" in navigator)
  );
}

export async function connect(): Promise<RpcTransport> {
  if (isNativeSerialAvailable()) {
    return connectNativeSerial();
  }
  if (shouldUseWebUsbForUsbConnection()) {
    return connectWebUsb();
  }
  return connectSerial();
}
