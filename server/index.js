require('dotenv').config();

const http = require('http');
const express = require('express');
const cors = require('cors');
const { Server } = require('socket.io');
const mediasoup = require('mediasoup');
const { nanoid } = require('nanoid');

const config = require('./config');
const { Room } = require('./room');
const { auth, toNodeHandler } = require('./auth');

const workers = [];
let nextWorkerIdx = 0;
const rooms = new Map(); // roomId -> Room

async function createWorkers() {
  const { numWorkers, workerSettings } = config.mediasoup;
  for (let i = 0; i < numWorkers; i++) {
    const worker = await mediasoup.createWorker(workerSettings);
    worker.on('died', () => {
      console.error(`mediasoup worker ${worker.pid} died, exiting`);
      setTimeout(() => process.exit(1), 2000);
    });
    workers.push(worker);
  }
  console.log(`mediasoup: spawned ${workers.length} workers`);
}

function nextWorker() {
  const worker = workers[nextWorkerIdx];
  nextWorkerIdx = (nextWorkerIdx + 1) % workers.length;
  return worker;
}

async function getOrCreateRoom(roomId, providedHostToken = null) {
  let room = rooms.get(roomId);
  if (room) return room;
  room = new Room(roomId);
  if (providedHostToken) {
    room.hostToken = providedHostToken;
  }
  rooms.set(roomId, room);
  console.log(`room created: ${roomId}`);
  return room;
}

