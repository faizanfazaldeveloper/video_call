require('dotenv').config();

const { betterAuth } = require('better-auth');
const { mongodbAdapter } = require('better-auth/adapters/mongodb');
const { toNodeHandler } = require('better-auth/node');
const { anonymous } = require('better-auth/plugins');
const { MongoClient } = require('mongodb');
const mongoose = require('mongoose');

// MongoDB connection string is provided via the MONGODB_URI environment variable
// (see server/.env.example). Never commit real credentials to source control.
const MONGO_URI = process.env.MONGODB_URI || 'mongodb://127.0.0.1:27017/videocall-mediasoup';

// Connect Mongoose for the rest of the application
mongoose.connect(MONGO_URI)
  .then(() => console.log('Mongoose connected successfully'))
  .catch(err => console.error('Mongoose connection error:', err));

// Better-Auth requires a native MongoDB db instance.
// We instantiate a MongoClient synchronously so the auth object can be exported immediately.
const mongoClient = new MongoClient(MONGO_URI);
mongoClient.connect().catch(console.error);
const db = mongoClient.db();

const baseURL = process.env.BETTER_AUTH_URL || 'http://localhost:4000';
const clientOrigin = process.env.CLIENT_ORIGIN || 'http://localhost:3000';

const auth = betterAuth({
  database: mongodbAdapter(db),
  emailAndPassword: {
    enabled: true,
  },
  plugins: [
    anonymous()
  ],
  baseURL,
  trustedOrigins: [clientOrigin],
  // Nginx terminates TLS and talks to Node over HTTP. Secure cookies follow the
  // public URL, otherwise the browser drops the session on an HTTPS page.
  advanced: {
    useSecureCookies: baseURL.startsWith('https://'),
  },
});

module.exports = { auth, toNodeHandler };
