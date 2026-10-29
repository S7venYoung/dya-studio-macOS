# Web Serial release fix

Browser USB connections now use an app-owned serial transport for both the
picker and automatic reconnect. It owns both `pipeTo` promises and aborts them
before waiting for their locks to release and calling `SerialPort.close()`.
Cleanup is idempotent, also runs on stream termination and `pagehide`, and a
replacement connection waits for the previous close. Concurrent opens of the
same port and duplicate Connect clicks are rejected/ignored.

Run the dependency-free regression suite with Node 24:

```sh
node --test scripts/tests/managed-serial.test.mjs
```

The tests execute the production transport with real WHATWG streams and a fake
serial port which rejects closing while locked. They cover locked-stream abort
and immediate reconnect, concurrent open, USB read error, page cleanup, normal
end-of-stream, and open failure without closing another owner's port.

This does not update the official DYA hosted site. Browser termination can stop
asynchronous page cleanup, so actual tab-close/reopen acceptance still needs a
browser and scanner. No scanner settings, pairing, or firmware are modified.
