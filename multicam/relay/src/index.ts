// Multicam relay: a control room for phone cameras plus an upload path into R2.
// Protocol: ../../PROTOCOL.md. The relay never carries media in real time — phones
// record locally and upload after stop — so it only has to be reliable, not fast.

import { DurableObject } from "cloudflare:workers";

interface Env {
	ROOM: DurableObjectNamespace<Room>;
	BUCKET: R2Bucket;
	MULTICAM_KEY: string;
}

const PART_SIZE = 32 * 1024 * 1024;

const json = (body: unknown, status = 200) =>
	new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// Object keys are built here, never taken whole from the client, so a phone cannot
// write outside multicam/.
const segment = (s: string | null | undefined) => {
	const clean = (s ?? "").normalize("NFKD").replace(/[^\w.-]+/g, "-").replace(/^[-.]+|-+$/g, "");
	if (!clean) throw new Error("empty path segment");
	return clean.slice(0, 80);
};
const objectKey = (sessionId: string, camera: string, file: string) =>
	`multicam/${segment(sessionId)}/${segment(camera)}/${segment(file)}`;
const checkKey = (key: string | null) => {
	if (!key?.startsWith("multicam/") || key.includes("..")) throw new Error("bad objectKey");
	return key;
};

export default {
	async fetch(request, env): Promise<Response> {
		const url = new URL(request.url);
		const auth = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? url.searchParams.get("key");
		if (!env.MULTICAM_KEY || auth !== env.MULTICAM_KEY) return json({ error: "unauthorized" }, 401);

		try {
			const room = url.pathname.match(/^\/v1\/rooms\/([\w-]{1,64})\/ws$/);
			if (room) {
				if (request.headers.get("upgrade") !== "websocket") return json({ error: "expected websocket" }, 426);
				return env.ROOM.get(env.ROOM.idFromName(room[1])).fetch(request);
			}

			switch (`${request.method} ${url.pathname}`) {
				case "POST /v1/upload/create": {
					const b = await request.json<{ sessionId: string; camera: string; file: string }>();
					const key = objectKey(b.sessionId, b.camera, b.file);
					const upload = await env.BUCKET.createMultipartUpload(key);
					return json({ objectKey: key, uploadId: upload.uploadId, partSize: PART_SIZE });
				}
				case "PUT /v1/upload/part": {
					const key = checkKey(url.searchParams.get("objectKey"));
					const part = Number(url.searchParams.get("part"));
					if (!Number.isInteger(part) || part < 1 || part > 10000) return json({ error: "bad part" }, 400);
					if (!request.body) return json({ error: "empty body" }, 400);
					const upload = env.BUCKET.resumeMultipartUpload(key, url.searchParams.get("uploadId")!);
					// R2 needs the length up front; a streamed body without one is rejected.
					const length = Number(request.headers.get("content-length"));
					const body = length > 0 ? request.body.pipeThrough(new FixedLengthStream(length)) : await request.arrayBuffer();
					const uploaded = await upload.uploadPart(part, body);
					return json({ partNumber: uploaded.partNumber, etag: uploaded.etag });
				}
				case "POST /v1/upload/complete": {
					const b = await request.json<{ objectKey: string; uploadId: string; parts: R2UploadedPart[] }>();
					const upload = env.BUCKET.resumeMultipartUpload(checkKey(b.objectKey), b.uploadId);
					const done = await upload.complete([...b.parts].sort((a, c) => a.partNumber - c.partNumber));
					return json({ objectKey: done.key, size: done.size });
				}
				case "PUT /v1/object": {
					const p = url.searchParams;
					const key = objectKey(p.get("sessionId")!, p.get("camera")!, p.get("file")!);
					const obj = await env.BUCKET.put(key, await request.arrayBuffer());
					return json({ objectKey: key, size: obj?.size });
				}
				case "GET /v1/object": {
					const obj = await env.BUCKET.get(checkKey(url.searchParams.get("objectKey")));
					if (!obj) return json({ error: "not found" }, 404);
					return new Response(obj.body, { headers: { "content-length": String(obj.size) } });
				}
				case "GET /v1/list": {
					const prefix = checkKey(url.searchParams.get("prefix"));
					const listed = await env.BUCKET.list({ prefix, limit: 1000 });
					return json({ objects: listed.objects.map((o) => ({ key: o.key, size: o.size, uploaded: o.uploaded })) });
				}
			}
			return json({ error: "not found" }, 404);
		} catch (e) {
			return json({ error: String(e) }, 400);
		}
	},
} satisfies ExportedHandler<Env>;

