local helpers = require "spec.helpers"
-- mock
-- we don't use mock or spy because we want to see multiple logs
-- also, it fails to mock some time
local log_history = ""
ngx.log = function (_, log) -- luacheck: ignore
  log_history = log_history .. log .. "\n"
end

local function wait_for_log(...)
  local logs = {...}
  helpers.wait_until(function ()
    if not log_history then return end
    for _, log in ipairs(logs) do
      if not log_history:find(log) then
        return
      end
    end
    return true
  end, 5)
  log_history = ""
end

local ws_client = require("spec.fixtures.mocks.lua-resty-websocket.resty.websocket.peer")
local ws_server = require("spec.fixtures.mocks.lua-resty-websocket.resty.websocket.peer")

local wrpc = require("kong.tools.wrpc")
local wrpc_proto = require("kong.tools.wrpc.proto")

local timeout = 10

local echo_service = "TestService.Echo"


local function new_server(ws_peer)
  ws_peer.close = true
  local proto = wrpc_proto.new()
  proto:addpath("spec/fixtures/wrpc")
  proto:import("test")
  proto:set_handler("TestService.Echo", function(_, msg)
    if msg.message == "log" then
      log_history = "log test!"
    end
    return msg
  end)
  local peer = assert(wrpc.new_peer(ws_peer, proto, timeout))
  peer:spawn_threads()
  return peer
end

local function new_client(ws_peer)
  local proto = wrpc_proto.new()
  proto:addpath("spec/fixtures/wrpc")
  proto:import("test")
  local peer = assert(wrpc.new_peer(ws_peer, proto, timeout))
  peer:spawn_threads()
  return peer
end

local function new_pair()
  local client = ws_client:new()
  local server = ws_server:new()
  server.peer = client
  client.peer = server

  -- this way it will be considered a wsclient by wrpc
  server.close = true
  client.close = true
  return new_client(client), new_server(server)
end

describe("wRPC protocol implementation", function()

  describe("simple echo tests", function()
    it("multiple client, multiple call waiting", function ()
      local client_n = 30
      local message_n = 1000

      local expecting = {}

      local clients = {}
      for i = 1, client_n do
        clients[i] = new_pair()
      end

      for i = 1, message_n do
        local client = math.random(1, client_n)
        local message = client .. ":" .. math.random(1, 160)
        local future = clients[client]:call(echo_service, { message = message, })
        expecting[i] = {future = future, message = message, }
      end

      for i = 1, message_n do
        local message = assert(expecting[i].future:wait())
        assert(message.message == expecting[i].message)
      end

    end)

    it("API test", function ()
      local client = new_pair()
      local param = { message = "log", }

      assert.same(param, client:call_async(echo_service, param))
      wait_for_log("log test!")

      assert(client:call_no_return(echo_service, param))
      wait_for_log("log test!")

      
      local rpc, payloads = assert(client.service:encode_args(echo_service, param))
      local future = assert(client:send_encoded_call(rpc, payloads))
      assert.same(param, future:wait())
      wait_for_log("log test!")
    end)

    it("errors", function ()
      local future = require "kong.tools.wrpc.future"
      local client = new_pair()
      local param = { message = "log", }
      local rpc, payloads = assert(client.service:encode_args(echo_service, param))

      local response_future = future.new(client, client.timeout)
      client:send_payload({
        mtype = "MESSAGE_TYPE_RPC",
        svc_id = rpc.svc_id,
        rpc_id = rpc.rpc_id + 1,
        payload_encoding = "ENCODING_PROTO3",
        payloads = payloads,
      })
      assert.same({
        nil, "Invalid service (or rpc)"
      },{response_future:wait()})

      response_future = future.new(client, client.timeout)
      client:send_payload({
        mtype = "MESSAGE_TYPE_RPC",
        svc_id = rpc.svc_id + 1,
        rpc_id = rpc.rpc_id,
        payload_encoding = "ENCODING_PROTO3",
        payloads = payloads,
      })
      assert.same({
        nil, "Invalid service (or rpc)"
      },{response_future:wait()})

      local other_types = {
        "MESSAGE_TYPE_UNSPECIFIED",
        "MESSAGE_TYPE_STREAM_BEGIN",
        "MESSAGE_TYPE_STREAM_MESSAGE",
        "MESSAGE_TYPE_STREAM_END",
      }

      for _, typ in ipairs(other_types) do
        response_future = future.new(client, client.timeout)
        client:send_payload({
          mtype = typ,
          svc_id = rpc.svc_id,
          rpc_id = rpc.rpc_id,
          payload_encoding = "ENCODING_PROTO3",
          payloads = payloads,
        })

        assert.same({
          nil, "Unsupported message type"
        },{response_future:wait()})
      end

      -- those will mess up seq so must be put at the last
      client:send_payload({
        mtype = "MESSAGE_TYPE_ERROR",
        svc_id = rpc.svc_id,
        rpc_id = rpc.rpc_id,
        payload_encoding = "ENCODING_PROTO3",
        payloads = payloads,
      })
      wait_for_log("malformed wRPC message")
      
      client:send_payload({
        ack = 11,
        mtype = "MESSAGE_TYPE_ERROR",
        svc_id = rpc.svc_id,
        rpc_id = rpc.rpc_id,
        payload_encoding = "ENCODING_PROTO3",
        payloads = payloads,
      })
      wait_for_log("receiving error message for a call expired or not initiated by this peer.")
      
      client:send_payload({
        ack = 11,
        mtype = "MESSAGE_TYPE_ERROR",
        svc_id = rpc.svc_id,
        rpc_id = rpc.rpc_id + 1,
        payload_encoding = "ENCODING_PROTO3",
        payloads = payloads,
      })
      wait_for_log("receiving error message for a call expired or not initiated by this peer.", "receiving error message for unkonwn RPC")
    end)
  end)
end)
