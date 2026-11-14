import { CString, dlopen, FFIType, ptr } from "bun:ffi";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";

const libraryName =
  process.platform === "darwin"
    ? "librill.dylib"
    : process.platform === "win32"
      ? "rill.dll"
      : "librill.so";

const libraryPath =
  process.env.RILL_LIBRARY ?? join(import.meta.dir, "..", "..", "build", libraryName);

const workerPath = fileURLToPath(new URL("./extract-worker.ts", import.meta.url));

if (!existsSync(libraryPath)) {
  throw new Error(`Rill library not found at ${libraryPath}`);
}

const { symbols } = dlopen(libraryPath, {
  rill_abi_version: { args: [], returns: FFIType.i32 },
  rill_init: { args: [FFIType.usize], returns: FFIType.i32 },
  rill_shutdown: { args: [], returns: FFIType.i32 },
  rill_extract_json: {
    args: [FFIType.cstring, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr],
    returns: FFIType.i32,
  },
  rill_free_string: { args: [FFIType.ptr], returns: FFIType.void },
  rill_download_start: {
    args: [FFIType.cstring, FFIType.cstring, FFIType.ptr, FFIType.ptr],
    returns: FFIType.ptr,
  },
  rill_download_poll: {
    args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr],
    returns: FFIType.i32,
  },
  rill_download_error: { args: [FFIType.ptr], returns: FFIType.ptr },
  rill_download_error_code: { args: [FFIType.ptr], returns: FFIType.ptr },
  rill_download_cancel: { args: [FFIType.ptr], returns: FFIType.i32 },
  rill_download_free: { args: [FFIType.ptr], returns: FFIType.void },
});

export class RillError extends Error {
  readonly code: number;
  readonly kind?: string;

  constructor(code: number, message: string, kind?: string) {
    super(message);
    this.code = code;
    this.kind = kind;
  }
}

export enum DownloadState {
  Queued = 0,
  Running = 1,
  Completed = 2,
  Failed = 3,
  Cancelled = 4,
}

export interface DownloadProgress {
  state: DownloadState;
  downloaded: number;
  total: number;
}

function readString(pointer: number | bigint | null): string {
  if (pointer === null || Number(pointer) === 0) {
    return "";
  }

  return new CString(Number(pointer)).toString();
}

function freePointer(pointer: number | bigint | null): void {
  if (pointer !== null && Number(pointer) !== 0) {
    symbols.rill_free_string(Number(pointer));
  }
}

function optionsPointer(value?: string): Buffer | null {
  return value === undefined ? null : Buffer.from(`${value}\0`);
}

export function abiVersion(): number {
  return Number(symbols.rill_abi_version());
}

export function init(workers = 0): void {
  const status = Number(symbols.rill_init(workers));
  if (status !== 0) {
    throw new RillError(status, "rill_init failed");
  }
}

export function shutdown(): void {
  const status = Number(symbols.rill_shutdown());
  if (status !== 0) {
    throw new RillError(status, "rill_shutdown failed");
  }
}

export function extractJsonSync(url: string, options?: string): string {
  const jsonOut = new BigUint64Array(1);
  const errorOut = new BigUint64Array(1);
  const codeOut = new BigUint64Array(1);

  const status = Number(
    symbols.rill_extract_json(
      url,
      optionsPointer(options),
      ptr(jsonOut),
      ptr(errorOut),
      ptr(codeOut),
    ),
  );

  const json = readString(jsonOut[0]);
  const message = readString(errorOut[0]);
  const kind = readString(codeOut[0]);

  freePointer(jsonOut[0]);
  freePointer(errorOut[0]);
  freePointer(codeOut[0]);

  if (status !== 0) {
    throw new RillError(status, message || "extraction failed", kind || undefined);
  }

  return json;
}

export async function extractJson(url: string, options?: string): Promise<string> {
  return await new Promise((resolve, reject) => {
    const worker = new Worker(workerPath, {
      workerData: { url, options, libraryPath },
    });

    let settled = false;

    worker.once("message", (message) => {
      settled = true;

      if (message.ok) {
        resolve(message.json);
      } else {
        reject(
          new RillError(
            message.error.status ?? 2,
            message.error.message,
            message.error.kind,
          ),
        );
      }

      worker.terminate();
    });

    worker.once("error", (error) => {
      if (!settled) {
        settled = true;
        reject(new RillError(2, error instanceof Error ? error.message : String(error), "internal"));
      }
    });

    worker.once("exit", (code) => {
      if (!settled) {
        settled = true;
        reject(new RillError(2, `extraction worker exited with ${code}`, "internal"));
      }
    });
  });
}

export class Download {
  readonly #handle: number;

  constructor(url: string, output: string, options?: string) {
    const errorOut = new BigUint64Array(1);
    const handle = Number(
      symbols.rill_download_start(url, output, optionsPointer(options), ptr(errorOut)),
    );

    if (handle === 0) {
      const message = readString(errorOut[0]);
      freePointer(errorOut[0]);
      throw new RillError(2, message || "download start failed", "internal");
    }

    this.#handle = handle;
  }

  poll(): DownloadProgress {
    const stateOut = new Int32Array(1);
    const downloadedOut = new BigInt64Array(1);
    const totalOut = new BigInt64Array(1);

    const status = Number(
      symbols.rill_download_poll(
        this.#handle,
        ptr(stateOut),
        ptr(downloadedOut),
        ptr(totalOut),
      ),
    );

    if (status !== 0) {
      throw new RillError(status, "rill_download_poll failed");
    }

    return {
      state: stateOut[0] as DownloadState,
      downloaded: Number(downloadedOut[0]),
      total: Number(totalOut[0]),
    };
  }

  cancel(): void {
    const status = Number(symbols.rill_download_cancel(this.#handle));
    if (status !== 0) {
      throw new RillError(status, "rill_download_cancel failed");
    }
  }

  error(): string {
    const pointer = symbols.rill_download_error(this.#handle);
    const message = readString(pointer);
    freePointer(pointer);
    return message;
  }

  errorCode(): string {
    const pointer = symbols.rill_download_error_code(this.#handle);
    const code = readString(pointer);
    freePointer(pointer);
    return code;
  }

  async wait(intervalMs = 50): Promise<DownloadProgress> {
    while (true) {
      const progress = this.poll();
      if (
        progress.state === DownloadState.Completed ||
        progress.state === DownloadState.Failed ||
        progress.state === DownloadState.Cancelled
      ) {
        return progress;
      }

      await Bun.sleep(intervalMs);
    }
  }

  waitSync(intervalMs = 50): DownloadProgress {
    while (true) {
      const progress = this.poll();
      if (
        progress.state === DownloadState.Completed ||
        progress.state === DownloadState.Failed ||
        progress.state === DownloadState.Cancelled
      ) {
        return progress;
      }

      Bun.sleepSync(intervalMs);
    }
  }

  close(): void {
    symbols.rill_download_free(this.#handle);
  }
}
