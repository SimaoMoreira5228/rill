export declare function abiVersion(): number;

export declare function init(workers?: number): void;

export declare function shutdown(): void;

export declare function extractJsonSync(url: string, options?: string): string;

export declare function extractJson(url: string, options?: string): Promise<string>;

export declare enum DownloadState {
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

export interface RillError extends Error {
  code?: string;
}

export declare class Download {
  constructor(url: string, output: string, options?: string);

  poll(): DownloadProgress;

  cancel(): void;

  error(): string;

  errorCode(): string;

  close(): void;

  wait(intervalMs?: number): Promise<DownloadProgress>;

  waitSync(intervalMs?: number): DownloadProgress;
}
