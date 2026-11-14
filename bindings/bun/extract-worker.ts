import { parentPort, workerData } from "node:worker_threads";

if (workerData.libraryPath) {
  process.env.RILL_LIBRARY = workerData.libraryPath;
}

const { extractJsonSync, RillError } = await import("./index.ts");

try {
  parentPort?.postMessage({
    ok: true,
    json: extractJsonSync(workerData.url, workerData.options),
  });
} catch (error) {
  const rillError = error as RillError;
  parentPort?.postMessage({
    ok: false,
    error: {
      message: rillError.message,
      code: rillError.code,
      kind: rillError.kind,
    },
  });
}
