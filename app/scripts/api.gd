extends Node
# Talks to the Pulse server. Every call returns a Dictionary; failures come back
# as {"ok": false, "error": ..., "message": ...} so screens never crash on them.

signal session_expired

const DEFAULT_SERVER := "https://pulse-nadr.onrender.com"
var base_url := DEFAULT_SERVER
var token := ""


func request(method: String, path: String, body = null, timeout: float = 25.0) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout
	add_child(http)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if token != "":
		headers.append("Authorization: Bearer " + token)
	var verb := HTTPClient.METHOD_GET
	var payload := ""
	if method == "POST":
		verb = HTTPClient.METHOD_POST
		payload = JSON.stringify(body if body != null else {})
	var err := http.request(base_url + path, headers, verb, payload)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "network", "message": "Could not start the request."}
	var res: Array = await http.request_completed
	http.queue_free()
	var result: int = res[0]
	var code: int = res[1]
	var raw: PackedByteArray = res[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "network", "message": "No connection. The server may be waking up - try again in a moment."}
	var data = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "bad_response", "message": "Unexpected server reply (%d)." % code}
	if code == 401 and str(data.get("error", "")) == "login_required":
		session_expired.emit()
	return data


func get_json(path: String) -> Dictionary:
	return await request("GET", path)


func post(path: String, body: Dictionary = {}) -> Dictionary:
	return await request("POST", path, body)


# Free servers sleep when idle. Keep knocking for up to ~2 minutes.
func wake(status_cb: Callable) -> bool:
	for attempt in range(8):
		status_cb.call("Connecting to Pulse..." if attempt == 0 else "Waking the Pulse server... (try %d)" % (attempt + 1))
		var r := await request("GET", "/health", null, 20.0)
		if r.get("ok", false):
			return true
		await get_tree().create_timer(3.0).timeout
	return false
