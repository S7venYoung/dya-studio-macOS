interface DYANativeEvent<T = unknown> {
  type: string;
  detail: T;
}

interface DYANativeBridge {
  readonly platform: "macOS";
  request<T = unknown>(method: string, params?: Record<string, unknown>): Promise<T>;
  addEventListener<T = unknown>(
    type: string,
    listener: (event: DYANativeEvent<T>) => void,
  ): void;
  removeEventListener<T = unknown>(
    type: string,
    listener: (event: DYANativeEvent<T>) => void,
  ): void;
}

interface Window {
  dyaNative?: DYANativeBridge;
}
