# Video Call Platform

A minimal video calling app built with **mediasoup** (SFU), **Node.js**, and **Next.js**. A user creates a meeting, shares the link, and other participants join from the same URL.

---

## Demo

**▶️ [Watch the 44-second walkthrough](https://drive.google.com/file/d/1Y8mkySOdFkZVl174VDZvVjZoUOroVYaj/view?usp=drive_link)**
· [download from this repo](docs/demo/video_call_demo.mp4)

A single unedited run against the local stack, showing both participants
side by side so you can see each action land on the other end:

| Time | |
| --- | --- |
| 0:00 | Host creates a meeting — the room is locked by default |
| 0:05 | Guest joins by code and is held in the lobby |
| 0:10 | Host admits — WebRTC negotiates, both streams go live |
| 0:15 | Real-time in-call chat, both directions |
| 0:25 | Screen sharing — publishes as a second producer, layout adapts |
| 0:34 | Host force-mutes a participant (one-way, by design) |
| 0:39 | Host removes a participant |

---

## Screenshots

Captured from a real two-participant call running against the local stack. Video is
Chrome's synthetic camera source, so no real webcam footage appears in these shots.

### Live call with host moderation

Two participants connected through the SFU. The host sees per-participant
**Mute**, **Stop Cam** and **Kick** controls; the room is **Locked**, so new
arrivals wait in a lobby until admitted.

![Live call with host moderation controls](docs/screenshots/01-in-call.png)

### Screen sharing and in-call chat

Screen share publishes as a second producer with its own tile, and the grid
re-flows to give it priority. Chat runs over the same Socket.io channel as the
signaling.

![Screen sharing with the chat sidebar open](docs/screenshots/02-screen-share-and-chat.png)

### Participant view

The same call from the guest's side. Moderation controls and the room-lock badge
are absent — host authority is enforced server-side on every privileged event,
not just hidden in the UI.

![Guest view without host controls](docs/screenshots/03-guest-view.png)

### Removing a participant

After the host kicks someone, their transports are closed server-side, the
matching consumers tear down on every other peer, and the tile disappears.

![Call after a participant has been removed](docs/screenshots/04-participant-removed.png)

---

## Features (Production-Ready Updates)

This repository has recently undergone a major transformation from a basic MVP into a high-concurrency, production-grade video platform:

- **Premium UI/UX**: Professional & industry-grade dark mode aesthetic, responsive dynamic flex grid, frosted glassmorphism overlays, and user-friendly connection/permission loaders.
- **Authentication**: Integrated `better-auth` with MongoDB for secure user sign-ups, session management, and one-click "Continue as Guest" access.
- **Host Controls & Moderation**: Meeting hosts can lock rooms, manage a waiting room lobby, forcefully mute participant microphones, and kick disruptive users.
- **Screen Sharing**: Fully synchronized screen sharing pipelines with dynamic layout adjustments.
- **Real-Time Chat**: Integrated collapsible sidebar for in-room text chat.
- **WebRTC Simulcast**: Video streams automatically adapt quality based on network conditions using 3-layer spatial simulcast encoding.
- **Worker Scaling**: Built-in cross-worker load balancing allowing the app to distribute room load effectively.

---

## Contents

1. [Architecture](#architecture)
2. [Project structure](#project-structure)
3. [How a call flows end-to-end](#how-a-call-flows-end-to-end)
4. [Signaling protocol](#signaling-protocol)
5. [Running locally](#running-locally)
6. [Configuration](#configuration)
7. [Running on a LAN or the internet](#running-on-a-lan-or-the-internet)
8. [Limitations & next steps](#limitations--next-steps)

---

## Architecture

There are two services:

```
┌────────────────────┐   HTTP + WebSocket   ┌────────────────────────┐
│  Next.js client    │ ───────────────────► │   Node.js signaling    │
│  (browser)         │                      │   (Express + Socket.io)│
│                    │                      │                        │
│  mediasoup-client  │ ◄── WebRTC media ──► │   mediasoup workers    │
│  (WebRTC)          │      (UDP/TCP)       │   (router per room)    │
└────────────────────┘                      └────────────────────────┘
```

**SFU (Selective Forwarding Unit).** mediasoup does **not** mix audio/video. Each participant uploads their tracks once to the server, and the server forwards a copy to every other participant. This is much more efficient than a mesh (N² uplinks) but uses more bandwidth than an MCU (which mixes streams).

**Per-room router.** When a room is created, the server picks one mediasoup worker (round-robin across CPUs) and creates a `Router` on it. The router holds the media routing graph for that room.

**Per-peer transports.** Each peer creates two WebRTC transports against the router:

- a **send transport** (browser → server) carrying that peer's microphone + camera as **producers**
- a **receive transport** (server → browser) carrying **consumers** that subscribe to other peers' producers

```
       PEER A                                    PEER B
  ┌─────────────┐                            ┌─────────────┐
  │  mic, cam   │── producers ─┐    ┌── producers ── mic, cam │
  └─────────────┘              │    │                  └─────────────┘
                               ▼    ▼
                          ┌─────────────┐
                          │   Router    │
                          │  (room X)   │
                          └─────┬─┬─────┘
                                │ │
                          ┌─────┘ └─────┐
                          ▼             ▼
                     consumers      consumers
                        for A          for B
```

---

## Project structure

```
video_call/
├── server/                          Node.js signaling + mediasoup SFU
│   ├── index.js                     HTTP + Socket.io event handlers
│   ├── room.js                      Room and Peer state
│   ├── config.js                    Ports, codecs, transport options
│   └── package.json
└── client/                          Next.js 14 (App Router)
    ├── app/
    │   ├── layout.js                Global layout
    │   ├── page.js                  Home: create / join a meeting
    │   └── room/[id]/page.js        Room UI: tiles, controls, status
    ├── lib/
    │   └── RoomClient.js            mediasoup-client wrapper
    ├── next.config.js
    └── package.json
```

Important files:

- [server/index.js](server/index.js) — all signaling events live here
- [server/room.js](server/room.js) — `Room` keeps a map of peers and their transports/producers/consumers
- [server/config.js](server/config.js) — codecs (opus/VP8/H264), worker count, RTC port range, `announcedIp`
- [client/lib/RoomClient.js](client/lib/RoomClient.js) — the client-side state machine (join → device → transports → produce → consume)
- [client/app/room/[id]/page.js](client/app/room/[id]/page.js) — React UI; mounts `RoomClient`, renders local + remote video tiles

---

## How a call flows end-to-end

The flow for a peer joining a room:

### 1. Room creation

User clicks **Create new meeting** on the home page. The client calls:

```
POST /rooms  →  { roomId: "abc123xyz0" }
```

The server creates a `Router` on a mediasoup worker and stores a `Room` keyed by `roomId`. The client then navigates to `/room/abc123xyz0`.

### 2. Socket connection + join

The room page opens a Socket.io connection and sends:

```
joinRoom { roomId }
```

The server adds the peer to the room and replies with:

- `rtpCapabilities` — the codecs/headers the router accepts
- `existingProducers` — list of `{ producerId, peerId, kind }` already published by other peers

### 3. mediasoup `Device` load

The client builds a `mediasoup-client` `Device` and calls `device.load({ routerRtpCapabilities })`. This is how the browser learns what it can negotiate with the SFU.

### 4. Transport setup

The client creates two WebRTC transports — one to **send**, one to **receive**:

```
createWebRtcTransport → { id, iceParameters, iceCandidates, dtlsParameters }
```

The server creates the transport on the router; the client mirrors it locally with `device.createSendTransport(params)` / `device.createRecvTransport(params)`.

When the transport's `connect` event fires (on first produce/consume), the client forwards DTLS parameters to the server:

```
connectTransport { transportId, dtlsParameters }
```

### 5. Publishing local media (producers)

The client calls `getUserMedia({ audio: true, video: true })`, then for each track:

```
sendTransport.produce({ track })
   └─ internally fires `produce` event
       └─ client emits: produce { transportId, kind, rtpParameters }
                            ↳ server: transport.produce(...)
                            ↳ replies with producer id
       └─ server broadcasts to other peers:
             newProducer { producerId, peerId, kind }
```

### 6. Subscribing to remote media (consumers)

When the client sees a `newProducer` event (or one of `existingProducers` at join time), it:

```
consume { producerId, rtpCapabilities, transportId }   →
   server checks router.canConsume(...)
   creates a paused Consumer on the recv transport
   replies with { id, producerId, kind, rtpParameters }
```

The client wraps the consumer's track in a `MediaStream` and attaches it to a `<video>` / `<audio>` element. Then it sends:

```
resumeConsumer { consumerId }
```

Consumers start **paused** on the server because the browser may not have attached the track to a media element yet — resuming after attachment avoids the first packets being discarded.

### 7. Mute / camera toggle

Toggling doesn't tear down the producer; it just pauses it:

```
producer.pause()    ← server stops forwarding RTP from this peer
producer.resume()
```

Other peers' consumers stay open; they simply see frozen video / silence while paused.

### 8. Leaving

On disconnect (page close or **Leave** button) the server closes the peer's transports, which closes its producers, which closes the matching consumers on other peers (they get a `consumerClosed` event). If the room is empty, the router is closed and the room entry is deleted.

---

## Signaling protocol

All client ↔ server signaling goes over Socket.io. Requests use the ack-callback pattern so they look like RPC.

### Client → Server (request/response)

| Event                    | Payload                                            | Reply                                                                    |
| ------------------------ | -------------------------------------------------- | ------------------------------------------------------------------------ |
| `joinRoom`               | `{ roomId }`                                       | `{ rtpCapabilities, existingProducers: [...] }`                          |
| `createWebRtcTransport`  | `{}`                                               | `{ id, iceParameters, iceCandidates, dtlsParameters }`                   |
| `connectTransport`       | `{ transportId, dtlsParameters }`                  | `{ ok: true }`                                                           |
| `produce`                | `{ transportId, kind, rtpParameters }`             | `{ id }` (producer id)                                                   |
| `consume`                | `{ producerId, rtpCapabilities, transportId }`     | `{ id, producerId, kind, rtpParameters }`                                |
| `resumeConsumer`         | `{ consumerId }`                                   | `{ ok: true }`                                                           |

### Server → Client (push)

| Event            | Payload                                | Meaning                                            |
| ---------------- | -------------------------------------- | -------------------------------------------------- |
| `newProducer`    | `{ producerId, peerId, kind }`         | Someone in the room started publishing a track     |
| `consumerClosed` | `{ consumerId }`                       | A consumer was closed (its producer went away)     |
| `peerLeft`       | `{ peerId }`                           | A peer disconnected; clean up their tiles          |

### HTTP

| Method | Path           | Body | Reply              |
| ------ | -------------- | ---- | ------------------ |
| POST   | `/rooms`       | —    | `{ roomId }`       |
| GET    | `/rooms/:id`   | —    | `{ exists }`       |
| GET    | `/health`      | —    | `{ ok: true }`     |

---

## Running locally

**1. Start MongoDB.** A compose file is included, so you don't need a local install:

```bash
docker compose up -d          # MongoDB on 127.0.0.1:27017
docker compose logs -f mongodb   # tail logs
docker compose down           # stop (data persists in the named volume)
```

It comes up as `videocall-mediasoup`, matching the default `MONGODB_URI` in
`server/.env.example`. The port is bound to loopback only — the container runs
without authentication so it matches the credential-less default URI, so don't
publish it to `0.0.0.0` without enabling auth first (see the commented block in
`docker-compose.yml`).

**2. Start the two services**, in two terminals:

```bash
# terminal 1 — signaling + SFU
cd server
pnpm install
pnpm dev        # listens on http://localhost:4000

# terminal 2 — Next.js
cd client
npm install
npm run dev     # listens on http://localhost:3000
```

> `server/` uses **pnpm**, not npm. pnpm 10+ blocks dependency build scripts by
> default, so `pnpm-workspace.yaml` allows mediasoup's — without it the native
> worker binary is silently skipped and `createWorker()` fails at boot with
> `ENOENT`.

Open `http://localhost:3000` in two browser windows (or one regular + one incognito so they get separate camera sessions). Click **Create new meeting** in one, copy the invite link, and paste it into the other.

> `getUserMedia` requires a **secure origin**. `http://localhost` qualifies, so local dev works. Plain HTTP on a LAN IP will be rejected by the browser — see the LAN/internet section.

### Requirements

- Node.js 18+ (Node 20+ recommended — one transitive dep of `mediasoup-client` declares engines `>=20`)
- A Linux/macOS host with `python3`, `make`, and a C++ compiler (mediasoup builds a native worker on `npm install` if no prebuilt is available)

---

## Configuration

### Server ([server/config.js](server/config.js))

| Setting                 | Default                              | Notes                                                       |
| ----------------------- | ------------------------------------ | ----------------------------------------------------------- |
| `listenPort`            | `4000`                               | HTTP + Socket.io                                            |
| `clientOrigin`          | `http://localhost:3000`              | CORS allowlist; override with `CLIENT_ORIGIN`               |
| `numWorkers`            | one per CPU                          | Each room is bound to one worker                            |
| `rtcMinPort`/`rtcMaxPort` | `10000` – `10100`                  | UDP+TCP range for RTP/RTCP                                  |
| `announcedIp`           | `127.0.0.1`                          | The IP put into ICE candidates; override with `MEDIASOUP_ANNOUNCED_IP` |
| `mediaCodecs`           | opus, VP8, H264                      | Add/remove codecs here                                      |

### Client ([client/.env.local](client/.env.local) or `client/.env`)

```env
NEXT_PUBLIC_SERVER_URL=http://localhost:4000
```

Point this at wherever the signaling server runs.

> **Note:** For a complete configuration reference, please see the `example.env` file in the root directory.

---

## Running on a LAN or the internet

Two things need attention:

**1. ICE candidates must use a reachable IP.**

If `announcedIp` stays `127.0.0.1`, peers will get loopback ICE candidates and media will never connect. Start the server with:

```bash
MEDIASOUP_ANNOUNCED_IP=192.168.1.42 npm run dev
```

For internet use, set it to the server's **public IP** and make sure UDP+TCP ports `10000–10100` and TCP `4000` are open in the firewall.

**2. The browser requires HTTPS for `getUserMedia` over a non-localhost origin.**

Options:

- Run Next.js behind a TLS-terminating reverse proxy (Caddy, nginx, Cloudflare Tunnel)
- Use [mkcert](https://github.com/FiloSottile/mkcert) for local LAN certs
- For quick demos: tunnel with `ngrok http 3000` and `ngrok http 4000`, then point `NEXT_PUBLIC_SERVER_URL` at the second tunnel

**3. NAT traversal.** mediasoup's WebRTC transports advertise the server's announced IP directly, so a server with a public IP needs no STUN/TURN for the server side. Clients behind symmetric NAT, however, may still need a TURN server in restrictive networks — none is configured by default.

---

## Limitations & next steps

While the core MVP limitations have been resolved (Authentication, Host Controls, Simulcast, Chat, Screen Sharing, and Worker Load Balancing), the following architecture steps are next on the roadmap:

- **TURN Server Implementation**: While the current setup works on standard connections, restrictive symmetric NATs will require a deployed TURN server integration (e.g., coturn) for guaranteed global peer-to-peer relay fallback.
- **Persisted Chat Logs**: Chat is currently ephemeral for the session; long-term persistence in MongoDB can be added for post-meeting records.
