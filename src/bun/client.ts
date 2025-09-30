import {
  cancelFetch,
  connectClient,
  createClient,
  fetchStreaming,
  freeClient,
  type ClientConfigOptions,
  type ClientHandle,
  type FetchEventRecord,
  type FetchResult,
  type FetchOptions,
} from "./internal/ffi-client";

type RequestInfoLike = string | URL | Request;
type RequestInitLike = globalThis.RequestInit;

export interface H3ClientOptions extends ClientConfigOptions {
  authority?: string;
}

export interface H3FetchInit extends RequestInitLike {
  h3?: {
    /** Override path (defaults to URL pathname + search). */
    path?: string;
    /** Optional timeout override (ms). */
    requestTimeoutMs?: number;
  };
}

export interface H3ResponseMeta {
  streamId: bigint;
  trailers: Headers;
  events: FetchEventRecord[];
}

export type H3Response = Response & { readonly h3: H3ResponseMeta };

function toHeaders(pairs: Array<[string, string]>): Headers {
  const headers = new Headers();
  for (const [name, value] of pairs) {
    headers.append(name, value);
  }
  return headers;
}

function buildPath(url: URL, override?: string): string {
  if (override) return override;
  const path = url.pathname || "/";
  const search = url.search || "";
  return `${path}${search}`;
}

function ensureHttps(url: URL): void {
  if (url.protocol !== "https:" && url.protocol !== "http:"
      && url.protocol !== "h3:" && url.protocol !== "http3:") {
    throw new TypeError(`Unsupported protocol for HTTP/3 client: ${url.protocol}`);
  }
}

export class H3Client {
  readonly #handle: ClientHandle;
  #closed = false;
  #connectedKey: string | null = null;
  readonly #options: H3ClientOptions;

  constructor(options: H3ClientOptions = {}) {
    this.#options = options;
    this.#handle = createClient(options);
  }

  get closed(): boolean {
    return this.#closed;
  }

  close(): void {
    if (this.#closed) return;
    freeClient(this.#handle);
    this.#closed = true;
  }

  async fetch(input: RequestInfoLike, init: H3FetchInit = {}): Promise<H3Response> {
    if (this.#closed) {
      throw new Error("H3Client has been closed");
    }

    const requestSource = input instanceof URL ? input.toString() : input;
    const request = input instanceof Request
      ? input
      : new Request(String(requestSource), init as RequestInitLike);
    if (request.bodyUsed && request.body !== null) {
      throw new Error("Streaming request bodies are not yet supported over the FFI client");
    }
    if (init.body) {
      throw new Error("Request bodies are not yet supported by H3Client.fetch");
    }

    const url = new URL(request.url);
    ensureHttps(url);

    const port = url.port ? Number(url.port) : url.protocol === "http:" ? 80 : 443;
    const authority = this.#options.authority ?? url.hostname;
    const connectionKey = `${authority}:${port}`;
    if (this.#connectedKey !== connectionKey) {
      connectClient(this.#handle, url.hostname, port, authority);
      this.#connectedKey = connectionKey;
    }

    const path = buildPath(url, init.h3?.path);
    const timeoutOverride = init.h3?.requestTimeoutMs ?? this.#options.requestTimeoutMs;

    const fetchOptions: FetchOptions = {
      method: request.method,
      path,
      collectBody: true,
    };
    if (timeoutOverride !== undefined) {
      fetchOptions.requestTimeoutMs = timeoutOverride;
    }

    const result = fetchStreaming(this.#handle, fetchOptions);

    return this.#buildResponse(result);
  }

  cancel(streamId: bigint | number, errorCode = -503): void {
    cancelFetch(this.#handle, streamId, errorCode);
  }

  #buildResponse(result: FetchResult): H3Response {
    const headers = toHeaders(result.headers);
    const response = new Response(result.body, {
      status: result.status,
      headers,
    });
    const trailers = toHeaders(result.trailers);
    const meta: H3ResponseMeta = {
      streamId: result.streamId,
      trailers,
      events: result.events,
    };
    Object.defineProperty(response, "h3", {
      value: meta,
      enumerable: false,
      configurable: false,
      writable: false,
    });
    return response as H3Response;
  }
}

export async function h3Fetch(
  input: RequestInfoLike,
  init?: H3FetchInit,
  options?: H3ClientOptions,
): Promise<H3Response> {
  const client = new H3Client(options);
  try {
    return await client.fetch(input, init);
  } finally {
    client.close();
  }
}
