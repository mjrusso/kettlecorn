processed = 0

function transform(event)
  local total = 0
  for _, item in ipairs(event.items) do
    total = total + item.unit_price_cents * item.quantity
  end

  local route = "standard"
  if total >= 10000 then
    route = "priority"
  end

  processed = processed + 1
  return event.id, total, route, processed
end
