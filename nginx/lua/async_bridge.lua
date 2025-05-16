local http = require("resty.http")
local cjson = require("cjson.safe")
local ws = require("resty.websocket.client")
local uuid = require("resty.jit-uuid")
uuid.seed()
ngx.req.read_body()
local req_body = ngx.req.get_body_data()
local content_type = ngx.req.get_headers()["Content-Type"] or "application/json"
local req_method = ngx.req.get_method()
local topic = ngx.var.topic
local correlation_id = uuid()
local httpc = http.new()
local publish_payload = {
  destinationName = topic,
  message = {
    payload = ngx.encode_base64(req_body or ""),
    contentType = content_type,
    correlationData = correlation_id,
    metaData = { httpMethod = req_method, path = ngx.var.request_uri }
  }
}
local res, err = httpc:request_uri("http://maps:8080/api/v1/messaging/publish", {
  method = "POST",
  body = cjson.encode(publish_payload),
  headers = { ["Content-Type"] = "application/json" }
})
if not res or res.status ~= 200 then
  ngx.status = 502
  ngx.say(cjson.encode({ error = "Failed to publish", detail = err or res.status }))
  return
end
local wsc = ws:new()
local ok, err = wsc:connect("ws://maps:8080/api/v1/messaging/subscribe?destinationName=" .. ngx.escape_uri(topic))
if not ok then
  ngx.status = 504
  ngx.say(cjson.encode({ error = "WebSocket connect failed", detail = err }))
  return
end
wsc:set_timeout(10000)
while true do
  local data, typ, err = wsc:recv_frame()
  if not data then
    ngx.status = 504
    ngx.say(cjson.encode({ error = "Timeout waiting for response", detail = err }))
    return
  end
  local decoded = cjson.decode(data)
  if decoded and decoded.message and decoded.message.correlationData == correlation_id then
    local resp_body = ngx.decode_base64(decoded.message.payload or "")
    ngx.status = decoded.message.statusCode or 200
    ngx.header["Content-Type"] = decoded.message.contentType or "application/json"
    ngx.say(resp_body)
    return
  end
end