async function main() {
  await createWorkers();

  const app = express();
  // Nginx sets X-Forwarded-* . Trust the local proxy so the secure scheme is visible.
  app.set('trust proxy', 'loopback');
  app.use(cors({ origin: config.clientOrigin, credentials: true }));
  app.use(express.json());

  app.all('/api/auth/*', toNodeHandler(auth));

  app.get('/health', (_req, res) => res.json({ ok: true }));

  // Create a new meeting room
  app.post('/rooms', async (_req, res) => {
    const roomId = nanoid(10);
    const room = await getOrCreateRoom(roomId);
    res.json({ roomId, hostToken: room.hostToken });
  });

  // Check if a room exists (so the client can show "meeting not found")
  app.get('/rooms/:id', (req, res) => {
    const room = rooms.get(req.params.id);
    res.json({ exists: !!room });
  });

  const server = http.createServer(app);
  const io = new Server(server, {
    cors: { origin: config.clientOrigin, methods: ['GET', 'POST'], credentials: true },
  });

  io.on('connection', (socket) => {
    console.log(`socket connected: ${socket.id}`);

    let joinedRoomId = null;
    let peerId = null;

    socket.on('joinRoom', async ({ roomId, hostToken }, cb) => {
      try {
        // Authenticate the user via better-auth
        const session = await auth.api.getSession({
          headers: new Headers({ cookie: socket.handshake.headers.cookie || '' }),
        });
        
        if (!session) {
          return cb({ error: 'Unauthorized: You must be logged in to join a room.' });
        }

        const room = await getOrCreateRoom(roomId, hostToken);
        peerId = socket.id;
        const userId = session.user.id;

        const isHost = hostToken === room.hostToken;

        if (room.locked && !isHost && !room.admittedPeers.has(userId)) {
          room.waitingPeers.set(peerId, { socket, userId });
          socket.to(roomId).emit('lobbyPeerWaiting', { peerId });
          return cb({ status: 'waiting' });
        }

        const worker = nextWorker();
        const peer = await room.addPeer(peerId, socket, worker);
        peer.isHost = isHost;
        peer.userId = userId;
        peer.displayName = session.user.name;
        joinedRoomId = roomId;
        socket.join(roomId);

        const existingProducers = [];
        for (const p of room.getOtherPeers(peerId)) {
          for (const producer of p.producers.values()) {
            existingProducers.push({
              producerId: producer.id,
              peerId: p.id,
              displayName: p.displayName,
              kind: producer.kind,
              appData: producer.appData,
              paused: producer.paused,
            });
          }
        }

        cb({
          status: 'joined',
          isHost,
          isLocked: room.locked,
          rtpCapabilities: peer.router.rtpCapabilities,
          existingProducers,
        });
      } catch (err) {
        console.error('joinRoom error', err);
        cb({ error: err.message });
      }
    });

    socket.on('admitPeer', ({ targetPeerId, admit }, cb) => {
      const room = rooms.get(joinedRoomId);
      if (!room || !room.peers.get(socket.id)?.isHost) return cb?.({ error: 'Not host' });
      
      const waiting = room.waitingPeers.get(targetPeerId);
      if (!waiting) return cb?.({ error: 'Peer not waiting' });
      
      room.waitingPeers.delete(targetPeerId);
      if (admit) {
        room.admittedPeers.add(waiting.userId);
        waiting.socket.emit('lobbyAdmitted');
      } else {
        waiting.socket.emit('lobbyRejected');
      }
      if (cb) cb({ ok: true });
    });

    socket.on('kickPeer', ({ targetPeerId }, cb) => {
      const room = rooms.get(joinedRoomId);
      if (!room || !room.peers.get(socket.id)?.isHost) return cb?.({ error: 'Not host' });
      
      const targetPeer = room.peers.get(targetPeerId);
      if (targetPeer) {
        targetPeer.socket.emit('kicked');
        targetPeer.socket.disconnect(true);
      }
      if (cb) cb({ ok: true });
    });

    socket.on('toggleMutePeer', async ({ targetPeerId, kind }, cb) => {
      const room = rooms.get(joinedRoomId);
      if (!room || !room.peers.get(socket.id)?.isHost) return cb?.({ error: 'Not host' });
      
      const targetPeer = room.peers.get(targetPeerId);
      if (targetPeer) {
        let targetProducer = null;
        for (const p of targetPeer.producers.values()) {
          if (p.kind === kind && p.appData.source !== 'screen') {
            targetProducer = p;
            break;
          }
        }
        // Host can only mute / turn a device OFF — never unmute or turn it back on.
        // Re-enabling is the participant's own choice (privacy).
        if (targetProducer && !targetProducer.paused) {
          await targetProducer.pause();
          targetPeer.socket.emit('forceMuted', { kind });
          io.to(joinedRoomId).emit('peerMuteStatus', { peerId: targetPeerId, kind, paused: true });
        }
      }
      if (cb) cb({ ok: true });
    });

    socket.on('toggleLock', ({ locked }, cb) => {
      const room = rooms.get(joinedRoomId);
      if (!room || !room.peers.get(socket.id)?.isHost) return cb?.({ error: 'Not host' });
      room.locked = locked;
      io.to(joinedRoomId).emit('roomLockChanged', { locked });
      if (cb) cb({ ok: true });
    });

    socket.on('createWebRtcTransport', async (_data, cb) => {
      try {
        const room = rooms.get(joinedRoomId);
        const peer = room?.peers.get(peerId);
        if (!peer) return cb({ error: 'not in room' });

        const transport = await room.createWebRtcTransport(peerId);
        peer.transports.set(transport.id, transport);

        transport.on('dtlsstatechange', (state) => {
          if (state === 'closed') transport.close();
        });

        cb({
          id: transport.id,
          iceParameters: transport.iceParameters,
          iceCandidates: transport.iceCandidates,
          dtlsParameters: transport.dtlsParameters,
        });
      } catch (err) {
        console.error('createWebRtcTransport error', err);
        cb({ error: err.message });
      }
    });

    socket.on('connectTransport', async ({ transportId, dtlsParameters }, cb) => {
      try {
        const peer = rooms.get(joinedRoomId)?.peers.get(peerId);
        const transport = peer?.transports.get(transportId);
        if (!transport) return cb({ error: 'transport not found' });
        await transport.connect({ dtlsParameters });
        cb({ ok: true });
      } catch (err) {
        console.error('connectTransport error', err);
        cb({ error: err.message });
      }
    });

    socket.on('produce', async ({ transportId, kind, rtpParameters, appData }, cb) => {
      try {
        const room = rooms.get(joinedRoomId);
        const peer = room?.peers.get(peerId);
        const transport = peer?.transports.get(transportId);
        if (!transport) return cb({ error: 'transport not found' });

        const producer = await transport.produce({ kind, rtpParameters, appData });
        peer.producers.set(producer.id, producer);

        producer.on('transportclose', () => {
          producer.close();
          peer.producers.delete(producer.id);
        });

        // Pipe this new producer to all other routers in the room
        await room.pipeProducerToAllOtherRouters(producer, peer.router);

        // Notify other peers in the room
        socket.to(joinedRoomId).emit('newProducer', {
          producerId: producer.id,
          peerId: peer.id,
          displayName: peer.displayName,
          kind: producer.kind,
          appData: producer.appData,
          paused: producer.paused,
        });

        cb({ id: producer.id });
      } catch (err) {
        console.error('produce error', err);
        cb({ error: err.message });
      }
    });

    socket.on('closeProducer', ({ producerId }) => {
      const room = rooms.get(joinedRoomId);
      if (!room) return;
      const peer = room.peers.get(socket.id);
      if (!peer) return;

      const producer = peer.producers.get(producerId);
      if (producer) {
        producer.close();
        peer.producers.delete(producerId);
      }
    });

    socket.on('pauseProducer', async ({ producerId }, cb) => {
      const room = rooms.get(joinedRoomId);
      if (!room) return cb?.({ error: 'No room' });
      const peer = room.peers.get(socket.id);
      if (!peer) return cb?.({ error: 'No peer' });
      
      const producer = peer.producers.get(producerId);
      if (producer) {
        await producer.pause();
        io.to(joinedRoomId).emit('peerMuteStatus', { peerId: socket.id, kind: producer.kind, paused: true });
      }
      if (cb) cb({ ok: true });
    });

    socket.on('resumeProducer', async ({ producerId }, cb) => {
      const room = rooms.get(joinedRoomId);
      if (!room) return cb?.({ error: 'No room' });
      const peer = room.peers.get(socket.id);
      if (!peer) return cb?.({ error: 'No peer' });
      
      const producer = peer.producers.get(producerId);
      if (producer) {
        await producer.resume();
        io.to(joinedRoomId).emit('peerMuteStatus', { peerId: socket.id, kind: producer.kind, paused: false });
      }
      if (cb) cb({ ok: true });
    });

    socket.on('consume', async ({ producerId, rtpCapabilities, transportId }, cb) => {
      try {
        const room = rooms.get(joinedRoomId);
        const peer = room?.peers.get(peerId);
        const transport = peer?.transports.get(transportId);
        if (!transport) return cb({ error: 'transport not found' });

        if (!peer.router.canConsume({ producerId, rtpCapabilities })) {
          return cb({ error: 'cannot consume' });
        }

        const consumer = await transport.consume({
          producerId,
          rtpCapabilities,
          paused: true, // start paused; resume after client is ready
        });

        peer.consumers.set(consumer.id, consumer);

        consumer.on('transportclose', () => {
          peer.consumers.delete(consumer.id);
        });
        consumer.on('producerclose', () => {
          peer.consumers.delete(consumer.id);
          socket.emit('consumerClosed', { consumerId: consumer.id });
        });

        cb({
          id: consumer.id,
          producerId,
          kind: consumer.kind,
          rtpParameters: consumer.rtpParameters,
        });
      } catch (err) {
        console.error('consume error', err);
        cb({ error: err.message });
      }
    });

    socket.on('resumeConsumer', async ({ consumerId }, cb) => {
      try {
        const peer = rooms.get(joinedRoomId)?.peers.get(peerId);
        const consumer = peer?.consumers.get(consumerId);
        if (!consumer) return cb({ error: 'consumer not found' });
        await consumer.resume();
        cb({ ok: true });
      } catch (err) {
        console.error('resumeConsumer error', err);
        cb({ error: err.message });
      }
    });

    socket.on('chatMessage', ({ text }, cb) => {
      try {
        if (!joinedRoomId) return cb?.({ error: 'not in room' });
        const senderName = rooms.get(joinedRoomId)?.peers.get(peerId)?.displayName;
        socket.to(joinedRoomId).emit('chatMessage', {
          peerId,
          name: senderName,
          text,
          timestamp: Date.now(),
        });
        if (cb) cb({ ok: true });
      } catch (err) {
        console.error('chatMessage error', err);
        if (cb) cb({ error: err.message });
      }
    });

    socket.on('disconnect', () => {
      console.log(`socket disconnected: ${socket.id}`);
      if (!joinedRoomId) return;
      const room = rooms.get(joinedRoomId);
      if (!room) return;
      room.removePeer(peerId);
      socket.to(joinedRoomId).emit('peerLeft', { peerId });
      if (room.isEmpty()) {
        for (const router of room.routers.values()) {
          router.close();
        }
        rooms.delete(joinedRoomId);
        console.log(`room closed: ${joinedRoomId}`);
      }
    });
  });

  server.listen(config.listenPort, config.listenIp, () => {
    console.log(`server listening on http://${config.listenIp}:${config.listenPort}`);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
