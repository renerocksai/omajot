# Lighthouse API sketch

One reading as it arrives from a sensor:

```json
{
  "site": "north-3",
  "sensor": "temp-12",
  "at": "2026-09-14T08:30:00Z",
  "value": 21.4
}
```

Endpoints:

- `POST /readings`: a batch of readings, at most 1 MiB
- `GET /sites/{id}/latest`: the last reading per sensor

#lighthouse #api
