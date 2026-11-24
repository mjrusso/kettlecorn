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

function receipt(event, issued_at, code)
  local valid_until = issued_at + 30 * 24 * 60 * 60
  return event.id, issued_at, valid_until, code
end
