dofile('tough.lua')
dofile('buffer.lua')

proxy = function(req, next)
  cookie = tough(req.cookie)
  data = buffer.load(req.data)
  url = req.url
  baseURL = req.baseURL

  res = {
    requestName = req.requestName,
    succ = true,
    data = buffer.dump(data),
    status = 200,
    statusText = 'OK',
    headers = {},
    cookie = cookie
  }
  next(res)
end