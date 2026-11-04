#!/usr/bin/env node
// Generate deployment secrets locally. Values are printed once for the operator
// to copy into the appropriate Railway service variables; they are never saved.
import { randomBytes } from "node:crypto";

const base64 = () => randomBytes(32).toString("base64");
const hex = () => randomBytes(32).toString("hex");

const values = {
  BETTER_AUTH_SECRET: base64(),
  SECRET_ENCRYPTION_KEY: base64(),
  GATEWAY_INTERNAL_SECRET: base64(),
  RUNNER_TOKEN: `rnr_${hex()}`,
  RUNNER_SESSION_KEY: `k1.${hex()}`,
  CHANNEL_ADAPTER_TOKEN: `cha_${hex()}`,
};

process.stdout.write(
  Object.entries(values)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n") + "\n",
);