type Role = "camera" | "director";
interface Peer {
	role: Role;
	id: string;
	name?: string;
	platform?: string;
	model?: string;
	os?: string;
	status?: Record<string, unknown>;
	connectedAt: number;
	lastSeen: number;
}
interface Take {
	sessionId: string;
	takeId: string;
	startedAt: number;
}

// One room = one studio. Hibernatable sockets: the object sleeps between messages,
// and each socket's identity lives in its attachment so it survives eviction.
export class Room extends DurableObject<Env> {
	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		const role = url.searchParams.get("role") as Role;
		const id = url.searchParams.get("id") ?? crypto.randomUUID();
		if (role !== "camera" && role !== "director") return json({ error: "role" }, 400);

		// A phone reconnecting after a network drop must replace its old socket, or
		// the director sees the same camera twice.
		for (const ws of this.ctx.getWebSockets(id)) ws.close(4000, "replaced");

		const pair = new WebSocketPair();
		const now = Date.now();
		this.ctx.acceptWebSocket(pair[1], [id, role]);
		pair[1].serializeAttachment({ role, id, connectedAt: now, lastSeen: now } satisfies Peer);

		const take = await this.take();
		if (role === "director") this.send(pair[1], await this.roster());
		if (role === "camera" && take) this.send(pair[1], { type: "start", ...take });
		return new Response(null, { status: 101, webSocket: pair[0] });
	}

	async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
		let msg: Record<string, any>;
		try {
			msg = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
		} catch {
			return;
		}
		const peer = ws.deserializeAttachment() as Peer;
		peer.lastSeen = Date.now();

		if (msg.type === "time") {
			this.send(ws, { type: "time", c: msg.c, s: Date.now() });
			ws.serializeAttachment(peer);
			return;
		}

		if (peer.role === "camera") {
			switch (msg.type) {
				case "hello":
					Object.assign(peer, { name: msg.name, platform: msg.platform, model: msg.model, os: msg.os });
					break;
				case "status":
					peer.status = msg;
					break;
				case "recordingStarted":
				case "recordingStopped":
				case "uploaded":
					this.toDirectors({ ...msg, cameraId: peer.id, cameraName: peer.name });
					break;
			}
			ws.serializeAttachment(peer);
			this.toDirectors(await this.roster());
			return;
		}

		ws.serializeAttachment(peer);
		switch (msg.type) {
			case "start": {
				const take: Take = { sessionId: String(msg.sessionId), takeId: String(msg.takeId), startedAt: Date.now() };
				if (!msg.target) await this.ctx.storage.put("take", take);
				this.toCameras({ type: "start", ...take }, msg.target);
				break;
			}
			case "stop":
				if (!msg.target) await this.ctx.storage.delete("take");
				this.toCameras({ type: "stop", takeId: msg.takeId }, msg.target);
				break;
		}
		this.toDirectors(await this.roster());
	}

	async webSocketClose(ws: WebSocket) {
		ws.close();
		this.toDirectors(await this.roster());
	}

	async webSocketError(ws: WebSocket) {
		this.toDirectors(await this.roster());
	}

	private take() {
		return this.ctx.storage.get<Take>("take");
	}

	private async roster() {
		const cameras = this.ctx
			.getWebSockets("camera")
			.filter((ws) => ws.readyState === WebSocket.OPEN)
			.map((ws) => {
				const p = ws.deserializeAttachment() as Peer;
				return { id: p.id, name: p.name, platform: p.platform, model: p.model, os: p.os, online: true, status: p.status, lastSeen: p.lastSeen };
			});
		return { type: "cameras", cameras, take: (await this.take()) ?? null };
	}

	private send(ws: WebSocket, msg: unknown) {
		try {
			ws.send(JSON.stringify(msg));
		} catch {}
	}

	private toDirectors(msg: unknown) {
		for (const ws of this.ctx.getWebSockets("director")) this.send(ws, msg);
	}

	private toCameras(msg: unknown, target?: string) {
		for (const ws of this.ctx.getWebSockets(target ?? "camera")) {
			if ((ws.deserializeAttachment() as Peer).role === "camera") this.send(ws, msg);
		}
	}
}
