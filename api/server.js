const express = require("express");
const cors = require("cors");
const Database = require("better-sqlite3");
const { verifyMessage } = require("viem");

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------
const db = new Database("comments.db");
db.pragma("journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    proposalId INTEGER NOT NULL,
    address TEXT NOT NULL,
    message TEXT NOT NULL,
    timestamp INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_proposal ON comments(proposalId);
`);

const insertComment = db.prepare(
  "INSERT INTO comments (proposalId, address, message, timestamp) VALUES (?, ?, ?, ?)"
);
const getComments = db.prepare(
  "SELECT * FROM comments WHERE proposalId = ? ORDER BY timestamp DESC"
);

// ---------------------------------------------------------------------------
// Rate limiter  (10 comments per address per 60 s, in-memory)
// ---------------------------------------------------------------------------
const rateMap = new Map(); // address -> [timestamps]
const RATE_WINDOW = 60_000;
const RATE_MAX = 10;

function isRateLimited(address) {
  const now = Date.now();
  let timestamps = rateMap.get(address);
  if (!timestamps) {
    timestamps = [];
    rateMap.set(address, timestamps);
  }
  // Prune old entries
  while (timestamps.length && timestamps[0] <= now - RATE_WINDOW) {
    timestamps.shift();
  }
  if (timestamps.length >= RATE_MAX) return true;
  timestamps.push(now);
  return false;
}

// Periodically clean up stale keys so the map doesn't grow forever
setInterval(() => {
  const now = Date.now();
  for (const [addr, ts] of rateMap) {
    while (ts.length && ts[0] <= now - RATE_WINDOW) ts.shift();
    if (!ts.length) rateMap.delete(addr);
  }
}, 120_000).unref();

// ---------------------------------------------------------------------------
// Express app
// ---------------------------------------------------------------------------
const app = express();
app.use(cors());
app.use(express.json());

const MAX_MESSAGE_LENGTH = 500;

// GET /api/comments/:proposalId
app.get("/api/comments/:proposalId", (req, res) => {
  const proposalId = Number(req.params.proposalId);
  if (!Number.isInteger(proposalId) || proposalId < 0) {
    return res.status(400).json({ error: "Invalid proposalId" });
  }
  const rows = getComments.all(proposalId);
  res.json(rows);
});

// POST /api/comments
app.post("/api/comments", async (req, res) => {
  try {
    const { proposalId, address, message, signature } = req.body;

    // ---- validation ----
    if (
      proposalId === undefined ||
      !address ||
      !message ||
      !signature
    ) {
      return res
        .status(400)
        .json({ error: "Missing required fields: proposalId, address, message, signature" });
    }

    const pid = Number(proposalId);
    if (!Number.isInteger(pid) || pid < 0) {
      return res.status(400).json({ error: "Invalid proposalId" });
    }

    if (typeof message !== "string" || message.length === 0) {
      return res.status(400).json({ error: "Message must be a non-empty string" });
    }

    if (message.length > MAX_MESSAGE_LENGTH) {
      return res
        .status(400)
        .json({ error: `Message exceeds max length of ${MAX_MESSAGE_LENGTH} characters` });
    }

    // ---- rate limit ----
    const lowerAddr = address.toLowerCase();
    if (isRateLimited(lowerAddr)) {
      return res
        .status(429)
        .json({ error: "Rate limit exceeded. Max 10 comments per minute." });
    }

    // ---- signature verification ----
    const expectedMessage = `Comment on proposal #${pid}: ${message}`;
    const valid = await verifyMessage({
      address,
      message: expectedMessage,
      signature,
    });

    if (!valid) {
      return res.status(401).json({ error: "Invalid signature" });
    }

    // ---- persist ----
    const timestamp = Date.now();
    const result = insertComment.run(pid, address, message, timestamp);

    const comment = {
      id: result.lastInsertRowid,
      proposalId: pid,
      address,
      message,
      timestamp,
    };

    res.status(201).json(comment);
  } catch (err) {
    console.error("POST /api/comments error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
  console.log(`Cabal comment API running on http://localhost:${PORT}`);
});
