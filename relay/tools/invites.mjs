#!/usr/bin/env node
// The relay owner's invite tool (docs/superpowers/specs/2026-11-25-relay-invites-and-pool-design.md).
//
//   node tools/invites.mjs create "<name>" [--machines N] [--owner]   prints the code once
//   node tools/invites.mjs list
//   node tools/invites.mjs revoke <id>
//   node tools/invites.mjs pool
//
// The relay's address comes from RELAY_URL (else relay/.relay-url); the admin token from
// RELAY_ADMIN_TOKEN (else relay/.admin-token). Both files are git-ignored.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

function setting(env, file) {
  if (process.env[env]) return process.env[env].trim();
  try {
    return readFileSync(join(here, "..", file), "utf8").trim();
  } catch {
    console.error(`Set ${env} or write relay/${file}.`);
    process.exit(2);
  }
}

const relay = setting("RELAY_URL", ".relay-url").replace(/\/+$/, "");
const token = setting("RELAY_ADMIN_TOKEN", ".admin-token");

async function call(method, path, body) {
  const r = await fetch(`${relay}/admin/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    console.error(`The relay answered ${r.status}: ${JSON.stringify(j)}`);
    process.exit(1);
  }
  return j;
}

const [cmd, ...args] = process.argv.slice(2);
const flag = (name) => args.includes(name);
const value = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};

if (cmd === "create" && args[0] && !args[0].startsWith("--")) {
  const j = await call("POST", "invites", {
    name: args[0],
    machines: value("--machines") ? Number(value("--machines")) : undefined,
    owner: flag("--owner"),
  });
  console.log(`Invite ${j.id} for ${j.name}: ${j.machines} machine(s)${j.owner ? ", owner (exempt from the pool)" : ""}.`);
  console.log(`Code (shown only now): ${j.code}`);
} else if (cmd === "list") {
  const { invites } = await call("GET", "invites");
  if (invites.length === 0) console.log("No invites yet.");
  for (const i of invites) {
    const state = i.revoked ? "revoked" : i.owner ? "owner" : `${i.used} of ${i.machines} machines`;
    console.log(`${i.id}  ${i.name.padEnd(20)} ${state}  (made ${new Date(i.createdAt).toISOString().slice(0, 10)})`);
  }
} else if (cmd === "revoke" && args[0]) {
  await call("POST", `invites/${args[0]}/revoke`);
  console.log(`Invite ${args[0]} revoked: its machines are refused from their next connection.`);
} else if (cmd === "pool") {
  const p = await call("GET", "pool");
  const pct = Math.round((p.used / p.limit) * 100);
  console.log(`Shared pool ${p.day}: ${p.used.toLocaleString("en")} of ${p.limit.toLocaleString("en")} units (${pct}%)${p.shut ? ", used up: friends' machines are paused until 00:00 UTC" : ""}.`);
} else {
  console.log('Usage: node tools/invites.mjs create "<name>" [--machines N] [--owner] | list | revoke <id> | pool');
  process.exit(cmd ? 2 : 0);
}
