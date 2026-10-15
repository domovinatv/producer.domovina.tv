#!/usr/bin/env node
// Multicam režija iz terminala: tko je spojen, start/stop, preuzimanje snimki.
// Protokol: PROTOCOL.md. Ključ se čita iz ~/.config/domovina-multicam/key.
//
//   node multicam/director.mjs join [ime]          URL (i QR) za spajanje telefona
//   node multicam/director.mjs watch               prati kamere uživo
//   node multicam/director.mjs start <sessionId>   pokreni snimanje na svim kamerama
//   node multicam/director.mjs stop                zaustavi
//   node multicam/director.mjs wait-uploaded <sessionId> <n> [timeoutS]
//   node multicam/director.mjs pull <sessionId> <dir>
//   node multicam/director.mjs fake-camera <ime> [MB]   lažna kamera za test relaya

import { readFileSync, mkdirSync, createWriteStream, existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { randomBytes, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";

const RELAY = process.env.MULTICAM_RELAY ?? "https://domovina-multicam-relay.d-o-m.workers.dev";
const ROOM = process.env.MULTICAM_ROOM ?? "studio";
const KEY = process.env.MULTICAM_KEY ?? readFileSync(join(homedir(), ".config/domovina-multicam/key"), "utf8").trim();
const auth = { authorization: `Bearer ${KEY}` };

function connect(role, id = randomUUID()) {
	const ws = new WebSocket(`${RELAY.replace(/^http/, "ws")}/v1/rooms/${ROOM}/ws?role=${role}&id=${id}&key=${KEY}`);
	const opened = new Promise((ok, fail) => {
		ws.addEventListener("open", ok, { once: true });
		ws.addEventListener("error", () => fail(new Error("websocket error")), { once: true });
	});
	ws.sendJSON = (m) => ws.send(JSON.stringify(m));
	ws.onJSON = (fn) => ws.addEventListener("message", (e) => fn(JSON.parse(e.data)));
	return { ws, opened };
}

const fmt = (c) => {
	const s = c.status ?? {};
	const up = s.upload ? ` upload ${Math.round((100 * s.upload.bytesDone) / Math.max(1, s.upload.bytesTotal))}%` : "";
	const bat = s.battery != null ? ` 🔋${Math.round(s.battery * 100)}%${s.charging ? "⚡" : ""}` : "";
	const free = s.freeBytes != null ? ` ${(s.freeBytes / 1e9).toFixed(1)} GB` : "";
	const rec = s.recordingSeconds != null && s.state === "recording" ? ` ${s.recordingSeconds.toFixed(0)}s` : "";
	return `  ${(c.name ?? c.id).padEnd(24)} ${(c.platform ?? "?").padEnd(8)} ${(s.state ?? "—").padEnd(10)}${rec}${up}${bat}${free}${s.error ? " ⚠️ " + s.error : ""}`;
};

async function director(onMessage) {
	const { ws, opened } = connect("director");
	await opened;
	ws.onJSON(onMessage);
	return ws;
}

async function uploadFile(path, sessionId, camera, file) {
	const size = statSync(path).size;
	const create = await (await fetch(`${RELAY}/v1/upload/create`, { method: "POST", headers: auth, body: JSON.stringify({ sessionId, camera, file }) })).json();
	const buf = readFileSync(path);
	const parts = [];
	for (let n = 1, off = 0; off < size; n++, off += create.partSize) {
		const body = buf.subarray(off, Math.min(size, off + create.partSize));
		const q = new URLSearchParams({ objectKey: create.objectKey, uploadId: create.uploadId, part: String(n) });
		const r = await fetch(`${RELAY}/v1/upload/part?${q}`, { method: "PUT", headers: auth, body });
		if (!r.ok) throw new Error(`part ${n}: ${r.status} ${await r.text()}`);
		parts.push(await r.json());
	}
	const done = await (await fetch(`${RELAY}/v1/upload/complete`, { method: "POST", headers: auth, body: JSON.stringify({ objectKey: create.objectKey, uploadId: create.uploadId, parts }) })).json();
	if (done.size !== size) throw new Error(`size mismatch ${done.size} != ${size}`);
	return done.objectKey;
}

const [cmd, ...args] = process.argv.slice(2);
switch (cmd) {
	case "join": {
		const q = new URLSearchParams({ relay: RELAY, room: ROOM, key: KEY });
		if (args[0]) q.set("name", args[0]);
		const url = `domovinacam://join?${q}`;
		console.log(url);
		try {
			execFileSync("qrencode", ["-t", "ANSIUTF8", url], { stdio: ["ignore", "inherit", "ignore"] });
		} catch {}
		break;
	}
	case "watch": {
		await director((m) => {
			if (m.type === "cameras") {
				console.clear();
				console.log(`Soba ${ROOM} — ${m.cameras.length} kamera${m.take ? `, SNIMA ${m.take.sessionId}/${m.take.takeId}` : ""}`);
				m.cameras.forEach((c) => console.log(fmt(c)));
			} else console.log(new Date().toISOString(), JSON.stringify(m));
		});
		break;
	}
	case "status": {
		const ws = await director((m) => {
			if (m.type !== "cameras") return;
			console.log(JSON.stringify(m, null, 2));
			ws.close();
		});
		break;
	}
	case "start":
	case "stop": {
		const sessionId = args[0] ?? new Date().toISOString().slice(0, 16).replace(/[T:]/g, "-");
		const ws = await director(() => {});
		ws.sendJSON(cmd === "start" ? { type: "start", sessionId, takeId: args[1] ?? sessionId } : { type: "stop", takeId: args[0] ?? "" });
		console.log(cmd === "start" ? `▶️  start ${sessionId}` : "⏹  stop");
		setTimeout(() => ws.close(), 500);
		break;
	}
	case "wait-uploaded": {
		// Nema tihog čekanja: ispisuje samo događaje, završava kad n kamera javi upload.
		const [sessionId, n, timeout = "1800"] = args;
		const seen = new Set();
		const ws = await director((m) => {
			if (m.type === "uploaded" && m.sessionId === sessionId) {
				seen.add(m.objectKeys[0]?.split("/")[2] ?? m.cameraId);
				console.log(`✅ ${m.cameraName}: ${m.objectKeys.join(", ")}`);
				if (new Set([...seen].map((k) => k.replace(/^r2:/, ""))).size >= Number(n)) ws.close();
			}
			if (m.type === "cameras") for (const c of m.cameras) if (c.status?.state === "error") console.log(`⚠️  ${c.name}: ${c.status.error}`);
		});
		// Telefon koji je uploadao prije nego se režija spojila ne pošalje više
		// događaj — zato se broje i kamere koje već imaju sidecar u R2.
		const poll = async () => {
			const r = await fetch(`${RELAY}/v1/list?prefix=multicam/${sessionId}/`, { headers: auth });
			const { objects = [] } = await r.json();
			for (const o of objects) {
				const cam = o.key.split("/")[2];
				if (o.key.endsWith(".json") && !seen.has(`r2:${cam}`)) {
					seen.add(`r2:${cam}`);
					console.log(`✅ ${cam}: ${o.key} (već u R2)`);
				}
			}
			const cams = new Set([...seen].map((k) => k.replace(/^r2:/, "")));
			if (cams.size >= Number(n)) process.exit(0);
		};
		poll();
		setInterval(poll, 15000);
		setTimeout(() => {
			console.log(`⏱  timeout, ${seen.size}/${n}`);
			process.exit(1);
		}, Number(timeout) * 1000);
		ws.addEventListener("close", () => process.exit(0));
		break;
	}
	case "pull": {
		const [sessionId, dir] = args;
		const { objects } = await (await fetch(`${RELAY}/v1/list?prefix=multicam/${sessionId}/`, { headers: auth })).json();
		for (const o of objects) {
			const dest = join(dir, o.key.split("/").slice(2).join("/"));
			if (existsSync(dest) && statSync(dest).size === o.size) continue;
			mkdirSync(dirname(dest), { recursive: true });
			const r = await fetch(`${RELAY}/v1/object?objectKey=${encodeURIComponent(o.key)}`, { headers: auth });
			await pipeline(Readable.fromWeb(r.body), createWriteStream(dest));
			console.log(`⬇️  ${dest} (${(o.size / 1e6).toFixed(1)} MB)`);
		}
		if (!objects.length) console.log("Nema ničega pod tim sessionId.");
		break;
	}
	case "fake-camera": {
		const [name = "fake", mb = "1"] = args;
		const id = `fake-${name}`;
		const { ws, opened } = connect("camera", id);
		await opened;
		ws.sendJSON({ type: "hello", id, name, platform: "node", model: "fake", os: process.version, app: "director.mjs" });
		let state = { state: "idle" };
		const status = () => ws.sendJSON({ type: "status", ...state, battery: 1, charging: true, freeBytes: 1e11 });
		status();
		setInterval(status, 2000);
		let take;
		ws.onJSON(async (m) => {
			if (m.type === "start" && take?.takeId !== m.takeId) {
				take = { ...m, t0: Date.now() };
				state = { state: "recording", takeId: m.takeId, recordingSeconds: 0 };
				ws.sendJSON({ type: "recordingStarted", sessionId: m.sessionId, takeId: m.takeId, file: `${m.takeId}.bin`, wallClockMs: Date.now() });
				status();
			}
			if (m.type === "stop" && take && state.state === "recording") {
				const path = `/tmp/${id}.bin`;
				const bytes = Number(mb) * 1024 * 1024;
				execFileSync("dd", ["if=/dev/urandom", `of=${path}`, "bs=1048576", `count=${mb}`], { stdio: "ignore" });
				ws.sendJSON({ type: "recordingStopped", sessionId: take.sessionId, takeId: take.takeId, file: `${take.takeId}.bin`, durationSeconds: (Date.now() - take.t0) / 1000, bytes });
				state = { state: "uploading", takeId: take.takeId, upload: { bytesDone: 0, bytesTotal: bytes } };
				status();
				const key = await uploadFile(path, take.sessionId, name, `${take.takeId}.bin`);
				ws.sendJSON({ type: "uploaded", sessionId: take.sessionId, takeId: take.takeId, objectKeys: [key] });
				state = { state: "idle" };
				status();
				take = undefined;
			}
		});
		break;
	}
	default:
		console.log(readFileSync(new URL(import.meta.url)).toString().split("\n").slice(1, 12).join("\n"));
}
