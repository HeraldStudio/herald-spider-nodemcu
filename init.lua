dofile('config.lua')

-- 各状态定义
STATE_INITIAL = 0
STATE_WIFI_CONNECTED = 1
STATE_WIFI_AUTHORIZED = 2
STATE_TOKEN_RECEIVED = 3
STATE_WS_CONNECTED = 4
STATE_WS_AUTHORIZED = 5
STATE_RETRY = 6

-- 当前状态
state = STATE_INITIAL
token = nil
ws = nil

-- 状态转换
transform = {}

-- 初始化操作
transform[STATE_INITIAL] = {
  enter = function()
    wifi.eventmon.register(wifi.eventmon.STA_CONNECTED, function(t)
      print('Wi-Fi 连接成功')
      wifi.eventmon.unregister(wifi.eventmon.STA_CONNECTED)
      wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, function(t)
        print('Wi-Fi 已分配 IP 地址：'..wifi.sta.getip())
        wifi.eventmon.unregister(wifi.eventmon.STA_GOT_IP)
        state = STATE_WIFI_CONNECTED
      end)
    end)
  end,
  run = function()
    wifi.setmode(wifi.STATION)
    wifi.sta.config({ ssid = 'seu-wlan' })
    wifi.sta.autoconnect(1)
  end,
  leave = function()
    wifi.eventmon.register(wifi.eventmon.STA_DISCONNECTED, function(t)
      print('Wi-Fi 连接断开')
      state = STATE_INITIAL
      wifi.eventmon.unregister(wifi.eventmon.STA_DISCONNECTED)
    end)
  end
}

-- SEU 登录
transform[STATE_WIFI_CONNECTED] = {
  run = function()
    http.post(
      'http://w.seu.edu.cn/index.php/index/login',
      'Content-Type: application/x-www-form-urlencoded\r\n',
      'username='..cardnum..'&password='..encoder.toBase64(password)..'&enablemacauth=1', function(_, res)
      local ok, res = pcall(sjson.decode, res)
      if (ok and (res.state ~= 0 or res.info == '用户已登录')) then
        print('Wi-Fi 认证成功')
        state = STATE_WIFI_AUTHORIZED
      else
        print('Wi-Fi 认证失败')
        state = STATE_RETRY
      end
    end)
  end
}

-- WS3 登录
transform[STATE_WIFI_AUTHORIZED] = {
  run = function()
    local data = sjson.encode({ cardnum = cardnum, password = password, platform = 'repl' })
    http.post('https://myseu.cn/ws3/auth', 'Content-Type: application/json\r\n', data, function(_, res)
      ok, res = pcall(sjson.decode, res)
      if (ok and res.code == 200) then
        print('Token 获取成功')
        token = res.result
        state = STATE_TOKEN_RECEIVED
      else
        print('Token 获取失败')
        state = STATE_RETRY
      end
    end)
  end
}


-- 连接 WS3 WebSocket 爬虫接口
transform[STATE_TOKEN_RECEIVED] = {
  enter = function()
    if (ws ~= nil) then ws.close() end
    ws = websocket.createClient()
  end,
  run = function()
    ws:connect('ws://myseu.cn:49034')
    ws:on('connection', function()
      print('WebSocket 连接成功')
      state = STATE_WS_CONNECTED
    end)
    ws:on('close', function()
      print('WebSocket 连接关闭')
      state = STATE_RETRY
    end)
  end,
  leave = function()
    ws:on('close', function()
      ws = nil
      print('WebSocket 连接关闭')
      state = STATE_TOKEN_RECEIVED
    end)
  end
}

-- WebSocket 认证
transform[STATE_WS_CONNECTED] = function()
  ws:send(sjson.encode({ token = token }))
  ws:on('receive', function(_, msg)
    if (msg == 'Auth_Success') then
      print('WebSocket 认证成功')
      state = STATE_WS_AUTHORIZED
    elseif (msg == 'Auth_Fail') then
      print('WebSocket 认证失败')
      state = STATE_TOKEN_RECEIVED
      ws:close()
    end
  end)
end

-- WebSocket 接受爬虫请求
heartbeat = tmr.create()
transform[STATE_WS_AUTHORIZED] = {
  enter = function()
    heartbeat:alarm(3000, tmr.ALARM_AUTO, function()
      ws:send('@herald—spider')
    end)
  end,
  run = function()
    ws:on('receive', function(_, msg)
      local ok, msg = pcall(sjson.decode, msg)
      if (ok) then
        -- 模拟 axios 的行为；暂无实现
        print(msg.requestName)
        print(msg.method)
        print(msg.url)
        print(msg.data.data)
        print(msg.cookie)
      end
    end)
  end,
  leave = function()
    heartbeat:unregister()
  end
}

-- 状态机控制器
-- 每 100ms 进行脏状态检查
-- 若状态改变，执行旧状态移出函数、新状态移入函数、新状态运行函数
-- 若状态变为 retry，恢复原状态，并再次执行原状态运行函数
prevState = -1
tmr.create():alarm(100, tmr.ALARM_AUTO, function()
  if (prevState ~= state) then
    if (state ~= STATE_RETRY) then
      if (transform[prevState] ~= nil and transform[prevState].leave ~= nil) then
        transform[prevState].leave()
      end
      prevState = state
      if (transform[state] ~= nil and transform[state].enter ~= nil) then
        transform[state].enter()
      end
    else
      state = prevState
    end
    if (transform[state] ~= nil and transform[state].run ~= nil) then
      transform[state].run()
    elseif (transform[state] ~= nil) then
      transform[state]()
    end
  end
end)