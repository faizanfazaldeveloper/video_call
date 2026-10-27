const os = require('os');

module.exports = {
  // HTTP/Socket.io only. mediasoup RTP stays on 0.0.0.0 (see webRtcTransportOptions).
  // Production deploy sets HTTP_LISTEN_IP=127.0.0.1 so Nginx is the only public entry.
  listenIp: process.env.HTTP_LISTEN_IP || '0.0.0.0',
  listenPort: process.env.PORT || 4000,
  clientOrigin: process.env.CLIENT_ORIGIN || 'http://localhost:3000',

  mediasoup: {
    numWorkers: Object.keys(os.cpus()).length,

    workerSettings: {
      logLevel: 'warn',
      logTags: ['info', 'ice', 'dtls', 'rtp', 'srtp', 'rtcp'],
      rtcMinPort: 10000,
      rtcMaxPort: 10100,
    },

    routerOptions: {
      mediaCodecs: [
        {
          kind: 'audio',
          mimeType: 'audio/opus',
          clockRate: 48000,
          channels: 2,
        },
        {
          kind: 'video',
          mimeType: 'video/VP8',
          clockRate: 90000,
          parameters: { 'x-google-start-bitrate': 1000 },
        },
        {
          kind: 'video',
          mimeType: 'video/H264',
          clockRate: 90000,
          parameters: {
            'packetization-mode': 1,
            'profile-level-id': '42e01f',
            'level-asymmetry-allowed': 1,
            'x-google-start-bitrate': 1000,
          },
        },
      ],
    },

    webRtcTransportOptions: {
      listenIps: [
        {
          ip: '0.0.0.0',
          // For LAN / production, set MEDIASOUP_ANNOUNCED_IP to your public IP.
          announcedIp: process.env.MEDIASOUP_ANNOUNCED_IP || '127.0.0.1',
        },
      ],
      enableUdp: true,
      enableTcp: true,
      preferUdp: true,
      initialAvailableOutgoingBitrate: 1_000_000,
    },
  },
};
