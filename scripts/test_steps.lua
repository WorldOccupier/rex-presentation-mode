local root = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
package.path = root .. "../?.lua;" .. package.path

local app = require("app")

local function check(name, ok)
  if not ok then error(name, 0) end
  print(name)
end

check("fourteen to twenty-four is ten points", app.steps(14, 24) == 10)
check("same size is zero", app.steps(24, 24) == 0)
check("larger than the target steps down", app.steps(30.2, 24) == -6)
check("half points round", app.steps(13.6, 18.2) == 4)
check("size clamps to the range", app.clamp(200) == app.MAX_SIZE)
check("small sizes clamp up", app.clamp(2) == app.MIN_SIZE)
check("size rejects a non-number", app.clamp("20") == nil)
