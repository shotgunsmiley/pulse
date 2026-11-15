import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import time

PORT = int(os.environ.get("PORT", 5000))
DIFFICULTY = 2
LEDGER_FILE = "pulse_ledger.json"


class PulseCoordinator:

  def __init__(self):
    self.chain = []
    self.pending_transactions = []
    self.load_or_create_chain()

  def compute_hash(self, index, previous_hash, timestamp, transactions, nonce):
    block_string = json.dumps({
        "index": index,
        "previous_hash": previous_hash,
        "timestamp": timestamp,
        "transactions": transactions,
        "nonce": nonce,
    }, sort_keys=True)
    return hashlib.sha256(block_string.encode()).hexdigest()

  def load_or_create_chain(self):
    if os.path.exists(LEDGER_FILE):
      with open(LEDGER_FILE, "r") as f:
        self.chain = json.load(f)
    else:
      genesis_block = {
          "index": 0,
          "previous_hash": "0",
          "timestamp": time.time(),
          "transactions": [{
              "sender": "GENESIS",
              "recipient": "pulse_genesis_vault",
              "amount": 1000000,
          }],
          "nonce": 0,
          "hash": "00000000000000000000000000000000",
      }
      self.chain.append(genesis_block)
      self.save_chain()

  def save_chain(self):
    with open(LEDGER_FILE, "w") as f:
      json.dump(self.chain, f, indent=2)

  def get_balances(self):
    balances = {}
    for block in self.chain:
      for tx in block.get("transactions", []):
        sender = tx.get("sender")
        recipient = tx.get("recipient")
        amount = tx.get("amount", 0)
        if sender not in ("NETWORK", "GENESIS"):
          balances[sender] = balances.get(sender, 0) - amount
        balances[recipient] = balances.get(recipient, 0) + amount
    return balances

  def add_transaction(self, tx):
    sender = tx.get("sender")
    recipient = tx.get("recipient")
    amount = tx.get("amount", 0)
    if not sender or not recipient or amount <= 0:
      return False, "Invalid format."
    if sender == recipient:
      return False, "Cannot send to yourself."

    balances = self.get_balances()
    if balances.get(sender, 0) < amount:
      return False, "Insufficient funds."

    self.pending_transactions.append(tx)
    return True, "Transaction queued."

  def validate_and_add_block(self, block):
    last_block = self.chain[-1]
    if block.get("index") != last_block["index"] + 1:
      return False, "Outdated index."
    if block.get("previous_hash") != last_block["hash"]:
      return False, "Hash mismatch."

    block_txs = block.get("transactions", [])
    rewards = [tx for tx in block_txs if tx.get("sender") == "NETWORK"]
    if len(rewards) != 1 or rewards[0].get("amount") != 50:
      return False, "Invalid reward."

    recomputed_hash = self.compute_hash(
        block["index"],
        block["previous_hash"],
        block["timestamp"],
        block_txs,
        block["nonce"],
    )
    if recomputed_hash != block.get("hash") or not recomputed_hash.startswith(
        "0" * DIFFICULTY
    ):
      return False, "Invalid PoW hash."

    self.chain.append(block)
    self.pending_transactions = []
    self.save_chain()
    return True, f"Block #{block['index']} added!"


coordinator = PulseCoordinator()


class RequestHandler(BaseHTTPRequestHandler):

  def _send_json(self, status_code, data):
    self.send_response(status_code)
    self.send_header("Content-Type", "application/json")
    self.end_headers()
    self.wfile.write(json.dumps(data).encode("utf-8"))

  def do_GET(self):
    if self.path == "/get_chain":
      self._send_json(200, coordinator.chain)
    elif self.path == "/balances":
      self._send_json(200, coordinator.get_balances())
    else:
      self._send_json(404, {"error": "Not found"})

  def do_POST(self):
    content_length = int(self.headers.get("Content-Length", 0))
    post_data = self.rfile.read(content_length)
    try:
      data = json.loads(post_data.decode("utf-8"))
      if self.path == "/submit_transaction":
        success, msg = coordinator.add_transaction(data)
        self._send_json(200 if success else 400, {"status": success, "message": msg})
      elif self.path == "/submit_block":
        success, msg = coordinator.validate_and_add_block(data)
        self._send_json(200 if success else 400, {"status": success, "message": msg})
      else:
        self._send_json(404, {"error": "Not found"})
    except Exception as e:
      self._send_json(400, {"status": False, "message": str(e)})


if __name__ == "__main__":
  server = HTTPServer(("0.0.0.0", PORT), RequestHandler)
  print(f"[*] Server running on port {PORT}...")
  server.serve_forever()
