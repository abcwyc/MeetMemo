#!/usr/bin/env node

const DEFAULT_BASE_URL = "https://ark.cn-beijing.volces.com/api/coding";
const DEFAULT_TIMEOUT_MS = 15000;
const REQUIRED_HOST = "ark.cn-beijing.volces.com";
const REQUIRED_PATH = "/api/coding";

function printUsage() {
  console.log(`Usage:
  VOLCENGINE_API_KEY=... VOLCENGINE_BASE_URL=... VOLCENGINE_MODEL=... node scripts/test_volcengine.mjs

  node scripts/test_volcengine.mjs --api-key <key> --base-url <url> --model <model>

Options:
  --api-key, -k   Volcano Ark API key
  --base-url, -u  Base URL, defaults to ${DEFAULT_BASE_URL}
  --model, -m     Model or endpoint id
  --timeout       Timeout in milliseconds, defaults to ${DEFAULT_TIMEOUT_MS}
  --help, -h      Show this help message
`);
}

function parseArgs(argv) {
  const result = {};

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (!token.startsWith("-")) {
      continue;
    }

    switch (token) {
      case "--api-key":
      case "-k":
        result.apiKey = argv[++index];
        break;
      case "--base-url":
      case "-u":
        result.baseURL = argv[++index];
        break;
      case "--model":
      case "-m":
        result.model = argv[++index];
        break;
      case "--timeout":
        result.timeoutMs = Number(argv[++index]);
        break;
      case "--help":
      case "-h":
        result.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${token}`);
    }
  }

  return result;
}

function normalizeBaseURL(rawValue) {
  const value = (rawValue ?? "").trim();
  if (!value) {
    return DEFAULT_BASE_URL;
  }

  return value.replace(/\/+$/, "");
}

function validateBaseURL(baseURL) {
  let url;

  try {
    url = new URL(baseURL);
  } catch {
    throw new Error(`Invalid URL: ${baseURL}`);
  }

  if (url.protocol !== "https:") {
    throw new Error("Base URL must use https");
  }

  if (url.hostname.toLowerCase() !== REQUIRED_HOST) {
    throw new Error(`Base URL host must be ${REQUIRED_HOST}`);
  }

  const path = url.pathname.replace(/\/+$/, "");
  if (path.toLowerCase() !== REQUIRED_PATH) {
    throw new Error(`Base URL path must be ${REQUIRED_PATH}`);
  }

  return url;
}

function getEnvOrArg(envValue, argValue) {
  return (envValue ?? argValue ?? "").trim();
}

function summarizeResponse(text) {
  const trimmed = text.trim();
  if (!trimmed) {
    return "<empty body>";
  }

  try {
    const json = JSON.parse(trimmed);

    if (json?.error) {
      const error = json.error;
      if (typeof error === "string") {
        return error;
      }
      if (typeof error.message === "string" && error.message.trim()) {
        return error.message.trim();
      }
    }

    const content = [];

    if (Array.isArray(json?.content)) {
      for (const item of json.content) {
        if (typeof item?.text === "string" && item.text.trim()) {
          content.push(item.text.trim());
        } else if (typeof item?.content === "string" && item.content.trim()) {
          content.push(item.content.trim());
        }
      }
    }

    if (content.length > 0) {
      return content.join("\n");
    }

    if (typeof json?.completion === "string" && json.completion.trim()) {
      return json.completion.trim();
    }

    if (typeof json?.message?.content === "string" && json.message.content.trim()) {
      return json.message.content.trim();
    }

    return JSON.stringify(json, null, 2);
  } catch {
    return trimmed;
  }
}

async function main() {
  const argv = parseArgs(process.argv.slice(2));

  if (argv.help) {
    printUsage();
    return;
  }

  const apiKey = getEnvOrArg(process.env.VOLCENGINE_API_KEY, argv.apiKey);
  const model = getEnvOrArg(process.env.VOLCENGINE_MODEL, argv.model);
  const baseURL = normalizeBaseURL(
    getEnvOrArg(process.env.VOLCENGINE_BASE_URL, argv.baseURL) || DEFAULT_BASE_URL
  );
  const timeoutMs = Number.isFinite(argv.timeoutMs) && argv.timeoutMs > 0
    ? argv.timeoutMs
    : DEFAULT_TIMEOUT_MS;

  if (!apiKey || !model) {
    printUsage();
    process.exitCode = 1;
    return;
  }

  const parsedBaseURL = validateBaseURL(baseURL);
  const requestURL = new URL("/messages", parsedBaseURL).toString();
  const requestBody = {
    model,
    messages: [
      {
        role: "user",
        content: "ping",
      },
    ],
    max_tokens: 1,
    stream: false,
  };

  const controller = new AbortController();
  const timeoutHandle = setTimeout(() => {
    controller.abort(new Error(`Request timed out after ${timeoutMs}ms`));
  }, timeoutMs);

  const startedAt = Date.now();

  try {
    const response = await fetch(requestURL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(requestBody),
      signal: controller.signal,
    });

    const responseText = await response.text();
    const elapsedMs = Date.now() - startedAt;

    console.log(`Request URL: ${requestURL}`);
    console.log(`Model: ${model}`);
    console.log(`HTTP Status: ${response.status} ${response.statusText}`);
    console.log(`Elapsed: ${elapsedMs}ms`);

    if (!response.ok) {
      console.error("\nRequest failed:");
      console.error(summarizeResponse(responseText));
      process.exitCode = 1;
      return;
    }

    console.log("\nRequest succeeded.");
    console.log("Response preview:");
    console.log(summarizeResponse(responseText));
  } catch (error) {
    console.error("\nRequest failed:");
    if (error instanceof Error) {
      console.error(error.message);
    } else {
      console.error(String(error));
    }
    process.exitCode = 1;
  } finally {
    clearTimeout(timeoutHandle);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
